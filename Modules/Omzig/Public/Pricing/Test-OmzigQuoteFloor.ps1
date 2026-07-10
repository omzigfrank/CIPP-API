function Test-OmzigQuoteFloor {
    <#
    .SYNOPSIS
    Quote-engine gate: enforces AI product pricing floors and the 70% gross
    margin floor (§3). Refuses any quote below floor without an executive
    override token signed by Frank.

    .DESCRIPTION
    Margin is computed against the Omzig AI Pricing Model v4 cost baselines:
    tech labor $85/hr, Frank/vCIO time $100/hr. Override tokens are validated
    as an HMAC-SHA256 signature of "<productId>:<price>" using the
    OMZIG_OVERRIDE_SIGNING_KEY secret (Key Vault; issued only by Frank's CLI
    signature or a UI approval — Appendix D).

    .PARAMETER ProductId
    aira | aidf | aid | maio

    .PARAMETER Price
    Quoted price (per engagement; per month for MAIO).

    .PARAMETER TechHours / VcioHours
    Estimated delivery effort — drives real-time gross margin.

    .PARAMETER OverrideToken
    Frank-signed executive override (base64 HMAC). Only accepted for
    below-floor quotes on products that may be discounted; AIRA is never
    discounted, so even a valid token cannot take AIRA below floor.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('aira', 'aidf', 'aid', 'maio')][string]$ProductId,
        [Parameter(Mandatory)][decimal]$Price,
        [decimal]$TechHours = 0,
        [decimal]$VcioHours = 0,
        [string]$OverrideToken,
        [string]$SigningKey = $env:OMZIG_OVERRIDE_SIGNING_KEY
    )

    $TechRate = 85   # $/hr, 1099 contractor rate
    $VcioRate = 100  # $/hr, internal cost rate — never billed to client line items

    $Product = Get-OmzigPricingFloors | Where-Object Id -EQ $ProductId
    $Cost = ($TechHours * $TechRate) + ($VcioHours * $VcioRate)
    $Margin = if ($Price -gt 0) { [math]::Round(($Price - $Cost) / $Price, 4) } else { 0 }

    $Violations = [System.Collections.Generic.List[string]]::new()
    if ($Price -lt $Product.SmbFloor) {
        $Violations.Add("Price $Price is below the $($Product.Name) floor of $($Product.SmbFloor).")
    }
    if ($Margin -lt $Product.MarginFloor) {
        $Violations.Add("Gross margin $($Margin.ToString('P1')) is below the $($Product.MarginFloor.ToString('P0')) floor (cost basis: $Cost).")
    }

    $OverrideValid = $false
    if ($Violations.Count -gt 0 -and -not [string]::IsNullOrEmpty($OverrideToken)) {
        if ($Product.NeverDiscounted) {
            $Violations.Add("$($Product.Name) is never discounted — override tokens are not accepted for this product.")
        } elseif ([string]::IsNullOrEmpty($SigningKey)) {
            $Violations.Add('OMZIG_OVERRIDE_SIGNING_KEY is not configured; override token cannot be verified.')
        } else {
            $Hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($SigningKey))
            $Expected = [Convert]::ToBase64String($Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("${ProductId}:${Price}")))
            $OverrideValid = [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                [Text.Encoding]::UTF8.GetBytes($Expected),
                [Text.Encoding]::UTF8.GetBytes($OverrideToken))
            if (-not $OverrideValid) { $Violations.Add('Override token signature is invalid for this product/price.') }
        }
    }

    [PSCustomObject]@{
        ProductId     = $ProductId
        Price         = $Price
        Cost          = $Cost
        GrossMargin   = $Margin
        Floor         = $Product.SmbFloor
        Violations    = $Violations
        OverrideValid = $OverrideValid
        Approved      = ($Violations.Count -eq 0) -or ($OverrideValid -and -not $Product.NeverDiscounted)
    }
}
