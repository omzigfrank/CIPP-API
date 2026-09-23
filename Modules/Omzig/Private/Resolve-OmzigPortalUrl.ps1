function Resolve-OmzigPortalUrl {
    <#
    .SYNOPSIS
    Returns the portal's public base URL (https://host), or $null when it is not known.
    .DESCRIPTION
    Order: app setting OMZIG_PORTAL_URL, then the host CIPP stores for itself in
    Config/InstanceProperties/CIPPURL. It never returns the function app's own hostname
    (WEBSITE_HOSTNAME): that sits behind the Static Web App's authentication, so an
    anonymous call to it is rejected before it reaches CIPP.
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param()

    $Candidate = $env:OMZIG_PORTAL_URL
    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        try {
            $ConfigTable = Get-CIPPTable -tablename 'Config'
            $Row = Get-CIPPAzDataTableEntity @ConfigTable -Filter "PartitionKey eq 'InstanceProperties' and RowKey eq 'CIPPURL'"
            $Candidate = [string]$Row.Value
        } catch {
            Write-Verbose "Portal URL lookup failed: $($_.Exception.Message)"
        }
    }
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }

    $Candidate = $Candidate.Trim().TrimEnd('/')
    if ($Candidate -notmatch '^https?://') { $Candidate = "https://$Candidate" }
    try { $Uri = [System.Uri]$Candidate } catch { return $null }
    if (-not $Uri.Host) { return $null }
    if ($env:WEBSITE_HOSTNAME -and $Uri.Host -eq ($env:WEBSITE_HOSTNAME -split ':')[0]) { return $null }
    return $Uri.GetLeftPart([System.UriPartial]::Authority)
}
