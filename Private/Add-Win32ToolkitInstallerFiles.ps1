function Add-Win32ToolkitInstallerFiles {
    <#
    .SYNOPSIS
        Copies operator-supplied installer file(s) into a project's Files\ folder.
    .DESCRIPTION
        Used by the manual (non-winget) flow. If SourcePath is a file, it is copied; if it is a
        folder, every file directly inside it is copied (installer + any companion MST/MSP/config).
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
        foreach ($f in (Get-ChildItem -LiteralPath $SourcePath -File)) {
            Copy-Item -LiteralPath $f.FullName -Destination $FilesPath -Force
            $copied++
        }
    }
    else {
        Copy-Item -LiteralPath $item.FullName -Destination $FilesPath -Force
        $copied++
    }

    Write-Host "✓ Copied $copied installer file(s) to Files\" -ForegroundColor Green
    return $copied
}
