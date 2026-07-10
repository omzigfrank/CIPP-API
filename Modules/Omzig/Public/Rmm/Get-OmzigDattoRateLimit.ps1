function Get-OmzigDattoRateLimit {
    <#
    .SYNOPSIS
    Surfaces current Datto RMM API rate-limit state (Appendix B — also exposed
    as the get-rate-limit MCP tool).

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    Invoke-OmzigDattoRmmRequest -Endpoint 'account/ratelimit'
}
