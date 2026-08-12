<#
.SYNOPSIS
    Read-only health check for the Omzig self-hosted CIPP instance.

.DESCRIPTION
    Runs every check that has ever caught a real CIPP outage here, and prints one
    table plus a prioritised action list. Nothing is modified. Safe to run any time,
    by anyone with Reader on the CIPP resource group + Key Vault secret read.

    Checks performed:
      1  Azure context and access
      2  Function app run state (API + processor)
      3  Key Vault references resolve to secrets that exist and are enabled
      4  LIVE token acquisition using the vault's current client secret   <-- catches AADSTS7000222
      5  CIPP-SAM app registration secret + certificate expiry runway
      6  Key Vault secret expiry metadata
      7  SAM refresh-token age (CIPP refresh tokens die at 90 days idle)
      8  Version drift: deployed fork vs KelvinTegelaar upstream (API + frontend)
      9  Upstream-sync PR status on both forks (the usual reason we fall behind)
      10 Last successful deployment age
      11 Stale / orphaned app-registration credentials
      12 Baseline hardening (HTTPS-only, min TLS)
      13 Auth error rate from Log Analytics

.PARAMETER SkipTokenTest
    Skip check 4. Use when the operator lacks Key Vault secret-read permission.

.PARAMETER SkipGitHub
    Skip checks 8 and 9 (no outbound GitHub access).

.PARAMETER Json
    Emit the findings as JSON instead of a table (for scheduled runs / ticket automation).

.EXAMPLE
    .\Invoke-CippHealthCheck.ps1

.EXAMPLE
    .\Invoke-CippHealthCheck.ps1 -Json | Out-File cipp-health-2026-08.json

.NOTES
    Exit codes:  0 = all green   1 = warnings only   2 = at least one critical finding
    Requires: Azure CLI, logged in (az login) to the MCPP subscription.
#>
[CmdletBinding()]
param(
    [string]$Subscription     = '48019666-dd78-439e-9890-030ab5156f23',
    [string]$ResourceGroup    = 'CIPP',
    [string]$ApiApp           = 'cippwemix',
    [string]$ProcessorApp     = 'cippwemix-proc',
    [string]$VaultName        = 'cippwemix',
    [string]$SecretName       = 'applicationsecret',
    [string]$Workspace        = 'law-cipp-wemix',
    [string]$ApiFork          = 'omzigfrank/CIPP-API',
    [string]$ApiUpstream      = 'KelvinTegelaar/CIPP-API',
    [string]$ApiBranch        = 'master',
    [string]$FrontendFork     = 'omzigfrank/CIPP',
    [string]$FrontendUpstream = 'KelvinTegelaar/CIPP',
    [string]$FrontendBranch   = 'main',
    [int]$SecretWarnDays      = 45,
    [switch]$SkipTokenTest,
    [switch]$SkipGitHub,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$script:Findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'CRITICAL', 'INFO')][string]$Severity,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Detail,
        [string]$Action = ''
    )
    $script:Findings.Add([pscustomobject]@{
        Severity = $Severity
        Check    = $Check
        Detail   = $Detail
        Action   = $Action
    })
}

$script:LastAzError = ''

function Invoke-Az {
    <# az CLI wrapper: returns parsed JSON, or $null on failure instead of throwing.
       Keeps stderr in $script:LastAzError so callers can tell a permission problem
       apart from a genuinely missing resource. #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $script:LastAzError = ''
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $raw = & az @Arguments -o json 2>$errFile
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            $script:LastAzError = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
            return $null
        }
        try { return $raw | ConvertFrom-Json } catch { return $null }
    } finally {
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }
}

function Get-AzErrorSummary {
    <# One-line, truncated form of the last az error, so a finding names the actual
       problem instead of just asserting one. #>
    [OutputType([string])]
    param([int]$MaxLength = 200)
    $t = ($script:LastAzError -replace '\s+', ' ').Trim()
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength) + '...' }
    return $t
}

