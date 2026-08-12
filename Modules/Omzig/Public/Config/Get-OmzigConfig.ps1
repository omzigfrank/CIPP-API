function Get-OmzigConfig {
    <#
    .SYNOPSIS
    Returns the resolved Omzig portal configuration.

    .DESCRIPTION
    Central configuration surface for the omzig.ai overlay. Values come from
    environment variables (wired by Bicep app settings) with the confirmed
    spec defaults applied: Datto RMM platform pinned to Vidal (§17 item 4)
    and Autotask as the primary PSA provider (§7.14). No secrets live here —
    secrets are resolved at call time from Key Vault via managed identity.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        Environment      = if ($env:OMZIG_ENVIRONMENT) { $env:OMZIG_ENVIRONMENT } else { 'dev' }
        PsaProvider      = if ($env:PSA_PROVIDER) { $env:PSA_PROVIDER.ToLower() } else { 'autotask' }
        DattoRmmPlatform = if ($env:DATTO_RMM_PLATFORM) { $env:DATTO_RMM_PLATFORM.ToLower() } else { 'vidal' }
        KeyVaultName     = $env:KEYVAULT_NAME
        AuditContainer   = if ($env:OMZIG_AUDIT_CONTAINER) { $env:OMZIG_AUDIT_CONTAINER } else { 'omzig-audit-worm' }
        AlertEmail       = if ($env:OMZIG_ALERT_EMAIL) { $env:OMZIG_ALERT_EMAIL } else { 'security@omzig.it' }
        # §17 item 11: every tenant defaults to BAA mode on day 1.
        BaaDefault       = $true
    }
}
