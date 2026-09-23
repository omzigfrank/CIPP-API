function Invoke-OmzigPortalWarmup {
    <#
    .SYNOPSIS
    Keeps the portal's API server ready to answer a whole page of calls at once.
    .DESCRIPTION
    Sends -Calls (default 12, one dashboard's worth) simultaneous anonymous PublicPing
    requests through the portal's public address, so the HTTP server has that many
    PowerShell runspaces built before anyone opens a page. Runs from the 5-minute
    OmzigSentinelTimer.

    Why it is needed (measured 2026-09-23): on Flex the PowerShell worker starts before
    the app settings are applied, so PSWorkerInProcConcurrencyUpperBound=4 is ignored and
    the host's default of 1000 applies. The worker adds a runspace whenever more calls
    arrive at once than it has runspaces, and it builds each one (CIPP's profile, ~3.5s)
    on the same thread that hands out every request, so they are built one after another
    while the page waits. A fresh server (deploy, restart, scale-out, or Azure replacing
    it overnight) therefore spent ~40s building runspaces during someone's first
    dashboard. Runspaces are never discarded, so on a warm server this costs 12 calls of
    about 0.1s each.

    A round only builds about one runspace once a few exist, because fast pings free their
    runspace for the next one. So a round slower than -FastMs is repeated, up to
    -MaxRounds, and a new server is fully warm after one tick instead of six.

    Target: see Resolve-OmzigPortalUrl. OMZIG_PORTAL_WARM_CALLS overrides -Calls; 0 turns
    this off. Never throws: a failed warm-up only means the next page may be slow.
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [string]$BaseUrl,
        [int]$Calls = 12,
        [int]$TimeoutSeconds = 90,
        [int]$MaxRounds = 6,
        [int]$FastMs = 2000
    )
    if (-not $PSBoundParameters.ContainsKey('Calls') -and $env:OMZIG_PORTAL_WARM_CALLS) {
        $Parsed = 0
        if ([int]::TryParse($env:OMZIG_PORTAL_WARM_CALLS, [ref]$Parsed)) { $Calls = $Parsed }
    }
    if ($Calls -le 0) { return [pscustomobject]@{ Skipped = 'turned off (OMZIG_PORTAL_WARM_CALLS=0)' } }

    if (-not $BaseUrl) { $BaseUrl = Resolve-OmzigPortalUrl }
    if (-not $BaseUrl) {
        Write-Warning 'OmzigPortalWarmup: no portal URL (set OMZIG_PORTAL_URL, or open the portal once so CIPP stores CIPPURL); skipped'
        return [pscustomobject]@{ Skipped = 'no portal URL' }
    }
    $Uri = '{0}/api/PublicPing' -f $BaseUrl.TrimEnd('/')

    $Client = [System.Net.Http.HttpClient]::new()
    $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $RoundMs = [System.Collections.Generic.List[int]]::new()
    try {
        do {
            $Sw = [System.Diagnostics.Stopwatch]::StartNew()
            # Start every request before waiting on any: they have to be in flight together.
            $Tasks = foreach ($i in 1..$Calls) { $Client.GetAsync("${Uri}?omzigwarm=$i") }
            $Statuses = foreach ($Task in $Tasks) {
                try {
                    $Response = $Task.GetAwaiter().GetResult()
                    [int]$Response.StatusCode
                    $Response.Dispose()
                } catch {
                    0
                }
            }
            $Sw.Stop()
            $RoundMs.Add([int]$Sw.ElapsedMilliseconds)
            $Ok = @($Statuses | Where-Object { $_ -eq 200 }).Count
        } while ($Ok -eq $Calls -and $Sw.ElapsedMilliseconds -gt $FastMs -and $RoundMs.Count -lt $MaxRounds)
    } finally {
        $Client.Dispose()
    }

    # Ok, Failed and WallMs describe the last round, i.e. how warm the server is now.
    $Result = [pscustomobject]@{
        Target  = ([System.Uri]$Uri).Host
        Calls   = $Calls
        Ok      = $Ok
        Failed  = $Calls - $Ok
        WallMs  = $RoundMs[-1]
        Rounds  = $RoundMs.Count
        RoundMs = @($RoundMs)
    }
    Write-Information ('OmzigPortalWarmup: ' + ($Result | ConvertTo-Json -Compress))
    if ($Result.Failed) {
        $Codes = ($Statuses | Where-Object { $_ -ne 200 } | Group-Object | ForEach-Object { '{0} x{1}' -f $(if ($_.Name -eq '0') { 'no response' } else { "HTTP $($_.Name)" }), $_.Count }) -join ', '
        Write-Warning "OmzigPortalWarmup: $($Result.Failed) of $Calls pings to $($Result.Target) failed ($Codes)"
    }
    return $Result
}
