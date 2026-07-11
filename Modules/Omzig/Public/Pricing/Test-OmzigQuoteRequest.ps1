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

    # Audit #9: techHours/vcioHours are REQUIRED and must be non-negative.
    # Omitting them defaulted the cost basis to 0 → a fake 100% gross margin
    # that always cleared the 70% floor; a negative value pushed the cost
    # below zero to inflate margin past 100%. Both are now rejected up front.
    foreach ($HoursField in @('techHours', 'vcioHours')) {
        if (-not (& $HasProperty $Body $HoursField) -or $null -eq (& $GetValue $Body $HoursField) -or [string]::IsNullOrEmpty((& $GetValue $Body $HoursField).ToString())) {
            $Errors.Add("$HoursField is required (use 0 only when there is genuinely no such effort).")
        } else {
            $HoursValue = & $GetValue $Body $HoursField
            $ParsedHours = 0
            if (-not [decimal]::TryParse([string]$HoursValue, [ref]$ParsedHours)) {
                $Errors.Add("$HoursField '$HoursValue' must be a number.")
            } elseif ($ParsedHours -lt 0) {
                $Errors.Add("$HoursField must be zero or positive; got $HoursValue.")
            }
        }
    }

    [PSCustomObject]@{
        IsValid = ($Errors.Count -eq 0)
        Errors  = @($Errors)
    }
}
