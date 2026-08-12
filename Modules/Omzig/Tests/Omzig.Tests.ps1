# Pester suite for the omzig.ai overlay module (QC pass 2, spec §13).
# Self-contained: no network, no CIPP table storage — everything external is mocked.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force
}

Describe 'Get-OmzigConfig' {
    It 'defaults the Datto RMM platform to vidal (§17 item 4)' {
        $Old = $env:DATTO_RMM_PLATFORM
        try {
            $env:DATTO_RMM_PLATFORM = $null
            (Get-OmzigConfig).DattoRmmPlatform | Should -Be 'vidal'
        } finally { $env:DATTO_RMM_PLATFORM = $Old }
    }

    It 'defaults the PSA provider to autotask (§7.14)' {
        $Old = $env:PSA_PROVIDER
        try {
            $env:PSA_PROVIDER = $null
            (Get-OmzigConfig).PsaProvider | Should -Be 'autotask'
        } finally { $env:PSA_PROVIDER = $Old }
    }

    It 'defaults BAA mode on (§17 item 11)' {
        (Get-OmzigConfig).BaaDefault | Should -BeTrue
    }
}

Describe 'Get-OmzigDattoApiUrl' {
    It 'resolves vidal to the Vidal API host' {
        Get-OmzigDattoApiUrl -Platform 'vidal' | Should -Be 'https://vidal-api.centrastage.net'
    }

    It 'resolves every documented regional platform' {
        foreach ($p in @('pinotage', 'merlot', 'concord', 'vidal', 'zinfandel', 'syrah')) {
            Get-OmzigDattoApiUrl -Platform $p | Should -Be "https://$p-api.centrastage.net"
        }
    }

    It 'is case-insensitive' {
        Get-OmzigDattoApiUrl -Platform 'Vidal' | Should -Be 'https://vidal-api.centrastage.net'
    }

    It 'throws loudly on an unknown platform' {
        { Get-OmzigDattoApiUrl -Platform 'bordeaux' } | Should -Throw "*Unknown Datto RMM platform*"
    }
}

Describe 'Get-OmzigPsaClient (IPsaClient contract, §7.14)' {
    It 'returns an Autotask adapter implementing the full contract' {
        $Client = Get-OmzigPsaClient -Provider 'autotask'
        $Client.Provider | Should -Be 'autotask'
        foreach ($Op in Get-OmzigPsaContract) {
            $Client.PSObject.Properties.Name | Should -Contain $Op
            $Client.$Op | Should -BeOfType [scriptblock]
        }
    }

    It 'returns a Halo stub implementing the full contract' {
        $Client = Get-OmzigPsaClient -Provider 'halo'
        $Client.Provider | Should -Be 'halo'
        foreach ($Op in Get-OmzigPsaContract) {
            $Client.PSObject.Properties.Name | Should -Contain $Op
        }
    }

    It 'Halo stub operations throw NotImplementedException with migration guidance' {
        $Client = Get-OmzigPsaClient -Provider 'halo'
        { & $Client.NewTicket @{ title = 'x' } } | Should -Throw '*shipped stub*'
    }
}

Describe 'Test-OmzigPreflight (§17 item 5)' {
    It 'halts when Pax8 credentials are missing' {
        $Resolver = { param($Name) $Name -notlike 'PAX8_*' }
        $Result = Test-OmzigPreflight -SecretResolver $Resolver
        $Result.Passed | Should -BeFalse
        @($Result.BlockingFailures | Where-Object Area -EQ 'Pax8').Count | Should -Be 2
        { Test-OmzigPreflight -SecretResolver $Resolver -Throw } | Should -Throw '*deployment halted*'
    }

    It 'passes when all blocking secrets are present' {
        $Result = Test-OmzigPreflight -SecretResolver { param($Name) $true }
        $Result.Passed | Should -BeTrue
    }

    It 'treats ConnectBooster/QuickBooks as non-blocking' {
        $Resolver = { param($Name) $Name -notin @('CONNECTBOOSTER_API_KEY', 'QBO_CLIENT_ID') }
        (Test-OmzigPreflight -SecretResolver $Resolver).Passed | Should -BeTrue
    }
}

