<#
.SYNOPSIS
    Rotates the CIPP-SAM client secret and repoints the Key Vault at the new value.

.DESCRIPTION
    This is the fix for:

        Error Loading data: Could not get token: invalid_client:AADSTS7000222:
        The provided client secret keys for app '<appId>' are expired.

    What it does, in order:
      1  Reads applicationid / tenantid from the CIPP Key Vault
      2  Creates a NEW client secret on the CIPP-SAM app registration (append - existing
         credentials are left alone, so nothing breaks mid-rotation)
      3  Verifies the new secret actually acquires a Graph token BEFORE storing it
      4  Writes it to the vault's 'applicationsecret' with matching expiry metadata
      5  Restarts both function apps so the Key Vault reference re-resolves
      6  Re-verifies, then prints the expired key-ids you should clean up

    The secret value is never written to disk, never logged, and never returned.
    All CIPP credential app settings are Key Vault references, so the vault is the
    only place that needs updating.

.PARAMETER LifetimeMonths
    Validity of the new secret. Default 24. Entra caps this per app-policy.

.PARAMETER WhatIf
    Show what would happen without creating or changing anything.

.EXAMPLE
    .\Invoke-CippSecretRotation.ps1

.EXAMPLE
    .\Invoke-CippSecretRotation.ps1 -LifetimeMonths 12 -WhatIf

.NOTES
    Requires: Azure CLI logged in with (a) Application Administrator or owner of the
    CIPP-SAM app registration, and (b) Key Vault secret set/get on the CIPP vault.

    Rotating the client secret does NOT invalidate the SAM refresh token - CIPP keeps
    working for all onboarded tenants. No GDAP re-consent is needed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Subscription   = '48019666-dd78-439e-9890-030ab5156f23',
    [string]$ResourceGroup  = 'CIPP',
    [string]$VaultName      = 'cippwemix',
    [string]$SecretName     = 'applicationsecret',
    [string[]]$FunctionApps = @('cippwemix', 'cippwemix-proc'),
    [ValidateRange(1, 24)][int]$LifetimeMonths = 24
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = & az @Arguments -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

