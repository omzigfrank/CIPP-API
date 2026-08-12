function Get-OmzigUpdateRepos {
    <#
    .SYNOPSIS
    Repository map for the omzig.ai Update Center.

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

    $FrontendBranch = if ($env:OMZIG_GITHUB_FRONTEND_BRANCH) { $env:OMZIG_GITHUB_FRONTEND_BRANCH } else { 'main' }
    $ApiBranch = if ($env:OMZIG_GITHUB_API_BRANCH) { $env:OMZIG_GITHUB_API_BRANCH } else { 'master' }
    # Which ref carries the omzig-update-install.yml file to dispatch. Normally
    # the default branch; overridable so a stack tracking a feature branch
    # (e.g. dev before the overlay PRs merge) can still dispatch installs.
    $WorkflowRef = $env:OMZIG_UPDATE_WORKFLOW_REF

    [PSCustomObject]@{
        Frontend = [PSCustomObject]@{
            Fork          = "$Owner/CIPP"
            Upstream      = 'KelvinTegelaar/CIPP'
            DefaultBranch = $FrontendBranch
            WorkflowRef   = if ($WorkflowRef) { $WorkflowRef } else { $FrontendBranch }
        }
        Api      = [PSCustomObject]@{
            Fork          = "$Owner/CIPP-API"
            Upstream      = 'KelvinTegelaar/CIPP-API'
            DefaultBranch = $ApiBranch
            WorkflowRef   = if ($WorkflowRef) { $WorkflowRef } else { $ApiBranch }
        }
    }
}
