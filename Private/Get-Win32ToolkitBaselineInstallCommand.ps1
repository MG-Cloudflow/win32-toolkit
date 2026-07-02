function Get-Win32ToolkitBaselineInstallCommand {
    <#
    .SYNOPSIS
        Builds the PowerShell one-liner that silently installs the old-baseline installer inside the
        Update-test sandbox.
    .DESCRIPTION
        Returns a command string that is later embedded into the .wsb LogonCommand
        (powershell.exe -Command "& { <here> ; ... }") by Test-Win32ToolkitProject. Handling:

          - exe / msi     Start-Process '<path>' [-ArgumentList '<silent args>'] -Wait
                          (an .msi path ShellExecutes through msiexec's Msi.Package verb).
          - msix / appx   Add-AppxPackage -Path '<path>'  — Start-Process on these opens the App
                          Installer GUI and blocks forever; Add-AppxPackage is the silent path.

        Escaping layers (values are untrusted: winget download filename + YAML silent args):
          1. ConvertTo-PSSingleQuoted -> values are data inside single-quoted PS literals.
          2. Double quotes are argv-escaped as \" — the command ends up inside the LogonCommand's
             powershell.exe -Command "..." argument, where a bare " would end the argument early and
             silently truncate/mangle the install command (e.g. SilentArgs INSTALLDIR="C:\App").
        The caller XML-encodes the final string for the .wsb (ConvertTo-XmlEncoded).
    .PARAMETER InstallerSandboxPath
        Installer path as seen inside the sandbox (e.g. C:\PSADT\Sandbox\OldVersion\app.exe).
    .PARAMETER InstallerType
        exe | msi | msix | appx (extension-derived, from Download-OldVersionInstaller).
    .PARAMETER SilentArgs
        Silent switches for exe/msi (ignored for msix/appx).
    .OUTPUTS
        [string] the install command.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstallerSandboxPath,

        [Parameter(Mandatory)]
        [ValidateSet('exe', 'msi', 'msix', 'appx')]
        [string]$InstallerType,

        [string]$SilentArgs
    )

    $pathSq = ConvertTo-PSSingleQuoted $InstallerSandboxPath

    $cmd = if ($InstallerType -in @('msix', 'appx')) {
        "Add-AppxPackage -Path '$pathSq'"
    }
    elseif ($SilentArgs) {
        "Start-Process '$pathSq' -ArgumentList '$(ConvertTo-PSSingleQuoted $SilentArgs)' -Wait"
    }
    else {
        "Start-Process '$pathSq' -Wait"
    }

    # Argv-escape embedded double quotes for the powershell.exe -Command "..." layer, following the
    # CRT rule: backslash runs IMMEDIATELY BEFORE a quote must be doubled, then the quote escaped
    # (2n backslashes + " = n backslashes + quote toggle). Without this, the msiexec idiom
    # INSTALLDIR="C:\App\" /qn loses its closing quote and swallows /qn.
    return [regex]::Replace($cmd, '(\\*)"', '$1$1\"')
}
