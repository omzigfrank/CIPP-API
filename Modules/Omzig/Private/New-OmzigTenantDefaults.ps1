function New-OmzigTenantDefaults {
    <#
    .SYNOPSIS
    Default Omzig tenant record (§14) with the confirmed day-1 defaults —
    baa=true for every tenant (§17 item 11).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure in-memory factory; persistence happens in Set-OmzigTenantRecord which supports ShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [string]$DisplayName = ''
    )

    [PSCustomObject]@{
        tenantId    = $TenantId
        displayName = $DisplayName
        omzigTier   = $null
        vertical    = 'other'
        baa         = $true
        psa         = [PSCustomObject]@{ system = 'autotask'; companyId = $null; contractId = $null }
        rmm         = [PSCustomObject]@{ system = 'datto'; siteId = $null }
        pax8        = [PSCustomObject]@{ companyId = $null }
        ai          = [PSCustomObject]@{
            airaStatus        = 'not-started'
            aidfStatus        = 'not-started'
            aidStatus         = 'not-started'
            maioStatus        = 'not-started'
            shadowAiFindings  = 0
        }
        healthScore = $null
    }
}
