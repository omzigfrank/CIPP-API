# Pester suite for the worker thread-pool floor (Private/Set-OmzigThreadPoolFloor.ps1).
# It changes the real, process-wide .NET thread pool, so every test restores the
# minimum it found.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Private' 'Set-OmzigThreadPoolFloor.ps1')
    function script:Get-PoolMin {
        $W = 0; $I = 0
        [System.Threading.ThreadPool]::GetMinThreads([ref]$W, [ref]$I)
        [pscustomobject]@{ Worker = $W; Io = $I }
    }
}

Describe 'Set-OmzigThreadPoolFloor' {
    BeforeEach {
        $script:Saved = Get-PoolMin
        $script:SavedEnv = $env:OMZIG_THREADPOOL_MIN
        Remove-Item Env:OMZIG_THREADPOOL_MIN -ErrorAction SilentlyContinue
        # Start each test from a low floor so "raise" is observable on any machine.
        $null = [System.Threading.ThreadPool]::SetMinThreads(2, $script:Saved.Io)
    }
    AfterEach {
        $null = [System.Threading.ThreadPool]::SetMinThreads($script:Saved.Worker, $script:Saved.Io)
        if ($null -ne $script:SavedEnv) { $env:OMZIG_THREADPOOL_MIN = $script:SavedEnv } else { Remove-Item Env:OMZIG_THREADPOOL_MIN -ErrorAction SilentlyContinue }
    }

    It 'raises the worker minimum to 32 by default' {
        $R = Set-OmzigThreadPoolFloor -InformationAction SilentlyContinue
        $R.Changed | Should -BeTrue
        $R.Before | Should -Be 2
        $R.After | Should -Be 32
        (Get-PoolMin).Worker | Should -Be 32
    }

    It 'never lowers a floor that is already higher' {
        $null = [System.Threading.ThreadPool]::SetMinThreads(48, $script:Saved.Io)
        $R = Set-OmzigThreadPoolFloor
        $R.Changed | Should -BeFalse
        (Get-PoolMin).Worker | Should -Be 48
    }

    It 'does nothing the second time (every runspace imports the module)' {
        $null = Set-OmzigThreadPoolFloor -InformationAction SilentlyContinue
        (Set-OmzigThreadPoolFloor).Changed | Should -BeFalse
        (Get-PoolMin).Worker | Should -Be 32
    }

    It 'takes its value from OMZIG_THREADPOOL_MIN' {
        $env:OMZIG_THREADPOOL_MIN = '20'
        (Set-OmzigThreadPoolFloor -InformationAction SilentlyContinue).After | Should -Be 20
    }

    It 'is switched off by OMZIG_THREADPOOL_MIN=0' {
        $env:OMZIG_THREADPOOL_MIN = '0'
        (Set-OmzigThreadPoolFloor).Changed | Should -BeFalse
        (Get-PoolMin).Worker | Should -Be 2
    }

    It 'ignores an unparseable OMZIG_THREADPOOL_MIN and uses the default' {
        $env:OMZIG_THREADPOOL_MIN = 'lots'
        (Set-OmzigThreadPoolFloor -InformationAction SilentlyContinue).After | Should -Be 32
    }

    It 'never lowers the IO-thread minimum' {
        $null = [System.Threading.ThreadPool]::SetMinThreads(2, 64)
        $null = Set-OmzigThreadPoolFloor -InformationAction SilentlyContinue
        (Get-PoolMin).Io | Should -Be 64
    }

    It 'respects -WhatIf' {
        (Set-OmzigThreadPoolFloor -WhatIf).Changed | Should -BeFalse
        (Get-PoolMin).Worker | Should -Be 2
    }
}

Describe 'Omzig.psm1 wiring' {
    It 'calls Set-OmzigThreadPoolFloor at import, only inside the Functions host' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..' 'Omzig.psm1'), [ref]$null, [ref]$null)
        $Gate = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'WEBSITE_SITE_NAME' }, $false) | Select-Object -First 1
        $Gate | Should -Not -BeNullOrEmpty
        $Gate.Clauses[0].Item2.Extent.Text | Should -Match 'Set-OmzigThreadPoolFloor'
    }

    It 'raises the floor when imported inside the Functions host' {
        $Before = Get-PoolMin
        $Site = $env:WEBSITE_SITE_NAME
        $env:WEBSITE_SITE_NAME = 'omzig-pester'
        try {
            $null = [System.Threading.ThreadPool]::SetMinThreads(2, $Before.Io)
            Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force -InformationAction SilentlyContinue
            (Get-PoolMin).Worker | Should -Be 32
        } finally {
            $null = [System.Threading.ThreadPool]::SetMinThreads($Before.Worker, $Before.Io)
            if ($Site) { $env:WEBSITE_SITE_NAME = $Site } else { Remove-Item Env:WEBSITE_SITE_NAME -ErrorAction SilentlyContinue }
        }
    }

    It 'leaves the thread pool alone when imported outside the Functions host' {
        $Before = Get-PoolMin
        $Site = $env:WEBSITE_SITE_NAME
        Remove-Item Env:WEBSITE_SITE_NAME -ErrorAction SilentlyContinue
        try {
            $null = [System.Threading.ThreadPool]::SetMinThreads(2, $Before.Io)
            Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force
            (Get-PoolMin).Worker | Should -Be 2
        } finally {
            $null = [System.Threading.ThreadPool]::SetMinThreads($Before.Worker, $Before.Io)
            if ($Site) { $env:WEBSITE_SITE_NAME = $Site }
        }
    }
}
