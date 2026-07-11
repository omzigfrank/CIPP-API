function Start-OmzigUpdateInstall {
    <#
    .SYNOPSIS
    Dispatches an on-demand update install from CIPP's official GitHub.

    .DESCRIPTION
    Triggers the omzig-update-install workflow (workflow_dispatch) on both
    fork repositories with the requested channel. The workflow merges the
    resolved upstream ref (latest stable release tag, latest prerelease, or
    the dev branch head) into each fork's deploy branch, which the existing
    deploy pipelines then ship. Requires CIPP's GitHub integration — the
    dispatch is a write operation against the fork repositories.

    .PARAMETER Channel
    stable, prerelease or dev.

    .PARAMETER Mode
    install (default) pushes the merge to the deploy branch; pr opens a
    pull request for review instead.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('stable', 'prerelease', 'dev')][string]$Channel,
        [ValidateSet('install', 'pr')][string]$Mode = 'install'
    )

    if (-not (Test-OmzigGitHubIntegration)) {
        throw 'The GitHub integration is not configured. Add a PAT with repo + workflow scope for the fork repositories under CIPP Settings > Integrations > GitHub, then try again.'
    }

    $Repos = Get-OmzigUpdateRepos
    $Dispatched = [System.Collections.Generic.List[object]]::new()

    foreach ($Side in @($Repos.Frontend, $Repos.Api)) {
        $Body = @{
            # The ref only selects which copy of the workflow file runs; the
            # workflow itself always checks out and updates its TARGET_BRANCH.
            ref    = $Side.WorkflowRef
            inputs = @{
                channel = $Channel
                mode    = $Mode
            }
        }
        Invoke-GitHubApiRequest -Method 'POST' -Path "repos/$($Side.Fork)/actions/workflows/omzig-update-install.yml/dispatches" -Body $Body | Out-Null
        $Dispatched.Add([PSCustomObject]@{
                Repository = $Side.Fork
                Branch     = $Side.DefaultBranch
                RunsUrl    = "https://github.com/$($Side.Fork)/actions/workflows/omzig-update-install.yml"
            })
    }

    $Verb = if ($Mode -eq 'pr') { 'update review PR requested' } else { 'install dispatched' }
    [PSCustomObject]@{
        # CippApiResults renders Results as the single success line.
        Results    = "$($Channel) $Verb on $($Repos.Frontend.Fork) and $($Repos.Api.Fork). If the repositories already contain the target release the run reports 'up to date' and changes nothing — follow the linked workflow runs for the outcome."
        Channel    = $Channel
        Mode       = $Mode
        Dispatched = @($Dispatched)
    }
}
