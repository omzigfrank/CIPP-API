# Pester suite for the omzig.ai single-pane tenant view (spec §7.1).
# Self-contained: the Omzig tenant record, PSA and Datto RMM functions are all
# mocked, so nothing here touches CIPP table storage or the network.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force
}

Describe 'Get-OmzigTenantView (§7.1)' {
    BeforeEach {
        $script:BaseRecord = [PSCustomObject]@{
            tenantId    = 'tenant-1'
            displayName = 'Contoso'
            omzigTier   = 'edge'
            vertical    = 'legal'
            baa         = $true
            psa         = [PSCustomObject]@{ system = 'autotask'; companyId = 12345; contractId = $null }
            rmm         = [PSCustomObject]@{ system = 'datto'; siteId = 'site-abc' }
            healthScore = $null
        }

        Mock -ModuleName Omzig Get-OmzigTenantRecord { $script:BaseRecord }
        Mock -ModuleName Omzig Set-OmzigTenantRecord {
            param($TenantId, $Properties)
            foreach ($Key in $Properties.Keys) { $script:BaseRecord.$Key = $Properties[$Key] }
            $script:BaseRecord
        }
    }

    It 'fully assembles the view when PSA and RMM are both available' {
        $Old = @($env:AUTOTASK_USERNAME, $env:AUTOTASK_SECRET, $env:AUTOTASK_INTEGRATION_CODE)
        try {
            $env:AUTOTASK_USERNAME = 'u'
            $env:AUTOTASK_SECRET = 's'
            $env:AUTOTASK_INTEGRATION_CODE = 'c'

            $FakePsa = [PSCustomObject]@{
                GetTickets   = { param($CompanyId) @(
                        [PSCustomObject]@{ id = 1; status = 1 }
                        [PSCustomObject]@{ id = 2; status = 5 }
                    ) }
                GetContracts = { param($CompanyId) @(
                        [PSCustomObject]@{ id = 900; contractName = 'MSP Agreement'; status = 1; endDate = '2027-01-01' }
                    ) }
            }
            Mock -ModuleName Omzig Get-OmzigPsaClient { $FakePsa }

            $Devices = @(
                [PSCustomObject]@{ online = $true; patchManagement = [PSCustomObject]@{ patchStatus = 'FullyPatched' } }
                [PSCustomObject]@{ online = $false; patchManagement = [PSCustomObject]@{ patchStatus = 'NotPatched' } }
            )
            Mock -ModuleName Omzig Get-OmzigDattoDevices { $Devices }
            Mock -ModuleName Omzig Get-OmzigDattoAlerts { @([PSCustomObject]@{ id = 'a1' }) }

            $View = Get-OmzigTenantView -TenantId 'tenant-1'

            $View.psa.available | Should -BeTrue
            $View.psa.openTicketCount | Should -Be 1
            $View.psa.contractCount | Should -Be 1

            $View.rmm.available | Should -BeTrue
            $View.rmm.deviceCount | Should -Be 2
            $View.rmm.onlineCount | Should -Be 1
            $View.rmm.offlineCount | Should -Be 1
            $View.rmm.openAlertCount | Should -Be 1

            $View.healthScore.Score | Should -Be 50
            Should -Invoke -ModuleName Omzig Set-OmzigTenantRecord -Times 1
        } finally {
            $env:AUTOTASK_USERNAME, $env:AUTOTASK_SECRET, $env:AUTOTASK_INTEGRATION_CODE = $Old
        }
    }

    It 'degrades psa to available=$false when the PSA client throws' {
        $env:AUTOTASK_USERNAME = 'u'; $env:AUTOTASK_SECRET = 's'; $env:AUTOTASK_INTEGRATION_CODE = 'c'
        Mock -ModuleName Omzig Get-OmzigPsaClient { throw 'Autotask zone lookup failed' }
        Mock -ModuleName Omzig Get-OmzigDattoDevices { @() }
        Mock -ModuleName Omzig Get-OmzigDattoAlerts { @() }

        $View = Get-OmzigTenantView -TenantId 'tenant-1'

        $View.psa.available | Should -BeFalse
        $View.psa.reason | Should -BeLike '*Autotask zone lookup failed*'
    }

    It 'degrades psa to available=$false when no company is mapped' {
        $script:BaseRecord.psa.companyId = $null
        Mock -ModuleName Omzig Get-OmzigDattoDevices { @() }
        Mock -ModuleName Omzig Get-OmzigDattoAlerts { @() }

        $View = Get-OmzigTenantView -TenantId 'tenant-1'

        $View.psa.available | Should -BeFalse
        $View.psa.reason | Should -BeLike '*No PSA company mapped*'
    }

    It 'degrades psa to available=$false when Autotask credentials are missing' {
        $Old = @($env:AUTOTASK_USERNAME, $env:AUTOTASK_SECRET, $env:AUTOTASK_INTEGRATION_CODE)
        try {
            $env:AUTOTASK_USERNAME = $null; $env:AUTOTASK_SECRET = $null; $env:AUTOTASK_INTEGRATION_CODE = $null
            Mock -ModuleName Omzig Get-OmzigDattoDevices { @() }
            Mock -ModuleName Omzig Get-OmzigDattoAlerts { @() }

            $View = Get-OmzigTenantView -TenantId 'tenant-1'

            $View.psa.available | Should -BeFalse
            $View.psa.reason | Should -BeLike '*credentials*'
        } finally {
            $env:AUTOTASK_USERNAME, $env:AUTOTASK_SECRET, $env:AUTOTASK_INTEGRATION_CODE = $Old
        }
    }

    It 'degrades rmm to available=$false when the Datto call throws' {
        $env:AUTOTASK_USERNAME = 'u'; $env:AUTOTASK_SECRET = 's'; $env:AUTOTASK_INTEGRATION_CODE = 'c'
        $FakePsa = [PSCustomObject]@{
            GetTickets   = { @() }
            GetContracts = { @() }
        }
        Mock -ModuleName Omzig Get-OmzigPsaClient { $FakePsa }
        Mock -ModuleName Omzig Get-OmzigDattoDevices { throw 'Datto RMM site not found' }

        $View = Get-OmzigTenantView -TenantId 'tenant-1'

        $View.rmm.available | Should -BeFalse
        $View.rmm.reason | Should -BeLike '*Datto RMM site not found*'
    }

    It 'degrades rmm to available=$false when no site is mapped' {
        $script:BaseRecord.rmm.siteId = $null
        $env:AUTOTASK_USERNAME = 'u'; $env:AUTOTASK_SECRET = 's'; $env:AUTOTASK_INTEGRATION_CODE = 'c'
        $FakePsa = [PSCustomObject]@{ GetTickets = { @() }; GetContracts = { @() } }
        Mock -ModuleName Omzig Get-OmzigPsaClient { $FakePsa }

        $View = Get-OmzigTenantView -TenantId 'tenant-1'

        $View.rmm.available | Should -BeFalse
        $View.rmm.reason | Should -BeLike '*No Datto RMM site mapped*'
    }

    It 'computes the health score from partial metrics (patch compliance only)' {
        $script:BaseRecord.psa.companyId = $null
        $Devices = @(
            [PSCustomObject]@{ online = $true; patchManagement = [PSCustomObject]@{ patchStatus = 'FullyPatched' } }
            [PSCustomObject]@{ online = $true; patchManagement = [PSCustomObject]@{ patchStatus = 'FullyPatched' } }
            [PSCustomObject]@{ online = $false; patchManagement = [PSCustomObject]@{ patchStatus = 'NotPatched' } }
            [PSCustomObject]@{ online = $false; patchManagement = [PSCustomObject]@{ patchStatus = 'NotPatched' } }
        )
        Mock -ModuleName Omzig Get-OmzigDattoDevices { $Devices }
        Mock -ModuleName Omzig Get-OmzigDattoAlerts { @() }

        $View = Get-OmzigTenantView -TenantId 'tenant-1'

        $View.healthScore.Score | Should -Be 50
        $View.healthScore.Components.Count | Should -Be 1
        $View.healthScore.Components[0].Name | Should -Be 'PatchCompliance'
    }

    It 'only persists the health score when it actually changed' {
        $script:BaseRecord.psa.companyId = $null
        $script:BaseRecord.rmm.siteId = $null
        # No PSA, no RMM => no metrics => Score stays $null, which matches the
        # existing record.healthScore ($null), so no write should happen.
        Get-OmzigTenantView -TenantId 'tenant-1' | Out-Null
        Should -Invoke -ModuleName Omzig Set-OmzigTenantRecord -Times 0
    }
}

