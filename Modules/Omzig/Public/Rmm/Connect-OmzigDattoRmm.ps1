function Connect-OmzigDattoRmm {
    <#
    .SYNOPSIS
    Gets a Datto RMM OAuth2 access token (client-credentials flow, Appendix B).

    .DESCRIPTION
    Datto RMM issues API key + secret per user (user profile → API Details).
    Tokens are requested against the configured regional platform (Vidal for
    Omzig production) and cached for the token lifetime.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [string]$ApiKey = $env:DATTO_RMM_API_KEY,
        [string]$ApiSecret = $env:DATTO_RMM_API_SECRET,
        [string]$Platform = (Get-OmzigConfig).DattoRmmPlatform
    )

    if ([string]::IsNullOrEmpty($ApiKey) -or [string]::IsNullOrEmpty($ApiSecret)) {
        throw 'Datto RMM credentials missing. Run Test-OmzigPreflight — DATTO_RMM_API_KEY / DATTO_RMM_API_SECRET must exist in Key Vault.'
    }

    if ($script:OmzigDattoToken -and $script:OmzigDattoTokenExpiry -gt (Get-Date).AddMinutes(2)) {
        return $script:OmzigDattoToken
    }

    $BaseUrl = Get-OmzigDattoApiUrl -Platform $Platform
    $Splat = @{
        Uri         = "$BaseUrl/auth/oauth/token"
        Method      = 'POST'
        ContentType = 'application/x-www-form-urlencoded'
        Headers     = @{
            Authorization = 'Basic {0}' -f [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('public-client:public'))
        }
        Body        = @{
            grant_type = 'password'
            username   = $ApiKey
            password   = $ApiSecret
        }
    }
    $Token = Invoke-OmzigRestWithRetry -RequestSplat $Splat
    $script:OmzigDattoToken = $Token.access_token
    $script:OmzigDattoTokenExpiry = (Get-Date).AddSeconds([int]$Token.expires_in)
    return $script:OmzigDattoToken
}
