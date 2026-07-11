# Pester suite for the ŌMZIG Update Center: channel resolution from CIPP's
# official GitHub, schedule persistence + GitHub Actions variable mirroring,
# on-demand install dispatch, and the two HTTP entrypoints. Self-contained:
# every CIPP core / GitHub call is stubbed with controllable global functions
# (the Omzig module resolves them through normal dynamic scoping), so no
# network and no table storage are ever touched.

# Top-level so it is available at both discovery and run time.
function NewPrincipalHeader {
    param([string]$Upn)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        (@{ userDetails = $Upn; userRoles = @('authenticated') } | ConvertTo-Json -Compress)))
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force

    $Accelerators = [PowerShell].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not $Accelerators::Get.ContainsKey('HttpStatusCode')) {
        $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode])
    }

    class HttpResponseContext {
        [int]$StatusCode
        [object]$Body
    }

    # ---- Controllable stub state -----------------------------------------
    $script:GitHubEnabled = $false
    $script:GitHubCalls = [System.Collections.Generic.List[object]]::new()
    $script:GitHubPatchFails = $false
    $script:UpdateSettingsEntity = $null
    $script:SavedEntities = [System.Collections.Generic.List[object]]::new()
    $script:ReleasesFixture = @()
    $script:DevBranchFixture = $null
    $script:GitHubReadsFail = $false
    # Access-control state: the configured updater group, the caller's group
    # memberships, and the caller's CIPP roles.
    $script:UPDATER_GROUP = '11111111-1111-1111-1111-111111111111'
    $script:UpdaterGroupEntity = [PSCustomObject]@{ UpdaterGroupId = $script:UPDATER_GROUP; UpdaterGroupName = 'ŌMZIG Updaters' }
    $script:GroupMemberships = @($script:UPDATER_GROUP)  # caller is a member by default
    $script:CallerRoles = @('editor')                    # caller is a plain editor by default

    function Global:Get-CIPPTable {
        param($TableName)
        @{ TableName = $TableName }
    }

    function Global:Get-CIPPAzDataTableEntity {
        param($TableName, $Filter)
        switch ($TableName) {
            'Extensionsconfig' {
                if ($script:GitHubEnabled) {
                    return [PSCustomObject]@{ config = '{"GitHub":{"Enabled":true}}' }
                }
                return [PSCustomObject]@{ config = '{"GitHub":{"Enabled":false}}' }
            }
            'OmzigUpdateSettings' {
                if ($Filter -match 'UpdateAccess') { return $script:UpdaterGroupEntity }
                return $script:UpdateSettingsEntity
            }
        }
        return $null
    }

    # Base64 SWA client-principal header for a given UPN (run-time helper).
    function Global:NewPrincipalHeader {
        param([string]$Upn)
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            (@{ userDetails = $Upn; userRoles = @('authenticated') } | ConvertTo-Json -Compress)))
    }

    # CIPP core auth helpers the Omzig update endpoints depend on.
    function Global:Get-CIPPAccessRole {
        param($Request, $Headers)
        return $script:CallerRoles
    }
    function Global:New-GraphGetRequest {
        param($uri, $NoAuthCheck, $AsApp, $tenantid)
        # Return the caller's group memberships as Graph directoryObjects.
        return @($script:GroupMemberships | ForEach-Object {
                [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.group'; id = $_ }
            })
    }


    function Global:Add-CIPPAzDataTableEntity {
        param($TableName, $Entity, [switch]$Force)
        $script:SavedEntities.Add([PSCustomObject]@{ TableName = $TableName; Entity = $Entity })
        $Entity
    }

    function Global:Invoke-GitHubApiRequest {
        param($Method = 'GET', $Path, $Body, $Accept, [switch]$ReturnHeaders)
        $script:GitHubCalls.Add([PSCustomObject]@{ Method = $Method; Path = $Path; Body = $Body })
        if ($Method -eq 'GET' -and $script:GitHubReadsFail) { throw 'GitHub unreachable' }
        if ($Method -eq 'PATCH' -and $script:GitHubPatchFails) { throw 'Not Found' }
        if ($Path -match 'releases\?') { return $script:ReleasesFixture }
        if ($Path -match 'branches/dev') { return $script:DevBranchFixture }
        return $null
    }

    function Global:Write-LogMessage {
        param($API, $tenant, $headers, $message, $Sev, $LogData)
    }

    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $EntrypointDir = Join-Path $RepoRoot 'Modules' 'CIPPHTTP' 'Public' 'Entrypoints' 'HTTP Functions' 'Omzig'
    . (Join-Path $EntrypointDir 'Invoke-ListOmzigUpdateStatus.ps1')
    . (Join-Path $EntrypointDir 'Invoke-ExecOmzigUpdates.ps1')

    $script:ReleasesDefault = @(
        [PSCustomObject]@{ tag_name = 'v10.6.0-beta.2'; name = 'Beta 2'; prerelease = $true; draft = $false; published_at = '2026-07-01T00:00:00Z'; html_url = 'https://github.com/KelvinTegelaar/CIPP/releases/tag/v10.6.0-beta.2' }
        [PSCustomObject]@{ tag_name = 'v10.6.0-draft'; name = 'Draft'; prerelease = $false; draft = $true; published_at = '2026-06-30T00:00:00Z'; html_url = 'https://example.invalid' }
        [PSCustomObject]@{ tag_name = 'v10.5.8'; name = 'Stable'; prerelease = $false; draft = $false; published_at = '2026-06-20T00:00:00Z'; html_url = 'https://github.com/KelvinTegelaar/CIPP/releases/tag/v10.5.8' }
        [PSCustomObject]@{ tag_name = 'v10.5.7'; name = 'Older'; prerelease = $false; draft = $false; published_at = '2026-06-01T00:00:00Z'; html_url = 'https://example.invalid' }
    )
    $script:DevBranchDefault = [PSCustomObject]@{
        commit = [PSCustomObject]@{
            sha    = 'abc1234def'
            commit = [PSCustomObject]@{
                committer = [PSCustomObject]@{ date = '2026-07-09T12:00:00Z' }
                message   = "feat: canary change`nbody"
            }
        }
    }
}

