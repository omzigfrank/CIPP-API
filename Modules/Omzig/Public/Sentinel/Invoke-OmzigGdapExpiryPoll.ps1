function Invoke-OmzigGdapExpiryPoll {
    <#
    .SYNOPSIS
    The scheduled poller behind the GDAP Expiry Sentinel (§7.6): reads every GDAP
    relationship from the partner tenant and alerts on the ones about to lapse.
    .DESCRIPTION
    Runs daily from the OmzigGdapSentinelTimer function. Each relationship alerts
    once per threshold (60 / 30 / 7 days left, table OmzigGdapAlerted), not every
    day for two months, so the alerts stay worth reading. Severity escalates:
    60 days = Warning, 30 = Critical, 7 = P1 (which also opens a PSA ticket).
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [datetime]$Now = [datetime]::UtcNow
    )

    $AlertedTable = Get-CIPPTable -tablename 'OmzigGdapAlerted'

    # Relationships live in the partner tenant, which is not in CIPP's customer list,
    # so -NoAuthCheck; -ErrorAction Stop so a refusal can never read as "none expiring".
    $Relationships = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships' `
            -tenantid $env:TenantID -NoAuthCheck $true -ErrorAction Stop)

    $Findings = @(Invoke-OmzigGdapExpirySentinel -Relationships $Relationships -Now $Now | Where-Object Type -EQ 'GdapExpiry')

    $Summary = [ordered]@{
        Relationships = $Relationships.Count
        Active        = @($Relationships | Where-Object status -EQ 'active').Count
        Expiring      = $Findings.Count
        Alerted       = 0
        Soonest       = $null
    }
    if ($Findings.Count) {
        $S = $Findings | Sort-Object DaysLeft | Select-Object -First 1
        $Summary.Soonest = "$($S.Customer): $($S.DaysLeft) days"
    }

    foreach ($F in $Findings) {
        $RowKey = '{0}|{1}' -f $F.RelationshipId, $F.Threshold
        if (Get-CIPPAzDataTableEntity @AlertedTable -Filter "PartitionKey eq 'GdapExpiry' and RowKey eq '$RowKey'") { continue }
        if (-not $PSCmdlet.ShouldProcess($F.DisplayName, "Alert: GDAP expires in $($F.DaysLeft) days")) { continue }

        $Severity = switch ($F.Severity) { 'P1' { 'P1' } 'P2' { 'Critical' } default { 'Warning' } }
        $Facts = [ordered]@{
            Customer        = $F.Customer
            Relationship    = $F.DisplayName
            'Ends (UTC)'    = ([datetime]$F.EndDateTime).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
            'Days left'     = $F.DaysLeft
            'Auto-extend'   = 'No - this relationship will lapse unless renewed'
            'Relationship ID' = $F.RelationshipId
        }
        $null = Send-OmzigAlert -Severity $Severity -TenantFilter 'None' -Facts $Facts `
            -Title "GDAP expires in $($F.DaysLeft) days - $($F.Customer)" `
            -Message "CIPP loses the roles in '$($F.DisplayName)' for $($F.Customer) when it lapses. Create a replacement in CIPP (Tenant Administration > GDAP) and get the customer's Global Admin to accept it before then."
        Add-CIPPAzDataTableEntity @AlertedTable -Force -Entity @{
            PartitionKey = 'GdapExpiry'; RowKey = $RowKey
            Customer = [string]$F.Customer; DaysLeft = [int]$F.DaysLeft; At = $Now.ToString('o')
        }
        $Summary.Alerted++
    }

    $Out = [pscustomobject]$Summary
    Write-Information ('OmzigSentinel GDAP expiry poll: ' + ($Out | ConvertTo-Json -Compress))
    return $Out
}
