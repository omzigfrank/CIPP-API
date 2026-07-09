function Get-OmzigDattoApiUrl {
    <#
    .SYNOPSIS
    Resolves the Datto RMM API base URL for the configured regional platform.

    .DESCRIPTION
    Omzig's instance is on Vidal (§17 item 4) — the default when
    DATTO_RMM_PLATFORM is unset. Throws on unknown platforms so a typo fails
    loudly at startup instead of at first API call.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [string]$Platform = (Get-OmzigConfig).DattoRmmPlatform
    )

    $Map = Get-OmzigDattoPlatformMap
    $Key = $Platform.ToLower()
    if (-not $Map.ContainsKey($Key)) {
        throw "Unknown Datto RMM platform '$Platform'. Valid platforms: $($Map.Keys -join ', '). Omzig production is 'vidal'."
    }
    return $Map[$Key]
}
