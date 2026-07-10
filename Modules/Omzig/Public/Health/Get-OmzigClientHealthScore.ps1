function Get-OmzigClientHealthScore {
    <#
    .SYNOPSIS
    Client Health Score v1 (§7.1): a 0-100 weighted composite over the
    signals fused in the single-pane tenant view.

    .DESCRIPTION
    Pure function over a metrics object so it is unit-testable and every
    surface (portal, vCIO decks, client portal trend) computes identically.
    Missing signals are excluded and the remaining weights renormalized, so a
    tenant without (say) backup telemetry is scored on what we can see rather
    than silently penalized.

    Weights (v1):
      securescore 25%, patch compliance 20%, MFA coverage 20%,
      backup success 15%, ticket load 10%, licensing efficiency 10%.

    .PARAMETER Metrics
    Object/hashtable with any of: SecureScorePercent, PatchCompliancePercent,
    MfaCoveragePercent, BackupSuccessPercent (0-100), OpenTicketsPerUser
    (0 tickets/user = 100, 1+/user = 0), LicenseUtilizationPercent.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Metrics
    )

    if ($Metrics -is [hashtable]) { $Metrics = [PSCustomObject]$Metrics }

    $Clamp = { param($v) [math]::Max(0, [math]::Min(100, [double]$v)) }

    $Components = [System.Collections.Generic.List[object]]::new()
    $Add = {
        param($Name, $Weight, $Value)
        if ($null -ne $Value) {
            $Components.Add([PSCustomObject]@{ Name = $Name; Weight = $Weight; Value = (& $Clamp $Value) })
        }
    }

    & $Add 'SecureScore' 0.25 $Metrics.SecureScorePercent
    & $Add 'PatchCompliance' 0.20 $Metrics.PatchCompliancePercent
    & $Add 'MfaCoverage' 0.20 $Metrics.MfaCoveragePercent
    & $Add 'BackupSuccess' 0.15 $Metrics.BackupSuccessPercent
    if ($null -ne $Metrics.OpenTicketsPerUser) {
        & $Add 'TicketLoad' 0.10 ((1 - [math]::Min(1, [double]$Metrics.OpenTicketsPerUser)) * 100)
    }
    & $Add 'LicenseEfficiency' 0.10 $Metrics.LicenseUtilizationPercent

    if ($Components.Count -eq 0) {
        return [PSCustomObject]@{ Score = $null; Components = @(); Message = 'No telemetry available yet.' }
    }

    $TotalWeight = ($Components | Measure-Object -Property Weight -Sum).Sum
    $Score = 0
    foreach ($C in $Components) {
        $Score += $C.Value * ($C.Weight / $TotalWeight)
    }

    [PSCustomObject]@{
        Score      = [int][math]::Round($Score)
        Components = $Components
    }
}
