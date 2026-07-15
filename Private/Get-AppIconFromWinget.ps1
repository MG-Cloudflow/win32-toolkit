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

        # Only ever fetch over HTTPS. An http:// (or any non-https) URL is never contacted —
        # a plaintext fetch is trivially MITM'd and we'd be writing attacker bytes as SYSTEM's icon.
        if ($iconUrl -notmatch '^(?i)https://') {
            Write-Warning "WinGet IconUrl is not HTTPS ('$iconUrl') — refusing to fetch; keeping default PSADT icon"
            return $false
        }

        Write-Verbose "Downloading app icon from WinGet: $iconUrl"

        # Determine save paths
        $assetsPath    = Join-Path $ProjectPath 'Assets'
        $psdtAssetsPath = Join-Path $ProjectPath 'PSAppDeployToolkit\Assets'

        foreach ($folder in @($assetsPath, $psdtAssetsPath)) {
            if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        }

        $maxBytes = 5MB

        $wr = Invoke-WebRequest -Uri $iconUrl -UseBasicParsing -ErrorAction Stop

        # Pre-check the advertised size when present — Content-Length can lie or be absent, so this is
        # only an early-out; the authoritative check is on the real byte count below.
        $declaredLen = $null
        try { $declaredLen = [int64]($wr.Headers['Content-Length'] | Select-Object -First 1) } catch { $declaredLen = $null }
        if ($declaredLen -and $declaredLen -gt $maxBytes) {
            Write-Warning "App icon Content-Length ($declaredLen bytes) exceeds the 5 MB cap — keeping default PSADT icon"
            return $false
        }

        $bytes = [byte[]]$wr.Content

        # Authoritative size check on what actually arrived.
        if ($null -eq $bytes -or $bytes.Length -eq 0) {
            Write-Warning 'App icon download was empty — keeping default PSADT icon'
            return $false
        }
        if ($bytes.Length -gt $maxBytes) {
            Write-Warning "App icon ($($bytes.Length) bytes) exceeds the 5 MB cap — keeping default PSADT icon"
            return $false
        }

        # Validate by magic bytes, NOT the URL extension — never write a non-image over the PSADT default.
        $iconExt = $null
        $b = $bytes
        if     ($b.Length -ge 4 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { $iconExt = '.png' }  # PNG  89 50 4E 47
        elseif ($b.Length -ge 4 -and $b[0] -eq 0x00 -and $b[1] -eq 0x00 -and $b[2] -eq 0x01 -and $b[3] -eq 0x00) { $iconExt = '.ico' }  # ICO  00 00 01 00
        elseif ($b.Length -ge 3 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF)                     { $iconExt = '.jpg' }  # JPEG FF D8 FF
        elseif ($b.Length -ge 2 -and $b[0] -eq 0x42 -and $b[1] -eq 0x4D)                                         { $iconExt = '.bmp' }  # BMP  42 4D
        elseif ($b.Length -ge 3 -and $b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46)                     { $iconExt = '.gif' }  # GIF  47 49 46

        if (-not $iconExt) {
            Write-Warning 'Downloaded app icon is not a recognised image (PNG/ICO/JPEG/BMP/GIF) — keeping default PSADT icon'
            return $false
        }

        # Keep the validated bytes as-is so the on-disk asset matches what winget served. (Intune's
        # largeIcon needs a GENUINE PNG, but that normalization happens once, at publish time, via
        # Get-Win32ToolkitLargeIconBytes → ConvertTo-Win32ToolkitPngBytes — not on every download here.)
        $iconDest = Join-Path $assetsPath 'AppIcon.png'
        [System.IO.File]::WriteAllBytes($iconDest, $bytes)

        # If the bytes are genuinely an ICO, also keep AppIcon.ico alongside it.
        if ($iconExt -eq '.ico') {
            $icoDest = Join-Path $assetsPath 'AppIcon.ico'
            [System.IO.File]::WriteAllBytes($icoDest, $bytes)
        }

        # Also copy to PSAppDeployToolkit\Assets so the toolkit's own default is replaced
        $psdtIconDest = Join-Path $psdtAssetsPath 'AppIcon.png'
        Copy-Item -Path $iconDest -Destination $psdtIconDest -Force

        # Record provenance so the capture-time icon reconcile (finalize) keeps this winget icon over the
        # one extracted from the install run (the winget-primary precedence decision).
        Set-Win32ToolkitIconSource -ProjectPath $ProjectPath -Source 'winget'

        Write-Host "✓ App icon downloaded and applied to Assets\" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Could not download app icon: $($_.Exception.Message)"
        return $false
    }
}