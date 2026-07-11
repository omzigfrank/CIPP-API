function Get-OmzigDattoDevices {
    <#
    .SYNOPSIS
    Lists devices for a Datto RMM site — feeds the single-pane tenant view
    (device count, online/offline, patch status) and the health score (§7.1).

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteUid,
        [int]$MaxPages = 50
    )

    $Results = [System.Collections.Generic.List[object]]::new()
    # Audit #13: URL-encode the caller-influenced path segment so it can't add
    # query params or traverse to other Datto endpoints (defense in depth on
    # top of the GUID validation at the settings boundary).
    $Endpoint = "site/$([uri]::EscapeDataString($SiteUid))/devices?max=250&page=0"
    for ($Page = 0; $Page -lt $MaxPages; $Page++) {
        $Response = Invoke-OmzigDattoRmmRequest -Endpoint $Endpoint
        foreach ($Device in $Response.devices) { $Results.Add($Device) }
        if ([string]::IsNullOrEmpty($Response.pageDetails.nextPageUrl)) { break }
        $Endpoint = ($Response.pageDetails.nextPageUrl -split '/api/v2/')[-1]
    }
    return $Results
}
