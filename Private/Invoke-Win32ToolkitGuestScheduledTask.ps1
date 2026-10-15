function Invoke-Win32ToolkitGuestScheduledTask {
    <#
    .SYNOPSIS
        Runs a command in the guest via a one-shot scheduled task as SYSTEM and returns its exit code.
    .DESCRIPTION
        Shared execution primitive for the Hyper-V backend. The task runs as NT AUTHORITY\SYSTEM
        (ServiceAccount, session 0, RunLevel Highest) - the ACCOUNT Intune deploys Win32 apps under. It is
        NOT full Intune parity: the task starts a 64-bit powershell.exe with -Command, while the Intune
        Management Extension launches the published command line from a 32-bit process. Bitness and
        launcher parity come from the Intune-parity phases (Sandbox\Invoke-PsadtPackage.ps1 -IntuneParity).
        PSADT itself shows its dialogs in the logged-on user's session when a phase asks for them.
        Untrusted values are passed as scriptblock ARGUMENTS, never spliced into code. HOST-ONLY.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER Command
        A 5.1-safe PowerShell command string to run in the guest.
    .PARAMETER RunAs
        'System' (the only context; kept as a parameter so callers and the remoting argument list are
        unchanged).
    .PARAMETER Label
        Short label for progress output.
    .PARAMETER TimeoutMinutes
        How long to wait for the task to finish (default 30).
    .OUTPUTS
        [int] the task's LastTaskResult (0 = success).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Command,
        [ValidateSet('System')] [string]$RunAs = 'System',
        [string]$Label = 'phase',
        [ValidateRange(1, 240)] [int]$TimeoutMinutes = 30
    )

    Write-Verbose "  [guest:SYSTEM] $Label"

    $result = Invoke-Command -Session $Session -ScriptBlock {
        param($cmd, $runAs, $timeoutMin)
        $taskName = 'Win32ToolkitPhase'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        # -WindowStyle Hidden so the raw powershell.exe console never shows — only PSADT's own GUI does.
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$cmd`""
        # SYSTEM is the only context (validated on the host; the argument stays in the list). Refuse anything
        # else in the guest too rather than run a phase in an unexpected context.
        if ($runAs -ne 'System') { throw "Unsupported RunAs '$runAs': guest phases run as SYSTEM only." }
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null

        # Snapshot the task info BEFORE starting. Task State is AMBIGUOUS: 'Ready' means both
        # "not started yet" and "already finished", and Start-ScheduledTask launches ASYNCHRONOUSLY —
        # a fast first poll can sample 'Ready' before the scheduler transitions to 'Running' and would
        # declare the phase complete while the installer is still launching (racing the UNINSTALL phase
        # against a running install). Completion is therefore keyed on a task-info TRANSITION
        # (LastRunTime / LastTaskResult changed vs this stamp) AND a non-Running state — which is what
        # lets the poll run at 1 s (guest-local, free) instead of the old blind 3 s pre-sleep per phase.
        $preInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue

        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddMinutes($timeoutMin)
        if ($preInfo) {
            # A task that NEVER starts (scheduler refuses it, principal problem) must fail fast, not
            # burn the full phase timeout: if nothing has transitioned and it was never seen Running
            # within 120 s of Start-ScheduledTask, bail — the stale LastTaskResult (267011,
            # "has not yet run") is returned and surfaces as a failed phase, like the old fast path.
            $startupDeadline = (Get-Date).AddSeconds(120)
            $sawRunning = $false
            do {
                $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
                if ($state -eq 'Running') { $sawRunning = $true }
                $info  = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                $ran   = $info -and (($info.LastRunTime -ne $preInfo.LastRunTime) -or ($info.LastTaskResult -ne $preInfo.LastTaskResult))
                if ($ran -and $state -ne 'Running') { break }
                if (-not $ran -and -not $sawRunning -and (Get-Date) -gt $startupDeadline) { break }
                Start-Sleep -Seconds 1
            } until ((Get-Date) -gt $deadline)
        }
        else {
            # No pre-start stamp (abnormal): the transition signal is unavailable, so fall back to the
            # legacy shape — a blind first sleep long enough to outlive the async launch, then state-only.
            do {
                Start-Sleep -Seconds 3
                $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            } until ($state -ne 'Running' -or (Get-Date) -gt $deadline)
        }

        $rc = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue).LastTaskResult
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($null -ne $rc) { $rc } else { 0 }
    } -ArgumentList $Command, $RunAs, $TimeoutMinutes

    return [int](@($result) | Select-Object -Last 1)
}