Describe 'Test-OmzigQuoteFloor (§3 pricing floors)' {
    BeforeAll {
        $script:Key = 'unit-test-signing-key'
        $script:Sign = {
            param($ProductId, $Price)
            $Hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($script:Key))
            [Convert]::ToBase64String($Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("${ProductId}:${Price}")))
        }
    }

    It 'approves an at-floor AIRA quote with healthy margin' {
        $Result = Test-OmzigQuoteFloor -ProductId aira -Price 4000 -TechHours 8 -VcioHours 4
        $Result.Approved | Should -BeTrue
        $Result.Violations | Should -BeNullOrEmpty
    }

    It 'refuses a below-floor quote without an override token' {
        $Result = Test-OmzigQuoteFloor -ProductId aidf -Price 9000
        $Result.Approved | Should -BeFalse
        $Result.Violations[0] | Should -BeLike '*below the*floor*'
    }

    It 'refuses a quote whose gross margin is under 70%' {
        # $15,500 price with 60 tech hours + 15 vCIO hours = $6,600 cost → 57% margin
        $Result = Test-OmzigQuoteFloor -ProductId aid -Price 15500 -TechHours 60 -VcioHours 15
        $Result.Approved | Should -BeFalse
        $Result.GrossMargin | Should -BeLessThan 0.70
    }

    It 'accepts a below-floor quote with a valid Frank-signed override' {
        $Token = & $script:Sign 'aidf' 9000
        $Result = Test-OmzigQuoteFloor -ProductId aidf -Price 9000 -OverrideToken $Token -SigningKey $script:Key
        $Result.OverrideValid | Should -BeTrue
        $Result.Approved | Should -BeTrue
    }

    It 'rejects an override token with a bad signature' {
        $Result = Test-OmzigQuoteFloor -ProductId aidf -Price 9000 -OverrideToken 'bm90LXZhbGlk' -SigningKey $script:Key
        $Result.OverrideValid | Should -BeFalse
        $Result.Approved | Should -BeFalse
    }

    It 'never discounts AIRA, even with a valid override token' {
        $Token = & $script:Sign 'aira' 2000
        $Result = Test-OmzigQuoteFloor -ProductId aira -Price 2000 -OverrideToken $Token -SigningKey $script:Key
        $Result.Approved | Should -BeFalse
        ($Result.Violations -join ' ') | Should -BeLike '*never discounted*'
    }

    It 'enforces the MAIO monthly floor of $3,600' {
        (Test-OmzigQuoteFloor -ProductId maio -Price 3599).Approved | Should -BeFalse
        (Test-OmzigQuoteFloor -ProductId maio -Price 3600).Approved | Should -BeTrue
    }
}

Describe 'Test-OmzigBreakGlassAccount (§17 item 12)' {
    It 'matches bg01/bg02 on the initial domain' {
        Test-OmzigBreakGlassAccount -UserPrincipalName 'bg01@contoso.onmicrosoft.com' -InitialDomain 'contoso.onmicrosoft.com' | Should -BeTrue
        Test-OmzigBreakGlassAccount -UserPrincipalName 'BG02@contoso.onmicrosoft.com' -InitialDomain 'contoso.onmicrosoft.com' | Should -BeTrue
    }

    It 'does not match ordinary users' {
        Test-OmzigBreakGlassAccount -UserPrincipalName 'katie@contoso.onmicrosoft.com' -InitialDomain 'contoso.onmicrosoft.com' | Should -BeFalse
    }

    It 'matches on the omzig:breakglass extension attribute regardless of name' {
        $Attrs = [PSCustomObject]@{ extensionAttribute1 = 'omzig:breakglass=true' }
        Test-OmzigBreakGlassAccount -UserPrincipalName 'emergency@contoso.com' -ExtensionAttributes $Attrs | Should -BeTrue
    }
}

Describe 'Invoke-OmzigBreakGlassSentinel (§7.5)' {
    BeforeAll {
        $script:SignIn = [PSCustomObject]@{
            userPrincipalName = 'bg01@contoso.onmicrosoft.com'
            createdDateTime   = '2026-07-09T12:00:00Z'
            appDisplayName    = 'Azure Portal'
            ipAddress         = '203.0.113.10'
        }
    }

    It 'fires a P1 alert for a break-glass sign-in outside any incident window' {
        $Fired = [System.Collections.Generic.List[object]]::new()
        $Alerts = Invoke-OmzigBreakGlassSentinel -TenantFilter 'tenant-1' -SignIns @($script:SignIn) `
            -InitialDomain 'contoso.onmicrosoft.com' -AlertAction { param($a) $Fired.Add($a) }
        $Alerts.Count | Should -Be 1
        $Alerts[0].Severity | Should -Be 'P1'
        $Fired.Count | Should -Be 1
    }

    It 'stays silent inside a declared incident window' {
        $Window = [PSCustomObject]@{ TenantId = 'tenant-1'; Start = '2026-07-09T11:00:00Z'; End = '2026-07-09T13:00:00Z' }
        $Alerts = Invoke-OmzigBreakGlassSentinel -TenantFilter 'tenant-1' -SignIns @($script:SignIn) `
            -InitialDomain 'contoso.onmicrosoft.com' -IncidentWindows @($Window) -AlertAction { }
        @($Alerts).Count | Should -Be 0
    }

    It 'ignores non-break-glass sign-ins' {
        $Normal = [PSCustomObject]@{ userPrincipalName = 'frank@contoso.com'; createdDateTime = '2026-07-09T12:00:00Z' }
        $Alerts = Invoke-OmzigBreakGlassSentinel -TenantFilter 'tenant-1' -SignIns @($Normal) -AlertAction { }
        @($Alerts).Count | Should -Be 0
    }
}