AfterAll {
    foreach ($Name in 'Get-CIPPTable', 'Get-CIPPAzDataTableEntity', 'Add-CIPPAzDataTableEntity', 'Invoke-GitHubApiRequest', 'Write-LogMessage', 'Get-CIPPAccessRole', 'New-GraphGetRequest') {
        Remove-Item -Path "function:Global:$Name" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-OmzigUpdateRepos' {
    It 'defaults to the omzigfrank forks tracking the official CIPP repos' {
        $Repos = Get-OmzigUpdateRepos
        $Repos.Frontend.Fork | Should -Be 'omzigfrank/CIPP'
        $Repos.Frontend.Upstream | Should -Be 'KelvinTegelaar/CIPP'
        $Repos.Frontend.DefaultBranch | Should -Be 'main'
        $Repos.Api.Fork | Should -Be 'omzigfrank/CIPP-API'
        $Repos.Api.Upstream | Should -Be 'KelvinTegelaar/CIPP-API'
        $Repos.Api.DefaultBranch | Should -Be 'master'
    }

    It 'honors the OMZIG_GITHUB_OWNER override' {
        $env:OMZIG_GITHUB_OWNER = 'someoneelse'
        try {
            (Get-OmzigUpdateRepos).Frontend.Fork | Should -Be 'someoneelse/CIPP'
        } finally {
            Remove-Item Env:OMZIG_GITHUB_OWNER -ErrorAction SilentlyContinue
        }
    }

    It 'dispatches from the default branch unless OMZIG_UPDATE_WORKFLOW_REF overrides it' {
        (Get-OmzigUpdateRepos).Frontend.WorkflowRef | Should -Be 'main'
        (Get-OmzigUpdateRepos).Api.WorkflowRef | Should -Be 'master'
        $env:OMZIG_UPDATE_WORKFLOW_REF = 'feature/pre-merge'
        try {
            $Repos = Get-OmzigUpdateRepos
            $Repos.Frontend.WorkflowRef | Should -Be 'feature/pre-merge'
            $Repos.Api.WorkflowRef | Should -Be 'feature/pre-merge'
        } finally {
            Remove-Item Env:OMZIG_UPDATE_WORKFLOW_REF -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-OmzigUpdateChannels' {
    BeforeEach {
        $script:GitHubReadsFail = $false
        $script:ReleasesFixture = $script:ReleasesDefault
        $script:DevBranchFixture = $script:DevBranchDefault
        $script:GitHubCalls.Clear()
    }

    It 'picks the newest published stable release, skipping drafts and prereleases' {
        $Channels = Get-OmzigUpdateChannels
        $Channels.Frontend.Stable.Version | Should -Be 'v10.5.8'
        $Channels.Frontend.Stable.Prerelease | Should -BeFalse
    }

    It 'exposes the latest prerelease as the beta channel' {
        $Channels = Get-OmzigUpdateChannels
        $Channels.Frontend.Prerelease.Version | Should -Be 'v10.6.0-beta.2'
        $Channels.Frontend.Prerelease.Prerelease | Should -BeTrue
    }

    It 'exposes the dev branch head as the canary channel' {
        $Channels = Get-OmzigUpdateChannels
        $Channels.Frontend.Dev.Sha | Should -Be 'abc1234def'
        $Channels.Frontend.Dev.Message | Should -Be 'feat: canary change'
        $Channels.Frontend.Dev.Url | Should -Match 'KelvinTegelaar/CIPP/tree/dev'
    }

    It 'returns nulls instead of throwing when GitHub is unreachable' {
        $script:GitHubReadsFail = $true
        $Channels = Get-OmzigUpdateChannels
        $Channels.Frontend.Stable | Should -BeNullOrEmpty
        $Channels.Api.Dev | Should -BeNullOrEmpty
    }

    It 'reports a missing prerelease as null so the UI can fall back' {
        $script:ReleasesFixture = $script:ReleasesDefault | Where-Object { -not $_.prerelease }
        (Get-OmzigUpdateChannels).Frontend.Prerelease | Should -BeNullOrEmpty
    }
}

Describe 'Get-OmzigUpdateSettings' {
    It 'defaults to auto-update off, stable channel, install mode' {
        $script:UpdateSettingsEntity = $null
        $Settings = Get-OmzigUpdateSettings
        $Settings.AutoUpdate | Should -BeFalse
        $Settings.Channel | Should -Be 'stable'
        $Settings.Mode | Should -Be 'install'
    }

    It 'reads back a saved schedule' {
        $script:UpdateSettingsEntity = [PSCustomObject]@{ AutoUpdate = 'true'; Channel = 'dev'; Mode = 'pr' }
        $Settings = Get-OmzigUpdateSettings
        $Settings.AutoUpdate | Should -BeTrue
        $Settings.Channel | Should -Be 'dev'
        $Settings.Mode | Should -Be 'pr'
    }
}

Describe 'Set-OmzigUpdateSettings' {
    BeforeEach {
        $script:SavedEntities.Clear()
        $script:GitHubCalls.Clear()
        $script:GitHubPatchFails = $false
    }

    It 'persists to the table but reports not-applied when the integration is missing' {
        $script:GitHubEnabled = $false
        $Result = Set-OmzigUpdateSettings -AutoUpdate $true -Channel 'stable' -Mode 'install'
        $Result.Saved | Should -BeTrue
        $Result.AppliedToGitHub | Should -BeFalse
        $Result.Errors[0] | Should -Match 'GitHub integration'
        $script:SavedEntities.Count | Should -Be 1
        $script:SavedEntities[0].Entity.AutoUpdate | Should -Be 'true'
        ($script:GitHubCalls | Where-Object { $_.Method -ne 'GET' }) | Should -BeNullOrEmpty
    }

    It 'mirrors all three variables to both fork repositories when enabled' {
        $script:GitHubEnabled = $true
        $Result = Set-OmzigUpdateSettings -AutoUpdate $true -Channel 'prerelease' -Mode 'pr'
        $Result.AppliedToGitHub | Should -BeTrue
        $Writes = $script:GitHubCalls | Where-Object { $_.Method -eq 'PATCH' }
        $Writes.Count | Should -Be 6
        ($Writes.Path | Where-Object { $_ -match 'omzigfrank/CIPP/' }).Count | Should -Be 3
        ($Writes.Path | Where-Object { $_ -match 'omzigfrank/CIPP-API/' }).Count | Should -Be 3
        ($Writes | Where-Object { $_.Body.name -eq 'OMZIG_UPDATE_CHANNEL' })[0].Body.value | Should -Be 'prerelease'
    }

    It 'falls back to creating a variable when the update returns 404' {
        $script:GitHubEnabled = $true
        $script:GitHubPatchFails = $true
        $Result = Set-OmzigUpdateSettings -AutoUpdate $false -Channel 'stable' -Mode 'install'
        $Result.AppliedToGitHub | Should -BeTrue
        ($script:GitHubCalls | Where-Object { $_.Method -eq 'POST' }).Count | Should -Be 6
    }

    It 'rejects an unknown channel' {
        { Set-OmzigUpdateSettings -AutoUpdate $true -Channel 'nightly' -Mode 'install' } | Should -Throw
    }
}

Describe 'Start-OmzigUpdateInstall' {
    BeforeEach { $script:GitHubCalls.Clear() }

    It 'refuses with an actionable message when the integration is missing' {
        $script:GitHubEnabled = $false
        { Start-OmzigUpdateInstall -Channel 'stable' } | Should -Throw '*GitHub integration*'
    }

    It 'dispatches the install workflow on both forks with the requested channel' {
        $script:GitHubEnabled = $true
        $Result = Start-OmzigUpdateInstall -Channel 'dev'
        $Dispatches = $script:GitHubCalls | Where-Object { $_.Path -match 'omzig-update-install.yml/dispatches' }
        $Dispatches.Count | Should -Be 2
        ($Dispatches | Where-Object { $_.Path -match 'omzigfrank/CIPP/' })[0].Body.ref | Should -Be 'main'
        ($Dispatches | Where-Object { $_.Path -match 'omzigfrank/CIPP-API/' })[0].Body.ref | Should -Be 'master'
        $Dispatches[0].Body.inputs.channel | Should -Be 'dev'
        $Result.Dispatched.Count | Should -Be 2
    }

    It 'coerces dev/prerelease installs to PR mode (audit #1 governance)' {
        $script:GitHubEnabled = $true
        Start-OmzigUpdateInstall -Channel 'dev' -Mode 'install' | Out-Null
        ($script:GitHubCalls | Where-Object { $_.Path -match 'dispatches' })[0].Body.inputs.mode | Should -Be 'pr'
        $script:GitHubCalls.Clear()
        (Start-OmzigUpdateInstall -Channel 'prerelease' -Mode 'install').Mode | Should -Be 'pr'
    }

    It 'leaves a stable install as direct install' {
        $script:GitHubEnabled = $true
        (Start-OmzigUpdateInstall -Channel 'stable' -Mode 'install').Mode | Should -Be 'install'
        ($script:GitHubCalls | Where-Object { $_.Path -match 'dispatches' })[0].Body.inputs.mode | Should -Be 'install'
    }

    It 'passes PR mode through to the workflow inputs' {
        $script:GitHubEnabled = $true
        Start-OmzigUpdateInstall -Channel 'stable' -Mode 'pr' | Out-Null
        ($script:GitHubCalls | Where-Object { $_.Path -match 'dispatches' })[0].Body.inputs.mode | Should -Be 'pr'
    }
}

Describe 'Get/Set-OmzigUpdaterGroup and Test-OmzigUpdateAuthorized' {
    BeforeEach {
        $script:SavedEntities.Clear()
        $script:UpdaterGroupEntity = [PSCustomObject]@{ UpdaterGroupId = $script:UPDATER_GROUP; UpdaterGroupName = 'ŌMZIG Updaters' }
        $script:GroupMemberships = @($script:UPDATER_GROUP)
    }

    It 'reads the configured updater group from the table' {
        $Group = Get-OmzigUpdaterGroup
        $Group.GroupId | Should -Be $script:UPDATER_GROUP
        $Group.Configured | Should -BeTrue
    }

    It 'falls back to OMZIG_UPDATE_GROUP_ID when the table is empty' {
        $script:UpdaterGroupEntity = $null
        $env:OMZIG_UPDATE_GROUP_ID = '22222222-2222-2222-2222-222222222222'
        try {
            (Get-OmzigUpdaterGroup).GroupId | Should -Be '22222222-2222-2222-2222-222222222222'
        } finally { Remove-Item Env:OMZIG_UPDATE_GROUP_ID -ErrorAction SilentlyContinue }
    }

    It 'rejects a non-GUID group id' {
        { Set-OmzigUpdaterGroup -GroupId 'not-a-guid' } | Should -Throw
    }

    It 'authorizes a member and denies a non-member' {
        (Test-OmzigUpdateAuthorized -UserPrincipalName 'in@omzig.it').Authorized | Should -BeTrue
        $script:GroupMemberships = @('99999999-9999-9999-9999-999999999999')
        (Test-OmzigUpdateAuthorized -UserPrincipalName 'out@omzig.it').Authorized | Should -BeFalse
    }

    It 'fails closed when no group is configured' {
        $script:UpdaterGroupEntity = $null
        (Test-OmzigUpdateAuthorized -UserPrincipalName 'in@omzig.it').Authorized | Should -BeFalse
    }

    It 'denies when the caller identity cannot be resolved' {
        (Test-OmzigUpdateAuthorized -UserPrincipalName '').Authorized | Should -BeFalse
    }
}

Describe 'Invoke-ListOmzigUpdateStatus (GET entrypoint)' {
    BeforeEach {
        $script:GitHubReadsFail = $false
        $script:ReleasesFixture = $script:ReleasesDefault
        $script:DevBranchFixture = $script:DevBranchDefault
        $script:UpdateSettingsEntity = $null
        $script:UpdaterGroupEntity = [PSCustomObject]@{ UpdaterGroupId = $script:UPDATER_GROUP; UpdaterGroupName = 'ŌMZIG Updaters' }
        $script:GroupMemberships = @($script:UPDATER_GROUP)
        $script:CallerRoles = @('editor')
        $script:GitHubEnabled = $true
    }

    It 'returns 200 with channels, settings, integration and access state' {
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ListOmzigUpdateStatus' }
            Headers = @{ 'x-ms-client-principal' = (NewPrincipalHeader 'updater@omzig.it') }
        }
        $Response = Invoke-ListOmzigUpdateStatus -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 200
        $Response.Body.Channels.Frontend.Stable.Version | Should -Be 'v10.5.8'
        $Response.Body.Settings.Channel | Should -Be 'stable'
        $Response.Body.GitHubIntegration | Should -BeTrue
        $Response.Body.Repos.Frontend.Fork | Should -Be 'omzigfrank/CIPP'
        $Response.Body.Access.GroupConfigured | Should -BeTrue
        $Response.Body.Access.CallerIsUpdater | Should -BeTrue
    }

    It 'reports CallerIsUpdater=false for a non-member' {
        $script:GroupMemberships = @('99999999-9999-9999-9999-999999999999')
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ListOmzigUpdateStatus' }
            Headers = @{ 'x-ms-client-principal' = (NewPrincipalHeader 'outsider@omzig.it') }
        }
        (Invoke-ListOmzigUpdateStatus -Request $Request -TriggerMetadata @{}).Body.Access.CallerIsUpdater | Should -BeFalse
    }
}

Describe 'Invoke-ExecOmzigUpdates (POST entrypoint)' {
    BeforeEach {
        $script:SavedEntities.Clear()
        $script:GitHubCalls.Clear()
        $script:GitHubPatchFails = $false
        # Default caller: an editor who IS a member of the updater group.
        $script:UpdaterGroupEntity = [PSCustomObject]@{ UpdaterGroupId = $script:UPDATER_GROUP; UpdaterGroupName = 'ŌMZIG Updaters' }
        $script:GroupMemberships = @($script:UPDATER_GROUP)
        $script:CallerRoles = @('editor')
        $script:MemberHeaders = @{ 'x-ms-client-principal' = (NewPrincipalHeader 'updater@omzig.it') }
    }

    It 'routes SetSchedule for a group member and returns the applied settings' {
        $script:GitHubEnabled = $true
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = $script:MemberHeaders
            Body    = [PSCustomObject]@{ Action = 'SetSchedule'; autoUpdate = $true; channel = 'stable'; mode = 'install' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 200
        $Response.Body.Saved | Should -BeTrue
        $Response.Body.AppliedToGitHub | Should -BeTrue
    }

    It 'routes InstallNow for a group member and surfaces the dispatch summary' {
        $script:GitHubEnabled = $true
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = $script:MemberHeaders
            Body    = [PSCustomObject]@{ Action = 'InstallNow'; channel = 'prerelease' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 200
        $Response.Body.Channel | Should -Be 'prerelease'
        $Response.Body.Dispatched.Count | Should -Be 2
    }

    It 'returns 403 for InstallNow when the caller is NOT in the updater group' {
        $script:GitHubEnabled = $true
        $script:GroupMemberships = @('99999999-9999-9999-9999-999999999999')
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = @{ 'x-ms-client-principal' = (NewPrincipalHeader 'outsider@omzig.it') }
            Body    = [PSCustomObject]@{ Action = 'InstallNow'; channel = 'stable' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 403
        $Response.Body.Error | Should -Match 'not a member of the updater group'
        # No dispatch happened.
        ($script:GitHubCalls | Where-Object { $_.Path -match 'dispatches' }) | Should -BeNullOrEmpty
    }

    It 'returns 403 for SetSchedule when the caller is NOT in the updater group' {
        $script:GroupMemberships = @('99999999-9999-9999-9999-999999999999')
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = @{ 'x-ms-client-principal' = (NewPrincipalHeader 'outsider@omzig.it') }
            Body    = [PSCustomObject]@{ Action = 'SetSchedule'; autoUpdate = $true; channel = 'dev'; mode = 'install' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 403
    }

    It 'returns 403 for InstallNow when no updater group is configured (fail closed)' {
        $script:GitHubEnabled = $true
        $script:UpdaterGroupEntity = $null
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = $script:MemberHeaders
            Body    = [PSCustomObject]@{ Action = 'InstallNow'; channel = 'stable' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 403
        $Response.Body.Error | Should -Match 'No updater group'
    }

    It 'lets a superadmin set the updater group' {
        $script:CallerRoles = @('superadmin')
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = @{ 'x-ms-client-principal' = (NewPrincipalHeader 'boss@omzig.it') }
            Body    = [PSCustomObject]@{ Action = 'SetUpdaterGroup'; groupId = '33333333-3333-3333-3333-333333333333'; groupName = 'Ops' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 200
        $Response.Body.Saved | Should -BeTrue
        ($script:SavedEntities | Where-Object { $_.Entity.RowKey -eq 'UpdateAccess' }).Entity.UpdaterGroupId | Should -Be '33333333-3333-3333-3333-333333333333'
    }

    It 'returns 403 when a non-superadmin tries to set the updater group' {
        $script:CallerRoles = @('editor')
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = $script:MemberHeaders
            Body    = [PSCustomObject]@{ Action = 'SetUpdaterGroup'; groupId = '33333333-3333-3333-3333-333333333333' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 403
        $Response.Body.Error | Should -Match 'superadmin'
    }

    It 'returns 400 with the actionable message when a member InstallNow lacks the integration' {
        $script:GitHubEnabled = $false
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = $script:MemberHeaders
            Body    = [PSCustomObject]@{ Action = 'InstallNow'; channel = 'stable' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 400
        $Response.Body.Error | Should -Match 'GitHub integration'
    }

    It 'returns 400 for an unknown action (from a group member)' {
        $Request = @{
            Params  = @{ CIPPEndpoint = 'ExecOmzigUpdates' }
            Headers = $script:MemberHeaders
            Body    = [PSCustomObject]@{ Action = 'SelfDestruct' }
        }
        $Response = Invoke-ExecOmzigUpdates -Request $Request -TriggerMetadata @{}
        $Response.StatusCode | Should -Be 400
        $Response.Body.Error | Should -Match 'Unknown Action'
    }
}
