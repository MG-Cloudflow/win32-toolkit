function Invoke-Win32ToolkitGuestInteractive {
    <#
    .SYNOPSIS
        Runs a phase in the guest's INTERACTIVE user session (so a GUI shows on the console / vmconnect).
    .DESCRIPTION
        Delegates to Invoke-Win32ToolkitGuestScheduledTask with RunAs = the logged-on user, which runs the
        task in that user's interactive session (LogonType Interactive, RunLevel Highest) where the UI is
        visible. This is the ONE place we deliberately do NOT use SYSTEM: session-0 isolation means a
        SYSTEM task can't paint a desktop, so hands-on PSADT GUI testing has to run as the user. Requires
        the guest user to be logged on interactively (the warm checkpoint captures the logged-in desktop).
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
        [int] the phase's exit code.
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

    $sam = $UserName.Split('\')[-1]
    return (Invoke-Win32ToolkitGuestScheduledTask -Session $Session -Command $Command -RunAs $sam -Label "$Label (watch the VM console)" -TimeoutMinutes $TimeoutMinutes)
}
