function Invoke-ListOmzigUpdateStatus {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.Read
    .DESCRIPTION
        ŌMZIG Update Center status: the local API version, the three update
        channels resolved from CIPP's official GitHub (latest stable release,
        latest prerelease/beta, dev branch head), the saved auto-update
        schedule, and whether the GitHub integration needed for installs is
        configured. Read-only; channel data is public GitHub information.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $LocalApiVersion = $null
    try {
        if ($env:CIPPNG -eq 'true') {
            $LocalApiVersion = $env:APP_VERSION
        } else {
            $LocalApiVersion = (Get-Content -Path (Join-Path $env:CIPPRootPath 'version_latest.txt') -ErrorAction Stop).Trim()
        }
    } catch {
        Write-Verbose "Local API version unavailable: $($_.Exception.Message)"
    }

    $Body = [PSCustomObject]@{
        LocalApiVersion   = $LocalApiVersion
        Channels          = Get-OmzigUpdateChannels
        Settings          = Get-OmzigUpdateSettings
        GitHubIntegration = Test-OmzigGitHubIntegration
        Repos             = Get-OmzigUpdateRepos
    }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $Body
        })
}
