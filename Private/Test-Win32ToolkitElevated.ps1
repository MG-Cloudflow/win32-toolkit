function Test-Win32ToolkitElevated {
    <#
    .SYNOPSIS
        Returns $true if the current PowerShell session is elevated (running as Administrator).
    .DESCRIPTION
        The Hyper-V test backend drives the guest over PowerShell Direct, which requires an elevated
        Hyper-V administrator on the host. Factored out as a testable predicate so the readiness check
        and (later) the Hyper-V provider can gate on it without duplicating the identity plumbing.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
