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

        Leftover client window (test campaign F1): Windows Sandbox 0.8 can leave its client window
        (WindowsSandboxRemoteSession / WindowsSandboxClient) open on 'The remote environment is shutting
        down' after the guest is gone, and the process check then waits for nothing. When the Windows
        Sandbox command line is available, 'wsb list' decides (Get-Win32ToolkitSandboxEnvironment). The
        windows are closed (Close-Win32ToolkitSandboxClient: close the window, stop the process after
        -CloseWaitSeconds) with a one-line message only when all of this holds:
          - wsb has reported NO running sandbox for -StaleClientSeconds, and says so again right before the close;
          - only client windows are left, all in this Windows session: 'wsb list' reports only this user's
            sandboxes, so a sandbox process in another session (another user's sandbox) means nothing is closed;
          - they are the SAME windows (process id and start time) for the whole grace: a window that appears
            meanwhile restarts it, because a sandbox that is starting shows its window seconds before wsb
            lists it;
          - each window is at least -StaleClientSeconds old.
        The wait reports free only once the process check no longer sees a sandbox; a window that could not
        be closed keeps the wait going until the timeout. Nothing is closed while wsb lists a running sandbox
        (a watched sandbox stays open), and WindowsSandboxServer is never touched. A failed wsb answer (wsb
        missing, failing, timing out or printing something unexpected) never counts as "no sandbox": it restarts the
        grace. One is tolerated (wsb can print one non-JSON answer while a sandbox shuts down; test campaign R1), and
        a good answer starts the count again; after two failed answers in a row the process check alone decides for
        the rest of the wait, as before. With -OwnRun the first answer decides whether to wait at all: when it fails
        and wsb.exe is not installed, $false at once, nothing waited for; when wsb.exe is installed, that one failed
        answer is tolerated too (the check runs right after the test's sandbox shut down): wsb is asked again after one
        poll, and only a second failed answer in a row returns $false without waiting.
    .PARAMETER TimeoutSeconds
        Max seconds to wait (default 90).
    .PARAMETER PollSeconds
        Poll cadence (default 2).
    .PARAMETER StaleClientSeconds
        How long wsb must report no running sandbox, with only the same client windows left, before they are
        closed; also the minimum age of a window that is closed (default 20).
    .PARAMETER CloseWaitSeconds
        How long a client window gets to close before its process is stopped (default 10).
    .PARAMETER OwnRun
        The sandbox of the test that is returning (Test-Win32ToolkitProject, unattended, after a completed run):
        wait for it to close and close a leftover client window by the same rule. Only this Windows session's
        sandbox processes count as still open (another user's sandbox is not this test's), the lines name this
        test's sandbox, and without wsb nothing is waited for ($false: the next run's wait handles it) - at once when
        wsb.exe is not installed, after one poll when its first two answers both fail.
    .OUTPUTS
        [bool] — $true when no sandbox is running (immediately or within the timeout), $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ValidateRange(0, 600)]
        [int]$TimeoutSeconds = 90,

        [ValidateRange(1, 30)]
        [int]$PollSeconds = 2,

        [ValidateRange(0, 300)]
        [int]$StaleClientSeconds = 20,

        [ValidateRange(0, 120)]
        [int]$CloseWaitSeconds = 10,

        # The sandbox of the test that is returning (Test-Win32ToolkitProject, unattended): wait for it to close and
        # close a leftover client window by the same rule; without wsb, do not wait.
        [switch]$OwnRun
    )

    $sandboxNames = @('WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession')
    $mySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    # "Still open": any sandbox process on the machine; for the returning test's own sandbox (-OwnRun) only this
    # Windows session's, so another user's sandbox never makes it wait or count as this test's.
    $stillOpen = if ($OwnRun) {
        { @(Get-Process -Name $sandboxNames -ErrorAction Ignore | Where-Object { $null -ne $_.SessionId -and [int]$_.SessionId -eq $mySession }).Count -gt 0 }
    }
    else { { Test-Win32ToolkitSandboxRunning } }

    if (-not (& $stillOpen)) { return $true }

    if ($OwnRun) {
        # Without wsb nothing can be judged: the next run's start-up wait handles the window, as before (Fd8).
        if ($null -eq (Get-Win32ToolkitSandboxEnvironment)) {
            if (-not (Get-Command -Name 'wsb.exe' -CommandType Application -ErrorAction Ignore)) { return $false }
            # wsb is installed: one failed answer is tolerated here too. This check runs right after the test's sandbox
            # shut down, when wsb can print one non-JSON answer (R1). Ask again after one poll; two in a row -> $false.
            Start-Sleep -Seconds $PollSeconds
            if (-not (& $stillOpen)) { return $true }
            if ($null -eq (Get-Win32ToolkitSandboxEnvironment)) { return $false }
        }
        Write-Host "Waiting up to $TimeoutSeconds s for this test's Windows Sandbox to close..." -ForegroundColor Gray
    }
    else {
        Write-Host "Another Windows Sandbox is still open (only one instance is allowed) — waiting up to $TimeoutSeconds s for it to close..." -ForegroundColor Yellow
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $clientNames = @('WindowsSandboxRemoteSession', 'WindowsSandboxClient')
    # A client window's identity: process id + start time (a reused id is another window). $null when unreadable.
    $startOf = {
        param($Proc)
        try { [datetime]$Proc.StartTime }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $null
        }
    }
    $reportFree = if ($OwnRun) { { Write-Host "✓ This test's Windows Sandbox closed." -ForegroundColor Green } }
    else { { Write-Host '✓ Previous sandbox closed.' -ForegroundColor Green } }
    $useWsb = $true          # $false after two failed wsb answers in a row: the process check alone decides, as before
    $wsbFailures = 0         # failed wsb answers in a row (missing, failed, timed out, unparseable); a good answer resets it
    $noSandboxSince = $null  # since when wsb has reported no sandbox while only the same client windows are left
    $staleKeys = ''          # those client windows (id:start), so a window that appears later restarts the grace
    do {
        Start-Sleep -Seconds $PollSeconds
        if (-not (& $stillOpen)) { & $reportFree; return $true }
        if (-not $useWsb) { continue }

        $sandboxes = Get-Win32ToolkitSandboxEnvironment
        # A failed answer is never "no sandbox": it restarts the grace. One is tolerated (R1 saw one transient non-JSON
        # answer while a sandbox shut down); the second in a row leaves the process check alone for the rest of the wait.
        if ($null -eq $sandboxes) { $wsbFailures++; $useWsb = $wsbFailures -lt 2; $noSandboxSince = $null; continue }
        $wsbFailures = 0
        if ($sandboxes.Count -gt 0) { $noSandboxSince = $null; continue }   # a running sandbox is never touched

        # Only this session's client windows can be judged: wsb reports only this user's sandboxes.
        $procs = @(Get-Process -Name $sandboxNames -ErrorAction Ignore)
        $clients = @($procs | Where-Object { $clientNames -contains [string]$_.ProcessName -and $null -ne $_.SessionId -and [int]$_.SessionId -eq $mySession })
        if ($procs.Count -eq 0 -or $clients.Count -ne $procs.Count) { $noSandboxSince = $null; continue }

        $keys = (@($clients | ForEach-Object { $st = & $startOf $_; '{0}:{1}' -f $_.Id, $(if ($st) { $st.Ticks } else { '?' }) }) | Sort-Object) -join ','
        if ($null -eq $noSandboxSince -or $keys -ne $staleKeys) { $noSandboxSince = Get-Date; $staleKeys = $keys; continue }
        $now = Get-Date
        if (($now - $noSandboxSince).TotalSeconds -lt $StaleClientSeconds) { continue }
        # A window that is not provably old enough (a sandbox that is starting) is never closed.
        $young = @($clients | Where-Object { $st = & $startOf $_; $null -eq $st -or ($now - $st).TotalSeconds -lt $StaleClientSeconds })
        if ($young.Count -gt 0) { continue }
        # Ask once more right before closing: a sandbox listed now is never touched.
        $again = Get-Win32ToolkitSandboxEnvironment
        if ($null -eq $again) { $wsbFailures++; $useWsb = $wsbFailures -lt 2; $noSandboxSince = $null; continue }
        $wsbFailures = 0
        if ($again.Count -gt 0) { $noSandboxSince = $null; continue }

        $names = (@($clients | ForEach-Object { [string]$_.ProcessName }) | Select-Object -Unique) -join ', '
        Write-Host "Windows Sandbox reports no running sandbox, but its window ($names) is still open after $StaleClientSeconds s: closing it." -ForegroundColor Yellow
        Close-Win32ToolkitSandboxClient -Process $clients -WaitSeconds $CloseWaitSeconds
        $noSandboxSince = $null
        if (-not (& $stillOpen)) { & $reportFree; return $true }
        # Still open (a window that could not be stopped, or a new sandbox): keep waiting until the timeout.
    } until ((Get-Date) -gt $deadline)

    if ($OwnRun) {
        Write-Host "A Windows Sandbox window of this session is still open after $TimeoutSeconds s; the next test waits for it to close." -ForegroundColor Yellow
    }
    return $false
}
