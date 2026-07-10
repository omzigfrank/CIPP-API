function Test-OmzigPreflight {
    <#
    .SYNOPSIS
    Config-validation preflight for the ŌMZIG portal (§17 item 5).

    .DESCRIPTION
    Validates that every integration the portal depends on is actually
    configured before the deployment is allowed to proceed. Per Frank's
    confirmed configuration, missing Pax8 credentials HALT deployment with a
    clear error instead of silently disabling license reconciliation.

    Secret presence is checked by name only — values are never read into the
    result object.

    .PARAMETER SecretResolver
    Scriptblock that returns $true when a named secret exists. Defaults to an
    environment-variable probe; production passes a Key Vault-backed resolver.

    .PARAMETER Throw
    Throw on any blocking failure (deployment-gate behaviour). Without it the
    caller gets the structured result and decides.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$SecretResolver = { param($Name) -not [string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable($Name)) },
        [switch]$Throw
    )

    $Config = Get-OmzigConfig
    $Checks = [System.Collections.Generic.List[object]]::new()

    $Definitions = @(
        @{ Name = 'PAX8_CLIENT_ID'; Area = 'Pax8'; Blocking = $true; Message = 'Pax8 OAuth2 client ID missing. License reconciliation cannot run. Generate the API client in Pax8 and store PAX8_CLIENT_ID in Key Vault.' }
        @{ Name = 'PAX8_CLIENT_SECRET'; Area = 'Pax8'; Blocking = $true; Message = 'Pax8 OAuth2 client secret missing. Store PAX8_CLIENT_SECRET in Key Vault.' }
        @{ Name = 'AUTOTASK_USERNAME'; Area = 'Autotask'; Blocking = $true; Message = 'Autotask API user missing. Probe for an existing Omzig integration user first (Find-OmzigAutotaskIntegrationUser); provision omzig-portal@omzig.it if none exists.' }
        @{ Name = 'AUTOTASK_SECRET'; Area = 'Autotask'; Blocking = $true; Message = 'Autotask API secret missing from Key Vault.' }
        @{ Name = 'AUTOTASK_INTEGRATION_CODE'; Area = 'Autotask'; Blocking = $true; Message = 'Autotask API tracking identifier (Integration Vendor "Omzig Portal") missing.' }
        @{ Name = 'DATTO_RMM_API_KEY'; Area = 'DattoRMM'; Blocking = $true; Message = 'Datto RMM API key missing from Key Vault.' }
        @{ Name = 'DATTO_RMM_API_SECRET'; Area = 'DattoRMM'; Blocking = $true; Message = 'Datto RMM API secret missing from Key Vault.' }
        @{ Name = 'CONNECTBOOSTER_API_KEY'; Area = 'ConnectBooster'; Blocking = $false; Message = 'ConnectBooster key missing — invoice reconciliation degrades to Pax8-vs-M365 only.' }
        @{ Name = 'QBO_CLIENT_ID'; Area = 'QuickBooks'; Blocking = $false; Message = 'QuickBooks Online client missing — revenue recognition column disabled in reconciliation.' }
    )

    foreach ($Def in $Definitions) {
        $Present = & $SecretResolver $Def.Name
        $Checks.Add([PSCustomObject]@{
                Name     = $Def.Name
                Area     = $Def.Area
                Present  = [bool]$Present
                Blocking = $Def.Blocking
                Message  = if ($Present) { 'OK' } else { $Def.Message }
            })
    }

    # Sanity: the Datto platform must be one of the six regional platforms.
    $PlatformValid = $null -ne (Get-OmzigDattoPlatformMap)[$Config.DattoRmmPlatform]
    $Checks.Add([PSCustomObject]@{
            Name     = 'DATTO_RMM_PLATFORM'
            Area     = 'DattoRMM'
            Present  = $PlatformValid
            Blocking = $true
            Message  = if ($PlatformValid) { 'OK' } else { "Unknown Datto RMM platform '$($Config.DattoRmmPlatform)'. Valid: $((Get-OmzigDattoPlatformMap).Keys -join ', '). Omzig production is 'vidal'." }
        })

    $BlockingFailures = @($Checks | Where-Object { $_.Blocking -and -not $_.Present })
    $Result = [PSCustomObject]@{
        Passed           = ($BlockingFailures.Count -eq 0)
        BlockingFailures = $BlockingFailures
        Checks           = $Checks
    }

    if ($Throw -and -not $Result.Passed) {
        $Detail = ($BlockingFailures | ForEach-Object { "[$($_.Area)] $($_.Name): $($_.Message)" }) -join "`n"
        throw "Omzig preflight failed — deployment halted.`n$Detail"
    }
    return $Result
}
