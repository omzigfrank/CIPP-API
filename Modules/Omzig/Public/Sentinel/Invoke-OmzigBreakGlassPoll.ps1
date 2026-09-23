function Invoke-OmzigBreakGlassPoll {
    <#
    .SYNOPSIS
    The scheduled poller behind the Break-Glass Sentinel (§7.5): reads recent
    break-glass sign-ins from every managed tenant and hands new ones to
    Invoke-OmzigBreakGlassSentinel.
    .DESCRIPTION
    Runs every 5 minutes from the OmzigSentinelTimer function. Per tenant:
      - queries Graph auditLogs/signIns for bg01@ / bg02@ accounts since the last
        check, minus an overlap, because sign-in logs arrive minutes late
      - drops sign-ins already alerted (OmzigBreakGlassSeen table), so the overlap
        never double-alerts
      - applies declared incident windows (OmzigIncidentWindows table)
      - records the check (OmzigSentinelState table)
    Sign-in logs need Entra ID P1 or higher in the customer tenant and a GDAP role
    that can read them. Tenants without either are counted and reported, never
    silently treated as clean.

    Declare an incident window so planned break-glass use does not page anyone:
      Add-CIPPAzDataTableEntity @(Get-CIPPTable -tablename OmzigIncidentWindows) -Entity @{
        PartitionKey = '<tenant default domain>'; RowKey = [guid]::NewGuid().ToString()
        Start = '2026-10-01T14:00:00Z'; End = '2026-10-01T16:00:00Z'; Reason = 'ticket 12345' }
    .PARAMETER TenantFilter
    Optional default domains to limit the poll to (tests and manual runs).
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$TenantFilter,
        [int]$FirstRunLookbackMinutes = 60,
        [int]$OverlapMinutes = 20,
        [datetime]$Now = [datetime]::UtcNow
    )

    $StateTable = Get-CIPPTable -tablename 'OmzigSentinelState'
    $SeenTable = Get-CIPPTable -tablename 'OmzigBreakGlassSeen'
    $WindowTable = Get-CIPPTable -tablename 'OmzigIncidentWindows'

    $Tenants = [System.Collections.Generic.List[object]]::new()
    foreach ($T in @(Get-Tenants)) { $Tenants.Add($T) }
    # The partner tenant holds Omzig's own break-glass accounts; Get-Tenants lists customers only.
    if ($env:TenantID -and -not ($Tenants | Where-Object { $_.customerId -eq $env:TenantID })) {
        $Tenants.Add([pscustomobject]@{ defaultDomainName = $env:TenantID; customerId = $env:TenantID; initialDomainName = $null; displayName = 'Partner tenant' })
    }
    if ($TenantFilter) {
        $Tenants = @($Tenants | Where-Object { $_.defaultDomainName -in $TenantFilter -or $_.customerId -in $TenantFilter })
    }

    $Windows = @(Get-CIPPAzDataTableEntity @WindowTable | Where-Object { $_.End -and ([datetime]$_.End) -gt $Now.AddDays(-2) } |
            ForEach-Object { [pscustomobject]@{ TenantId = $_.PartitionKey; Start = [datetime]$_.Start; End = [datetime]$_.End } })

    $Summary = [ordered]@{
        Tenants = $Tenants.Count; Checked = 0; SignIns = 0; NewSignIns = 0; Alerts = 0
        NoSignInLogs = [System.Collections.Generic.List[string]]::new()
        Denied = [System.Collections.Generic.List[string]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($Tenant in $Tenants) {
        $Key = [string]$Tenant.customerId
        $State = Get-CIPPAzDataTableEntity @StateTable -Filter "PartitionKey eq 'BreakGlass' and RowKey eq '$Key'"
        $Since = if ($State.LastChecked) {
            ([datetime]$State.LastChecked).ToUniversalTime().AddMinutes(-$OverlapMinutes)
        } else {
            $Now.AddMinutes(-$FirstRunLookbackMinutes)
        }
        $Filter = "createdDateTime ge $($Since.ToString('yyyy-MM-ddTHH:mm:ssZ')) and " +
        "(startsWith(userPrincipalName,'bg01@') or startsWith(userPrincipalName,'bg02@'))"
        $Uri = 'https://graph.microsoft.com/v1.0/auditLogs/signIns?$filter=' + [uri]::EscapeDataString($Filter) +
        '&$select=id,userPrincipalName,createdDateTime,appDisplayName,ipAddress,status&$top=100'

        $LastResult = 'ok'
        # -ErrorAction Stop matters: CIPP's Graph helper reports some refusals with a
        # NON-terminating Write-Error, which would otherwise return nothing and let an
        # unread tenant be counted as checked and clean. The partner tenant is not in
        # CIPP's customer list, so CIPP itself reads it with -NoAuthCheck.
        $GraphArgs = @{ uri = $Uri; tenantid = $Tenant.defaultDomainName; ErrorAction = 'Stop' }
        if ($Tenant.customerId -eq $env:TenantID) { $GraphArgs.NoAuthCheck = $true }
        try {
            $SignIns = @(New-GraphGetRequest @GraphArgs)
        } catch {
            $Err = [string]$_.Exception.Message
            if ($Err -match 'premium|NonPremium|B2C') {
                $Summary.NoSignInLogs.Add($Tenant.defaultDomainName); $LastResult = 'no sign-in logs (needs Entra ID P1)'
            } elseif ($Err -match '403|Forbidden|Authorization_RequestDenied|Insufficient privileges|not in the allowed roles') {
                $Summary.Denied.Add($Tenant.defaultDomainName); $LastResult = 'access denied (GDAP role cannot read sign-in logs)'
            } else {
                # Transient: leave LastChecked alone so this window is read again next run.
                $Summary.Errors.Add("$($Tenant.defaultDomainName): $Err")
                continue
            }
            $SignIns = @()
        }
        $Summary.Checked++
        $Summary.SignIns += $SignIns.Count

        $New = @(foreach ($S in $SignIns) {
                if (-not $S.id) { $S; continue }
                $Seen = Get-CIPPAzDataTableEntity @SeenTable -Filter "PartitionKey eq '$Key' and RowKey eq '$($S.id)'"
                if (-not $Seen) { $S }
            })
        $Summary.NewSignIns += $New.Count

        if ($New.Count -gt 0 -and $PSCmdlet.ShouldProcess($Tenant.defaultDomainName, "Evaluate $($New.Count) break-glass sign-in(s)")) {
            $Alerts = @(Invoke-OmzigBreakGlassSentinel -TenantFilter $Tenant.defaultDomainName -SignIns $New `
                    -IncidentWindows $Windows -InitialDomain $Tenant.initialDomainName)
            $Summary.Alerts += $Alerts.Count
            foreach ($S in $New | Where-Object { $_.id }) {
                Add-CIPPAzDataTableEntity @SeenTable -Force -Entity @{
                    PartitionKey = $Key; RowKey = [string]$S.id
                    Account = [string]$S.userPrincipalName; At = [string]$S.createdDateTime
                }
            }
        }

        Add-CIPPAzDataTableEntity @StateTable -Force -Entity @{
            PartitionKey = 'BreakGlass'; RowKey = $Key
            Tenant = [string]$Tenant.defaultDomainName; LastChecked = $Now.ToString('o'); LastResult = $LastResult
        }
    }

    $Out = [pscustomobject]$Summary
    Write-Information ('OmzigSentinel break-glass poll: ' + ($Out | ConvertTo-Json -Compress -Depth 3))
    return $Out
}
