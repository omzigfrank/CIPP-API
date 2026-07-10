function Get-OmzigPricingFloors {
    <#
    .SYNOPSIS
    The Omzig AI product line with locked pricing floors (§3 / §7.7).
    These are HARD floors — Test-OmzigQuoteFloor refuses anything below them
    without a Frank-signed executive override token.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    @(
        [PSCustomObject]@{ Id = 'aira'; Name = 'AIRA - AI Readiness Assessment'; SmbFloor = 4000; Recurring = $false; MarginFloor = 0.70; NeverDiscounted = $true }
        [PSCustomObject]@{ Id = 'aidf'; Name = 'AIDF - AI Data Foundation'; SmbFloor = 11000; Recurring = $false; MarginFloor = 0.70; NeverDiscounted = $false }
        [PSCustomObject]@{ Id = 'aid'; Name = 'AID - AI Deployment'; SmbFloor = 15500; Recurring = $false; MarginFloor = 0.70; NeverDiscounted = $false }
        [PSCustomObject]@{ Id = 'maio'; Name = 'MAIO - Managed AI Operations'; SmbFloor = 3600; Recurring = $true; MinimumTermMonths = 12; MarginFloor = 0.70; NeverDiscounted = $false }
    )
}
