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
        # Audit #9: negative hours would push the cost basis below zero and
        # inflate margin past 100%. Reject at the boundary as defense in depth
        # (Test-OmzigQuoteRequest also rejects them before we get here).
        [ValidateRange(0, [double]::MaxValue)][decimal]$TechHours = 0,
        [ValidateRange(0, [double]::MaxValue)][decimal]$VcioHours = 0,
        [string]$OverrideToken,
        # Audit #8: optional Unix-seconds expiry. When the caller supplies an
        # expiry, it is bound into the signed message and the token is rejected
        # once past — so a leaked override is no longer replayable forever.
        [Nullable[long]]$OverrideExpiry,
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
        } elseif ($null -ne $OverrideExpiry) {
            # Expiry-bound token (audit #8): reject once past, otherwise verify
            # the signature over "<productId>:<price>:<expiry>".
            $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($OverrideExpiry -lt $Now) {
                $Violations.Add('Override token has expired.')
            } else {
                $Hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($SigningKey))
                $Expected = [Convert]::ToBase64String($Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("${ProductId}:${Price}:${OverrideExpiry}")))
                $OverrideValid = [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                    [Text.Encoding]::UTF8.GetBytes($Expected),
                    [Text.Encoding]::UTF8.GetBytes($OverrideToken))
                if (-not $OverrideValid) { $Violations.Add('Override token signature is invalid for this product/price/expiry.') }
            }
        } elseif ($env:OMZIG_OVERRIDE_REQUIRE_EXPIRY -eq 'true') {
            # Migration switch: once Frank's signer emits expiry-bound tokens,
            # set OMZIG_OVERRIDE_REQUIRE_EXPIRY=true to refuse legacy unbounded
            # (indefinitely replayable) tokens entirely.
            $Violations.Add('Override tokens must carry an expiry; legacy unbounded tokens are no longer accepted.')
        } else {
            # Legacy unbounded token: "<productId>:<price>" (no expiry). Still
            # accepted for backward compatibility until the signer is updated.
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
