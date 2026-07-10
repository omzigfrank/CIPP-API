function Invoke-OmzigAutotaskRequest {
    <#
    .SYNOPSIS
    Calls the Autotask REST API (Appendix A) with zone discovery, the Omzig
    Portal tracking identifier, rate-limit-aware retries and paging support.

    .PARAMETER Endpoint
    Path under /v1.0, e.g. 'Tickets/query' or 'Companies/12345'.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        $Body,
        [string]$Username = $env:AUTOTASK_USERNAME,
        [string]$Secret = $env:AUTOTASK_SECRET,
        [string]$IntegrationCode = $env:AUTOTASK_INTEGRATION_CODE
    )

    foreach ($Pair in @(@('AUTOTASK_USERNAME', $Username), @('AUTOTASK_SECRET', $Secret), @('AUTOTASK_INTEGRATION_CODE', $IntegrationCode))) {
        if ([string]::IsNullOrEmpty($Pair[1])) {
            throw "Autotask credential $($Pair[0]) missing. Run Test-OmzigPreflight."
        }
    }

    $ZoneUrl = Get-OmzigAutotaskZoneUrl -Username $Username
    $Splat = @{
        Uri     = "$ZoneUrl/v1.0/$($Endpoint.TrimStart('/'))"
        Method  = $Method
        Headers = @{
            UserName           = $Username
            Secret             = $Secret
            ApiIntegrationCode = $IntegrationCode
        }
    }
    if ($null -ne $Body) {
        $Splat.Body = ($Body | ConvertTo-Json -Depth 10)
        $Splat.ContentType = 'application/json'
    }
    Invoke-OmzigRestWithRetry -RequestSplat $Splat
}
