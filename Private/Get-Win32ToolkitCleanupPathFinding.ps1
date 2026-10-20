function Get-Win32ToolkitCleanupPathFinding {
    <#
    .SYNOPSIS
        Checks a project's uninstall cleanup paths (AppConfig Uninstall.CleanupPaths) against the allowlist.
    .DESCRIPTION
        The data-driven uninstall deletes every SupportFiles\AppConfig.json Uninstall.CleanupPaths entry
        recursively, as SYSTEM, on every device. Captures made before win32-toolkit kept those paths inside
        the app's own install folders could list shared folders (C:\Program Files (x86), Edge / WebView2
        folders an updater created during the capture). This helper is the ONE evaluation behind the Export
        error (Assert-Win32ToolkitPackageReady -Stage Export, no override) and the Publish warning, so the
        two can never disagree.

          1. SupportFiles\AppConfig.json is read; when PowerShell 7 cannot read it, one 'Unreadable'
             finding, which the Export gate treats as an error like the others: Windows PowerShell 5.1,
             which runs the deploy script on the device, accepts JSON that PowerShell 7 rejects (a number
             written '+1'), so the device could still read and delete cleanup paths nobody checked. A
             missing file is the empty seed config (Get-Win32ToolkitAppConfig): no cleanup path, no finding.
          2. The cleanup paths are the Uninstall.CleanupPaths entries exactly as the deploy script reads them
             (every non-empty entry); none -> no finding.
          3. The capture is the newest Documentation\InstallationChanges_*.json (an unparseable one counts
             as absent).
          4. The install roots are Uninstall.InstallRoots when the section has them (each invalid root is an
             'InstallRoot' finding and is not used), else the roots Get-Win32ToolkitInstallRoot derives from
             the capture, else none.
          5. With a capture, a path must also be a folder the capture created.
          6. Each path that fails Test-Win32ToolkitCleanupPath is a 'CleanupPath' finding.

        Read-only and never throws. A check that fails unexpectedly is reported as a 'CleanupPath' finding
        (fail closed: a cleanup list that could not be checked is never packaged).
    .PARAMETER ProjectPath
        The project folder (the folder that contains SupportFiles\AppConfig.json).
    .OUTPUTS
        [pscustomobject] per finding: Kind ('CleanupPath', 'InstallRoot' or 'Unreadable'), Path, Reasons
        ([string[]], Test-Win32ToolkitCleanupPath codes), Explanation (the predicate's human-readable
        reasons), Message (the full one-line text). Nothing when there is nothing to report.
    .EXAMPLE
        @(Get-Win32ToolkitCleanupPathFinding -ProjectPath $proj) | ForEach-Object Message
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    # Untrusted text (capture and AppConfig data) never reaches the console with control or format characters.
    $safe = { param([string]$Text) ([string]$Text) -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?' }
    $newFinding = {
        param([string]$Kind, [string]$Path, [string[]]$Reasons, [string]$Explanation, [string]$Message)
        [pscustomobject]@{ Kind = $Kind; Path = $Path; Reasons = [string[]]@($Reasons); Explanation = $Explanation; Message = $Message }
    }
    $recapture = "re-run the install capture (Complete-Win32ToolkitManualApp -ProjectPath '$((& $safe $ProjectPath).Replace("'", "''"))')"

    # -- 1. AppConfig ---------------------------------------------------------------------------------------
    # Unreadable is NOT harmless: Windows PowerShell 5.1 (the device) accepts JSON that PowerShell 7 rejects
    # (e.g. a number written '+1'), so the deploy script could still read and delete paths nobody checked.
    # The capture cannot repair it (Update-PSADTUninstallLogic reads the same file first): fix it or rebuild.
    $cfg = $null
    try { $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath -ErrorAction Stop }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        $why = (& $safe $_.Exception.Message).Trim().TrimEnd('.')
        & $newFinding 'Unreadable' '' @() $why (
            "SupportFiles\AppConfig.json could not be read, so its uninstall cleanup paths could not be checked: $why. " +
            'Fix the JSON so PowerShell 7 can read it (Windows PowerShell 5.1 on the device may still read it and delete the cleanup paths unchecked), ' +
            'or re-create the project. This check has no override.')
        return
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    try {
        # -- 2. the paths, read exactly as the deploy script reads them ------------------------------------
        # (foreach ($folder in @($appConfig.Uninstall.CleanupPaths)) { if (-not $folder) { continue } ... })
        $uninstall = $cfg.Uninstall
        $paths = @(foreach ($entry in @($cfg.Uninstall.CleanupPaths)) { if ($entry) { [string]$entry } })

        if ($paths.Count) {
            # -- 3. the newest install capture --------------------------------------------------------------
            $capture = $null
            $captureFile = Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($ProjectPath, 'Documentation')) -Filter 'InstallationChanges_*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property Name | Select-Object -Last 1
            if ($captureFile) {
                try { $capture = Get-Content -LiteralPath $captureFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    Write-Verbose "Cleanup paths: '$($captureFile.Name)' could not be parsed ($(& $safe $_.Exception.Message)); checked without a capture."
                    $capture = $null
                }
            }

            $app = $cfg.App
            $displayName = if ($app -and $app.DisplayName) { [string]$app.DisplayName } elseif ($app) { [string]$app.Name } else { '' }
            $installRoot = if ($null -ne $capture) { Get-Win32ToolkitInstallRoot -Capture $capture -ProjectPath $ProjectPath -DisplayName $displayName } else { $null }

            # -- 4. install roots ---------------------------------------------------------------------------
            $roots = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $uninstall -and $null -ne $uninstall.PSObject.Properties['InstallRoots']) {
                foreach ($entry in @($uninstall.InstallRoots)) {
                    if (-not $entry) { continue }
                    $rootText = ([string]$entry).TrimEnd('\')
                    $check = Test-Win32ToolkitCleanupPath -Path $rootText -AsInstallRoot
                    if ($check.Valid) { $roots.Add($rootText); continue }
                    $findings.Add((& $newFinding 'InstallRoot' ([string]$entry) $check.Reasons $check.Explanation (
                                "Unsafe uninstall install root: '$(& $safe $entry)' in SupportFiles\AppConfig.json (Uninstall.InstallRoots) - $($check.Explanation). " +
                                "Cleanup paths are only accepted inside the app's own install folders. Remove the entry, or $recapture so the install folders are rebuilt from the app's own uninstall entry, or re-create the project. This check has no override.")))
                }
            }
            elseif ($installRoot) {
                foreach ($r in @($installRoot.Roots)) { $roots.Add([string]$r) }
            }

            # -- 5. + 6. each path --------------------------------------------------------------------------
            foreach ($path in $paths) {
                $arguments = @{ Path = $path; InstallRoot = [string[]]$roots.ToArray() }
                if ($installRoot) { $arguments.CreatedDirectory = [string[]]@($installRoot.CreatedDirectories) }
                $check = Test-Win32ToolkitCleanupPath @arguments
                if ($check.Valid) { continue }
                $findings.Add((& $newFinding 'CleanupPath' $path $check.Reasons $check.Explanation (
                            "Unsafe uninstall cleanup path: '$(& $safe $path)' in SupportFiles\AppConfig.json (Uninstall.CleanupPaths) - $($check.Explanation). " +
                            "The uninstall deletes every cleanup path recursively as SYSTEM. Remove the entry, or $recapture so the paths are rebuilt from the allowlist, or re-create the project. This check has no override.")))
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        # Fail closed: a cleanup list that could not be checked is never packaged.
        $why = & $safe $_.Exception.Message
        $findings.Add((& $newFinding 'CleanupPath' '' @('Unchecked') "the entries could not be checked ($why)" (
                    "Unsafe uninstall cleanup path: the entries in SupportFiles\AppConfig.json (Uninstall.CleanupPaths) could not be checked ($why). " +
                    "The uninstall deletes every cleanup path recursively as SYSTEM. Fix the Uninstall section, or $recapture, or re-create the project. This check has no override.")))
    }
    $findings.ToArray()
}
