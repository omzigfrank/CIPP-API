function Test-OmzigQuoteRequest {
    <#
    .SYNOPSIS
    Validates a quote-engine request payload (§3) before it reaches
    Test-OmzigQuoteFloor.

    .DESCRIPTION
    Factored out of the Invoke-ExecOmzigQuote HTTP entrypoint so the
    validation rules are unit-testable without a $Request/$TriggerMetadata
    stand-in. Checks only structural/shape concerns (product id membership,
    price is a positive number) — the pricing-floor and margin-floor
    business rules themselves live in Test-OmzigQuoteFloor.

    .PARAMETER Body
    Hashtable or PSCustomObject with: productId (required), price (required),
    techHours (optional), vcioHours (optional), overrideToken (optional).

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Body
    )

    $ValidProductIds = @('aira', 'aidf', 'aid', 'maio')

    $HasProperty = {
        param($Obj, $Name)
        if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Name) }
        return @($Obj.PSObject.Properties.Name) -contains $Name
    }
    $GetValue = {
        param($Obj, $Name)
        if ($Obj -is [hashtable]) { return $Obj[$Name] }
        return $Obj.$Name
    }

    $Errors = [System.Collections.Generic.List[string]]::new()

    $ProductId = & $GetValue $Body 'productId'
    if ([string]::IsNullOrEmpty($ProductId)) {
        $Errors.Add('productId is required.')
    } elseif ($ProductId -notin $ValidProductIds) {
        $Errors.Add("productId '$ProductId' is invalid. Allowed: $($ValidProductIds -join ', ').")
    }

    if (-not (& $HasProperty $Body 'price') -or $null -eq (& $GetValue $Body 'price') -or [string]::IsNullOrEmpty((& $GetValue $Body 'price').ToString())) {
        $Errors.Add('price is required.')
    } else {
        $PriceValue = & $GetValue $Body 'price'
        $Parsed = 0
        if (-not [decimal]::TryParse([string]$PriceValue, [ref]$Parsed)) {
            $Errors.Add("price '$PriceValue' must be a number.")
        } elseif ($Parsed -le 0) {
            $Errors.Add("price must be a positive number; got $PriceValue.")
        }
    }

    [PSCustomObject]@{
        IsValid = ($Errors.Count -eq 0)
        Errors  = @($Errors)
    }
}
