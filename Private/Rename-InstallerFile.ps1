function Rename-InstallerFile {
    param(
        [string]$FilesPath,
        [string]$AppName,
        [string]$Version,
        [string]$Architecture
    )

    # Build a clean base name: AppName_Architecture_Version  (no spaces, filesystem-safe chars only)
    $cleanName = ($AppName -replace '[^A-Za-z0-9._-]', '_') -replace '_+', '_'
    $cleanVer  = ($Version  -replace '[^A-Za-z0-9._-]', '_') -replace '_+', '_'
    $cleanArch = ($Architecture -replace '[^A-Za-z0-9]', '').ToLower()
    $baseName  = "${cleanName}_${cleanArch}_${cleanVer}"

    $renamed = $false
    foreach ($ext in @('msi', 'exe', 'msix', 'appx')) {
        $files = Get-ChildItem -Path $FilesPath -Filter "*.$ext" -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.BaseName -ne $baseName }
        foreach ($file in $files) {
            $newName = "$baseName.$ext"
            $newPath = Join-Path $FilesPath $newName
            if (Test-Path $newPath) { Remove-Item $newPath -Force }
            Rename-Item -Path $file.FullName -NewName $newName -Force
            Write-Host "Renamed: $($file.Name)  →  $newName" -ForegroundColor Cyan
            $renamed = $true
        }
    }
    if (-not $renamed) {
        Write-Host "Installer filename already clean — no rename needed." -ForegroundColor Gray
    }
}