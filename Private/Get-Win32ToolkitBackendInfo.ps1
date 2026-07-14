function Get-Win32ToolkitBackendInfo {
    <#
    .SYNOPSIS
        Describes the effective test/capture backend for the TUI: what is CONFIGURED, what will actually
        RUN, a display label, and whether it silently fell back to Sandbox (and why).
    .DESCRIPTION
        The TUI used to hard-code "Windows Sandbox" in its labels even though documentation capture and the
        test scenarios silently follow the configured TestBackend — so it told the operator their app ran in
        a sandbox when it actually ran in the Hyper-V VM. Every screen now renders from this one helper so
        the UI can never drift from Get-Win32ToolkitTestBackend again.

        Resolution is delegated to Get-Win32ToolkitTestBackend (Sandbox unless HyperV is configured AND the
        VM/checkpoint/credential exist AND the host is elevated). Its fallback warning is suppressed here —
        the caller decides how to surface FellBack/Reasons.
    .OUTPUTS
        PSCustomObject:
          Configured [string]  — 'Sandbox' | 'HyperV' (the stored preference)
          Resolved   [string]  — 'Sandbox' | 'HyperV' (what will actually run)
          Label      [string]  — 'Windows Sandbox' | 'Hyper-V VM (<name>)'
          FellBack   [bool]    — HyperV was requested but Sandbox will run
          Reasons    [string[]]— why it is not ready (empty unless FellBack)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $configured = Get-Win32ToolkitConfigValue -Name 'TestBackend'  -Default 'Sandbox'
    $vmName     = Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden'
    $resolved   = Get-Win32ToolkitTestBackend -WarningAction SilentlyContinue

    $label = if ($resolved -eq 'HyperV') { "Hyper-V VM ($vmName)" } else { 'Windows Sandbox' }

    $fellBack = [bool]($configured -eq 'HyperV' -and $resolved -ne 'HyperV')
    $reasons  = if ($fellBack) { @(Test-Win32ToolkitHyperVReady) } else { @() }

    [pscustomobject]@{
        Configured = $configured
        Resolved   = $resolved
        Label      = $label
        FellBack   = $fellBack
        Reasons    = $reasons
    }
}
