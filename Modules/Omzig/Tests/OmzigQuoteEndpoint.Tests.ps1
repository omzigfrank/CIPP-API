# Pester suite for the omzig.ai quote engine surface (spec §3): the
# Test-OmzigQuoteRequest validation helper and the two HTTP entrypoints that
# expose the pricing floors and the quote evaluator. Self-contained: no
# network, no CIPP table storage. Test-OmzigQuoteFloor and
# Get-OmzigPricingFloors are pure/deterministic and already unit-tested
# elsewhere (Omzig.Tests.ps1), so the entrypoint tests below call the real
# functions rather than mocking them; only the CIPPCore logging/exception
# helpers (Write-LogMessage, Get-CippException) are stubbed, matching the
# convention in Tests/Endpoint/*.Tests.ps1.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Omzig.psd1') -Force

    # [HttpStatusCode] / [HttpResponseContext] are bare names supplied by the
    # Azure Functions PowerShell worker at runtime; add the accelerator here
    # so the dot-sourced entrypoint scripts resolve them the same way outside
    # the Functions host.
    $Accelerators = [PowerShell].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not $Accelerators::Get.ContainsKey('HttpStatusCode')) {
        $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode])
    }

    class HttpResponseContext {
        [int]$StatusCode
        [object]$Body
    }

    function Get-CippException {
        param($Exception)
        [PSCustomObject]@{ NormalizedError = $Exception.Exception.Message }
    }
    function Write-LogMessage {
        param($API, $tenant, $headers, $message, $sev, $LogData)
    }

    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $EntrypointDir = Join-Path $RepoRoot 'Modules' 'CIPPHTTP' 'Public' 'Entrypoints' 'HTTP Functions' 'Omzig'

    . (Join-Path $EntrypointDir 'Invoke-ListOmzigPricingFloors.ps1')
    . (Join-Path $EntrypointDir 'Invoke-ExecOmzigQuote.ps1')

    function New-OmzigTestRequest {
        param($Body)
        [PSCustomObject]@{
            Params  = [PSCustomObject]@{ CIPPEndpoint = 'test' }
            Headers = [PSCustomObject]@{}
            Body    = $Body
        }
    }
}

Describe 'Test-OmzigQuoteRequest (§3 quote request validation)' {
    It 'accepts a valid payload with zero hours' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'aira'; price = 4000; techHours = 0; vcioHours = 0 }
        $Result.IsValid | Should -BeTrue
        $Result.Errors | Should -BeNullOrEmpty
    }

    It 'rejects a payload missing techHours/vcioHours (audit #9 — no fake 100% margin)' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'aira'; price = 4000 }
        $Result.IsValid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -BeLike '*techHours is required*'
        ($Result.Errors -join ' ') | Should -BeLike '*vcioHours is required*'
    }

    It 'rejects negative techHours/vcioHours (audit #9 — no inflated margin)' {
        $Neg = Test-OmzigQuoteRequest -Body @{ productId = 'aira'; price = 4000; techHours = -5; vcioHours = 0 }
        $Neg.IsValid | Should -BeFalse
        ($Neg.Errors -join ' ') | Should -BeLike '*techHours must be zero or positive*'
    }

    It 'accepts a valid full payload with all optional fields' {
        $Result = Test-OmzigQuoteRequest -Body @{
            productId     = 'maio'
            price         = 3600
            techHours     = 5
            vcioHours     = 2
            overrideToken = 'token-value'
        }
        $Result.IsValid | Should -BeTrue
    }

    It 'rejects a missing productId' {
        $Result = Test-OmzigQuoteRequest -Body @{ price = 4000 }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike '*productId*required*'
    }

    It 'rejects an invalid productId' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'widgets'; price = 4000 }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike "*productId*'widgets'*invalid*"
    }

    It 'rejects a missing price' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'aira' }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike '*price*required*'
    }

    It 'rejects a zero price' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'aira'; price = 0 }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike '*positive*'
    }

    It 'rejects a negative price' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'aira'; price = -500 }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike '*positive*'
    }

    It 'rejects a non-numeric price' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'aira'; price = 'a lot' }
        $Result.IsValid | Should -BeFalse
        $Result.Errors[0] | Should -BeLike '*must be a number*'
    }

    It 'reports both errors when productId and price are both invalid' {
        $Result = Test-OmzigQuoteRequest -Body @{ productId = 'widgets'; price = -1; techHours = 0; vcioHours = 0 }
        $Result.Errors.Count | Should -Be 2
    }

    It 'validates a PSCustomObject payload the same as a hashtable (Request.Body shape)' {
        $Body = [PSCustomObject]@{ productId = 'aidf'; price = 11000; techHours = 0; vcioHours = 0 }
        (Test-OmzigQuoteRequest -Body $Body).IsValid | Should -BeTrue

        $BadBody = [PSCustomObject]@{ productId = 'nope'; price = 11000; techHours = 0; vcioHours = 0 }
        (Test-OmzigQuoteRequest -Body $BadBody).IsValid | Should -BeFalse
    }

    It 'still treats overrideToken/overrideExpiry as optional' {
        (Test-OmzigQuoteRequest -Body @{ productId = 'aid'; price = 15500; techHours = 2; vcioHours = 1 }).IsValid | Should -BeTrue
    }
}

