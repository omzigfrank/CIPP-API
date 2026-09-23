function Invoke-OmzigSentinelTimerRun {
    <#
    .SYNOPSIS
    Body of the OmzigSentinelTimer function (every 5 minutes). The Functions entrypoint
    is the thin Receive-OmzigSentinelTimer wrapper written in Omzig.psm1 itself.
    .DESCRIPTION
    Overlay-owned timer, deliberately separate from CIPP's CIPPTimer: CIPP's timer
    list (Config/CIPPTimers.json) and its scheduled-task allow-list are upstream
    files, and patching either would conflict on every upstream sync.

    Self-test: add a row PartitionKey='SelfTest', RowKey='Pending' to the
    OmzigSentinelState table and the next run sends a clearly labelled TEST alert
    down every channel, removes the row, and records the per-channel result in
    PartitionKey='SelfTest', RowKey='LastResult'. No break-glass account is used.

    Run the daily GDAP expiry check now: add a row PartitionKey='RunNow',
    RowKey='GdapExpiry' to OmzigSentinelState. The next 5-minute tick runs it once
    and removes the row. No function keys are needed.

    Every tick also runs Invoke-OmzigPortalWarmup (portal runspace warm-up, Runbook section 8).

    Kill switch: app setting AzureWebJobs.OmzigSentinelTimer.Disabled=1 (this stops the
    warm-up too; OMZIG_PORTAL_WARM_CALLS=0 stops only the warm-up).
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param($Timer)

    try {
        $StateTable = Get-CIPPTable -tablename 'OmzigSentinelState'
        $SelfTest = Get-CIPPAzDataTableEntity @StateTable -Filter "PartitionKey eq 'SelfTest' and RowKey eq 'Pending'"
        if ($SelfTest) {
            $Delivery = Send-OmzigAlert -Severity 'Test' -Title 'Break-glass alerting self-test' `
                -Message 'TEST ONLY - no account signed in. This confirms the break-glass alert channels are wired.' `
                -Facts ([ordered]@{ 'Requested by' = [string]$SelfTest.RequestedBy; 'Sent (UTC)' = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') }) `
                -SkipPsa
            Remove-AzDataTableEntity @StateTable -Entity $SelfTest | Out-Null
            Add-CIPPAzDataTableEntity @StateTable -Force -Entity @{
                PartitionKey = 'SelfTest'; RowKey = 'LastResult'
                At = [datetime]::UtcNow.ToString('o'); Result = ($Delivery | ConvertTo-Json -Compress)
            }
            Write-Information ('OmzigSentinel self-test: ' + ($Delivery | ConvertTo-Json -Compress))
        }

        $RunNow = Get-CIPPAzDataTableEntity @StateTable -Filter "PartitionKey eq 'RunNow' and RowKey eq 'GdapExpiry'"
        if ($RunNow) {
            Remove-AzDataTableEntity @StateTable -Entity $RunNow | Out-Null
            try { $null = Invoke-OmzigGdapExpiryPoll } catch { Write-LogMessage -API 'OmzigSentinel' -message "On-demand GDAP expiry run failed: $($_.Exception.Message)" -sev 'Error' }
        }

        $null = Invoke-OmzigBreakGlassPoll
    } catch {
        Write-LogMessage -API 'OmzigSentinel' -message "Break-glass sentinel run failed: $($_.Exception.Message)" -sev 'Error'
        throw
    } finally {
        # Portal warm-up rides on this tick because a timer of its own would start its own
        # server every 5 minutes. It runs after the poll so it can never delay an alert, and
        # it can never fail the run.
        try { $null = Invoke-OmzigPortalWarmup } catch { Write-Warning "OmzigPortalWarmup failed: $($_.Exception.Message)" }
    }
}
