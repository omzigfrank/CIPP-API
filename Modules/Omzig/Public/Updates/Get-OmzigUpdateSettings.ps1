function Get-OmzigUpdateSettings {
    <#
    .SYNOPSIS
    Reads the ŌMZIG scheduled-update settings.

    .DESCRIPTION
    Settings are persisted in the OmzigUpdateSettings table. The install
    workflow itself reads the mirrored GitHub repository variables (set by
    Set-OmzigUpdateSettings); the table copy is the UI's source of truth.
    Defaults: auto-update off, stable channel, direct install mode.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    $Settings = $null
    try {
        $Table = Get-CIPPTable -TableName OmzigUpdateSettings
        $Settings = Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'Omzig' and RowKey eq 'UpdateSettings'"
    } catch {
        Write-Verbose "Get-OmzigUpdateSettings: $($_.Exception.Message)"
    }

    [PSCustomObject]@{
        AutoUpdate = if ($null -ne $Settings.AutoUpdate) { $Settings.AutoUpdate -eq 'true' } else { $false }
        Channel    = if ($Settings.Channel) { $Settings.Channel } else { 'stable' }
        Mode       = if ($Settings.Mode) { $Settings.Mode } else { 'install' }
    }
}
