function Get-OmzigDattoAlerts {
    <#
    .SYNOPSIS
    Lists open Datto RMM alerts for a site (single-pane tenant view, §7.1).

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteUid,
        [switch]$Resolved
    )

    $State = if ($Resolved) { 'resolved' } else { 'open' }
    # Audit #13: URL-encode the caller-influenced site segment (defense in depth).
    (Invoke-OmzigDattoRmmRequest -Endpoint "site/$([uri]::EscapeDataString($SiteUid))/alerts/$State").alerts
}
