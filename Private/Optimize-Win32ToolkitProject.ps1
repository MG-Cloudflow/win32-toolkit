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

    # Folders to remove entirely
    $foldersToRemove = @(
        'Docs',
        'Examples',
        'Sandbox',        # test artifacts: .wsb configs, Countdown, OldVersion + Dependencies installers
        'Documentation',
        'Intune'          # Publications.json — tenant ids + app ids must NEVER travel to a device
    )

    foreach ($folder in $foldersToRemove) {
        $folderPath = Join-Path $ProjectPath $folder
        if (Test-Path $folderPath) {
            Remove-Item -Path $folderPath -Recurse -Force
            Write-Verbose "Removed folder : $folder\"
        }
    }

    # Markdown and WSB files in project root
    $rootFiles = Get-ChildItem -Path $ProjectPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.md', '.wsb' }
    foreach ($file in $rootFiles) {
        Remove-Item -Path $file.FullName -Force
        Write-Verbose "Removed file   : $($file.Name)"
    }

    # SupportFiles\ — remove the documentation script and logs, keep RequirementScript.ps1
    $supportFiles = Join-Path $ProjectPath 'SupportFiles'
    if (Test-Path $supportFiles) {
        $docsArtifacts = Get-ChildItem -Path $supportFiles -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'TargetedDocumentationScript*' -or $_.Name -like 'Targeted_Documentation_Log*' }
        foreach ($file in $docsArtifacts) {
            Remove-Item -Path $file.FullName -Force
            Write-Verbose "Removed file   : SupportFiles\$($file.Name)"
        }
    }

    # Remove empty subdirectories (bottom-up so nested empty dirs are caught)
    $allDirs = Get-ChildItem -Path $ProjectPath -Recurse -Directory |
        Sort-Object -Property FullName -Descending

    foreach ($dir in $allDirs) {
        $isEmpty = ($dir.GetFileSystemInfos().Count -eq 0)
        if ($isEmpty) {
            Remove-Item -Path $dir.FullName -Force
            Write-Verbose "Removed empty  : $($dir.Name)\"
        }
    }

    Write-Host '✓ Project optimized — ready to package.' -ForegroundColor Green
}
