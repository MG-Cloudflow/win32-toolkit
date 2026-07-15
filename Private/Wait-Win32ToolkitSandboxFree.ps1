function Wait-Win32ToolkitSandboxFree {
    <#
    .SYNOPSIS
        Waits (bounded) for the single allowed Windows Sandbox instance to exit; $true when free.
    .DESCRIPTION
        Windows Sandbox permits ONE running instance. The test flows used to THROW the moment another
        instance existed — which silently killed chained runs: the documentation-capture sandbox is still
        in its auto-close countdown (or shutting down) when the pipeline reaches the InstallUninstall
        test, and the InstallUninstall sandbox (kept open with -NoExit in watched mode) is still up when
        the chained Update test starts. The error was non-terminating, so packaging proceeded as if the
        test had run.

        Waiting up to -TimeoutSeconds for the tracked processes to exit makes back-to-back runs just
        work: an auto-closing capture sandbox clears in seconds, and an unattended test sandbox ends with
        a guest shutdown. A sandbox deliberately left open (watched mode) still exhausts the wait and the
        caller then throws with the same guidance as before — interactive IU→Update chaining remains a
        documented "close it yourself" limitation by design.
    .PARAMETER TimeoutSeconds
        Max seconds to wait (default 90).
    .PARAMETER PollSeconds
        Poll cadence (default 2).
    .OUTPUTS
        [bool] — $true when no sandbox is running (immediately or within the timeout), $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ValidateRange(0, 600)]
        [int]$TimeoutSeconds = 90,

        [ValidateRange(1, 30)]
        [int]$PollSeconds = 2
    )

    if (-not (Test-Win32ToolkitSandboxRunning)) { return $true }

    Write-Host "Another Windows Sandbox is still open (only one instance is allowed) — waiting up to $TimeoutSeconds s for it to close..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds $PollSeconds
        if (-not (Test-Win32ToolkitSandboxRunning)) {
            Write-Host '✓ Previous sandbox closed.' -ForegroundColor Green
            return $true
        }
    } until ((Get-Date) -gt $deadline)

    return $false
}