Describe 'Test-OmzigTenantSettings (§14 validation, §7.1 settings drawer)' {
    It 'accepts a valid tier and vertical' {
        (Test-OmzigTenantSettings -Settings @{ omzigTier = 'summit'; vertical = 'healthcare' }).IsValid | Should -BeTrue
    }

    It 'accepts every documented tier, including $null' {
        foreach ($Tier in @('core', 'edge', 'summit', 'pinnacle', 'core-plus', 'edge-plus', 'premium-plus', $null)) {
            (Test-OmzigTenantSettings -Settings @{ omzigTier = $Tier }).IsValid | Should -BeTrue
        }
    }

    It 'accepts every documented vertical' {
        foreach ($Vertical in @('healthcare', 'legal', 'wealth', 'cpa', 'title', 'hospitality', 'family-office', 'other')) {
            (Test-OmzigTenantSettings -Settings @{ vertical = $Vertical }).IsValid | Should -BeTrue
        }
    }

    It 'rejects an invalid omzigTier' {
        $Result = Test-OmzigTenantSettings -Settings @{ omzigTier = 'gold' }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike "*omzigTier*"
    }

    It 'rejects an invalid vertical' {
        $Result = Test-OmzigTenantSettings -Settings @{ vertical = 'finance' }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike "*vertical*"
    }

    It 'does not validate fields that are absent from the payload' {
        (Test-OmzigTenantSettings -Settings @{ baa = $true }).IsValid | Should -BeTrue
    }

    It 'is valid on an empty settings object' {
        (Test-OmzigTenantSettings -Settings @{}).IsValid | Should -BeTrue
    }

    It 'reports both errors when tier and vertical are both invalid' {
        $Result = Test-OmzigTenantSettings -Settings @{ omzigTier = 'gold'; vertical = 'finance' }
        $Result.Errors.Count | Should -Be 2
    }

    It 'accepts a numeric psa.companyId and a GUID rmm.siteId (audit #13)' {
        $Result = Test-OmzigTenantSettings -Settings @{
            psa = @{ companyId = 12345 }
            rmm = @{ siteId = '11111111-1111-1111-1111-111111111111' }
            baa = $true
        }
        $Result.IsValid | Should -BeTrue
    }

    It 'rejects a non-numeric psa.companyId (path-injection guard)' {
        $Result = Test-OmzigTenantSettings -Settings @{ psa = @{ companyId = '1/../secrets' } }
        $Result.IsValid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -BeLike '*companyId*numeric*'
    }

    It 'rejects a non-GUID rmm.siteId (path-injection guard)' {
        $Result = Test-OmzigTenantSettings -Settings @{ rmm = @{ siteId = 'abc/devices?evil=1' } }
        $Result.IsValid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -BeLike '*siteId*GUID*'
    }

    It 'rejects a non-boolean baa (audit #13 — protect the HIPAA default)' {
        $Result = Test-OmzigTenantSettings -Settings @{ baa = 'nope' }
        $Result.IsValid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -BeLike '*baa must be a boolean*'
    }
}
