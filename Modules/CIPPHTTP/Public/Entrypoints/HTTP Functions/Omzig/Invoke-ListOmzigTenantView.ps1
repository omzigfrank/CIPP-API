function Invoke-ListOmzigTenantView {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Administration.Read
    .DESCRIPTION
        Returns the ŌMZIG single-pane tenant view (§7.1): the Omzig tenant
        record fused with PSA ticket/contract summaries, Datto RMM
        device/alert counts and the Client Health Score.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $TenantFilter = $Request.Query.tenantFilter

    try {
        if ([string]::IsNullOrEmpty($TenantFilter)) {
            throw 'tenantFilter is required.'
        }

        $View = Get-OmzigTenantView -TenantId $TenantFilter
        $StatusCode = [HttpStatusCode]::OK
        $Body = $View
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API $APIName -tenant $TenantFilter -headers $Request.Headers -message "Failed to load Omzig tenant view: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::BadRequest
        $Body = @{ Error = $ErrorMessage.NormalizedError }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
