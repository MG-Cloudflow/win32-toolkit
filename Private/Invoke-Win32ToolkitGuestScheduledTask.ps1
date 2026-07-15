function Invoke-Win32ToolkitGuestScheduledTask {
    <#
    .SYNOPSIS
        Runs a command in the guest via a one-shot scheduled task, as SYSTEM or as an interactive user,
        and returns its exit code.
    .DESCRIPTION
        Shared execution primitive for the Hyper-V backend. Running through a scheduled task lets us pick
        the security context:
          - RunAs 'System'  -> NT AUTHORITY\SYSTEM (ServiceAccount, session 0, non-interactive). This is
            the SAME context Intune deploys Win32 apps under, so silent/automation runs match production.
          - RunAs '<user>'  -> the logged-on user (Interactive), RunLevel Highest, so a GUI renders on the
            console (for hands-on PSADT testing). SYSTEM cannot show a GUI (session-0 isolation).
        Untrusted values are passed as scriptblock ARGUMENTS, never spliced into code. HOST-ONLY.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER Command
        A 5.1-safe PowerShell command string to run in the guest.
    .PARAMETER RunAs
        'System' (default) or a SAM username to run the task as.
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
        [string]$RunAs = 'System',
        [string]$Label = 'phase',
        [ValidateRange(1, 240)] [int]$TimeoutMinutes = 30
    )

    $ctx = if ($RunAs -eq 'System') { 'SYSTEM' } else { "$RunAs (interactive)" }
    Write-Verbose "  [guest:$ctx] $Label"

    $result = Invoke-Command -Session $Session -ScriptBlock {
        param($cmd, $runAs, $timeoutMin)
        $taskName = 'Win32ToolkitPhase'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        # -WindowStyle Hidden so the raw powershell.exe console never shows — only PSADT's own GUI does.
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$cmd`""
        $principal = if ($runAs -eq 'System') {
            New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        } else {
            New-ScheduledTaskPrincipal -UserId $runAs -LogonType Interactive -RunLevel Highest
        }
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null

        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddMinutes($timeoutMin)
        do {
            Start-Sleep -Seconds 3
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
        } until ($state -ne 'Running' -or (Get-Date) -gt $deadline)

        $rc = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue).LastTaskResult
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($null -ne $rc) { $rc } else { 0 }
    } -ArgumentList $Command, $RunAs, $TimeoutMinutes

    return [int](@($result) | Select-Object -Last 1)
}
