function Get-OmzigUpdateChannels {
    <#
    .SYNOPSIS
    Resolves the three omzig.ai update channels from CIPP's official GitHub.

    .DESCRIPTION
    Queries KelvinTegelaar/CIPP and KelvinTegelaar/CIPP-API for:
      - Stable:     the version in the upstream release branch's version file
                    (main/public/version.json, master/version_latest.txt) -
                    the same source CIPP's own update check uses
      - Prerelease: the latest published prerelease (beta), when one exists
      - Dev:        the head of the upstream dev branch (canary)
    Stable used to be the latest GitHub Release, but upstream stopped
    publishing Releases on these repositories after FE v10.7.0 / API 10.9.1
    (they moved to the CyberDrain/CIPP monorepo), so the Update Center
    reported 10.10.3 as up to date while upstream was on 11.0.2. Releases are
    still read to link release notes and for the beta channel.
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
    $NotesCache = @{}
    foreach ($SideName in @('Frontend', 'Api')) {
        $Side = $Repos.$SideName
        $Upstream = $Side.Upstream
        $Stable = $null
        $Prerelease = $null
        try {
            $Releases = Invoke-GitHubApiRequest -Path "repos/$Upstream/releases?per_page=30" |
                Where-Object { -not $_.draft }
            $Prerelease = & $ReleaseInfo ($Releases | Where-Object { $_.prerelease } | Select-Object -First 1)
        } catch {
            Write-Verbose "Get-OmzigUpdateChannels: releases for $Upstream failed: $($_.Exception.Message)"
        }
        try {
            $Raw = Invoke-CIPPRestMethod -Uri "https://raw.githubusercontent.com/$Upstream/$($Side.UpstreamBranch)/$($Side.VersionFile)"
            $Version = if ($Side.VersionFile -like '*.json') {
                if ($Raw -is [string]) { ($Raw | ConvertFrom-Json).version } else { $Raw.version }
            } else {
                ("$Raw" -split "`n")[0]
            }
            $Version = "$Version".Trim().TrimStart('v')
            if ($Version -match '^\d+(\.\d+)+$') {
                if (-not $NotesCache.ContainsKey($Version)) {
                    $NotesCache[$Version] = $null
                    try {
                        $NotesCache[$Version] = Invoke-GitHubApiRequest -Path "repos/$($Side.ReleaseNotesRepo)/releases/tags/v$Version"
                    } catch {
                        Write-Verbose "Get-OmzigUpdateChannels: no v$Version release notes in $($Side.ReleaseNotesRepo): $($_.Exception.Message)"
                    }
                }
                $Notes = $NotesCache[$Version]
                $Stable = [PSCustomObject]@{
                    Version     = $Version
                    Name        = if ($Notes.name) { $Notes.name } else { "v$Version" }
                    PublishedAt = $Notes.published_at
                    Url         = if ($Notes.html_url) { $Notes.html_url } else { "https://github.com/$Upstream/blob/$($Side.UpstreamBranch)/$($Side.VersionFile)" }
                    Prerelease  = $false
                }
            } else {
                Write-Verbose "Get-OmzigUpdateChannels: unexpected version '$Version' in $Upstream/$($Side.VersionFile)"
            }
        } catch {
            Write-Verbose "Get-OmzigUpdateChannels: version file for $Upstream failed: $($_.Exception.Message)"
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
