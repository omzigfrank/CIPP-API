# Pester suite for the portal runspace warm-up (Public/Performance/Invoke-OmzigPortalWarmup.ps1,
# Private/Resolve-OmzigPortalUrl.ps1) and its hook in the 5-minute sentinel tick.
# The HTTP tests run against a throwaway HttpListener on localhost; nothing leaves the machine.

BeforeAll {
    $Stubs = @{
        'Get-CIPPTable'             = '[CmdletBinding()] param($tablename)'
        'Get-CIPPAzDataTableEntity' = '[CmdletBinding()] param($Context, $Filter, $Property, $First, $Skip)'
        'Add-CIPPAzDataTableEntity' = '[CmdletBinding()] param($Context, $Entity, [switch]$Force, [switch]$CreateTableIfNotExists, $OperationType)'
        'Remove-AzDataTableEntity'  = '[CmdletBinding()] param($Context, $Entity)'
        'Write-LogMessage'          = '[CmdletBinding()] param($message, $tenant, $API, $tenantId, $headers, $user, $sev, $LogData)'
    }
    foreach ($Name in $Stubs.Keys) {
        Set-Item -Path "function:global:$Name" -Value ([scriptblock]::Create($Stubs[$Name]))
    }
    Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force

    # A local HTTP server that answers each request after -DelayMs, on its own thread, so
    # parallel requests are served in parallel. Returns the listener and a bag of paths.
    function global:Start-WarmTestServer([int]$Handlers, [int]$DelayMs = 0, [int]$Status = 200) {
        $Probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $Probe.Start(); $Port = $Probe.LocalEndpoint.Port; $Probe.Stop()
        $Listener = [System.Net.HttpListener]::new()
        $Listener.Prefixes.Add("http://localhost:$Port/")
        $Listener.Start()
        $Seen = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
        $Workers = foreach ($i in 1..$Handlers) {
            $Ps = [powershell]::Create()
            $null = $Ps.AddScript({
                    param($Listener, $Seen, $DelayMs, $Status)
                    try {
                        $Ctx = $Listener.GetContext()
                        $Seen.Add($Ctx.Request.Url.AbsolutePath)
                        if ($DelayMs) { Start-Sleep -Milliseconds $DelayMs }
                        $Ctx.Response.StatusCode = $Status
                        $Ctx.Response.Close()
                    } catch { }  # listener stopped at the end of the test
                }).AddArgument($Listener).AddArgument($Seen).AddArgument($DelayMs).AddArgument($Status)
            [pscustomobject]@{ Ps = $Ps; Handle = $Ps.BeginInvoke() }
        }
        [pscustomobject]@{ Url = "http://localhost:$Port"; Listener = $Listener; Seen = $Seen; Workers = $Workers }
    }
    function global:Stop-WarmTestServer($Server) {
        $Server.Listener.Stop(); $Server.Listener.Close()
        foreach ($W in $Server.Workers) { try { $W.Ps.Stop() } catch { }; $W.Ps.Dispose() }
    }
}

