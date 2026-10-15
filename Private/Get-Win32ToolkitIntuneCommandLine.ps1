function Get-Win32ToolkitIntuneCommandLine {
    <#
    .SYNOPSIS
        The Intune install/uninstall command lines of a win32-toolkit package (single source of truth).
    .DESCRIPTION
        Returns the constant command lines that Publish-Win32ToolkitIntuneApp sends to Intune and
        Export-Win32ToolkitDocumentation prints, so the published app and its documentation can never
        disagree. Anything else that must launch a package exactly as Intune does reads it from here too.

        The package is started through PSADT's own launcher, Invoke-AppDeployToolkit.exe, and NOT with
        'powershell.exe -File Invoke-AppDeployToolkit.ps1' (the command line of win32-toolkit 1.1.6 and
        older). The Intune Management Extension is a 32-bit process, so a bare 'powershell.exe' resolves
        to the 32-bit (SysWOW64) Windows PowerShell on a 64-bit device:
          * PSADT 4.2 refuses to run in a 32-bit PowerShell on a 64-bit OS and exits 60008 before any
            deployment phase runs;
          * PSADT 4.1 runs, but 32-bit, so the install tattoo lands under HKLM\SOFTWARE\WOW6432Node,
            where the 64-bit detection rule never finds it.
        Invoke-AppDeployToolkit.exe is AnyCPU (PSADT 4.1 and 4.2): it runs 64-bit on a 64-bit OS, even
        from a 32-bit parent, and starts the 64-bit Windows PowerShell 5.1.

        Deliberately absent (Tests\IntuneCommandLine.unit.ps1 asserts each):
          * '-DeployMode' - PSADT chooses the mode itself (Auto); forcing one on the Intune command line
            would change the dialogs of every app.
          * 'AllowWowProcess' and 'Sysnative' - both keep a 32-bit or redirected launch alive.

        Apps that win32-toolkit 1.1.6 or older published keep the old 'powershell.exe -File' command line
        in Intune until they are republished or their command lines are edited in the Intune portal.
    .OUTPUTS
        [pscustomobject] with Install, Uninstall, Launcher and Script (all [string]).
    .EXAMPLE
        (Get-Win32ToolkitIntuneCommandLine).Install
        # Invoke-AppDeployToolkit.exe -DeploymentType Install
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $launcher = 'Invoke-AppDeployToolkit.exe'
    [pscustomobject]@{
        Install   = "$launcher -DeploymentType Install"
        Uninstall = "$launcher -DeploymentType Uninstall"
        Launcher  = $launcher
        Script    = 'Invoke-AppDeployToolkit.ps1'
    }
}
