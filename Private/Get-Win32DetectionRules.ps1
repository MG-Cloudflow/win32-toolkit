function Get-Win32DetectionRules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )

    # ── Tattoo detection (preferred) ──────────────────────────────────────────────
    # The generated deploy script writes HKLM:\SOFTWARE\<Author>\<Vendor>\<Name>\Version at install
    # (see Set-PSADTDataDrivenScript). Detect on that value so Intune confirms the app is installed
    # AND at the correct version. This is independent of the sandbox capture, so it also covers hard
    # (manual-install) apps. The condition mirrors the deploy-script guard exactly, so the key path
    # here is identical to what the device writes.
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $app = if ($cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
    if ($app -and $app.ScriptAuthor -and $app.Vendor -and $app.Name -and $app.Version) {
        $tattooKey = "HKEY_LOCAL_MACHINE\SOFTWARE\$($app.ScriptAuthor)\$($app.Vendor)\$($app.Name)"
        Write-Host "  Detection rule (Registry version): $tattooKey\Version = $($app.Version)" -ForegroundColor Gray
        return @(
            [ordered]@{
                '@odata.type'          = '#microsoft.graph.win32LobAppRegistryDetection'
                'keyPath'              = $tattooKey
                'valueName'            = 'Version'
                'detectionType'        = 'version'
                'operator'             = 'equal'
                'detectionValue'       = "$($app.Version)"
                'check32BitOn64System' = $false
            }
        )
    }

    # ── Capture-based fallback (MSI Zero-Config / apps without a tattoo) ────────────
    $docPath = Join-Path $ProjectPath 'Documentation'
    if (-not (Test-Path $docPath)) {
        Write-Host '  No Documentation folder found — no detection rules generated.' -ForegroundColor Yellow
        return @()
    }

    $jsonFile = Get-ChildItem -Path $docPath -Filter 'InstallationChanges_*.json' -File |
        Select-Object -First 1
    if (-not $jsonFile) {
        Write-Host '  No InstallationChanges_*.json found — no detection rules generated.' -ForegroundColor Yellow
        return @()
    }

    try {
        $data = Get-Content $jsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to parse $($jsonFile.Name): $($_.Exception.Message)"
        return @()
    }

    # ── Registry detection (preferred) ────────────────────────────────────────────
    # Each NewRegistryKeys item has .Path and .Values properties
    $regKeys = @($data.NewRegistryKeys)
    if ($regKeys.Count -gt 0) {
        # Prefer Uninstall key — most reliable indicator of app presence
        $candidate = $regKeys | Where-Object { $_.Path -match 'Uninstall' } | Select-Object -First 1
        if (-not $candidate) {
            $candidate = $regKeys |
                Where-Object { $_.Path -match 'HKEY_LOCAL_MACHINE\\SOFTWARE' } |
                Select-Object -First 1
        }
        if (-not $candidate) {
            $candidate = $regKeys | Select-Object -First 1
        }

        if ($candidate) {
            # Normalize common registry path abbreviations to full form
            $keyPath = $candidate.Path
            $keyPath = $keyPath -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
            $keyPath = $keyPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
            $keyPath = $keyPath -replace '^HKCR\\', 'HKEY_CLASSES_ROOT\'

            Write-Host "  Detection rule (Registry): $keyPath" -ForegroundColor Gray
            return @(
                [ordered]@{
                    '@odata.type'          = '#microsoft.graph.win32LobAppRegistryDetection'
                    'keyPath'              = $keyPath
                    'valueName'            = $null
                    'detectionType'        = 'exists'
                    'check32BitOn64System' = $false
                    'operator'             = 'notConfigured'
                    'detectionValue'       = $null
                }
            )
        }
    }

    # ── File system fallback ───────────────────────────────────────────────────────
    $filePaths = @()
    if ($data.NewFiles)     { $filePaths += @($data.NewFiles) }
    if ($data.NewFilePaths) { $filePaths += @($data.NewFilePaths) }

    # Flatten to strings in case items are objects
    $filePaths = $filePaths | ForEach-Object {
        if ($_ -is [string]) { $_ } elseif ($_.Path) { $_.Path } else { $_.ToString() }
    }

    $candidate = $filePaths |
        Where-Object { $_ -match '^C:\\Program Files' } |
        Select-Object -First 1

    if ($candidate) {
        $folder   = Split-Path $candidate -Parent
        $fileName = Split-Path $candidate -Leaf
        Write-Host "  Detection rule (File): $candidate" -ForegroundColor Gray
        return @(
            [ordered]@{
                '@odata.type'          = '#microsoft.graph.win32LobAppFileSystemDetection'
                'path'                 = $folder
                'fileOrFolderName'     = $fileName
                'detectionType'        = 'exists'
                'check32BitOn64System' = $false
                'operator'             = 'notConfigured'
                'detectionValue'       = $null
            }
        )
    }

    Write-Host '  No suitable detection rule candidates found.' -ForegroundColor Yellow
    return @()
}
