function Get-OmzigAutotaskZoneUrl {
    <#
    .SYNOPSIS
    Discovers the Autotask REST API zone URL for the API user (Appendix A).

    .DESCRIPTION
    Autotask base URLs are region-specific and MUST be discovered via the
    global zoneInformation endpoint — never hard-coded. The result is cached
    for the process lifetime.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [string]$Username = $env:AUTOTASK_USERNAME
    )

    if ([string]::IsNullOrEmpty($Username)) {
        throw 'Autotask username missing. Run Test-OmzigPreflight — AUTOTASK_USERNAME must exist in Key Vault.'
    }
    if ($script:OmzigAutotaskZoneUrl) { return $script:OmzigAutotaskZoneUrl }

    $Splat = @{
        Uri    = "https://webservices.autotask.net/atservicesrest/v1.0/zoneInformation?user=$([uri]::EscapeDataString($Username))"
        Method = 'GET'
    }
    $Zone = Invoke-OmzigRestWithRetry -RequestSplat $Splat
    $script:OmzigAutotaskZoneUrl = $Zone.url.TrimEnd('/')
    return $script:OmzigAutotaskZoneUrl
}