function Test-AzAuthError {
    <# True when the last az call failed for lack of permission rather than absence.
       Reporting "cippwemix not found" at CRITICAL when the caller simply lacks a
       role sends people hunting a deleted resource that is sitting right there. #>
    [OutputType([bool])]
    param()
    return [bool]($script:LastAzError -match 'AuthorizationFailed|does not have authorization|Forbidden|\(403\)')
}

function Get-DaysUntil {
    param([Parameter(Mandatory)][datetime]$When)
    [int][math]::Floor(($When.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
}

Write-Host "`nCIPP health check - $([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm')) UTC" -ForegroundColor Cyan
Write-Host ("=" * 72)

# ---------------------------------------------------------------- 1. Azure context
$account = Invoke-Az @('account', 'show')
if (-not $account) {
    Add-Finding CRITICAL 'Azure context' 'Not logged in to Azure CLI.' 'Run: az login'
    $script:Findings | Format-Table -AutoSize
    exit 2
}
if ($account.id -ne $Subscription) {
    & az account set --subscription $Subscription 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Add-Finding CRITICAL 'Azure context' "Cannot select subscription $Subscription." 'Check your access.'
        $script:Findings | Format-Table -AutoSize
        exit 2
    }
}
Add-Finding INFO 'Azure context' "Signed in as $($account.user.name) on '$($account.name)'."

# ------------------------------------------------------- 2. Function app run state
# NB: read the site through ARM rather than `az functionapp show`. The CLI wrapper
# makes extra calls beyond reading the resource (publishing credentials among
# them), so it fails for a principal holding only Reader — which is exactly what
# the operators group and the scheduled service principal hold. A plain GET needs
# only Microsoft.Web/sites/read, which */read covers.
function Get-CippSite {
    param([Parameter(Mandatory)][string]$Name)
    $base = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$Name"
    $site = Invoke-Az @('rest', '--method', 'GET', '--url', "$base`?api-version=2023-12-01")
    if (-not $site) { return $null }
    # minTlsVersion lives on /config/web, not the site object. Also a plain read.
    $web = Invoke-Az @('rest', '--method', 'GET', '--url', "$base/config/web?api-version=2023-12-01")
    return [pscustomobject]@{
        state      = $site.properties.state
        httpsOnly  = $site.properties.httpsOnly
        siteConfig = [pscustomobject]@{ minTlsVersion = $web.properties.minTlsVersion }
    }
}

foreach ($app in @($ApiApp, $ProcessorApp)) {
    $site = Get-CippSite -Name $app
    if (-not $site) {
        if (Test-AzAuthError) {
            Add-Finding WARN 'Function app' "$app not readable: $(Get-AzErrorSummary)" `
                'Ask an admin to add you to CIPP-Azure-Operators.'
        } else {
            Add-Finding CRITICAL 'Function app' "$app not found. $(Get-AzErrorSummary)" `
                'Verify the app still exists.'
        }
        continue
    }
    if ($site.state -eq 'Running') {
        Add-Finding OK 'Function app' "$app is Running."
    } else {
        Add-Finding CRITICAL 'Function app' "$app is '$($site.state)'." "Run: az functionapp start -g $ResourceGroup -n $app"
    }

    # ------------------------------------------------ 12. Baseline hardening
    if ($site.httpsOnly -ne $true) {
        Add-Finding WARN 'Hardening' "$app does not enforce HTTPS-only." `
            "Run: az functionapp update -g $ResourceGroup -n $app --set httpsOnly=true"
    }
    if ($site.siteConfig.minTlsVersion -and [double]$site.siteConfig.minTlsVersion -lt 1.2) {
        Add-Finding WARN 'Hardening' "$app min TLS is $($site.siteConfig.minTlsVersion)." 'Raise to 1.2 or higher.'
    }
}

# ------------------------------------- 3. Key Vault references resolve to real secrets
$settings = Invoke-Az @('functionapp', 'config', 'appsettings', 'list', '-g', $ResourceGroup, '-n', $ApiApp)
$vaultSecrets = Invoke-Az @('keyvault', 'secret', 'list', '--vault-name', $VaultName)

if (-not $settings) {
    if (Test-AzAuthError) {
        # Listing app settings is Microsoft.Web/sites/config/list/action — an ACTION,
        # which the built-in Reader role (*/read) does not grant. That is why
        # CIPP-Azure-Operators also carries the CIPP App Settings Reader custom role.
        Add-Finding WARN 'App settings' `
            "Cannot list app settings on $ApiApp (needs Microsoft.Web/sites/config/list/action): $(Get-AzErrorSummary)" `
            'Confirm you are in CIPP-Azure-Operators, which carries the CIPP App Settings Reader role.'
    } else {
        Add-Finding CRITICAL 'App settings' "Cannot read app settings on $ApiApp." 'Check RBAC.'
    }
} elseif (-not $vaultSecrets) {
    Add-Finding CRITICAL 'Key Vault' "Cannot list secrets in vault '$VaultName'." 'Check your Key Vault access.'
} else {
    $enabledNames = $vaultSecrets |
        Where-Object { $_.attributes.enabled } |
        ForEach-Object { ($_.id -split '/')[-1] }

    $refs = $settings | Where-Object { $_.value -like '@Microsoft.KeyVault(*' }
    Add-Finding INFO 'Key Vault refs' "$($refs.Count) app settings resolve via Key Vault."

    foreach ($ref in $refs) {
        # NB: not $secretName - PowerShell variable names are case-insensitive, so that
        # would silently overwrite the $SecretName parameter used later on.
        if ($ref.value -match 'SecretName=([^;)]+)') {
            $refSecret = $Matches[1]
            # Vault secret names are case-insensitive, so compare that way.
            if (-not ($enabledNames | Where-Object { $_ -eq $refSecret })) {
                Add-Finding CRITICAL 'Key Vault refs' `
                    "$($ref.name) points at secret '$refSecret' which is missing or disabled." `
                    "Restore or re-create '$refSecret' in vault $VaultName."
            }
        }
    }

    # Anything holding a literal credential instead of a reference is drift waiting to happen.
    foreach ($n in @('ApplicationSecret', 'RefreshToken')) {
        $s = $settings | Where-Object { $_.name -eq $n }
        if ($s -and $s.value -notlike '@Microsoft.KeyVault(*') {
            Add-Finding WARN 'App settings' "$n is a literal value, not a Key Vault reference." `
                "Repoint it at the vault so rotation only has to happen in one place."
        }
    }
}