Describe 'Invoke-OmzigGdapExpirySentinel (§7.6)' {
    It 'flags relationships at the 60/30/7 day thresholds with escalating severity' {
        $Now = [datetime]'2026-07-09T00:00:00Z'
        $Rels = @(
            [PSCustomObject]@{ id = 'r1'; displayName = 'Expires in 5'; status = 'active'; endDateTime = $Now.AddDays(5); accessDetails = @{ unifiedRoles = @() } }
            [PSCustomObject]@{ id = 'r2'; displayName = 'Expires in 20'; status = 'active'; endDateTime = $Now.AddDays(20); accessDetails = @{ unifiedRoles = @() } }
            [PSCustomObject]@{ id = 'r3'; displayName = 'Expires in 45'; status = 'active'; endDateTime = $Now.AddDays(45); accessDetails = @{ unifiedRoles = @() } }
            [PSCustomObject]@{ id = 'r4'; displayName = 'Expires in 300'; status = 'active'; endDateTime = $Now.AddDays(300); accessDetails = @{ unifiedRoles = @() } }
        )
        $Findings = Invoke-OmzigGdapExpirySentinel -Relationships $Rels -Now $Now
        @($Findings).Count | Should -Be 3
        ($Findings | Where-Object RelationshipId -EQ 'r1').Severity | Should -Be 'P1'
        ($Findings | Where-Object RelationshipId -EQ 'r2').Severity | Should -Be 'P2'
        ($Findings | Where-Object RelationshipId -EQ 'r3').Severity | Should -Be 'P3'
    }

    It 'detects role drift against a required-role set' {
        $Now = [datetime]'2026-07-09T00:00:00Z'
        $Rel = [PSCustomObject]@{
            id = 'r5'; displayName = 'Drifted'; status = 'active'; endDateTime = $Now.AddDays(200)
            accessDetails = @{ unifiedRoles = @(@{ roleDefinitionId = 'aaa' }) }
        }
        $Findings = Invoke-OmzigGdapExpirySentinel -Relationships @($Rel) -Now $Now -RequiredRoleIds @('aaa', 'bbb')
        @($Findings).Count | Should -Be 1
        $Findings[0].Type | Should -Be 'GdapRoleDrift'
        $Findings[0].MissingRoles | Should -Be @('bbb')
    }

    It 'skips terminated relationships' {
        $Now = [datetime]'2026-07-09T00:00:00Z'
        $Rel = [PSCustomObject]@{ id = 'r6'; displayName = 'Gone'; status = 'terminated'; endDateTime = $Now.AddDays(2); accessDetails = @{ unifiedRoles = @() } }
        @(Invoke-OmzigGdapExpirySentinel -Relationships @($Rel) -Now $Now).Count | Should -Be 0
    }
}

Describe 'Get-OmzigClientHealthScore (§7.1)' {
    It 'scores a fully healthy tenant at 100' {
        $Result = Get-OmzigClientHealthScore -Metrics @{
            SecureScorePercent = 100; PatchCompliancePercent = 100; MfaCoveragePercent = 100
            BackupSuccessPercent = 100; OpenTicketsPerUser = 0; LicenseUtilizationPercent = 100
        }
        $Result.Score | Should -Be 100
    }

    It 'renormalizes weights when a signal is missing instead of penalizing it' {
        $Result = Get-OmzigClientHealthScore -Metrics @{ SecureScorePercent = 80; MfaCoveragePercent = 80 }
        $Result.Score | Should -Be 80
        $Result.Components.Count | Should -Be 2
    }

    It 'returns a null score with a message when no telemetry exists' {
        $Result = Get-OmzigClientHealthScore -Metrics @{}
        $Result.Score | Should -BeNullOrEmpty
        $Result.Message | Should -BeLike '*No telemetry*'
    }

    It 'clamps out-of-range inputs' {
        # 250 clamps to 100 (weight .25), -10 clamps to 0 (weight .20):
        # (100*.25 + 0*.20) / .45 = 55.6 → 56
        $Result = Get-OmzigClientHealthScore -Metrics @{ SecureScorePercent = 250; MfaCoveragePercent = -10 }
        $Result.Score | Should -Be 56
    }
}

Describe 'Omzig tenant record defaults (§14 / §17 item 11)' {
    It 'new tenants default to baa=true with the full §14 shape' {
        InModuleScope Omzig {
            $Record = New-OmzigTenantDefaults -TenantId 'tenant-9'
            $Record.baa | Should -BeTrue
            $Record.psa.system | Should -Be 'autotask'
            $Record.rmm.system | Should -Be 'datto'
            $Record.ai.airaStatus | Should -Be 'not-started'
            $Record.ai.shadowAiFindings | Should -Be 0
        }
    }
}
