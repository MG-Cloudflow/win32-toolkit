function Close-Win32ToolkitSandboxClient {
    <#
    .SYNOPSIS
        Closes leftover Windows Sandbox client windows (WindowsSandboxRemoteSession, WindowsSandboxClient)
        whose sandbox is already gone.
    .DESCRIPTION
        Windows Sandbox 0.8 can leave its client window open on 'The remote environment is shutting down'
        after the guest has shut down, which blocked the next test run (test campaign F1).
        Wait-Win32ToolkitSandboxFree calls this only when 'wsb list' has reported no running sandbox for a
        grace period and these client windows are the only Windows Sandbox processes left.

        It asks each window to close (CloseMainWindow), waits up to -WaitSeconds, then stops the given
        processes that are still running (the same process objects, never by name, never their process tree).
        Only processes named WindowsSandboxRemoteSession or WindowsSandboxClient in this Windows session are
        touched: WindowsSandboxServer, anything else passed in and another session's window (another user's
        sandbox, which 'wsb list' does not report) are ignored. Never throws for a process that cannot be
        closed (a warning names it).
    .PARAMETER Process
        The client processes to close (from Get-Process).
    .PARAMETER WaitSeconds
        Seconds to wait for the windows to close before the processes are stopped (default 10).
    .PARAMETER PollSeconds
        Poll cadence while waiting (default 1).
    .EXAMPLE
        Close-Win32ToolkitSandboxClient -Process (Get-Process -Name WindowsSandboxRemoteSession)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Process,

        [ValidateRange(0, 120)]
        [int]$WaitSeconds = 10,

        [ValidateRange(1, 30)]
        [int]$PollSeconds = 1
    )

    $clientNames = @('WindowsSandboxRemoteSession', 'WindowsSandboxClient')
    $mySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $windows = @($Process | Where-Object { $null -ne $_ -and $clientNames -contains [string]$_.ProcessName })
    $targets = @($windows | Where-Object { $null -ne $_.SessionId -and [int]$_.SessionId -eq $mySession })
    foreach ($p in @($windows | Where-Object { $targets -notcontains $_ })) {
        Write-Verbose "Not closing the Windows Sandbox window of process $($p.Id): it belongs to another Windows session."
    }
    $running = {
        param($Proc)
        try { -not $Proc.HasExited }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $false
        }
    }

    foreach ($p in $targets) {
        try { $null = $p.CloseMainWindow() }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Could not ask the Windows Sandbox window (process $($p.Id)) to close: $($_.Exception.Message)"
        }
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (@($targets | Where-Object { & $running $_ }).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
    }

    foreach ($p in @($targets | Where-Object { & $running $_ })) {
        try {
            $p.Kill()
            Write-Verbose "Stopped the leftover Windows Sandbox window (process $($p.Id))."
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Warning "Could not stop the leftover Windows Sandbox window ($($p.ProcessName), process $($p.Id)): $($_.Exception.Message)"
        }
    }
}