# ---------------------------- 4. LIVE token test (the check that catches AADSTS7000222)
$appId = $null
if ($vaultSecrets) {
    $appId = (Invoke-Az @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', 'applicationid')).value
    $tenantId = (Invoke-Az @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', 'tenantid')).value
}

if ($SkipTokenTest) {
    Add-Finding INFO 'SAM auth' 'Live token test skipped (-SkipTokenTest).'
} elseif (-not $appId -or -not $tenantId) {
    Add-Finding WARN 'SAM auth' 'Could not read applicationid/tenantid from the vault; token test skipped.' `
        'Grant yourself Key Vault secret-read, or re-run with -SkipTokenTest.'
} else {
    $secret = (Invoke-Az @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', 'applicationsecret')).value
    if (-not $secret) {
        Add-Finding CRITICAL 'SAM auth' 'applicationsecret is unreadable or empty in the vault.' `
            'Run Invoke-CippSecretRotation.ps1.'
    } else {
        try {
            $body = @{
                client_id     = $appId
                client_secret = $secret
                scope         = 'https://graph.microsoft.com/.default'
                grant_type    = 'client_credentials'
            }
            $resp = Invoke-RestMethod -Method Post -TimeoutSec 30 `
                -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $body
            if ($resp.access_token) {
                Add-Finding OK 'SAM auth' 'Vault secret successfully acquired a Graph token.'
            } else {
                Add-Finding CRITICAL 'SAM auth' 'Token endpoint returned no access_token.' 'Investigate immediately.'
            }
        } catch {
            $msg = $_.ErrorDetails.Message
            if (-not $msg) { $msg = $_.Exception.Message }
            $short = ($msg -replace '\s+', ' ')
            if ($short.Length -gt 220) { $short = $short.Substring(0, 220) }
            $action = if ($msg -match '7000222|invalid_client') {
                'Client secret is expired or wrong. Run Invoke-CippSecretRotation.ps1.'
            } else {
                'Investigate the Entra error below before touching anything else.'
            }
            Add-Finding CRITICAL 'SAM auth' "Token acquisition FAILED: $short" $action
        } finally {
            $secret = $null; $body = $null
            [System.GC]::Collect()
        }
    }
}

# ------------------------- 5 & 11. App registration credential runway + stale creds
if ($appId) {
    $pwCreds   = Invoke-Az @('ad', 'app', 'credential', 'list', '--id', $appId)
    $certCreds = Invoke-Az @('ad', 'app', 'credential', 'list', '--id', $appId, '--cert')

    # A clean report must mean "checked and fine", never "could not check". Reading
    # app credentials needs directory access (Graph Application.Read.All); the
    # scheduled service principal has none, so without this the single most
    # important check — is the SAM secret about to expire — would vanish silently
    # and the run would still say all green. That is the failure that took CIPP
    # down on 2026-07-22.
    if ($null -eq $pwCreds) {
        Add-Finding WARN 'SAM secret' `
            "Could not read CIPP-SAM credentials, so expiry runway was NOT checked. $(Get-AzErrorSummary 120)" `
            'Run as a user in CIPP-Azure-Admins, or grant the automation Graph Application.Read.All.'
    }

    if ($null -ne $pwCreds) {
        $live = @($pwCreds | Where-Object { [datetime]$_.endDateTime -gt [datetime]::UtcNow })
        $dead = @($pwCreds).Count - $live.Count

        if ($live.Count -eq 0) {
            Add-Finding CRITICAL 'SAM secret' 'CIPP-SAM has no unexpired client secret.' `
                'Run Invoke-CippSecretRotation.ps1 now.'
        } else {
            $furthest = ($live | Sort-Object { [datetime]$_.endDateTime } -Descending)[0]
            $days = Get-DaysUntil ([datetime]$furthest.endDateTime)
            if ($days -lt $SecretWarnDays) {
                Add-Finding WARN 'SAM secret' "Longest-lived client secret expires in $days days ($($furthest.displayName))." `
                    'Rotate this month: Invoke-CippSecretRotation.ps1'
            } else {
                Add-Finding OK 'SAM secret' "Client secret runway: $days days ($($furthest.displayName))."
            }
        }

        if ($dead -gt 0) {
            Add-Finding WARN 'Credential hygiene' "$dead expired client secret(s) still attached to CIPP-SAM." `
                'Remove them: az ad app credential delete --id <appId> --key-id <keyId>'
        }
        if ($live.Count -gt 2) {
            Add-Finding WARN 'Credential hygiene' "$($live.Count) live client secrets on CIPP-SAM (expected 1-2)." `
                'Each one is a full CSP-privileged credential. Delete every key-id CIPP is not using.'
        }
    }

    if ($null -eq $certCreds) {
        Add-Finding WARN 'SAM certificate' 'Could not read certificate credentials, so expiry was NOT checked.' `
            'Same cause as the SAM secret finding above.'
    }

    if ($null -ne $certCreds -and @($certCreds).Count -gt 0) {
        foreach ($c in $certCreds) {
            $days = Get-DaysUntil ([datetime]$c.endDateTime)
            $sev = if ($days -lt 0) { 'WARN' } elseif ($days -lt $SecretWarnDays) { 'WARN' } else { 'OK' }
            Add-Finding $sev 'SAM certificate' "'$($c.displayName)' runway: $days days."
        }
    }
}

# ----------------------------------------------- 6. Key Vault secret expiry metadata
if ($vaultSecrets) {
    foreach ($s in $vaultSecrets) {
        $name = ($s.id -split '/')[-1]
        if ($s.attributes.expires) {
            $days = Get-DaysUntil ([datetime]$s.attributes.expires)
            if ($days -lt 0) {
                Add-Finding CRITICAL 'Vault expiry' "Secret '$name' expiry date has passed ($days days)." `
                    'Rotate it and update the expiry metadata.'
            } elseif ($days -lt $SecretWarnDays) {
                Add-Finding WARN 'Vault expiry' "Secret '$name' expires in $days days." 'Schedule rotation.'
            }
        } elseif ($name -in @('applicationsecret', 'SSOAppSecret')) {
            Add-Finding WARN 'Vault expiry' "Secret '$name' has no expiry metadata." `
                "Set one so this check can warn you: az keyvault secret set-attributes --vault-name $VaultName --name $name --expires <ISO8601>"
        }
    }

    # ---------------------------------------------- 7. Refresh-token age (90-day idle limit)
    $rt = $vaultSecrets | Where-Object { ($_.id -split '/')[-1] -eq 'RefreshToken' }
    if ($rt) {
        $age = [int][math]::Floor(([datetime]::UtcNow - ([datetime]$rt.attributes.updated).ToUniversalTime()).TotalDays)
        if ($age -gt 80) {
            Add-Finding CRITICAL 'Refresh token' "SAM refresh token last updated $age days ago (90-day limit)." `
                'Re-run the CIPP SAM setup wizard to mint a new refresh token before it dies.'
        } elseif ($age -gt 60) {
            Add-Finding WARN 'Refresh token' "SAM refresh token is $age days old." 'Watch it; CIPP normally self-refreshes.'
        } else {
            Add-Finding OK 'Refresh token' "SAM refresh token is $age days old."
        }
    }
}

# ---------------------------------------------------------- 8 & 9. Version drift + sync PRs
function Get-GitHubJson {
    param([Parameter(Mandatory)][string]$Url)
    $headers = @{ 'User-Agent' = 'omzig-cipp-healthcheck' }
    if ($env:GH_TOKEN) { $headers['Authorization'] = "Bearer $env:GH_TOKEN" }
    try { return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 30 } catch { return $null }
}
function Get-GitHubText {
    param([Parameter(Mandatory)][string]$Url)
    try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30).Content.Trim() } catch { return $null }
}

if ($SkipGitHub) {
    Add-Finding INFO 'Version' 'GitHub checks skipped (-SkipGitHub).'
} else {
    # Backend version lives in version_latest.txt; frontend in public/version.json.
    $apiDeployed = Get-GitHubText "https://raw.githubusercontent.com/$ApiFork/$ApiBranch/version_latest.txt"
    $apiLatest   = Get-GitHubText "https://raw.githubusercontent.com/$ApiUpstream/$ApiBranch/version_latest.txt"
    $feDeployedRaw = Get-GitHubText "https://raw.githubusercontent.com/$FrontendFork/$FrontendBranch/public/version.json"
    $feLatestRaw   = Get-GitHubText "https://raw.githubusercontent.com/$FrontendUpstream/$FrontendBranch/public/version.json"
    $feDeployed = if ($feDeployedRaw) { ($feDeployedRaw | ConvertFrom-Json).version }
    $feLatest   = if ($feLatestRaw)   { ($feLatestRaw   | ConvertFrom-Json).version }

    foreach ($pair in @(
        @{ Name = 'CIPP-API (backend)'; Have = $apiDeployed; Want = $apiLatest },
        @{ Name = 'CIPP (frontend)';    Have = $feDeployed;  Want = $feLatest }
    )) {
        if (-not $pair.Have -or -not $pair.Want) {
            Add-Finding WARN 'Version' "Could not determine version for $($pair.Name)." 'Check GitHub connectivity.'
        } elseif ($pair.Have -eq $pair.Want) {
            Add-Finding OK 'Version' "$($pair.Name) is current at $($pair.Have)."
        } else {
            Add-Finding WARN 'Version' "$($pair.Name) is on $($pair.Have); upstream is $($pair.Want)." `
                'Merge the upstream-sync PR (see next finding), then let the deploy Action run.'
        }
    }

    foreach ($repo in @($ApiFork, $FrontendFork)) {
        $prs = Get-GitHubJson "https://api.github.com/repos/$repo/pulls?state=open&per_page=20"
        if ($null -eq $prs) {
            Add-Finding WARN 'Upstream sync' "Could not read open PRs on $repo." 'Check GitHub connectivity or set GH_TOKEN.'
            continue
        }
        $sync = @($prs | Where-Object { $_.user.login -eq 'pull[bot]' })
        if ($sync.Count -eq 0) {
            Add-Finding OK 'Upstream sync' "$repo has no pending upstream-sync PR."
            continue
        }
        foreach ($pr in $sync) {
            # mergeable_state is only present on the single-PR endpoint.
            $detail = Get-GitHubJson "https://api.github.com/repos/$repo/pulls/$($pr.number)"
            $state = if ($detail) { $detail.mergeable_state } else { 'unknown' }
            $ageDays = [int][math]::Floor(([datetime]::UtcNow - ([datetime]$pr.created_at).ToUniversalTime()).TotalDays)
            if ($state -eq 'dirty') {
                Add-Finding CRITICAL 'Upstream sync' `
                    "$repo PR #$($pr.number) has merge CONFLICTS and has been open $ageDays days. Updates are blocked." `
                    'Resolve conflicts (see runbook section "Unblocking a conflicted sync PR").'
            } elseif ($ageDays -gt 7) {
                Add-Finding WARN 'Upstream sync' "$repo PR #$($pr.number) open $ageDays days, state '$state'." 'Merge it.'
            } else {
                Add-Finding INFO 'Upstream sync' "$repo PR #$($pr.number) open $ageDays days, state '$state'."
            }
        }
    }
}

# ------------------------------------------------------- 10. Last deployment age
$deployUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup" +
             "/providers/Microsoft.Web/sites/$ApiApp/deployments?api-version=2022-03-01"
$deployments = Invoke-Az @('rest', '--method', 'GET', '--url', $deployUrl)
if ($deployments -and $deployments.value) {
    $active = $deployments.value | Where-Object { $_.properties.active } | Select-Object -First 1
    if (-not $active) { $active = $deployments.value | Select-Object -First 1 }
    $when = [datetime]$active.properties.end_time
    $ageDays = [int][math]::Floor(([datetime]::UtcNow - $when.ToUniversalTime()).TotalDays)
    $sev = if ($ageDays -gt 21) { 'WARN' } else { 'OK' }
    Add-Finding $sev 'Deployment' "Active deployment on $ApiApp is $ageDays days old ($($when.ToString('yyyy-MM-dd')))." `
        $(if ($ageDays -gt 21) { 'Deploys have stalled - check the GitHub Action and the sync PR.' } else { '' })
} else {
    Add-Finding WARN 'Deployment' "Could not read deployment history for $ApiApp." ''
}

# --------------------------------------------- 13. Auth error rate from Log Analytics
# lastAuthError is what matters, not the raw count: after a rotation the previous day's
# failures are still in the window but are history. Compare them against the rotation time.
$kql = @'
AppTraces
| where TimeGenerated > ago(24h)
| summarize total = count(),
            authErrors = countif(Message has "7000222" or Message has "invalid_client"),
            errors = countif(SeverityLevel >= 3),
            lastAuthError = maxif(TimeGenerated, Message has "7000222" or Message has "invalid_client")
'@
$queryBody = (@{ query = $kql } | ConvertTo-Json -Compress)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cipp-kql-$([guid]::NewGuid().ToString('N')).json"
try {
    Set-Content -Path $tmp -Value $queryBody -Encoding utf8 -NoNewline
    $laUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup" +
             "/providers/Microsoft.OperationalInsights/workspaces/$Workspace/api/query?api-version=2020-08-01"
    $la = Invoke-Az @('rest', '--method', 'POST', '--url', $laUrl, '--body', "@$tmp",
                      '--headers', 'Content-Type=application/json')
    if ($la -and $la.Tables -and $la.Tables[0].Rows.Count -gt 0) {
        $row = $la.Tables[0].Rows[0]
        $total = $row[0]; $authErr = $row[1]; $err = $row[2]; $lastAuthError = $row[3]

        # When was the secret last rotated? Auth errors older than that are already fixed.
        $rotatedAt = $null
        if ($vaultSecrets) {
            $sec = $vaultSecrets | Where-Object { ($_.id -split '/')[-1] -eq $SecretName }
            if ($sec -and $sec.attributes.updated) { $rotatedAt = ([datetime]$sec.attributes.updated).ToUniversalTime() }
        }
        $lastErrUtc = if ($lastAuthError) { ([datetime]$lastAuthError).ToUniversalTime() } else { $null }
        $errorsArePreRotation = $lastErrUtc -and $rotatedAt -and ($lastErrUtc -lt $rotatedAt)

        if ($total -eq 0) {
            Add-Finding WARN 'Telemetry' 'No traces in the last 24h - CIPP may not be running or logging.' `
                'Confirm the processor app is executing timers.'
        } elseif ($authErr -eq 0) {
            Add-Finding OK 'Telemetry' "$total traces / $err error-level in 24h, 0 auth failures."
        } elseif ($errorsArePreRotation) {
            Add-Finding OK 'Telemetry' ("$authErr auth errors in 24h, but the last one was " +
                "$($lastErrUtc.ToString('HH:mm'))Z - before the $($rotatedAt.ToString('HH:mm'))Z rotation. Clean since.")
        } else {
            Add-Finding CRITICAL 'Telemetry' ("$authErr auth (invalid_client) errors in 24h, most recent " +
                "$($lastErrUtc.ToString('yyyy-MM-dd HH:mm'))Z - AFTER the last rotation.") `
                'Rotate the SAM secret: Invoke-CippSecretRotation.ps1'
        }
    } else {
        Add-Finding WARN 'Telemetry' 'Log Analytics query returned no data.' 'Check workspace access.'
    }
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------ Report
if ($Json) {
    $script:Findings | ConvertTo-Json -Depth 4
} else {
    $order = @{ CRITICAL = 0; WARN = 1; OK = 2; INFO = 3 }
    $script:Findings |
        Sort-Object { $order[$_.Severity] }, Check |
        Format-Table -Wrap -Property Severity, Check, Detail, Action

    $crit = @($script:Findings | Where-Object Severity -eq 'CRITICAL')
    $warn = @($script:Findings | Where-Object Severity -eq 'WARN')

    Write-Host ("=" * 72)
    if ($crit.Count -gt 0) {
        Write-Host "$($crit.Count) CRITICAL, $($warn.Count) WARN - act today." -ForegroundColor Red
    } elseif ($warn.Count -gt 0) {
        Write-Host "$($warn.Count) WARN, 0 CRITICAL - handle in this month's window." -ForegroundColor Yellow
    } else {
        Write-Host 'All green.' -ForegroundColor Green
    }
    Write-Host ''
}

$crit = @($script:Findings | Where-Object Severity -eq 'CRITICAL')
$warn = @($script:Findings | Where-Object Severity -eq 'WARN')
if ($crit.Count -gt 0) { exit 2 } elseif ($warn.Count -gt 0) { exit 1 } else { exit 0 }
