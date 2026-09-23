function Set-OmzigThreadPoolFloor {
    <#
    .SYNOPSIS
    Raises the .NET thread-pool minimum for the Functions worker so a burst of portal
    calls does not stall while the pool grows.
    .DESCRIPTION
    The PowerShell worker holds one pool thread for every invocation in flight, including
    the ones queued for a free runspace. .NET starts with one thread per visible core (4
    on the Flex instance, as its startup log shows), adds threads beyond that slowly
    (about 2 a second) and retires idle ones after ~20 seconds. So the first page after a
    quiet spell, which fires 10+ calls at once, waited seconds for threads. Measured
    2026-09-23 with the anonymous PublicPing on a server whose runspaces were already
    built: 10 parallel calls after 45s idle took 5.3s before this change and 0.46s after.

    The minimum only lets the pool create threads without that delay; it does not
    pre-create them. It never lowers a floor that is already higher. App setting
    OMZIG_THREADPOOL_MIN overrides the default of 32; 0 turns this off. The environment
    variable .NET reads for this (DOTNET_ThreadPool_ForceMinWorkerThreads) needs .NET 10,
    and PowerShell 7.4 runs on .NET 8, hence the in-process call.
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$Minimum = 32
    )
    if ($PSBoundParameters.ContainsKey('Minimum') -eq $false -and $env:OMZIG_THREADPOOL_MIN) {
        $Parsed = 0
        if ([int]::TryParse($env:OMZIG_THREADPOOL_MIN, [ref]$Parsed)) { $Minimum = $Parsed }
    }

    $Worker = 0
    $Io = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$Worker, [ref]$Io)
    $Result = [pscustomobject]@{ Changed = $false; Before = $Worker; After = $Worker }
    if ($Minimum -le 0 -or $Worker -ge $Minimum) { return $Result }
    if (-not $PSCmdlet.ShouldProcess('.NET thread pool', "Raise minimum worker threads from $Worker to $Minimum")) { return $Result }

    if ([System.Threading.ThreadPool]::SetMinThreads($Minimum, [Math]::Max($Io, $Minimum))) {
        [System.Threading.ThreadPool]::GetMinThreads([ref]$Worker, [ref]$Io)
        $Result.Changed = $true
        $Result.After = $Worker
        Write-Information "Omzig: thread-pool minimum raised from $($Result.Before) to $Worker worker threads"
    } else {
        Write-Warning "Omzig: could not raise the thread-pool minimum to $Minimum (it is $Worker)"
    }
    return $Result
}
