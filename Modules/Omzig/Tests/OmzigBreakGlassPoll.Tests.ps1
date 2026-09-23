# Pester suite for the break-glass poller, alert dispatcher and Teams card (§7.5).
# Self-contained: CIPP helpers are stubbed, then mocked; nothing touches the network.

BeforeAll {
    # CIPP-API helpers the overlay calls. They are not loaded in a bare test run, and
    # Pester can only mock a command that exists, so define no-op stubs first.
    $Stubs = @{
        'Get-CIPPTable'             = '[CmdletBinding()] param($tablename)'
        'Get-CIPPAzDataTableEntity' = '[CmdletBinding()] param($Context, $Filter, $Property, $First, $Skip)'
        'Add-CIPPAzDataTableEntity' = '[CmdletBinding()] param($Context, $Entity, [switch]$Force, [switch]$CreateTableIfNotExists, $OperationType)'
        'Remove-AzDataTableEntity'  = '[CmdletBinding()] param($Context, $Entity)'
        'Get-Tenants'               = '[CmdletBinding()] param([switch]$IncludeAll, [switch]$IncludeErrors, $TenantFilter)'
        'New-GraphGetRequest'       = '[CmdletBinding()] param($uri, $tenantid, $AsApp, $noPagination)'
        'Write-LogMessage'          = '[CmdletBinding()] param($message, $tenant, $API, $tenantId, $headers, $user, $sev, $LogData)'
        'Send-CIPPAlert'            = '[CmdletBinding()] param($Type, $Title, $HTMLContent, $JSONContent, $TenantFilter, $altEmail, $altWebhook, $APIName)'
        'Get-CippKeyVaultSecret'    = '[CmdletBinding()] param($VaultName, $Name, [switch]$AsPlainText)'
    }
    foreach ($Name in $Stubs.Keys) {
        if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$Name" -Value ([scriptblock]::Create($Stubs[$Name]))
        }
    }
    Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force

    $script:Now = [datetime]::new(2026, 10, 1, 12, 0, 0, [DateTimeKind]::Utc)
    $script:Tenant = [pscustomobject]@{ defaultDomainName = 'contoso.com'; customerId = 'cust-1'; initialDomainName = 'contoso.onmicrosoft.com' }
    function global:New-SignIn([string]$Id, [string]$Upn, [int]$ErrorCode = 0, [string]$When = '2026-10-01T11:55:00Z') {
        [pscustomobject]@{ id = $Id; userPrincipalName = $Upn; createdDateTime = $When; appDisplayName = 'Azure Portal'
            ipAddress = '203.0.113.10'; status = [pscustomobject]@{ errorCode = $ErrorCode; failureReason = $(if ($ErrorCode) { 'Invalid password' }) } }
    }
}

Describe 'New-OmzigTeamsCard' {
    It 'builds a Workflows-compatible Adaptive Card message, not the retired { text } body' {
        $Msg = New-OmzigTeamsCard -Title 'T' -Severity 'P1' -Summary 'S' -Facts ([ordered]@{ A = 1; B = 'two' }) -LinkUrl 'https://x'
        $Msg.type | Should -Be 'message'
        $Msg.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $Card = $Msg.attachments[0].content
        $Card.type | Should -Be 'AdaptiveCard'
        $Card.body[0].color | Should -Be 'attention'
        ($Card.body | Where-Object type -EQ 'FactSet').facts.title | Should -Be @('A', 'B')
        $Card.actions[0].url | Should -Be 'https://x'
        $Msg.Keys | Should -Not -Contain 'text'
    }
    It 'serialises to JSON without losing the card' {
        $Json = New-OmzigTeamsCard -Title 'T' | ConvertTo-Json -Depth 20 -Compress
        ($Json | ConvertFrom-Json).attachments[0].content.version | Should -Be '1.4'
    }
}

