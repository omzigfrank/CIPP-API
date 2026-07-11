function Get-OmzigUpdaterGroup {
    <#
    .SYNOPSIS
    Returns the configured ŌMZIG updater access group.

    .DESCRIPTION
    Only members of this Entra security group may trigger update installs or
    change the update schedule (Set/Start-OmzigUpdateInstall). The group is
    stored on the OmzigUpdateSettings table under RowKey 'UpdateAccess' (set
    by a superadmin via Set-OmzigUpdaterGroup) and falls back to the
    OMZIG_UPDATE_GROUP_ID app setting so infra can seed it out-of-band. When
    neither is set, updates are locked down (fail closed) — no group means no
    one is authorized.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    $GroupId = $null
    $GroupName = $null
    try {
        $Table = Get-CIPPTable -TableName OmzigUpdateSettings
        $Access = Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'Omzig' and RowKey eq 'UpdateAccess'"
        if ($Access.UpdaterGroupId) {
            $GroupId = $Access.UpdaterGroupId
            $GroupName = $Access.UpdaterGroupName
        }
    } catch {
        Write-Verbose "Get-OmzigUpdaterGroup: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($GroupId) -and -not [string]::IsNullOrWhiteSpace($env:OMZIG_UPDATE_GROUP_ID)) {
        $GroupId = $env:OMZIG_UPDATE_GROUP_ID
    }

    [PSCustomObject]@{
        GroupId   = $GroupId
        GroupName = $GroupName
        Configured = -not [string]::IsNullOrWhiteSpace($GroupId)
    }
}
