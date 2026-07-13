function Invoke-Win32ToolkitGuestPhase {
    <#
    .SYNOPSIS
        Runs a non-interactive test/capture phase in the guest as SYSTEM — the same context Intune uses.
    .DESCRIPTION
        Delegates to Invoke-Win32ToolkitGuestScheduledTask with RunAs 'System', so the silent/automation
        path installs exactly like a real Intune Win32 deployment (NT AUTHORITY\SYSTEM, session 0). This
        surfaces SYSTEM-context bugs (HKCU/profile assumptions, mapped drives, "current user" logic) that
        a test run as an admin USER would mask.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER Command
        A 5.1-safe PowerShell command string to run in the guest.
    .PARAMETER Label
        Short label for progress output.
    .OUTPUTS
        [int] the phase's exit code (0 = success).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Command,
        [string]$Label = 'phase'
    )

    return (Invoke-Win32ToolkitGuestScheduledTask -Session $Session -Command $Command -RunAs 'System' -Label $Label)
}
