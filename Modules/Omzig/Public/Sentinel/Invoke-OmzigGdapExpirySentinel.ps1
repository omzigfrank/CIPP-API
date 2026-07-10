function Invoke-OmzigGdapExpirySentinel {
    <#
    .SYNOPSIS
    GDAP Drift / Expiry Sentinel (§7.6): flags relationships expiring in
    60 / 30 / 7 days and relationships missing Omzig-required roles.

    .PARAMETER Relationships
    Graph delegatedAdminRelationship objects (id, displayName, status,
    endDateTime, accessDetails.unifiedRoles). Injected by the scheduled
    poller; supplied directly in tests.

    .PARAMETER RequiredRoleIds
    Roles every Omzig relationship must carry (defaults to the vertical
    bundle baseline check performed upstream; pass explicitly for drift
    detection against a specific bundle).

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Relationships,
        [datetime]$Now = (Get-Date),
        [array]$RequiredRoleIds = @()
    )

    $Thresholds = @(60, 30, 7)
    $Findings = [System.Collections.Generic.List[object]]::new()

    foreach ($Rel in $Relationships) {
        if ($Rel.status -ne 'active') { continue }
        $DaysLeft = [math]::Floor(([datetime]$Rel.endDateTime - $Now).TotalDays)

        $Threshold = $Thresholds | Where-Object { $DaysLeft -le $_ } | Select-Object -Last 1
        if ($null -ne $Threshold) {
            $Findings.Add([PSCustomObject]@{
                    Type           = 'GdapExpiry'
                    RelationshipId = $Rel.id
                    DisplayName    = $Rel.displayName
                    DaysLeft       = $DaysLeft
                    Threshold      = $Threshold
                    Severity       = if ($DaysLeft -le 7) { 'P1' } elseif ($DaysLeft -le 30) { 'P2' } else { 'P3' }
                    Message        = "GDAP relationship '$($Rel.displayName)' expires in $DaysLeft days. One-click renew from the GDAP page."
                })
        }

        if ($RequiredRoleIds.Count -gt 0) {
            $PresentRoles = @($Rel.accessDetails.unifiedRoles.roleDefinitionId)
            $MissingRoles = @($RequiredRoleIds | Where-Object { $_ -notin $PresentRoles })
            if ($MissingRoles.Count -gt 0) {
                $Findings.Add([PSCustomObject]@{
                        Type           = 'GdapRoleDrift'
                        RelationshipId = $Rel.id
                        DisplayName    = $Rel.displayName
                        Severity       = 'P2'
                        MissingRoles   = $MissingRoles
                        Message        = "GDAP relationship '$($Rel.displayName)' is missing $($MissingRoles.Count) Omzig-required role(s)."
                    })
            }
        }
    }

    return $Findings
}
