function Get-OmzigDattoPlatformMap {
    <#
    .SYNOPSIS
    Maps the six Datto RMM regional platforms to their API hosts (Appendix B).
    Omzig's production platform is Vidal (§17 item 4); the map stays complete
    so the dev sandbox can point elsewhere via DATTO_RMM_PLATFORM.
    #>
    [CmdletBinding()]
    param()

    @{
        pinotage  = 'https://pinotage-api.centrastage.net'
        merlot    = 'https://merlot-api.centrastage.net'
        concord   = 'https://concord-api.centrastage.net'
        vidal     = 'https://vidal-api.centrastage.net'
        zinfandel = 'https://zinfandel-api.centrastage.net'
        syrah     = 'https://syrah-api.centrastage.net'
    }
}
