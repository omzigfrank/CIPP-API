function Invoke-OmzigDattoRmmRequest {
    <#
    .SYNOPSIS
    Calls the Datto RMM v2 API on the configured platform (Vidal in prod).

    .PARAMETER Endpoint
    Path under /api/v2, e.g. 'account/sites' or 'site/{id}/devices'.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method = 'GET',
        $Body
    )

    $BaseUrl = Get-OmzigDattoApiUrl
    $Token = Connect-OmzigDattoRmm
    $Splat = @{
        Uri     = "$BaseUrl/api/v2/$($Endpoint.TrimStart('/'))"
        Method  = $Method
        Headers = @{ Authorization = "Bearer $Token" }
    }
    if ($null -ne $Body) {
        $Splat.Body = ($Body | ConvertTo-Json -Depth 10)
        $Splat.ContentType = 'application/json'
    }
    Invoke-OmzigRestWithRetry -RequestSplat $Splat
}
