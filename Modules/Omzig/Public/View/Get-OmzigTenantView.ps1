function Get-OmzigTenantView {
    <#
    .SYNOPSIS
    Assembles the ŌMZIG single-pane tenant view (§7.1): the Omzig tenant
    record fused with live PSA and Datto RMM signals plus the Client Health
    Score.

    .DESCRIPTION
    Every external integration is individually try/caught so one dead
    integration (Autotask down, Datto RMM site unmapped, etc.) never kills
    the rest of the view. When an integration isn't configured or a call
    fails, its section degrades to @{ available = $false; reason = '...' }
    instead of throwing.

    The Client Health Score is recomputed from whatever telemetry is
    available (currently patch compliance from Datto device data) and is
    persisted back onto the tenant record via Set-OmzigTenantRecord, but
    only when the score actually changed — repeated view loads don't spam
    table storage with no-op writes.

    .PARAMETER TenantId
    The Omzig/CIPP tenant identifier (RowKey of the OmzigTenants table).

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId
    )

    $Record = Get-OmzigTenantRecord -TenantId $TenantId

    # --- PSA (Autotask) section --------------------------------------------------
    # Autotask status code 5 is "Complete" — everything else counts as open.
    $AutotaskCompleteStatus = 5
    $Devices = $null

    if ($Record.psa -and $Record.psa.companyId) {
        try {
            if ([string]::IsNullOrEmpty($env:AUTOTASK_USERNAME) -or
                [string]::IsNullOrEmpty($env:AUTOTASK_SECRET) -or
                [string]::IsNullOrEmpty($env:AUTOTASK_INTEGRATION_CODE)) {
                throw 'Autotask credentials are not configured. Run Test-OmzigPreflight.'
            }

            $Psa = Get-OmzigPsaClient
            $Tickets = @(& $Psa.GetTickets -CompanyId $Record.psa.companyId)
            $Contracts = @(& $Psa.GetContracts -CompanyId $Record.psa.companyId)
            $OpenTickets = @($Tickets | Where-Object { $_.status -ne $AutotaskCompleteStatus })

            $PsaView = [PSCustomObject]@{
                available       = $true
                openTicketCount = $OpenTickets.Count
                contractCount   = $Contracts.Count
                contracts       = @($Contracts | ForEach-Object {
                        [PSCustomObject]@{
                            id           = $_.id
                            contractName = $_.contractName
                            status       = $_.status
                            endDate      = $_.endDate
                        }
                    })
            }
        } catch {
            $PsaView = [PSCustomObject]@{ available = $false; reason = $_.Exception.Message }
        }
    } else {
        $PsaView = [PSCustomObject]@{ available = $false; reason = 'No PSA company mapped for this tenant.' }
    }

    # --- RMM (Datto) section -----------------------------------------------------
    if ($Record.rmm -and $Record.rmm.siteId) {
        try {
            $Devices = @(Get-OmzigDattoDevices -SiteUid $Record.rmm.siteId)
            $Alerts = @(Get-OmzigDattoAlerts -SiteUid $Record.rmm.siteId)
            $OnlineDevices = @($Devices | Where-Object { $_.online -eq $true })

            $RmmView = [PSCustomObject]@{
                available      = $true
                deviceCount    = $Devices.Count
                onlineCount    = $OnlineDevices.Count
                offlineCount   = $Devices.Count - $OnlineDevices.Count
                openAlertCount = $Alerts.Count
            }
        } catch {
            $Devices = $null
            $RmmView = [PSCustomObject]@{ available = $false; reason = $_.Exception.Message }
        }
    } else {
        $RmmView = [PSCustomObject]@{ available = $false; reason = 'No Datto RMM site mapped for this tenant.' }
    }

    # --- Client Health Score (§7.1) -----------------------------------------------
    # Only the signals we can currently source feed the composite; everything
    # else is omitted so Get-OmzigClientHealthScore renormalizes around it.
    $Metrics = @{}
    try {
        if ($Devices -and $Devices.Count -gt 0) {
            $PatchedDevices = @($Devices | Where-Object { $_.patchManagement.patchStatus -eq 'FullyPatched' })
            $Metrics.PatchCompliancePercent = [math]::Round(($PatchedDevices.Count / $Devices.Count) * 100, 0)
        }
    } catch {
        # Patch telemetry shape surprised us — leave PatchCompliancePercent unset
        # rather than let a malformed device record kill the whole view.
    }

    try {
        $HealthScore = Get-OmzigClientHealthScore -Metrics $Metrics
    } catch {
        $HealthScore = [PSCustomObject]@{
            Score      = $null
            Components = @()
            Message    = "Health score computation failed: $($_.Exception.Message)"
        }
    }

    if ($Record.healthScore -ne $HealthScore.Score) {
        try {
            $Record = Set-OmzigTenantRecord -TenantId $TenantId -Properties @{ healthScore = $HealthScore.Score }
        } catch {
            # Persistence failure is non-fatal — keep serving the freshly computed
            # view even if the write-back to table storage didn't stick.
        }
    }

    [PSCustomObject]@{
        tenantId    = $TenantId
        record      = $Record
        psa         = $PsaView
        rmm         = $RmmView
        healthScore = $HealthScore
    }
}
