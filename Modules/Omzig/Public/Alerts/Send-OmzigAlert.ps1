function Send-OmzigAlert {
    <#
    .SYNOPSIS
    Sends one Omzig alert down every configured channel.
    .DESCRIPTION
    Channels, each best-effort so a failure in one never suppresses the others:
      1. CIPP Logbook entry (always) - the persistent record inside the portal
      2. Teams Adaptive Card to the Workflows webhook (see Get-OmzigTeamsWebhook)
      3. Email to the alert address (OMZIG_ALERT_EMAIL, default security@omzig.it),
         sent through CIPP's own Send-CIPPAlert mail path
      4. PSA ticket, P1 only, when a PSA is configured
    Returns what happened on each channel. Never returns or logs the webhook URL.
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('P1', 'Critical', 'Warning', 'Test')][string]$Severity,
        [Parameter(Mandatory)][string]$Message,
        [string]$TenantFilter = 'None',
        [System.Collections.IDictionary]$Facts = [ordered]@{},
        [switch]$SkipPsa
    )

    $Result = [ordered]@{ Logbook = 'not attempted'; Teams = 'not attempted'; Email = 'not attempted'; Psa = 'not applicable' }
    if (-not $PSCmdlet.ShouldProcess($Title, "Send $Severity alert")) {
        foreach ($Key in @($Result.Keys)) { $Result[$Key] = 'what-if' }
        return [pscustomobject]$Result
    }

    $LogSev = switch ($Severity) { { $_ -in 'P1', 'Critical' } { 'Critical' } 'Warning' { 'Warning' } default { 'Info' } }

    # 1. Logbook
    try {
        Write-LogMessage -API 'OmzigAlert' -tenant $TenantFilter -message "[$Severity] $Title - $Message" -sev $LogSev -LogData ([pscustomobject]$Facts)
        $Result.Logbook = 'sent'
    } catch { $Result.Logbook = "failed: $($_.Exception.Message)" }

    # 2. Teams
    try {
        $Webhook = Get-OmzigTeamsWebhook
        if ($Webhook) {
            $Card = New-OmzigTeamsCard -Title "[$Severity] $Title" -Severity $Severity -Summary $Message -Facts $Facts `
                -LinkText 'Open CIPP Logbook' -LinkUrl 'https://management.omzig.it/cipp/logs'
            $null = Invoke-OmzigRestWithRetry -RequestSplat @{
                Uri         = $Webhook
                Method      = 'POST'
                ContentType = 'application/json'
                Body        = ($Card | ConvertTo-Json -Depth 20 -Compress)
            }
            $Result.Teams = 'sent'
        } else {
            $Result.Teams = 'not configured'
        }
    } catch { $Result.Teams = "failed: $($_.Exception.Message)" }
    finally { $Webhook = $null }

    # 3. Email
    try {
        $To = (Get-OmzigConfig).AlertEmail
        if ($To -like '*@*') {
            $Rows = ($Facts.Keys | ForEach-Object {
                    '<tr><td style="padding:2px 12px 2px 0"><b>{0}</b></td><td>{1}</td></tr>' -f [System.Net.WebUtility]::HtmlEncode([string]$_), [System.Net.WebUtility]::HtmlEncode([string]$Facts[$_])
                }) -join ''
            $Html = '<h3>[{0}] {1}</h3><p>{2}</p><table>{3}</table><p><a href="https://management.omzig.it/cipp/logs">Open the CIPP Logbook</a></p>' -f `
                $Severity, [System.Net.WebUtility]::HtmlEncode($Title), [System.Net.WebUtility]::HtmlEncode($Message), $Rows
            Send-CIPPAlert -Type 'email' -Title "[$Severity] $Title" -HTMLContent $Html -TenantFilter $TenantFilter -altEmail $To -APIName 'OmzigAlert' | Out-Null
            $Result.Email = "sent to $To"
        } else {
            $Result.Email = 'not configured'
        }
    } catch { $Result.Email = "failed: $($_.Exception.Message)" }

    # 4. PSA ticket - P1 only
    if ($Severity -eq 'P1' -and -not $SkipPsa) {
        try {
            $Psa = Get-OmzigPsaClient
            & $Psa.NewTicket @{
                title       = "P1: $Title"
                description = "$Message`n`n$(([pscustomobject]$Facts) | ConvertTo-Json -Compress)"
                priority    = 1
            } | Out-Null
            $Result.Psa = 'sent'
        } catch { $Result.Psa = "skipped: $($_.Exception.Message)" }
    }

    return [pscustomobject]$Result
}
