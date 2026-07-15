function Optimize-Win32ToolkitProject {
<#
.SYNOPSIS
    Removes PSADT v4 boilerplate and test artifacts before IntuneWin packaging.
.DESCRIPTION
    Cleans up items that inflate the package size or are not needed inside the
    .intunewin file: documentation folders, example scripts, markdown files,
    the Sandbox testing folder (including OldVersion installers), the
    Documentation capture folder, and any empty subdirectories left behind.
.PARAMETER ProjectPath
    Full path to the PSADT project folder (the folder that contains
    Invoke-AppDeployToolkit.ps1).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )

    if (-not (Test-Path $ProjectPath)) {
        throw "Project path not found: $ProjectPath"
    }

    Write-Host 'Optimizing project for IntuneWin packaging...' -ForegroundColor Yellow

    # Silence stock-cmdlet progress bars for the whole cleanup — a large Remove-Item -Recurse otherwise
    # paints a bar that tears an interactive (Spectre) TUI. Restored in finally.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        # Non-shipping folders (test scaffolding + secrets). Export normally EXCLUDES these from the Staging
        # copy up front, so this loop is usually a no-op safety net — but when Optimize is run on its own, or
        # anything slipped through, remove them robustly (a freshly-copied PSADT .psm1 is often briefly
        # AV-locked, which is why a plain Remove-Item here used to fail and leave the folder to ship).
        $foldersToRemove = Get-Win32ToolkitNonShippingFolders
        $failed = @()
        foreach ($folder in $foldersToRemove) {
            $folderPath = Join-Path $ProjectPath $folder
            if (Test-Path -LiteralPath $folderPath) {
                if (Remove-Win32ToolkitPathWithRetry -Path $folderPath) { Write-Verbose "Removed folder : $folder\" }
                else { $failed += $folder }
            }
        }

        # Markdown and WSB files in project root
        $rootFiles = Get-ChildItem -Path $ProjectPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.md', '.wsb' }
        foreach ($file in $rootFiles) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            Write-Verbose "Removed file   : $($file.Name)"
        }

        # SupportFiles\ — remove the documentation script and logs, keep RequirementScript.ps1
        $supportFiles = Join-Path $ProjectPath 'SupportFiles'
        if (Test-Path $supportFiles) {
            $docsArtifacts = Get-ChildItem -Path $supportFiles -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'TargetedDocumentationScript*' -or $_.Name -like 'Targeted_Documentation_Log*' }
            foreach ($file in $docsArtifacts) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed file   : SupportFiles\$($file.Name)"
            }
        }

        # Remove empty subdirectories (bottom-up so nested empty dirs are caught)
        $allDirs = Get-ChildItem -Path $ProjectPath -Recurse -Directory |
            Sort-Object -Property FullName -Descending

        foreach ($dir in $allDirs) {
            $isEmpty = ($dir.GetFileSystemInfos().Count -eq 0)
            if ($isEmpty) {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed empty  : $($dir.Name)\"
            }
        }

        # A folder that could NOT be stripped would ship inside the .intunewin. Never claim success over it:
        # 'Intune' holds Publications.json (tenant + app ids that must never reach a device), so a surviving
        # 'Intune' folder is fatal; the rest are bloat and warned (re-run once the lock clears to fix).
        if ($failed.Count -gt 0) {
            if ($failed -contains 'Intune') {
                throw ("Refusing to package: could not remove the 'Intune' folder from the Staging copy at '$ProjectPath' " +
                    '(a file is locked). It holds Publications.json — tenant + app ids that must never ship to a device. ' +
                    'Close whatever is using that folder and re-run.')
            }
            Write-Warning ("Could not strip these folders from the Staging copy (a file was locked): {0}. The .intunewin may be larger than necessary — close any process using the Staging folder and re-run to fix." -f ($failed -join ', '))
        }

        Write-Host '✓ Project optimized — ready to package.' -ForegroundColor Green
    }
    finally { $ProgressPreference = $prevProgress }
}
