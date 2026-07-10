function Test-OmzigGitHubIntegration {
    <#
    .SYNOPSIS
    Reports whether CIPP's native GitHub integration is enabled.

    .DESCRIPTION
    The Update Center reads public release data anonymously, but write
    operations (dispatching the install workflow, setting the auto-update
    repository variables) need the authenticated GitHub integration that
    CIPP already ships (Settings > Integrations > GitHub, PAT stored via
    Extensionsconfig). This helper mirrors the enablement check inside
    Invoke-GitHubApiRequest without touching the PAT itself.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    try {
        $Table = Get-CIPPTable -TableName Extensionsconfig
        $ExtensionConfig = (Get-CIPPAzDataTableEntity @Table).config
        if ($ExtensionConfig -and (Test-Json -Json $ExtensionConfig -ErrorAction SilentlyContinue)) {
            return [bool](($ExtensionConfig | ConvertFrom-Json).GitHub.Enabled)
        }
    } catch {
        Write-Verbose "Test-OmzigGitHubIntegration: $($_.Exception.Message)"
    }
    return $false
}
