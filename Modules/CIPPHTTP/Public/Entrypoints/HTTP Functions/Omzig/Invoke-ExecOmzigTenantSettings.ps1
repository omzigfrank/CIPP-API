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

        # Audit #13: a BAA toggle changes the HIPAA/compliance posture, so log
        # it distinctly (and at Alert severity when it's being turned OFF) for
        # the audit trail — not buried in the generic settings-update line.
        if ($Properties.ContainsKey('baa')) {
            $BaaState = if ($Properties['baa']) { 'ENABLED' } else { 'DISABLED' }
            $BaaSev = if ($Properties['baa']) { 'Info' } else { 'Alert' }
            Write-LogMessage -headers $Headers -API $APIName -message "Omzig BAA mode $BaaState for tenant $TenantFilter" -Sev $BaaSev -tenant $TenantFilter
        }
        Write-LogMessage -headers $Headers -API $APIName -message "Updated Omzig tenant settings for $TenantFilter" -Sev 'Info' -tenant $TenantFilter

        $StatusCode = [HttpStatusCode]::OK
        $Body = $Record
    } catch {
        # Audit #4-low: normalize rather than returning raw exception text.
        $StatusCode = [HttpStatusCode]::BadRequest
        $Body = @{ Error = (Get-CippException -Exception $_).NormalizedError }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
