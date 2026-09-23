function Invoke-OmzigGdapSentinelRun {
    <#
    .SYNOPSIS
    Body of the OmzigGdapSentinelTimer function (daily, 13:00 UTC). The Functions
    entrypoint is the thin Receive-OmzigGdapSentinelTimer wrapper in Omzig.psm1.
    .DESCRIPTION
    Kill switch: app setting AzureWebJobs.OmzigGdapSentinelTimer.Disabled=1.
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param($Timer)

    try {
        $null = Invoke-OmzigGdapExpiryPoll
    } catch {
        Write-LogMessage -API 'OmzigSentinel' -message "GDAP expiry sentinel run failed: $($_.Exception.Message)" -sev 'Error'
        throw
    }
}
