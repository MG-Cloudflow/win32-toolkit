function Get-Win32ToolkitBaselineInstallCommand {
    <#
    .SYNOPSIS
        Builds the PowerShell one-liner that silently installs the old-baseline installer inside the
        Update-test sandbox.
    .DESCRIPTION
        Returns a command string that is later embedded into the .wsb LogonCommand
        (powershell.exe -Command "& { <here> ; ... }") by Test-Win32ToolkitProject. Handling:

          - exe / msi     Start-Process '<path>' [-ArgumentList '<silent args>'] -Wait -PassThru
                          (an .msi path ShellExecutes through msiexec's Msi.Package verb); the exit code
                          is kept.
          - msix / appx   Add-AppxPackage -Path '<path>'  — Start-Process on these opens the App
                          Installer GUI and blocks forever; Add-AppxPackage is the silent path (exit 0,
                          or 1 when it fails).
        A fixed suffix then appends '[<UTC>Z] baseline Install parent=vendor exit=<n> result=<class>' to
        C:\PSADT\Sandbox\Logs\PsadtExitCodes.log and sets $LASTEXITCODE to the exit code (no 'exit').

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
        "try { Add-AppxPackage -Path '$pathSq' -ErrorAction Stop; `$w32tRc = 0 } catch { `$w32tRc = 1 }"
    }
    elseif ($SilentArgs) {
        "`$w32tBl = Start-Process '$pathSq' -ArgumentList '$(ConvertTo-PSSingleQuoted $SilentArgs)' -Wait -PassThru; `$w32tRc = [int]`$w32tBl.ExitCode"
    }
    else {
        "`$w32tBl = Start-Process '$pathSq' -Wait -PassThru; `$w32tRc = [int]`$w32tBl.ExitCode"
    }
    # Record the vendor baseline's exit code like the guest runner records a package (test campaign 2026-10-21,
    # H6-F7): one line in Sandbox\Logs\PsadtExitCodes.log (label 'baseline', parent=vendor, the runner's classes)
    # and $LASTEXITCODE for a Hyper-V phase's 'exit $LASTEXITCODE'. A FIXED, value-free suffix: no 'exit' (the
    # Sandbox LogonCommand goes on after it), single quotes only (the argv escape below runs over the string).
    $cmd += '; $w32tCls = ''Failed''; if ($w32tRc -eq 0 -or $w32tRc -eq 1707) { $w32tCls = ''Success'' } elseif ($w32tRc -eq 3010) { $w32tCls = ''SoftReboot'' } elseif ($w32tRc -eq 1641) { $w32tCls = ''HardReboot'' }; ' +
            '(''[{0}] baseline Install parent=vendor exit={1} result={2}'' -f ([DateTime]::UtcNow.ToString(''yyyy-MM-dd HH:mm:ss'', [Globalization.CultureInfo]::InvariantCulture) + ''Z''), $w32tRc, $w32tCls) | ' +
            'Add-Content -LiteralPath ''C:\PSADT\Sandbox\Logs\PsadtExitCodes.log'' -Encoding UTF8 -ErrorAction SilentlyContinue; $global:LASTEXITCODE = $w32tRc'

    # Argv-escape embedded double quotes for the powershell.exe -Command "..." layer, following the
    # CRT rule: backslash runs IMMEDIATELY BEFORE a quote must be doubled, then the quote escaped
    # (2n backslashes + " = n backslashes + quote toggle). Without this, the msiexec idiom
    # INSTALLDIR="C:\App\" /qn loses its closing quote and swallows /qn.
    return [regex]::Replace($cmd, '(\\*)"', '$1$1\"')
}