Describe 'Send-OmzigAlert' {
    BeforeEach {
        Mock -ModuleName Omzig Write-LogMessage { }
        Mock -ModuleName Omzig Send-CIPPAlert { }
        Mock -ModuleName Omzig Invoke-OmzigRestWithRetry { }
        Mock -ModuleName Omzig Get-OmzigPsaClient { [pscustomobject]@{ NewTicket = { param($t) } } }
    }
    It 'sends to Logbook, Teams and email, and the result never contains the webhook URL' {
        Mock -ModuleName Omzig Get-OmzigTeamsWebhook { 'https://example.invalid/webhook/SECRET-TOKEN' }
        $R = Send-OmzigAlert -Severity 'P1' -Title 'T' -Message 'M' -Facts ([ordered]@{ Tenant = 'contoso.com' })
        $R.Logbook | Should -Be 'sent'
        $R.Teams | Should -Be 'sent'
        $R.Email | Should -Match '^sent to '
        $R.Psa | Should -Be 'sent'
        ($R | ConvertTo-Json) | Should -Not -Match 'SECRET-TOKEN'
        Should -Invoke -ModuleName Omzig Invoke-OmzigRestWithRetry -Times 1 -ParameterFilter {
            ($RequestSplat.Body | ConvertFrom-Json).attachments[0].contentType -eq 'application/vnd.microsoft.card.adaptive'
        }
    }
    It 'reports Teams as not configured instead of failing when there is no webhook' {
        Mock -ModuleName Omzig Get-OmzigTeamsWebhook { $null }
        $R = Send-OmzigAlert -Severity 'Test' -Title 'T' -Message 'M' -SkipPsa
        $R.Teams | Should -Be 'not configured'
        $R.Logbook | Should -Be 'sent'
        $R.Psa | Should -Be 'not applicable'
    }
    It 'keeps going when one channel throws' {
        Mock -ModuleName Omzig Get-OmzigTeamsWebhook { 'https://example.invalid/hook' }
        Mock -ModuleName Omzig Invoke-OmzigRestWithRetry { throw 'Teams is down' }
        $R = Send-OmzigAlert -Severity 'P1' -Title 'T' -Message 'M'
        $R.Teams | Should -Match '^failed: Teams is down'
        $R.Email | Should -Match '^sent to '
        $R.Logbook | Should -Be 'sent'
    }
    It 'only opens a PSA ticket for P1' {
        Mock -ModuleName Omzig Get-OmzigTeamsWebhook { $null }
        (Send-OmzigAlert -Severity 'Critical' -Title 'T' -Message 'M').Psa | Should -Be 'not applicable'
    }
}

Describe 'Invoke-OmzigBreakGlassSentinel outcome' {
    It 'flags a failed attempt as FAILED, not as a sign-in' {
        $A = Invoke-OmzigBreakGlassSentinel -TenantFilter 'contoso.com' -InitialDomain 'contoso.onmicrosoft.com' `
            -SignIns @(New-SignIn 'x1' 'bg01@contoso.onmicrosoft.com' 50126) -AlertAction { }
        $A[0].Outcome | Should -Match '^FAILED \(error 50126'
        $A[0].Message | Should -Match 'failed sign-in attempt'
    }
    It 'sends through Send-OmzigAlert when no AlertAction is given' {
        Mock -ModuleName Omzig Send-OmzigAlert { [pscustomobject]@{ Teams = 'sent' } }
        $A = Invoke-OmzigBreakGlassSentinel -TenantFilter 'contoso.com' -InitialDomain 'contoso.onmicrosoft.com' `
            -SignIns @(New-SignIn 'x2' 'bg02@contoso.onmicrosoft.com')
        $A[0].Outcome | Should -Be 'SUCCEEDED'
        $A[0].Delivery.Teams | Should -Be 'sent'
        Should -Invoke -ModuleName Omzig Send-OmzigAlert -Times 1 -ParameterFilter { $Severity -eq 'P1' }
    }
}

