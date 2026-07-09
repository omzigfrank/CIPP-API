function Get-OmzigDattoSites {
    <#
    .SYNOPSIS
    Lists Datto RMM sites (paged) for tenant-mapping and the single-pane view.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [int]$MaxPages = 50
    )

    $Results = [System.Collections.Generic.List[object]]::new()
    $Endpoint = 'account/sites?max=250&page=0'
    for ($Page = 0; $Page -lt $MaxPages; $Page++) {
        $Response = Invoke-OmzigDattoRmmRequest -Endpoint $Endpoint
        foreach ($Site in $Response.sites) { $Results.Add($Site) }
        if ([string]::IsNullOrEmpty($Response.pageDetails.nextPageUrl)) { break }
        $Endpoint = ($Response.pageDetails.nextPageUrl -split '/api/v2/')[-1]
    }
    return $Results
}
