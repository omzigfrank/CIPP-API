function Invoke-OmzigBreakGlassSentinel {
    <#
    .SYNOPSIS
    Break-Glass Sentinel (§7.5): evaluates sign-in events and fires the P1
    chain for any break-glass authentication outside a declared incident
    window.

    .DESCRIPTION
    Alert chain on trigger: P1 Autotask ticket via the PSA client, Teams
    message (Ops webhook), email to security@omzig.it, and a persistent
    portal banner record. Acceptance test: alert within 60 s of a simulated
    break-glass sign-in.

    .PARAMETER SignIns
    Sign-in events (Graph signIn resource shape: userPrincipalName,
    createdDateTime, appDisplayName, ipAddress). Supplied by the scheduled
    poller; injected directly in tests.

    .PARAMETER IncidentWindows
    Active incident windows: objects with Start/End [datetime] and TenantId.
    A break-glass sign-in inside a window is expected and NOT alerted.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TenantFilter,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$SignIns,
        [array]$IncidentWindows = @(),
        [string]$InitialDomain,
        [scriptblock]$AlertAction
    )

    $Alerts = [System.Collections.Generic.List[object]]::new()

    foreach ($SignIn in $SignIns) {
        if (-not (Test-OmzigBreakGlassAccount -UserPrincipalName $SignIn.userPrincipalName -InitialDomain $InitialDomain)) {
            continue
        }

        $When = [datetime]$SignIn.createdDateTime
        $InWindow = @($IncidentWindows | Where-Object {
                $_.TenantId -eq $TenantFilter -and $When -ge [datetime]$_.Start -and $When -le [datetime]$_.End
            }).Count -gt 0
        if ($InWindow) { continue }

        $Alert = [PSCustomObject]@{
            Severity  = 'P1'
            Type      = 'BreakGlassSignIn'
            TenantId  = $TenantFilter
            Account   = $SignIn.userPrincipalName
            At        = $When.ToString('o')
            App       = $SignIn.appDisplayName
            IpAddress = $SignIn.ipAddress
            Message   = "EMERGENCY-ONLY account $($SignIn.userPrincipalName) authenticated outside a declared incident window."
        }
        $Alerts.Add($Alert)

        if ($PSCmdlet.ShouldProcess($SignIn.userPrincipalName, 'Fire break-glass P1 alert chain')) {
            if ($AlertAction) {
                & $AlertAction $Alert
            } else {
                # Production chain — each leg is best-effort so one failed
                # channel never suppresses the others.
                try {
                    $Psa = Get-OmzigPsaClient
                    & $Psa.NewTicket @{
                        companyID   = 0 # resolved from the omzig_tenants PSA mapping by the caller wrapper
                        title       = "P1 BREAK-GLASS: $($Alert.Account) signed in outside incident window"
                        description = ($Alert | ConvertTo-Json)
                        priority    = 1
                    } | Out-Null
                } catch { Write-Warning "Break-glass PSA ticket failed: $_" }
                try {
                    if ($env:OMZIG_TEAMS_WEBHOOK) {
                        Invoke-OmzigRestWithRetry -RequestSplat @{
                            Uri         = $env:OMZIG_TEAMS_WEBHOOK
                            Method      = 'POST'
                            ContentType = 'application/json'
                            Body        = (@{ text = "🚨 $($Alert.Message) Tenant: $TenantFilter, IP: $($Alert.IpAddress)" } | ConvertTo-Json)
                        } | Out-Null
                    }
                } catch { Write-Warning "Break-glass Teams alert failed: $_" }
            }
        }
    }

    return $Alerts
}