Describe 'Invoke-ListOmzigPricingFloors (entrypoint)' {
    It 'returns all four products with their pricing floors' {
        $Response = Invoke-ListOmzigPricingFloors -Request (New-OmzigTestRequest -Body $null) -TriggerMetadata $null

        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        $Response.Body | Should -HaveCount 4
        ($Response.Body | Where-Object Id -EQ 'aira').SmbFloor | Should -Be 4000
        ($Response.Body | Where-Object Id -EQ 'maio').MinimumTermMonths | Should -Be 12
    }
}

Describe 'Invoke-ExecOmzigQuote (entrypoint)' {
    It 'returns 400 with a clear message for an invalid productId' {
        $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{ productId = 'widgets'; price = 4000 })
        $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
        $Response.Body.Error | Should -BeLike '*productId*invalid*'
    }

    It 'returns 400 with a clear message for a non-positive price' {
        $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{ productId = 'aira'; price = 0 })
        $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
        $Response.Body.Error | Should -BeLike '*positive*'
    }

    It 'returns 400 with a clear message for a missing price' {
        $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{ productId = 'aira' })
        $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
        $Response.Body.Error | Should -BeLike '*price*required*'
    }

    It 'evaluates a valid at-floor quote and passes through the full Test-OmzigQuoteFloor result' {
        $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{
                productId = 'aira'
                price     = 4000
                techHours = 8
                vcioHours = 4
            })
        $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        $Response.Body.ProductId | Should -Be 'aira'
        $Response.Body.Price | Should -Be 4000
        $Response.Body.Approved | Should -BeTrue
        $Response.Body.Violations | Should -BeNullOrEmpty
        $Response.Body.PSObject.Properties.Name | Should -Contain 'GrossMargin'
        $Response.Body.PSObject.Properties.Name | Should -Contain 'Floor'
        $Response.Body.PSObject.Properties.Name | Should -Contain 'OverrideValid'
    }

    It 'evaluates a below-floor quote as refused with violations' {
        $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{ productId = 'aidf'; price = 9000; techHours = 0; vcioHours = 0 })
        $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        $Response.Body.Approved | Should -BeFalse
        $Response.Body.Violations.Count | Should -BeGreaterThan 0
    }

    It 'never discounts AIRA even with an override token supplied' {
        $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{
                productId     = 'aira'
                price         = 2000
                techHours     = 0
                vcioHours     = 0
                overrideToken = 'whatever'
            })
        $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
        $Response.Body.Approved | Should -BeFalse
        ($Response.Body.Violations -join ' ') | Should -BeLike '*never discounted*'
    }

    It 'never returns a signingKey property on the response body' {
        $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{ productId = 'aira'; price = 4000; techHours = 0; vcioHours = 0 })
        $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

        $Response.Body.PSObject.Properties.Name | Should -Not -Contain 'SigningKey'
        $Response.Body.PSObject.Properties.Name | Should -Not -Contain 'signingKey'
    }

    It 'ignores a signingKey supplied in the request body (env var is the only source)' {
        $Old = $env:OMZIG_OVERRIDE_SIGNING_KEY
        try {
            $env:OMZIG_OVERRIDE_SIGNING_KEY = 'real-key'
            $Request = New-OmzigTestRequest -Body ([PSCustomObject]@{
                    productId  = 'aidf'
                    price      = 9000
                    techHours  = 0
                    vcioHours  = 0
                    signingKey = 'attacker-supplied-key'
                })
            $Response = Invoke-ExecOmzigQuote -Request $Request -TriggerMetadata $null

            # No override token was supplied, so the quote is simply refused;
            # the point is that a signingKey in the body has no effect at all.
            $Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::OK)
            $Response.Body.OverrideValid | Should -BeFalse
        } finally {
            $env:OMZIG_OVERRIDE_SIGNING_KEY = $Old
        }
    }
}

