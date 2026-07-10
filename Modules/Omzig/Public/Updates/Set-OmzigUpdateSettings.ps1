function Set-OmzigUpdateSettings {
    <#
    .SYNOPSIS
    Saves the ŌMZIG scheduled-update settings and mirrors them to GitHub.

    .DESCRIPTION
    Persists the settings to the OmzigUpdateSettings table, then (when the
    GitHub integration is enabled) mirrors them onto both fork repositories
    as Actions variables — OMZIG_AUTO_UPDATE, OMZIG_UPDATE_CHANNEL and
    OMZIG_AUTO_UPDATE_MODE — which is what the scheduled run of the
    omzig-update-install workflow actually reads. Without the integration
    the table save still succeeds and AppliedToGitHub comes back $false so
    the UI can tell the operator the schedule is not yet live.

    .PARAMETER AutoUpdate
    Whether the daily scheduled install is enabled.

    .PARAMETER Channel
    Which channel scheduled installs track: stable, prerelease or dev.

    .PARAMETER Mode
    install = merge upstream and push to the deploy branch directly;
    pr = open a pull request for review instead.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$AutoUpdate,
        [Parameter(Mandatory = $true)][ValidateSet('stable', 'prerelease', 'dev')][string]$Channel,
        [Parameter(Mandatory = $true)][ValidateSet('install', 'pr')][string]$Mode
    )

    $Table = Get-CIPPTable -TableName OmzigUpdateSettings
    Add-CIPPAzDataTableEntity @Table -Entity @{
        PartitionKey = 'Omzig'
        RowKey       = 'UpdateSettings'
        AutoUpdate   = "$AutoUpdate".ToLower()
        Channel      = $Channel
        Mode         = $Mode
    } -Force | Out-Null

    $AppliedToGitHub = $false
    $Errors = [System.Collections.Generic.List[string]]::new()

    if (Test-OmzigGitHubIntegration) {
        $Repos = Get-OmzigUpdateRepos
        $Variables = @{
            OMZIG_AUTO_UPDATE      = "$AutoUpdate".ToLower()
            OMZIG_UPDATE_CHANNEL   = $Channel
            OMZIG_AUTO_UPDATE_MODE = $Mode
        }
        $AppliedToGitHub = $true
        foreach ($Side in @($Repos.Frontend, $Repos.Api)) {
            foreach ($Name in $Variables.Keys) {
                $Body = @{ name = $Name; value = $Variables[$Name] }
                try {
                    # Update in place; a 404 means the variable doesn't exist yet.
                    Invoke-GitHubApiRequest -Method 'PATCH' -Path "repos/$($Side.Fork)/actions/variables/$Name" -Body $Body | Out-Null
                } catch {
                    try {
                        Invoke-GitHubApiRequest -Method 'POST' -Path "repos/$($Side.Fork)/actions/variables" -Body $Body | Out-Null
                    } catch {
                        $AppliedToGitHub = $false
                        $Errors.Add("$($Side.Fork): could not set $Name — $($_.Exception.Message)")
                    }
                }
            }
        }
    } else {
        $Errors.Add('GitHub integration is not configured (CIPP Settings > Integrations > GitHub), so the schedule is saved but not yet live on the repositories.')
    }

    [PSCustomObject]@{
        Saved           = $true
        AppliedToGitHub = $AppliedToGitHub
        AutoUpdate      = $AutoUpdate
        Channel         = $Channel
        Mode            = $Mode
        Errors          = @($Errors)
    }
}
