@{
    RootModule        = '.\Omzig.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8f2a4c1e-93d7-4b6a-b1f0-6a5c2e9d0741'
    Author            = 'Omzig, Inc.'
    CompanyName       = 'Omzig, Inc.'
    Copyright         = '(c) 2026 Omzig, Inc. All rights reserved.'
    Description       = 'omzig.ai overlay for CIPP-API: PSA abstraction (Autotask primary, HaloPSA stub), Datto RMM (Vidal), break-glass and GDAP sentinels, AI product pricing floors, Omzig tenant records and client health score.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('*')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Omzig', 'CIPP', 'Autotask', 'DattoRMM', 'GDAP')
            ProjectUri = 'https://github.com/omzigfrank/CIPP-API'
        }
    }
}
