function Set-OmzigUpdaterGroup {
    <#
    .SYNOPSIS
    Saves the omzig.ai updater access group (superadmin action).

    .DESCRIPTION
    Persists the Entra security group whose members may trigger update
    installs. Stored on its own RowKey ('UpdateAccess') so it is never
    clobbered by Set-OmzigUpdateSettings (which owns 'UpdateSettings').
    Authorization (superadmin-only) is enforced by the caller
    (Invoke-ExecOmzigUpdates) — this helper only persists.

    .PARAMETER GroupId
    The Entra security group object id (GUID). Empty string clears it, which
    locks updates down until a new group is set.

    .PARAMETER GroupName
    Optional friendly name shown in the UI.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GroupId,
        [string]$GroupName
    )

    $Trimmed = $GroupId.Trim()
    if (-not [string]::IsNullOrWhiteSpace($Trimmed) -and
        $Trimmed -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "GroupId '$Trimmed' is not a valid Entra group object id (GUID)."
    }

    $Table = Get-CIPPTable -TableName OmzigUpdateSettings
    Add-CIPPAzDataTableEntity @Table -Entity @{
        PartitionKey     = 'Omzig'
        RowKey           = 'UpdateAccess'
        UpdaterGroupId   = $Trimmed
        UpdaterGroupName = "$GroupName"
    } -Force | Out-Null

    [PSCustomObject]@{
        Saved     = $true
        GroupId   = $Trimmed
        GroupName = $GroupName
        Configured = -not [string]::IsNullOrWhiteSpace($Trimmed)
    }
}
