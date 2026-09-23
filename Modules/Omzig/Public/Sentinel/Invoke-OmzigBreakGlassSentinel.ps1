function Invoke-OmzigBreakGlassSentinel {
    <#
    .SYNOPSIS
    Break-Glass Sentinel (§7.5): evaluates sign-in events and fires the P1
    chain for any break-glass authentication outside a declared incident
    window.

    .DESCRIPTION
    Alert chain on trigger (Send-OmzigAlert): CIPP Logbook critical entry, Teams
    Adaptive Card, email to security@omzig.it, and a P1 PSA ticket when a PSA is
    configured. Driven every 5 minutes by Invoke-OmzigBreakGlassPoll from the
    OmzigSentinelTimer function; sign-in logs themselves land in Graph a few
    minutes after the sign-in, so expect an alert within ~10 minutes.

    .PARAMETER SignIns
    Sign-in events (Graph signIn resource shape: id, userPrincipalName,
    createdDateTime, appDisplayName, ipAddress, status). Supplied by the
    scheduled poller; injected directly in tests.

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

        # A failed attempt is still an alert (someone is trying the account), but
        # the responder needs to know which it was before anything else.
        $ErrorCode = $SignIn.status.errorCode
        $Succeeded = ($null -eq $SignIn.status) -or ([int]$ErrorCode -eq 0)
        $Outcome = if ($Succeeded) { 'SUCCEEDED' } else { "FAILED (error $ErrorCode$(if ($SignIn.status.failureReason) { ": $($SignIn.status.failureReason)" }))" }
        $Verb = if ($Succeeded) { 'signed in' } else { 'had a failed sign-in attempt' }

        $Alert = [PSCustomObject]@{
            Severity  = 'P1'
            Type      = 'BreakGlassSignIn'
            TenantId  = $TenantFilter
            Account   = $SignIn.userPrincipalName
            At        = $When.ToString('o')
            App       = $SignIn.appDisplayName
            IpAddress = $SignIn.ipAddress
            Outcome   = $Outcome
            SignInId  = $SignIn.id
            Message   = "EMERGENCY-ONLY account $($SignIn.userPrincipalName) $Verb outside a declared incident window."
        }
        $Alerts.Add($Alert)

        if ($PSCmdlet.ShouldProcess($SignIn.userPrincipalName, 'Fire break-glass P1 alert chain')) {
            if ($AlertAction) {
                & $AlertAction $Alert
            } else {
                $Facts = [ordered]@{
                    Tenant      = $TenantFilter
                    Account     = $Alert.Account
                    Outcome     = $Alert.Outcome
                    'When (UTC)' = $When.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
                    App         = $Alert.App
                    'IP address' = $Alert.IpAddress
                    'Sign-in ID' = $Alert.SignInId
                }
                $Sent = Send-OmzigAlert -Severity 'P1' -Title "Break-glass $Verb - $TenantFilter" -Message $Alert.Message `
                    -TenantFilter $TenantFilter -Facts $Facts
                $Alert | Add-Member -NotePropertyName Delivery -NotePropertyValue $Sent -Force
            }
        }
    }

    return $Alerts
}
