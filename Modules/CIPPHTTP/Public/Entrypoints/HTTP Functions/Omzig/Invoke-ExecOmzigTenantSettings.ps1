function Invoke-ExecOmzigTenantSettings {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Administration.ReadWrite
    .DESCRIPTION
        Updates the Omzig tenant record (omzigTier, vertical, baa, psa, rmm
        mappings) that backs the single-pane tenant view (§7.1). Accepts any
        subset of the settable fields; omzigTier and vertical are validated
        against the closed value sets from §14.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $Request.Body.tenantFilter.value ?? $Request.Body.tenantFilter

    try {
        if ([string]::IsNullOrEmpty($TenantFilter)) {
            throw 'tenantFilter is required.'
        }

        $Validation = Test-OmzigTenantSettings -Settings $Request.Body
        if (-not $Validation.IsValid) {
            throw ($Validation.Errors -join ' ')
        }

        $Properties = @{}
        foreach ($Key in @('omzigTier', 'vertical', 'baa', 'psa', 'rmm')) {
            if (@($Request.Body.PSObject.Properties.Name) -contains $Key) {
                $Properties[$Key] = $Request.Body.$Key
            }
        }

        $Record = Set-OmzigTenantRecord -TenantId $TenantFilter -Properties $Properties
        Write-LogMessage -headers $Headers -API $APIName -message "Updated Omzig tenant settings for $TenantFilter" -Sev 'Info' -tenant $TenantFilter

        $StatusCode = [HttpStatusCode]::OK
        $Body = $Record
    } catch {
        $StatusCode = [HttpStatusCode]::BadRequest
        $Body = @{ Error = $_.Exception.Message }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
