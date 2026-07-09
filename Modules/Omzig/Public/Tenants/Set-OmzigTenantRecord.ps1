function Set-OmzigTenantRecord {
    <#
    .SYNOPSIS
    Upserts the Omzig tenant record (§14). New records inherit the day-1
    defaults (baa=true, §17 item 11) before the supplied properties apply.

    .PARAMETER Properties
    Hashtable of record fields to set, e.g. @{ omzigTier = 'edge'; vertical = 'legal' }.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][hashtable]$Properties
    )

    $Record = Get-OmzigTenantRecord -TenantId $TenantId
    foreach ($Key in $Properties.Keys) {
        if ($Record.PSObject.Properties.Name -contains $Key) {
            $Record.$Key = $Properties[$Key]
        } else {
            $Record | Add-Member -NotePropertyName $Key -NotePropertyValue $Properties[$Key]
        }
    }

    if ($PSCmdlet.ShouldProcess($TenantId, 'Upsert Omzig tenant record')) {
        $Table = Get-CIPPTable -TableName 'OmzigTenants'
        $Entity = @{
            PartitionKey = 'Tenant'
            RowKey       = $TenantId
            Data         = [string]($Record | ConvertTo-Json -Depth 10 -Compress)
        }
        Add-CIPPAzDataTableEntity @Table -Entity $Entity -Force
    }
    return $Record
}
