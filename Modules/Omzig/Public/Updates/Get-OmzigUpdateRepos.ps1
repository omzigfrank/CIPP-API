function Get-OmzigUpdateRepos {
    <#
    .SYNOPSIS
    Repository map for the omzig.ai Update Center.

    .DESCRIPTION
    Returns the fork repositories that receive updates, the upstream CIPP
    repositories they track, and each fork's default branch (the branch the
    deploy pipelines watch). Overridable via app settings so a rename never
    requires a code change.

    Since 11.0 upstream develops in the CyberDrain/CIPP monorepo and publishes
    GitHub Releases only there. KelvinTegelaar/CIPP and KelvinTegelaar/CIPP-API
    are bot-synced mirrors of it, and they are what the forks merge, so the
    stable version is read from each mirror's version file (UpstreamBranch +
    VersionFile); ReleaseNotesRepo is only used to link the release notes.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    $Owner = if ($env:OMZIG_GITHUB_OWNER) { $env:OMZIG_GITHUB_OWNER } else { 'omzigfrank' }

    $FrontendBranch = if ($env:OMZIG_GITHUB_FRONTEND_BRANCH) { $env:OMZIG_GITHUB_FRONTEND_BRANCH } else { 'main' }
    $ApiBranch = if ($env:OMZIG_GITHUB_API_BRANCH) { $env:OMZIG_GITHUB_API_BRANCH } else { 'master' }
    # Which ref carries the omzig-update-install.yml file to dispatch. Normally
    # the default branch; overridable so a stack tracking a feature branch
    # (e.g. dev before the overlay PRs merge) can still dispatch installs.
    $WorkflowRef = $env:OMZIG_UPDATE_WORKFLOW_REF
    $ReleaseNotesRepo = if ($env:OMZIG_UPSTREAM_RELEASES_REPO) { $env:OMZIG_UPSTREAM_RELEASES_REPO } else { 'CyberDrain/CIPP' }

    [PSCustomObject]@{
        Frontend = [PSCustomObject]@{
            Fork          = "$Owner/CIPP"
            Upstream         = 'KelvinTegelaar/CIPP'
            UpstreamBranch   = 'main'
            VersionFile      = 'public/version.json'
            ReleaseNotesRepo = $ReleaseNotesRepo
            DefaultBranch    = $FrontendBranch
            WorkflowRef      = if ($WorkflowRef) { $WorkflowRef } else { $FrontendBranch }
        }
        Api      = [PSCustomObject]@{
            Fork          = "$Owner/CIPP-API"
            Upstream         = 'KelvinTegelaar/CIPP-API'
            UpstreamBranch   = 'master'
            VersionFile      = 'version_latest.txt'
            ReleaseNotesRepo = $ReleaseNotesRepo
            DefaultBranch    = $ApiBranch
            WorkflowRef      = if ($WorkflowRef) { $WorkflowRef } else { $ApiBranch }
        }
    }
}