function Test-SamToken {
    <# Returns $true when the supplied secret can mint a Graph token. #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [ref]$ErrorText
    )
    try {
        $resp = Invoke-RestMethod -Method Post -TimeoutSec 30 `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{
                client_id     = $ClientId
                client_secret = $ClientSecret
                scope         = 'https://graph.microsoft.com/.default'
                grant_type    = 'client_credentials'
            }
        return [bool]$resp.access_token
    } catch {
        $m = $_.ErrorDetails.Message
        if (-not $m) { $m = $_.Exception.Message }
        if ($ErrorText) { $ErrorText.Value = ($m -replace '\s+', ' ') }
        return $false
    }
}

Write-Host "`nCIPP-SAM secret rotation" -ForegroundColor Cyan
Write-Host ("=" * 60)

& az account set --subscription $Subscription 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Cannot select subscription $Subscription. Run 'az login' first." }

# ------------------------------------------------------------------ 1. Identify the app
$appId    = (Invoke-Az @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', 'applicationid')).value
$tenantId = (Invoke-Az @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', 'tenantid')).value
if (-not $appId -or -not $tenantId) {
    throw "Could not read applicationid/tenantid from vault '$VaultName'. Check your Key Vault permissions."
}

$app = Invoke-Az @('ad', 'app', 'show', '--id', $appId)
if (-not $app) { throw "App registration $appId not found in tenant $tenantId." }

Write-Host "App        : $($app.displayName)"
Write-Host "App ID     : $appId"
Write-Host "Tenant     : $tenantId"
Write-Host "Vault      : $VaultName / $SecretName"

$expiry     = [datetime]::UtcNow.Date.AddMonths($LifetimeMonths)
$expiryIso  = $expiry.ToString('yyyy-MM-ddTHH:mm:ssZ')
$displayName = "CIPP-SAM-$([datetime]::UtcNow.ToString('yyyy-MM-dd'))"
Write-Host "New secret : $displayName, expires $($expiry.ToString('yyyy-MM-dd'))"
Write-Host ''

if (-not $PSCmdlet.ShouldProcess("$($app.displayName) ($appId)", "Create a new client secret and update vault '$VaultName'")) {
    Write-Host 'WhatIf: nothing was changed.' -ForegroundColor Yellow
    return
}

$newSecret = $null
try {
    # ---------------------------------------------------- 2. Create (append, never replace)
    Write-Host 'Creating new client secret...' -NoNewline
    $newSecret = & az ad app credential reset --id $appId --append `
        --display-name $displayName --end-date $expiryIso --query password -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newSecret)) {
        throw 'Failed to create the client secret. Do you have Application Administrator on CIPP-SAM?'
    }
    Write-Host ' done.' -ForegroundColor Green

    # ---------------------------------- 3. Prove it works BEFORE we put it in the vault
    Write-Host 'Verifying the new secret against Entra...' -NoNewline
    $err = ''
    # Entra needs a moment to replicate a brand-new credential.
    $ok = $false
    foreach ($attempt in 1..6) {
        if (Test-SamToken -TenantId $tenantId -ClientId $appId -ClientSecret $newSecret -ErrorText ([ref]$err)) {
            $ok = $true; break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $ok) { throw "New secret could not acquire a token after 30s. Vault NOT modified. Entra said: $err" }
    Write-Host ' token acquired.' -ForegroundColor Green

    # ------------------------------------------------------------------ 4. Store in vault
    Write-Host 'Writing to Key Vault...' -NoNewline
    $set = & az keyvault secret set --vault-name $VaultName --name $SecretName `
        --value $newSecret --expires $expiryIso -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to write '$SecretName' to vault '$VaultName'." }
    Write-Host ' done.' -ForegroundColor Green
    $version = (($set | ConvertFrom-Json).id -split '/')[-1]
    Write-Host "  new version: $version"
}
finally {
    # Scrub the plaintext from memory either way.
    $newSecret = $null
    [System.GC]::Collect()
}

# ------------------------- 5. Restart so the Key Vault reference re-resolves immediately
foreach ($fa in $FunctionApps) {
    Write-Host "Restarting $fa..." -NoNewline
    & az functionapp restart -g $ResourceGroup -n $fa -o none 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host ' done.' -ForegroundColor Green }
    else { Write-Host ' FAILED - restart it manually.' -ForegroundColor Red }
}

Write-Host 'Waiting 30s for the apps to come back...'
Start-Sleep -Seconds 30

# ------------------------------------------------------------------- 6. Re-verify
Write-Host 'Re-verifying from the vault...' -NoNewline
$stored = (Invoke-Az @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', $SecretName)).value
$err = ''
if ($stored -and (Test-SamToken -TenantId $tenantId -ClientId $appId -ClientSecret $stored -ErrorText ([ref]$err))) {
    Write-Host ' OK.' -ForegroundColor Green
} else {
    Write-Host ' FAILED.' -ForegroundColor Red
    Write-Host "  $err" -ForegroundColor Red
    $stored = $null
    exit 2
}
$stored = $null
[System.GC]::Collect()

foreach ($fa in $FunctionApps) {
    $state = (Invoke-Az @('functionapp', 'show', '-g', $ResourceGroup, '-n', $fa)).state
    Write-Host "  $fa : $state"
}

# --------------------------------------------------- Cleanup guidance (never automatic)
$creds = Invoke-Az @('ad', 'app', 'credential', 'list', '--id', $appId)
$expired = @($creds | Where-Object { [datetime]$_.endDateTime -le [datetime]::UtcNow })
$live    = @($creds | Where-Object { [datetime]$_.endDateTime -gt [datetime]::UtcNow })

Write-Host ''
Write-Host 'Rotation complete.' -ForegroundColor Green
Write-Host "  Live client secrets on this app : $($live.Count)"
Write-Host "  Expired, still attached         : $($expired.Count)"

if ($expired.Count -gt 0 -or $live.Count -gt 2) {
    Write-Host ''
    Write-Host 'Credential hygiene: every secret below is a full CSP-privileged credential.' -ForegroundColor Yellow
    Write-Host 'Delete the ones CIPP is not using (deletion is not reversible - check with Frank first):' -ForegroundColor Yellow
    foreach ($c in ($creds | Sort-Object { [datetime]$_.endDateTime })) {
        if ($c.displayName -eq $displayName) { continue }   # never suggest deleting the one we just made
        $tag = if ([datetime]$c.endDateTime -le [datetime]::UtcNow) { 'EXPIRED' } else { 'live   ' }
        Write-Host ("  {0}  az ad app credential delete --id {1} --key-id {2}   # {3}, ends {4:yyyy-MM-dd}" -f `
            $tag, $appId, $c.keyId, $c.displayName, [datetime]$c.endDateTime)
    }
}
Write-Host ''
Write-Host 'Next: open CIPP and confirm the dashboard loads tenant data.' -ForegroundColor Cyan