Describe 'Invoke-OmzigBreakGlassPoll' {
    BeforeEach {
        $script:Written = [System.Collections.Generic.List[object]]::new()
        $script:SeenIds = @()
        $script:LastChecked = $null
        $script:WindowRows = @()
        $script:GraphUris = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Omzig Get-CIPPTable { @{ Context = $tablename } }
        Mock -ModuleName Omzig Get-Tenants { @($script:Tenant) }
        Mock -ModuleName Omzig Add-CIPPAzDataTableEntity { $script:Written.Add($Entity) }
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity {
            switch ($Context) {
                'OmzigSentinelState' { if ($script:LastChecked) { [pscustomobject]@{ LastChecked = $script:LastChecked } } }
                'OmzigBreakGlassSeen' { if ($Filter -match "RowKey eq '([^']+)'" -and $Matches[1] -in $script:SeenIds) { [pscustomobject]@{ RowKey = $Matches[1] } } }
                'OmzigIncidentWindows' { $script:WindowRows }
            }
        }
        Mock -ModuleName Omzig Invoke-OmzigBreakGlassSentinel { @($SignIns | ForEach-Object { [pscustomobject]@{ SignInId = $_.id } }) }
        $env:TenantID = $null
    }

    It 'looks back one hour on the first run and filters on the bg01/bg02 accounts' {
        Mock -ModuleName Omzig New-GraphGetRequest { $script:GraphUris.Add($uri); @() }
        $null = Invoke-OmzigBreakGlassPoll -Now $script:Now
        $Uri = [uri]::UnescapeDataString($script:GraphUris[0])
        $Uri | Should -Match 'createdDateTime ge 2026-10-01T11:00:00Z'
        $Uri | Should -Match "startsWith\(userPrincipalName,'bg01@'\)"
        $Uri | Should -Match "startsWith\(userPrincipalName,'bg02@'\)"
    }

    It 'reads from the last check minus the overlap afterwards' {
        $script:LastChecked = '2026-10-01T11:55:00.0000000Z'
        Mock -ModuleName Omzig New-GraphGetRequest { $script:GraphUris.Add($uri); @() }
        $null = Invoke-OmzigBreakGlassPoll -Now $script:Now -OverlapMinutes 20
        [uri]::UnescapeDataString($script:GraphUris[0]) | Should -Match 'createdDateTime ge 2026-10-01T11:35:00Z'
    }

    It 'alerts on new sign-ins and records them so the overlap never double-alerts' {
        Mock -ModuleName Omzig New-GraphGetRequest { @(New-SignIn 's1' 'bg01@contoso.onmicrosoft.com'), (New-SignIn 's2' 'bg02@contoso.onmicrosoft.com') }
        $script:SeenIds = @('s1')
        $R = Invoke-OmzigBreakGlassPoll -Now $script:Now
        $R.SignIns | Should -Be 2
        $R.NewSignIns | Should -Be 1
        Should -Invoke -ModuleName Omzig Invoke-OmzigBreakGlassSentinel -Times 1 -ParameterFilter { $SignIns.Count -eq 1 -and $SignIns[0].id -eq 's2' }
        ($script:Written | Where-Object { $_.RowKey -eq 's2' }) | Should -Not -BeNullOrEmpty
        ($script:Written | Where-Object { $_.PartitionKey -eq 'BreakGlass' }).LastResult | Should -Be 'ok'
    }

    It 'passes declared incident windows through, keyed by tenant domain' {
        $script:WindowRows = @([pscustomobject]@{ PartitionKey = 'contoso.com'; Start = '2026-10-01T11:00:00Z'; End = '2026-10-01T13:00:00Z' })
        Mock -ModuleName Omzig New-GraphGetRequest { @(New-SignIn 's3' 'bg01@contoso.onmicrosoft.com') }
        $null = Invoke-OmzigBreakGlassPoll -Now $script:Now
        Should -Invoke -ModuleName Omzig Invoke-OmzigBreakGlassSentinel -Times 1 -ParameterFilter { $IncidentWindows.Count -eq 1 -and $IncidentWindows[0].TenantId -eq 'contoso.com' }
    }

    It 'reports a tenant without sign-in logs instead of treating it as clean' {
        Mock -ModuleName Omzig New-GraphGetRequest { throw 'Neither tenant is B2C or tenant doesn''t have premium license' }
        $R = Invoke-OmzigBreakGlassPoll -Now $script:Now
        $R.NoSignInLogs | Should -Contain 'contoso.com'
        ($script:Written | Where-Object { $_.PartitionKey -eq 'BreakGlass' }).LastResult | Should -Match 'Entra ID P1'
    }

    It 'does not advance the checkpoint after a transient error, so the window is re-read' {
        Mock -ModuleName Omzig New-GraphGetRequest { throw 'The operation timed out' }
        $R = Invoke-OmzigBreakGlassPoll -Now $script:Now
        $R.Errors.Count | Should -Be 1
        ($script:Written | Where-Object { $_.PartitionKey -eq 'BreakGlass' }) | Should -BeNullOrEmpty
    }

    It 'includes the partner tenant, where Omzig''s own break-glass accounts live' {
        $env:TenantID = 'partner-tenant-id'
        Mock -ModuleName Omzig New-GraphGetRequest { $script:GraphUris.Add($tenantid); @() }
        $R = Invoke-OmzigBreakGlassPoll -Now $script:Now
        $R.Tenants | Should -Be 2
        $script:GraphUris | Should -Contain 'partner-tenant-id'
        $env:TenantID = $null
    }
}

Describe 'Receive-OmzigSentinelTimer self-test' {
    It 'sends a TEST alert once, clears the request and records the result' {
        Mock -ModuleName Omzig Get-CIPPTable { @{ Context = $tablename } }
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity { [pscustomobject]@{ PartitionKey = 'SelfTest'; RowKey = 'Pending'; RequestedBy = 'claude' } }
        Mock -ModuleName Omzig Send-OmzigAlert { [pscustomobject]@{ Logbook = 'sent'; Teams = 'sent'; Email = 'sent to x'; Psa = 'not applicable' } }
        Mock -ModuleName Omzig Remove-AzDataTableEntity { }
        $script:Recorded = $null
        Mock -ModuleName Omzig Add-CIPPAzDataTableEntity { $script:Recorded = $Entity }
        Mock -ModuleName Omzig Invoke-OmzigBreakGlassPoll { }
        Receive-OmzigSentinelTimer -Timer $null
        Should -Invoke -ModuleName Omzig Send-OmzigAlert -Times 1 -ParameterFilter { $Severity -eq 'Test' -and $SkipPsa }
        Should -Invoke -ModuleName Omzig Remove-AzDataTableEntity -Times 1
        $script:Recorded.RowKey | Should -Be 'LastResult'
        Should -Invoke -ModuleName Omzig Invoke-OmzigBreakGlassPoll -Times 1
    }
}
