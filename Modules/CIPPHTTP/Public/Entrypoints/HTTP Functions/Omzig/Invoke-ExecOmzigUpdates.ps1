function Invoke-ExecOmzigUpdates {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    .DESCRIPTION
        ŌMZIG Update Center actions. Body.Action selects:
          SetSchedule — persist the auto-update schedule (autoUpdate, channel,
            mode) and mirror it to the fork repositories as Actions variables
            read by the scheduled omzig-update-install workflow.
          InstallNow — dispatch the omzig-update-install workflow on both
            fork repositories for the requested channel (stable, prerelease
            or dev), installing directly or opening a review PR per mode.
        Both write paths require CIPP's GitHub integration; nothing here ever
        reads or returns the PAT itself.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    try {
        $Action = $Request.Body.Action
        switch ($Action) {
            'SetSchedule' {
                $SetParams = @{
                    AutoUpdate = [bool]$Request.Body.autoUpdate
                    Channel    = [string]$Request.Body.channel
                    Mode       = [string]$Request.Body.mode
                }
                $Result = Set-OmzigUpdateSettings @SetParams
                Write-LogMessage -headers $Headers -API $APIName -message "Omzig update schedule set: AutoUpdate=$($SetParams.AutoUpdate), Channel=$($SetParams.Channel), Mode=$($SetParams.Mode), AppliedToGitHub=$($Result.AppliedToGitHub)" -Sev 'Info'
            }
            'InstallNow' {
                $InstallParams = @{ Channel = [string]$Request.Body.channel }
                if ($Request.Body.mode) { $InstallParams.Mode = [string]$Request.Body.mode }
                $Result = Start-OmzigUpdateInstall @InstallParams
                Write-LogMessage -headers $Headers -API $APIName -message "Omzig update install dispatched: Channel=$($Result.Channel), Mode=$($Result.Mode)" -Sev 'Alert'
            }
            default {
                throw "Unknown Action '$Action'. Expected SetSchedule or InstallNow."
            }
        }

        $StatusCode = [HttpStatusCode]::OK
        $Body = $Result
    } catch {
        $StatusCode = [HttpStatusCode]::BadRequest
        $Body = @{ Error = $_.Exception.Message }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
