function Invoke-ListOmzigUpdateStatus {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.Read
    .DESCRIPTION
        omzig.ai Update Center status: the local API version, the three update
        channels resolved from CIPP's official GitHub (latest stable release,
        latest prerelease/beta, dev branch head), the saved auto-update
        schedule, and whether the GitHub integration needed for installs is
        configured. Read-only; channel data is public GitHub information.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    # Version fallback chain: APP_VERSION (CIPPNG images) -> version_latest.txt
    # under CIPPRootPath -> the app root. Some stacks set CIPPNG=true without
    # APP_VERSION, so never stop at an empty first candidate.
    $LocalApiVersion = $null
    $Candidates = @(
        $env:APP_VERSION
        if ($env:CIPPRootPath) { Join-Path $env:CIPPRootPath 'version_latest.txt' }
        if ($env:HOME) { Join-Path $env:HOME 'site/wwwroot/version_latest.txt' }
    )
    foreach ($Candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($Candidate)) { continue }
        if ($Candidate -notmatch 'version_latest\.txt$') {
            $LocalApiVersion = $Candidate.Trim()
            break
        }
        try {
            $LocalApiVersion = (Get-Content -Path $Candidate -ErrorAction Stop | Select-Object -First 1).Trim()
            break
        } catch {
            Write-Verbose "Local API version candidate '$Candidate' unavailable: $($_.Exception.Message)"
        }
    }

    # Access control state so the UI can enable/disable the write controls.
    $CallerUpn = $null
    try {
        $CallerUpn = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Request.Headers.'x-ms-client-principal')) | ConvertFrom-Json).userDetails
    } catch {
        Write-Verbose "Caller principal undecodable: $($_.Exception.Message)"
    }
    $Group = Get-OmzigUpdaterGroup
    $CallerIsUpdater = (Test-OmzigUpdateAuthorized -UserPrincipalName $CallerUpn).Authorized
    $CallerIsSuperAdmin = $false
    try {
        $CallerIsSuperAdmin = (Get-CIPPAccessRole -Request $Request) -contains 'superadmin'
    } catch {
        Write-Verbose "Role resolution failed: $($_.Exception.Message)"
    }

    $Body = [PSCustomObject]@{
        LocalApiVersion    = $LocalApiVersion
        Channels           = Get-OmzigUpdateChannels
        Settings           = Get-OmzigUpdateSettings
        GitHubIntegration  = Test-OmzigGitHubIntegration
        Repos              = Get-OmzigUpdateRepos
        Access             = [PSCustomObject]@{
            UpdaterGroupId     = $Group.GroupId
            UpdaterGroupName   = $Group.GroupName
            GroupConfigured    = $Group.Configured
            CallerIsUpdater    = $CallerIsUpdater
            CallerIsSuperAdmin = $CallerIsSuperAdmin
        }
    }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $Body
        })
}
