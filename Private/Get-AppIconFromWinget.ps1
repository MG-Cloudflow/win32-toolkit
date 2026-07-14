function Get-AppIconFromWinget {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$ProjectPath,
        [string]$FilesPath
    )

    try {
        # Find IconUrl in any YAML file under FilesPath
        $iconUrl = $null
        $yamlFiles = Get-ChildItem -Path $FilesPath -Filter '*.yaml' -ErrorAction SilentlyContinue
        foreach ($yaml in $yamlFiles) {
            $content = Get-Content -Path $yaml.FullName -Raw -Encoding UTF8
            if ($content -match 'IconUrl:\s*(.+)') {
                $iconUrl = $matches[1].Trim()
                break
            }
        }

        if (-not $iconUrl) {
            Write-Warning 'No WinGet IconUrl found in YAML — keeping default PSADT icon'
            return $false
        }

        Write-Verbose "Downloading app icon from WinGet: $iconUrl"

        # Determine save paths
        $assetsPath    = Join-Path $ProjectPath 'Assets'
        $psdtAssetsPath = Join-Path $ProjectPath 'PSAppDeployToolkit\Assets'

        foreach ($folder in @($assetsPath, $psdtAssetsPath)) {
            if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        }

        $iconDest = Join-Path $assetsPath 'AppIcon.png'

        $wr = Invoke-WebRequest -Uri $iconUrl -UseBasicParsing -ErrorAction Stop
        [System.IO.File]::WriteAllBytes($iconDest, $wr.Content)

        # Determine the icon file type from URL extension or Content-Type
        $ext = [System.IO.Path]::GetExtension($iconUrl).ToLower()
        if ($ext -notin @('.png','.ico','.jpg','.jpeg','.bmp')) { $ext = '.png' }

        # If it's an ICO, save with correct extension alongside the PNG copy
        if ($ext -eq '.ico') {
            $icoDest = Join-Path $assetsPath 'AppIcon.ico'
            [System.IO.File]::WriteAllBytes($icoDest, $wr.Content)
        }

        # Also copy to PSAppDeployToolkit\Assets so the toolkit's own default is replaced
        $psdtIconDest = Join-Path $psdtAssetsPath 'AppIcon.png'
        Copy-Item -Path $iconDest -Destination $psdtIconDest -Force

        Write-Host "✓ App icon downloaded and applied to Assets\" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Could not download app icon: $($_.Exception.Message)"
        return $false
    }
}