AfterAll {
    foreach ($Name in 'Get-CIPPTable', 'Get-CIPPAzDataTableEntity', 'Add-CIPPAzDataTableEntity', 'Remove-AzDataTableEntity',
        'Write-LogMessage', 'Start-WarmTestServer', 'Stop-WarmTestServer') {
        Remove-Item -Path "function:global:$Name" -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-OmzigPortalUrl' {
    BeforeEach {
        $script:SavedEnv = @{ OMZIG_PORTAL_URL = $env:OMZIG_PORTAL_URL; WEBSITE_HOSTNAME = $env:WEBSITE_HOSTNAME }
        Remove-Item Env:OMZIG_PORTAL_URL, Env:WEBSITE_HOSTNAME -ErrorAction SilentlyContinue
        Mock -ModuleName Omzig Get-CIPPTable { @{ Context = $tablename } }
    }
    AfterEach {
        foreach ($K in $script:SavedEnv.Keys) {
            if ($null -ne $script:SavedEnv[$K]) { Set-Item "Env:$K" $script:SavedEnv[$K] } else { Remove-Item "Env:$K" -ErrorAction SilentlyContinue }
        }
    }

    It 'uses the host CIPP stores for itself' {
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity { if ($Filter -match "RowKey eq 'CIPPURL'") { [pscustomobject]@{ Value = 'management.omzig.it' } } }
        InModuleScope Omzig { Resolve-OmzigPortalUrl } | Should -Be 'https://management.omzig.it'
    }

    It 'prefers OMZIG_PORTAL_URL and keeps only scheme and host' {
        $env:OMZIG_PORTAL_URL = 'https://portal.example.com/some/page/'
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity { [pscustomobject]@{ Value = 'management.omzig.it' } }
        InModuleScope Omzig { Resolve-OmzigPortalUrl } | Should -Be 'https://portal.example.com'
        Should -Invoke -ModuleName Omzig Get-CIPPAzDataTableEntity -Times 0
    }

    It "never returns the function app's own hostname (it would reject an anonymous ping)" {
        $env:WEBSITE_HOSTNAME = 'cippwemix-flex.azurewebsites.net'
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity { [pscustomobject]@{ Value = 'cippwemix-flex.azurewebsites.net' } }
        InModuleScope Omzig { Resolve-OmzigPortalUrl } | Should -BeNullOrEmpty
    }

    It 'returns nothing when no URL is known, and when the lookup fails' {
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity { }
        InModuleScope Omzig { Resolve-OmzigPortalUrl } | Should -BeNullOrEmpty
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity { throw 'storage unavailable' }
        InModuleScope Omzig { Resolve-OmzigPortalUrl } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-OmzigPortalWarmup' {
    BeforeEach {
        $script:SavedCalls = $env:OMZIG_PORTAL_WARM_CALLS
        Remove-Item Env:OMZIG_PORTAL_WARM_CALLS -ErrorAction SilentlyContinue
    }
    AfterEach {
        if ($null -ne $script:SavedCalls) { $env:OMZIG_PORTAL_WARM_CALLS = $script:SavedCalls } else { Remove-Item Env:OMZIG_PORTAL_WARM_CALLS -ErrorAction SilentlyContinue }
        if ($script:Server) { Stop-WarmTestServer $script:Server; $script:Server = $null }
    }

    It 'pings PublicPing 12 times by default, all in flight together' {
        $script:Server = Start-WarmTestServer -Handlers 12 -DelayMs 400
        $R = Invoke-OmzigPortalWarmup -BaseUrl $script:Server.Url -InformationAction SilentlyContinue
        $R.Calls | Should -Be 12
        $R.Ok | Should -Be 12
        $R.Failed | Should -Be 0
        @($script:Server.Seen | Where-Object { $_ -eq '/api/PublicPing' }).Count | Should -Be 12
        # One after another would take 12 x 400ms = 4.8s.
        $R.WallMs | Should -BeLessThan 2400
    }

    It 'takes the count from OMZIG_PORTAL_WARM_CALLS' {
        $env:OMZIG_PORTAL_WARM_CALLS = '3'
        $script:Server = Start-WarmTestServer -Handlers 3
        (Invoke-OmzigPortalWarmup -BaseUrl $script:Server.Url -InformationAction SilentlyContinue).Ok | Should -Be 3
    }

    It 'is switched off by OMZIG_PORTAL_WARM_CALLS=0 and sends nothing' {
        $env:OMZIG_PORTAL_WARM_CALLS = '0'
        $script:Server = Start-WarmTestServer -Handlers 1
        (Invoke-OmzigPortalWarmup -BaseUrl $script:Server.Url).Skipped | Should -Match 'turned off'
        Start-Sleep -Milliseconds 200
        $script:Server.Seen.Count | Should -Be 0
    }

    It 'counts rejected pings as failed and warns' {
        $script:Server = Start-WarmTestServer -Handlers 2 -Status 401
        $R = Invoke-OmzigPortalWarmup -BaseUrl $script:Server.Url -Calls 2 -InformationAction SilentlyContinue -WarningVariable W -WarningAction SilentlyContinue
        $R.Ok | Should -Be 0
        $R.Failed | Should -Be 2
        "$W" | Should -Match 'HTTP 401 x2'
    }

    It 'counts an unreachable server as failed instead of throwing' {
        $R = Invoke-OmzigPortalWarmup -BaseUrl 'http://localhost:1' -Calls 2 -TimeoutSeconds 5 -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $R.Failed | Should -Be 2
    }

    It 'skips with a warning when no portal URL is known' {
        Mock -ModuleName Omzig Resolve-OmzigPortalUrl { }
        $R = Invoke-OmzigPortalWarmup -WarningVariable W -WarningAction SilentlyContinue
        $R.Skipped | Should -Be 'no portal URL'
        "$W" | Should -Match 'OMZIG_PORTAL_URL'
    }
}

Describe 'Portal warm-up on the 5-minute sentinel tick' {
    BeforeEach {
        Mock -ModuleName Omzig Get-CIPPTable { @{ Context = $tablename } }
        Mock -ModuleName Omzig Get-CIPPAzDataTableEntity { }
        $global:WarmOrder = [System.Collections.Generic.List[string]]::new()
    }
    AfterEach { Remove-Variable -Name WarmOrder -Scope Global -ErrorAction SilentlyContinue }

    It 'runs after the break-glass poll, so it can never delay an alert' {
        Mock -ModuleName Omzig Invoke-OmzigBreakGlassPoll { $global:WarmOrder.Add('poll') }
        Mock -ModuleName Omzig Invoke-OmzigPortalWarmup { $global:WarmOrder.Add('warm') }
        Invoke-OmzigSentinelTimerRun -Timer $null
        $global:WarmOrder -join ',' | Should -Be 'poll,warm'
    }

    It 'still runs when the poll fails, and the poll failure still fails the run' {
        Mock -ModuleName Omzig Invoke-OmzigBreakGlassPoll { throw 'graph down' }
        Mock -ModuleName Omzig Invoke-OmzigPortalWarmup { $global:WarmOrder.Add('warm') }
        Mock -ModuleName Omzig Write-LogMessage { }
        { Invoke-OmzigSentinelTimerRun -Timer $null } | Should -Throw '*graph down*'
        $global:WarmOrder -join ',' | Should -Be 'warm'
    }

    It 'never fails the run itself' {
        Mock -ModuleName Omzig Invoke-OmzigBreakGlassPoll { }
        Mock -ModuleName Omzig Invoke-OmzigPortalWarmup { throw 'boom' }
        { Invoke-OmzigSentinelTimerRun -Timer $null -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}
