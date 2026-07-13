function Invoke-Win32ToolkitGuestInteractive {
    <#
    .SYNOPSIS
        Runs a command in the guest's INTERACTIVE desktop session (so a GUI shows on the console /
        vmconnect) via a one-shot scheduled task, and waits for it to finish.
    .DESCRIPTION
        PowerShell Direct's Invoke-Command runs in a NON-interactive session, so a GUI launched that way
        never renders on the logged-in desktop. To let an operator watch/drive a PSADT GUI install, this
        registers a one-shot scheduled task that runs as the logged-in user (LogonType Interactive,
        RunLevel Highest) — which executes in their interactive session where the UI is visible — starts
        it, waits for completion, and returns the task's LastTaskResult. Requires the guest user to be
        logged on interactively (the warm checkpoint captures the logged-in desktop, so it is).
        See knowledge-base/designs/hyperv-backend-plan.md.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER Command
        A 5.1-safe PowerShell command string to run interactively in the guest.
    .PARAMETER UserName
        The interactive guest user (SAM name, e.g. 'w32admin') the task runs as.
    .PARAMETER Label
        Short label for progress output.
    .PARAMETER TimeoutMinutes
        How long to wait for the interactive task to finish (default 30).
    .OUTPUTS
        [int] the task's LastTaskResult (0 = success; may be non-zero if it timed out or was cancelled).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Command,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$UserName,
        [string]$Label = 'interactive phase',
        [ValidateRange(1, 240)] [int]$TimeoutMinutes = 30
    )

    Write-Host "  [guest-gui] $Label (watch the VM console / vmconnect)" -ForegroundColor Gray
    $sam = $UserName.Split('\')[-1]

    $result = Invoke-Command -Session $Session -ScriptBlock {
        param($cmd, $user, $timeoutMin)
        $taskName = 'Win32ToolkitInteractive'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
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
    } -ArgumentList $Command, $sam, $TimeoutMinutes

    return [int](@($result) | Select-Object -Last 1)
}
