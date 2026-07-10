function Invoke-OmzigRestWithRetry {
    <#
    .SYNOPSIS
    Invoke-RestMethod wrapper with rate-limit awareness and jittered backoff.

    .DESCRIPTION
    Shared HTTP core for the Autotask and Datto RMM clients (Appendices A/B):
    respects Retry-After / X-RateLimit-* on 429, retries transient 5xx with
    exponential backoff + jitter, and surfaces the final error unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$RequestSplat,
        [int]$MaxRetries = 4,
        [int]$BaseDelaySeconds = 2
    )

    $Attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod @RequestSplat
        } catch {
            $Attempt++
            $StatusCode = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }
            $Retryable = $StatusCode -in @(429, 500, 502, 503, 504)
            if (-not $Retryable -or $Attempt -gt $MaxRetries) {
                throw
            }

            $Delay = $BaseDelaySeconds * [math]::Pow(2, $Attempt - 1)
            if ($StatusCode -eq 429 -and $_.Exception.Response.Headers) {
                $RetryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
                if ($RetryAfter) { $Delay = [math]::Max($Delay, $RetryAfter) }
            }
            $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000
            Write-Verbose "Omzig HTTP retry $Attempt/$MaxRetries after HTTP $StatusCode — sleeping $([math]::Round($Delay + $Jitter, 2))s"
            Start-Sleep -Seconds ($Delay + $Jitter)
        }
    }
}
