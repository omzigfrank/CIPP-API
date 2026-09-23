function Resolve-OmzigPortalUrl {
    <#
    .SYNOPSIS
    Returns the portal's public base URL (https://host), or $null when it is not known.
    .DESCRIPTION
    Order: app setting OMZIG_PORTAL_URL, then the host CIPP stores for itself in
    Config/InstanceProperties/CIPPURL. It never returns a *.azurewebsites.net host: those
    are function apps, never the portal (a Static Web App), and they reject an anonymous
    call before it reaches CIPP. On 2026-09-23 the stored CIPPURL still named the retired
    app cippwemix.azurewebsites.net, and all 12 warm-up pings got HTTP 403.
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
    $SiteHost = ($env:WEBSITE_HOSTNAME -split ':')[0]
    if ($Uri.Host -like '*.azurewebsites.net' -or ($SiteHost -and $Uri.Host -eq $SiteHost)) {
        Write-Warning "OmzigPortalWarmup: '$($Uri.Host)' is a function app, not the portal; set OMZIG_PORTAL_URL"
        return $null
    }
    return $Uri.GetLeftPart([System.UriPartial]::Authority)
}
