function Add-Win32ToolkitInstallerFiles {
    <#
    .SYNOPSIS
        Copies operator-supplied installer file(s) into a project's Files\ folder.
    .DESCRIPTION
        Used by the manual (non-winget) flow. If SourcePath is a file, it is copied; if it is a folder, its
        CONTENTS are copied RECURSIVELY, preserving structure.

        The recursion matters. This used to copy only the files *directly* inside the folder, so a vendor
        installer that ships `setup.exe` beside a payload directory (`data\`, `redist\`, an administrative
        install point — precisely the "Advanced" manual-app case) had those subdirectories SILENTLY DROPPED.
        The package built and published cleanly and then failed on the device, with nothing in the logs
        pointing at the missing payload.

        The primary installer is detected afterwards by Get-InstallerFileInfo.
    .PARAMETER SourcePath
        Path to an installer file, or a folder containing the installer (and companion files).
    .PARAMETER FilesPath
        The project's Files\ folder (created if missing).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilesPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Source path not found: $SourcePath"
    }
    if (-not (Test-Path -LiteralPath $FilesPath)) {
        New-Item -Path $FilesPath -ItemType Directory -Force | Out-Null
    }

    $item   = Get-Item -LiteralPath $SourcePath
    $copied = 0
    if ($item.PSIsContainer) {
        # Copy the folder's CONTENTS recursively (structure preserved), not just its top-level files —
        # see the note above: dropping subdirectories produced a package that failed on the device.
        $children = @(Get-ChildItem -LiteralPath $SourcePath -Force)
        if ($children.Count -gt 0) {
            Copy-Item -Path (Join-Path $SourcePath '*') -Destination $FilesPath -Recurse -Force -ErrorAction Stop
        }
        $copied = @(Get-ChildItem -LiteralPath $FilesPath -Recurse -File -ErrorAction SilentlyContinue).Count
    }
    else {
        Copy-Item -LiteralPath $item.FullName -Destination $FilesPath -Force
        $copied++
    }

    Write-Host "✓ Copied $copied installer file(s) to Files\" -ForegroundColor Green
    return $copied
}
