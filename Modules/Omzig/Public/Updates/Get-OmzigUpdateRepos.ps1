function Get-OmzigUpdateRepos {
    <#
    .SYNOPSIS
    Repository map for the ŌMZIG Update Center.

    .DESCRIPTION
    Returns the fork repositories that receive updates, the upstream CIPP
    repositories they track, and each fork's default branch (the branch the
    deploy pipelines watch). Overridable via app settings so a rename never
    requires a code change.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    $Owner = if ($env:OMZIG_GITHUB_OWNER) { $env:OMZIG_GITHUB_OWNER } else { 'omzigfrank' }

    [PSCustomObject]@{
        Frontend = [PSCustomObject]@{
            Fork          = "$Owner/CIPP"
            Upstream      = 'KelvinTegelaar/CIPP'
            DefaultBranch = if ($env:OMZIG_GITHUB_FRONTEND_BRANCH) { $env:OMZIG_GITHUB_FRONTEND_BRANCH } else { 'main' }
        }
        Api      = [PSCustomObject]@{
            Fork          = "$Owner/CIPP-API"
            Upstream      = 'KelvinTegelaar/CIPP-API'
            DefaultBranch = if ($env:OMZIG_GITHUB_API_BRANCH) { $env:OMZIG_GITHUB_API_BRANCH } else { 'master' }
        }
    }
}
