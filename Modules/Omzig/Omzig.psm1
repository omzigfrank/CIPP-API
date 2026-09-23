# omzig.ai overlay module loader — mirrors the CippExtensions source-mode loader.
# All Omzig-specific backend logic lives in this module (Omzig Custom CIPP
# Build v1.1 §11.4 overlay pattern). Never patch upstream CIPP modules.
$Public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public\*.ps1') -Recurse -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private\*.ps1') -Recurse -ErrorAction SilentlyContinue)
$Functions = $Public + $Private
foreach ($import in @($Functions)) {
    try {
        . $import.FullName
    } catch {
        Write-Error -Message "Failed to import function $($import.FullName): $_"
    }
}

# Functions-host entrypoints. The PowerShell worker finds a function.json entryPoint by
# parsing THIS file's syntax tree, so an entrypoint must be written here; one that is only
# dot-sourced from Public\ fails with "Cannot find the function ... defined in Omzig.psm1".
# Keep each wrapper thin; the logic lives in the Public function it calls.
function Receive-OmzigSentinelTimer {
    param($Timer)
    Invoke-OmzigSentinelTimerRun -Timer $Timer
}

Export-ModuleMember -Function (@($Public.BaseName) + 'Receive-OmzigSentinelTimer') -Alias *
