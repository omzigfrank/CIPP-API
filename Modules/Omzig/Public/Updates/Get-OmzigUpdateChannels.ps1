function Get-OmzigUpdateChannels {
    <#
    .SYNOPSIS
    Resolves the three ŌMZIG update channels from CIPP's official GitHub.

    .DESCRIPTION
    Queries KelvinTegelaar/CIPP and KelvinTegelaar/CIPP-API for:
      - Stable:     the latest published (non-draft, non-prerelease) release
      - Prerelease: the latest published prerelease (beta), when one exists
      - Dev:        the head of the upstream dev branch (canary)
    All reads are public GitHub data; Invoke-GitHubApiRequest handles both
    the authenticated integration and the anonymous fallback. Any side that
    cannot be resolved comes back $null so the UI can degrade gracefully.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    $Repos = Get-OmzigUpdateRepos

    $ReleaseInfo = {
        param($Release)
        if (-not $Release) { return $null }
        [PSCustomObject]@{
            Version     = $Release.tag_name
            Name        = $Release.name
            PublishedAt = $Release.published_at
            Url         = $Release.html_url
            Prerelease  = [bool]$Release.prerelease
        }
    }

    $Sides = [ordered]@{}
    foreach ($SideName in @('Frontend', 'Api')) {
        $Upstream = $Repos.$SideName.Upstream

        $Stable = $null
        $Prerelease = $null
        try {
            $Releases = Invoke-GitHubApiRequest -Path "repos/$Upstream/releases?per_page=30" |
                Where-Object { -not $_.draft }
            $Stable = & $ReleaseInfo ($Releases | Where-Object { -not $_.prerelease } | Select-Object -First 1)
            $Prerelease = & $ReleaseInfo ($Releases | Where-Object { $_.prerelease } | Select-Object -First 1)
        } catch {
            Write-Verbose "Get-OmzigUpdateChannels: releases for $Upstream failed: $($_.Exception.Message)"
        }

        $Dev = $null
        try {
            $Branch = Invoke-GitHubApiRequest -Path "repos/$Upstream/branches/dev"
            if ($Branch) {
                $Dev = [PSCustomObject]@{
                    Sha     = $Branch.commit.sha
                    Date    = $Branch.commit.commit.committer.date
                    Message = ($Branch.commit.commit.message -split "`n")[0]
                    Url     = "https://github.com/$Upstream/tree/dev"
                }
            }
        } catch {
            Write-Verbose "Get-OmzigUpdateChannels: dev branch for $Upstream failed: $($_.Exception.Message)"
        }

        $Sides[$SideName] = [PSCustomObject]@{
            Stable     = $Stable
            Prerelease = $Prerelease
            Dev        = $Dev
        }
    }

    [PSCustomObject]@{
        Frontend = $Sides['Frontend']
        Api      = $Sides['Api']
    }
}
