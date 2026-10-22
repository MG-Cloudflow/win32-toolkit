function Invoke-Win32ToolkitGuestPhase {
    <#
    .SYNOPSIS
        Runs one test/capture phase in the guest as SYSTEM (the account Intune deploys under) and returns its exit code.
    .DESCRIPTION
        Delegates to Invoke-Win32ToolkitGuestScheduledTask with RunAs 'System'. Every Hyper-V phase goes
        through here: the unattended phases and the watched GUI phases (PSADT shows its dialogs in the
        logged-on session). Running as NT AUTHORITY\SYSTEM surfaces SYSTEM-context bugs (HKCU/profile
        assumptions, mapped drives, "current user" logic) that a test run as an admin USER would mask.
        The account alone is not full Intune parity: launcher and bitness parity come from the guest
        runner's -IntuneParity phases (Sandbox\Invoke-PsadtPackage.ps1), which unattended runs use.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER Command
        A 5.1-safe PowerShell command string to run in the guest.
    .PARAMETER Label
        Short label for progress output.
    .PARAMETER TimeoutMinutes
        How long the phase may run before it is stopped (1-240, default 30), passed to
        Invoke-Win32ToolkitGuestScheduledTask: a phase still running then is stopped and reported as 267009.
        Invoke-Win32ToolkitHyperVRun raises it for a phase whose guest runner has a longer limit
        (RunnerTimeoutMinutes), so the phase backstop stays above the runner's own limit.
    .OUTPUTS
        [int] the phase's exit code (0 = success).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Command,
        [string]$Label = 'phase',
        # How long the phase may run before it is stopped; Invoke-Win32ToolkitGuestScheduledTask, default 30.
        [ValidateRange(1, 240)] [int]$TimeoutMinutes = 30
    )

    return (Invoke-Win32ToolkitGuestScheduledTask -Session $Session -Command $Command -RunAs 'System' -Label $Label -TimeoutMinutes $TimeoutMinutes)
}