Describe 'Override token expiry binding (audit #8)' {
    BeforeAll {
        $script:SignKey = 'test-signing-key-abc123'
        function script:MakeToken {
            param($ProductId, $Price, $Expiry)
            $Msg = if ($null -ne $Expiry) { "${ProductId}:${Price}:${Expiry}" } else { "${ProductId}:${Price}" }
            $Hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($script:SignKey))
            [Convert]::ToBase64String($Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Msg)))
        }
    }

    It 'approves a below-floor quote with a valid, unexpired expiry-bound token' {
        $Expiry = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
        $Token = script:MakeToken 'aidf' 9000 $Expiry
        $Result = Test-OmzigQuoteFloor -ProductId 'aidf' -Price 9000 -TechHours 20 -VcioHours 10 -OverrideToken $Token -OverrideExpiry $Expiry -SigningKey $script:SignKey
        $Result.OverrideValid | Should -BeTrue
        $Result.Approved | Should -BeTrue
    }

    It 'refuses an expired token even if the signature is otherwise valid' {
        $Expiry = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeSeconds()
        $Token = script:MakeToken 'aidf' 9000 $Expiry
        $Result = Test-OmzigQuoteFloor -ProductId 'aidf' -Price 9000 -TechHours 20 -VcioHours 10 -OverrideToken $Token -OverrideExpiry $Expiry -SigningKey $script:SignKey
        $Result.OverrideValid | Should -BeFalse
        $Result.Approved | Should -BeFalse
        ($Result.Violations -join ' ') | Should -BeLike '*expired*'
    }

    It 'does not accept a legacy (no-expiry) token as if it were expiry-bound' {
        # A token signed WITHOUT expiry must not validate when an expiry is claimed.
        $Expiry = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
        $LegacyToken = script:MakeToken 'aidf' 9000 $null
        $Result = Test-OmzigQuoteFloor -ProductId 'aidf' -Price 9000 -TechHours 20 -VcioHours 10 -OverrideToken $LegacyToken -OverrideExpiry $Expiry -SigningKey $script:SignKey
        $Result.OverrideValid | Should -BeFalse
    }

    It 'still accepts a legacy unbounded token when no expiry is supplied (backward compat)' {
        $Token = script:MakeToken 'aidf' 9000 $null
        $Result = Test-OmzigQuoteFloor -ProductId 'aidf' -Price 9000 -TechHours 20 -VcioHours 10 -OverrideToken $Token -SigningKey $script:SignKey
        $Result.OverrideValid | Should -BeTrue
    }

    It 'refuses legacy unbounded tokens when OMZIG_OVERRIDE_REQUIRE_EXPIRY=true' {
        $Old = $env:OMZIG_OVERRIDE_REQUIRE_EXPIRY
        try {
            $env:OMZIG_OVERRIDE_REQUIRE_EXPIRY = 'true'
            $Token = script:MakeToken 'aidf' 9000 $null
            $Result = Test-OmzigQuoteFloor -ProductId 'aidf' -Price 9000 -TechHours 20 -VcioHours 10 -OverrideToken $Token -SigningKey $script:SignKey
            $Result.OverrideValid | Should -BeFalse
            ($Result.Violations -join ' ') | Should -BeLike '*must carry an expiry*'
        } finally {
            $env:OMZIG_OVERRIDE_REQUIRE_EXPIRY = $Old
        }
    }

    It 'rejects negative hours at the floor boundary (audit #9 defense in depth)' {
        { Test-OmzigQuoteFloor -ProductId 'aidf' -Price 11000 -TechHours -5 -VcioHours 0 } | Should -Throw
    }
}
