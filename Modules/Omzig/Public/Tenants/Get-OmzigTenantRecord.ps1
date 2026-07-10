function Get-OmzigTenantRecord {
    <#
    .SYNOPSIS
    Reads the Omzig tenant record (§14 omzig_tenants shape) from CIPP storage.

    .DESCRIPTION
    Stored in the OmzigTenants table via the upstream Get-CIPPTable helpers so
    the overlay rides the same storage plumbing as the rest of CIPP-API. A
    tenant with no record yet gets the confirmed defaults — most importantly
    baa=true (§17 item 11: all tenants default to BAA mode on day 1).

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId
    )

    # OData filter escaping: single quotes in the key are doubled so a crafted
    # tenant id cannot alter the filter expression.
    $SafeTenantId = $TenantId -replace "'", "''"
    $Table = Get-CIPPTable -TableName 'OmzigTenants'
    $Entity = Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'Tenant' and RowKey eq '$SafeTenantId'"

    if (-not $Entity) {
        return New-OmzigTenantDefaults -TenantId $TenantId
    }

    $Record = $Entity.Data | ConvertFrom-Json
    return $Record
}
