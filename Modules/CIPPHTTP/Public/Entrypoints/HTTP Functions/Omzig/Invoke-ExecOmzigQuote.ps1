function Invoke-ExecOmzigQuote {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    .DESCRIPTION
        Evaluates a omzig.ai AI product quote against the §3 pricing floors and
        70% gross margin floor via Test-OmzigQuoteFloor. Accepts an optional
        Frank-signed executive override token; the signing key itself is only
        ever read from the OMZIG_OVERRIDE_SIGNING_KEY environment variable —
        it is never accepted from the request body, returned in the response,
        or written to the log.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    try {
        $Validation = Test-OmzigQuoteRequest -Body $Request.Body
        if (-not $Validation.IsValid) {
            throw ($Validation.Errors -join ' ')
        }

        $QuoteParams = @{
            ProductId = $Request.Body.productId
            Price     = [decimal]$Request.Body.price
        }
        if (@($Request.Body.PSObject.Properties.Name) -contains 'techHours' -and $null -ne $Request.Body.techHours) {
            $QuoteParams.TechHours = [decimal]$Request.Body.techHours
        }
        if (@($Request.Body.PSObject.Properties.Name) -contains 'vcioHours' -and $null -ne $Request.Body.vcioHours) {
            $QuoteParams.VcioHours = [decimal]$Request.Body.vcioHours
        }
        if (@($Request.Body.PSObject.Properties.Name) -contains 'overrideToken' -and -not [string]::IsNullOrEmpty($Request.Body.overrideToken)) {
            $QuoteParams.OverrideToken = $Request.Body.overrideToken
        }
        # Audit #8: optional expiry that binds the override token to a deadline.
        if (@($Request.Body.PSObject.Properties.Name) -contains 'overrideExpiry' -and -not [string]::IsNullOrEmpty($Request.Body.overrideExpiry.ToString())) {
            $QuoteParams.OverrideExpiry = [long]$Request.Body.overrideExpiry
        }

        # Signing key is never accepted from the request body — the env var
        # (Test-OmzigQuoteFloor's own default) is the only source.
        $Result = Test-OmzigQuoteFloor @QuoteParams
        Write-LogMessage -headers $Headers -API $APIName -message "Evaluated Omzig quote for product $($QuoteParams.ProductId): Approved=$($Result.Approved)" -Sev 'Info'

        $StatusCode = [HttpStatusCode]::OK
        $Body = $Result
    } catch {
        # Audit #4-low: normalize the error rather than returning the raw
        # exception text/stack to the client.
        $StatusCode = [HttpStatusCode]::BadRequest
        $Body = @{ Error = (Get-CippException -Exception $_).NormalizedError }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
