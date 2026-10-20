function Assert-Win32ToolkitPackageReady {
    <#
    .SYNOPSIS
        Refuses to finalise or package a project whose deploy script win32-toolkit cannot vouch for.
    .DESCRIPTION
        The gate in front of the expensive and irreversible steps (D15, PKG-04, L5):
        Invoke-Win32ToolkitFinalize runs it with -Stage Finalize before the project is tested, and
        Export-Win32ToolkitIntuneWin with -Stage Export before IntuneWinAppUtil.exe builds the .intunewin.

        Every check runs. All errors are collected and thrown ONCE as a W32T.PackageNotReady error whose
        message has one line per problem, each with its fix. Warnings are written with Write-Warning and
        returned.

            Check                                                       Stage    Result
            Invoke-AppDeployToolkit.ps1 exists                          both     error
            it parses (host parser)                                     both     error
            it has the AppConfig loader ('$appConfig =')                both     error; -AllowLegacyScript: warning
            its template shape and version are supported               both     error; -AllowLegacyScript: warning
            it was patched by win32-toolkit 1.1.6 or older ('Legacy')   both     warning only
            it writes the win32-toolkit install tattoo                  both     warning only
            it parses under Windows PowerShell 5.1 (fail-open)          Export   error
            Invoke-AppDeployToolkit.exe exists next to it               Export   error
            the bundled PSADT module and the script form a supported    Export   error; -AllowLegacyScript: warning
            pair (Get-Win32ToolkitProjectPsadtVersion)
            the bundled PSADT module is a prerelease (e.g. 4.2.0-rc2)   Export   warning only (F-05)
            uninstall cleanup paths stay inside the app's own install   Export   error (no override)
            folders (AppConfig)

        The shape/version policy itself lives in Get-Win32ToolkitDeployScriptShape (its Support value), so
        this gate and Get-Win32ToolkitProjectPsadtVersion cannot drift apart. A project patched by
        win32-toolkit 1.1.6 or older (Support 'Legacy') passes both stages with exactly one warning and
        needs no switch, so existing projects can still be packaged and republished from the TUI.

        Every shape/version finding (an unsupported shape or DeployAppScriptVersion, or a bundled module
        that does not pair with the script) is reported on a line that starts with the stable text
        'Unsupported PSADT template shape: ' (the same prefix the generator uses), followed by
        '<script path>; shape <Shape>; DeployAppScriptVersion <version or none>; supported: <range>. <hint>'.

        The uninstall deletes every SupportFiles\AppConfig.json Uninstall.CleanupPaths entry recursively as
        SYSTEM. At Export, each entry outside the app's own install folders (Get-Win32ToolkitCleanupPathFinding,
        Test-Win32ToolkitCleanupPath) is an error line that starts with 'Unsafe uninstall cleanup path: '
        (an invalid Uninstall.InstallRoots entry: 'Unsafe uninstall install root: '); -AllowLegacyScript does
        not downgrade it. Finalize does not check it: Finalize is the step that re-captures and repairs the
        paths. An AppConfig.json that cannot be read is an error too: Windows PowerShell 5.1 accepts JSON that
        PowerShell 7 rejects (e.g. +1), so the device could delete paths nobody checked.
    .PARAMETER ProjectPath
        Path to the PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1). A relative,
        '~' or PSDrive path is resolved against the current PowerShell location; messages show the full path.
    .PARAMETER Stage
        'Finalize' (before testing) or 'Export' (before packaging). Export adds the Windows PowerShell 5.1
        parse, the launcher check, the bundled-module check and the uninstall cleanup-path check.
    .PARAMETER AllowLegacyScript
        Downgrade the loader, shape and bundled-module findings to warnings: package a deploy script that
        win32-toolkit never patched, or whose layout this version does not support, as-is. Projects
        patched by older win32-toolkit versions do not need it. Parse, launcher and uninstall cleanup-path
        errors still stop.
    .OUTPUTS
        [pscustomobject] Ready ($true), Shape, VersionText, Warnings ([string[]]). Throws an ErrorRecord with
        FullyQualifiedErrorId 'W32T.PackageNotReady' instead when any error was found.
    .EXAMPLE
        $null = Assert-Win32ToolkitPackageReady -ProjectPath $proj -Stage Export -AllowLegacyScript:$AllowLegacyScript
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('Finalize', 'Export')]
        [string]$Stage,

        [switch]$AllowLegacyScript
    )

    # Make the path absolute FIRST: ParseFile and the shape / project-version helpers hand it to .NET, which
    # resolves a relative path against the process directory, not the PowerShell location (Set-Location
    # does not move it). Handles '.\App', '~\...' and PSDrive paths; a missing folder stays reportable
    # (unresolved = no existence check). An unknown drive keeps the raw text, reported as not found below
    # (Path.Combine, unlike Join-Path, does not fail on a drive that does not exist).
    try { $ProjectPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath) }
    catch { Write-Verbose "Could not resolve '$ProjectPath' to a file-system path: $($_.Exception.Message)" }

    $commandLine  = Get-Win32ToolkitIntuneCommandLine
    $scriptPath   = [System.IO.Path]::Combine($ProjectPath, $commandLine.Script)
    $launcherPath = [System.IO.Path]::Combine($ProjectPath, $commandLine.Launcher)
    $range        = if ($script:PsadtSupportedRange -and $script:PsadtSupportedRange.Display) { [string]$script:PsadtSupportedRange.Display } else { 'unknown' }
    $recreate     = 'Re-create the project with this win32-toolkit version (copy any hand-written Install code out of Invoke-AppDeployToolkit.ps1 first: re-creating a project deletes its folder)'

    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # A finding the operator may override: an error that names the switch, or - with -AllowLegacyScript - a
    # warning that says the script is accepted as-is.
    $downgrade = [bool]$AllowLegacyScript
    $addOverridable = {
        param([string]$Problem, [string]$Fix)
        if ($downgrade) { $warnings.Add("$Problem Accepted as-is (-AllowLegacyScript).") }
        else { $errors.Add("$Problem $Fix, or pass -AllowLegacyScript to package it as-is.") }
    }

    $shape       = $null
    $versionText = 'unknown'

    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        $errors.Add("$($commandLine.Script) not found in '$ProjectPath': this is not a PSADT project win32-toolkit can package. Create it with Invoke-Win32Toolkit or New-Win32ToolkitManualApp.")
    }
    else {
        # -- host parse ------------------------------------------------------------------------------------
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
        $hostParseClean = -not ($parseErrors -and @($parseErrors).Count)
        if (-not $hostParseClean) {
            $first = @($parseErrors)[0]
            $errors.Add("$scriptPath does not parse ($(@($parseErrors).Count) error(s); first at line $($first.Extent.StartLineNumber): $($first.Message)). Fix the script, or re-create the project.")
        }

        # -- shape / loader / tattoo (single policy: Get-Win32ToolkitDeployScriptShape) ---------------------
        $shape = Get-Win32ToolkitDeployScriptShape -Path $scriptPath
        $dasv  = if ([string]::IsNullOrWhiteSpace([string]$shape.DeployAppScriptVersion)) { 'none' } else { [string]$shape.DeployAppScriptVersion }
        # Every shape/version line starts with this exact text (stable L5 wording, spec C-1), so operators
        # and scripts can search for it; the generator uses the same prefix.
        $shapePrefix = "Unsupported PSADT template shape: $scriptPath; shape $($shape.Shape); DeployAppScriptVersion $dasv; supported: $range."

        # Bundled module + script version: read here for the result and the legacy text, enforced at Export.
        $projectVersion = Get-Win32ToolkitProjectPsadtVersion -ProjectPath $ProjectPath
        if ($projectVersion -and $projectVersion.VersionText) { $versionText = [string]$projectVersion.VersionText }

        if (-not $shape.IsPatched) {
            & $addOverridable "$scriptPath has no AppConfig loader (no '`$appConfig =' line): win32-toolkit never patched it, so none of the configured install, uninstall or tattoo data reaches the device." $recreate
        }

        $support = [string]$shape.Support
        if ($support -notin @('Supported', 'Legacy')) {
            $hint = [string]$shape.SupportReason
            if ([string]::IsNullOrWhiteSpace($hint)) {
                $hint = switch ([string]$shape.Shape) {
                    'Psadt42Default' { 'Scaffolded from the PSADT 4.2 default template without Zero-Config.' }
                    'Unknown'        { 'Not a template layout this win32-toolkit version knows (newer PSADT?) - use a supported PSADT (see the health check).' }
                    default          { "The script's DeployAppScriptVersion is outside the supported range or does not match its layout." }
                }
            }
            if ([string]$shape.Shape -eq 'Unknown' -and -not [string]::IsNullOrWhiteSpace([string]$shape.Reason) -and -not $hint.Contains([string]$shape.Reason)) {
                $hint = "$hint ($($shape.Reason))"
            }
            $hint = $hint.Trim()
            if ($hint -notmatch '[.!?]$') { $hint += '.' }
            & $addOverridable "$shapePrefix $hint" $recreate
        }
        elseif ($support -eq 'Legacy') {
            # Supported with ONE warning: patched by win32-toolkit 1.1.6 or older (no -AllowLegacyScript needed).
            $legacy = [string]$shape.SupportReason
            if ([string]::IsNullOrWhiteSpace($legacy) -and $projectVersion) { $legacy = [string]$projectVersion.Warning }
            if ([string]::IsNullOrWhiteSpace($legacy)) {
                $legacy = 'generated by an older win32-toolkit: its uninstall does not remove the legacy WOW6432Node tattoo; re-create the project with this version to get it'
            }
            $warnings.Add("${scriptPath}: $legacy")
        }

        if (-not $shape.HasTattoo) {
            $warnings.Add("$scriptPath writes no win32-toolkit install tattoo, so Intune detection falls back to the sandbox capture (Documentation\InstallationChanges_*.json). Re-create the project to get version detection.")
        }

        if ($Stage -eq 'Export') {
            # Real Windows PowerShell 5.1 parse: Intune runs the script there (fail-open when 5.1 is absent).
            # Skipped when the host parser already failed - the error above says the same thing.
            if ($hostParseClean) {
                $ps51 = @(Test-Win32ToolkitPS51Syntax -Path $scriptPath)
                if ($ps51.Count) {
                    $errors.Add("$scriptPath does not parse under Windows PowerShell 5.1, which Intune uses to run it ($($ps51.Count) error(s): $((@($ps51) | Select-Object -First 3) -join ' | ')). Remove PowerShell 7-only syntax (?:, ??, ?., &&, ||).")
                }
            }

            # Only when the shape itself is acceptable: an unsupported shape always makes the pair
            # unsupported too, and that is already reported above.
            if ($support -in @('Supported', 'Legacy') -and -not ($projectVersion -and $projectVersion.IsSupported)) {
                $why = if ($projectVersion -and $projectVersion.Reason) { " ($(([string]$projectVersion.Reason).Trim().TrimEnd('.')))" } else { '' }
                & $addOverridable "$shapePrefix The bundled PSAppDeployToolkit module ($versionText, PSAppDeployToolkit\PSAppDeployToolkit.psd1) and this deploy script are not a supported pair$why." 'Re-create the project with a supported PSAppDeployToolkit'
            }

            # A prerelease PSADT is allowed (testing 4.2 rc builds side by side, spec L4) but must not reach
            # production unnoticed: warn at Export only, so a Finalize -> Export run says it once.
            if ($projectVersion -and -not [string]::IsNullOrWhiteSpace([string]$projectVersion.Prerelease)) {
                $warnings.Add("$ProjectPath bundles PSAppDeployToolkit $versionText, a PRERELEASE (for testing only). Rebuild the project on a stable PSAppDeployToolkit before you publish it to production devices.")
            }
        }
    }

    if ($Stage -eq 'Export' -and -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        $errors.Add("$($commandLine.Launcher) is missing from '$ProjectPath': Intune starts every install and uninstall through it ('$($commandLine.Install)'), so the package would fail on every device. Re-create the project with this win32-toolkit version (PSADT's template copies the launcher).")
    }

    # -- uninstall cleanup paths (D6, L7) ----------------------------------------------------------------------
    # The uninstall deletes every cleanup path recursively as SYSTEM: a path outside the app's own install
    # folders is an error with NO override (never $addOverridable). Export only: Finalize is the step that
    # re-captures and repairs the paths. Every finding is an error, an unreadable AppConfig.json included:
    # Windows PowerShell 5.1 on the device accepts JSON that PowerShell 7 rejects (e.g. +1), so its cleanup
    # paths could still be deleted unchecked.
    if ($Stage -eq 'Export') {
        foreach ($finding in @(Get-Win32ToolkitCleanupPathFinding -ProjectPath $ProjectPath)) {
            $errors.Add([string]$finding.Message)
        }
    }

    foreach ($w in $warnings) { Write-Warning $w }

    if ($errors.Count) {
        $nothing = if ($Stage -eq 'Finalize') { 'Nothing was tested, packaged or published.' } else { 'Nothing was packaged or published.' }
        $message = (@("win32-toolkit cannot vouch for the deploy script of '$ProjectPath' (stage $Stage):") + @($errors) +
                    @("$nothing Fix each problem above and retry.")) -join [Environment]::NewLine
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message), 'W32T.PackageNotReady',
            [System.Management.Automation.ErrorCategory]::InvalidData, $ProjectPath)
    }

    [pscustomobject]@{
        Ready       = $true
        Shape       = if ($shape) { [string]$shape.Shape } else { $null }
        VersionText = $versionText
        Warnings    = [string[]]@($warnings)
    }
}
