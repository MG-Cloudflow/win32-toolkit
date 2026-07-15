function Get-Win32DetectionRules {
    [CmdletBinding()]
    [OutputType([object[]])]
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
    # DisplayName is the tattoo/detection name (populated even for MSI Zero-Config, where Name is empty);
    # fall back to Name for projects generated before DisplayName existed.
    $detName = if ($app) { if ($app.PSObject.Properties['DisplayName'] -and $app.DisplayName) { $app.DisplayName } else { $app.Name } } else { $null }
    if ($app -and $app.ScriptAuthor -and $app.Vendor -and $detName -and $app.Version) {
        # Only emit the tattoo rule if the deploy script actually writes the tattoo — otherwise Intune
        # would detect on a key the device never creates. Projects generated before the tattoo (no
        # tattoo block) fall through to the capture-based rules below.
        $deployScript = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        $hasTattoo = (Test-Path -LiteralPath $deployScript) -and
                     ((Get-Content -LiteralPath $deployScript -Raw) -match [regex]::Escape('win32-toolkit install tattoo - records'))
        if ($hasTattoo) {
            $tattooKey = "HKEY_LOCAL_MACHINE\SOFTWARE\$($app.ScriptAuthor)\$($app.Vendor)\$detName"
            Write-Verbose "  Detection rule (Registry version): $tattooKey\Version = $($app.Version)"
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
        Write-Warning '  Tattoo values are present but the deploy script has no install tattoo — regenerate this project to enable version detection. Falling back to capture-based rules.'
    }
    elseif ($app) {
        $missing = @()
        if (-not $app.ScriptAuthor) { $missing += 'App.ScriptAuthor (regenerate with an org template)' }
        if (-not $app.Vendor)       { $missing += 'App.Vendor (winget Publisher / manual -Publisher)' }
        if (-not $detName)          { $missing += 'App.DisplayName/Name (regenerate to populate)' }
        if (-not $app.Version)      { $missing += 'App.Version' }
        if ($missing.Count) {
            Write-Warning "  Tattoo/version detection unavailable — missing $($missing -join ', '). Using capture-based detection."
        }
    }

    # ── Capture-based fallback (MSI Zero-Config / apps without a tattoo) ────────────
    # Newest capture wins (shared selector) — the old first-in-name-order pick could build the
    # detection rule from a STALE capture of a previous version.
    $jsonFile = Get-LatestInstallationCapture -ProjectPath $ProjectPath
    if (-not $jsonFile) {
        Write-Warning '  No InstallationChanges_*.json capture found — no detection rules generated.'
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

            Write-Verbose "  Detection rule (Registry): $keyPath"
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

    # Choose the best single MACHINE-WIDE file candidate. An app under C:\Tools, C:\ProgramData, D:\Apps,
    # etc. is a valid detection target — the old hard filter to '^C:\Program Files' returned @() for those,
    # leaving Intune with NO detection rule. Rank so Program Files (the most stable location) wins when
    # present, then any other machine-wide absolute path, dropping obvious capture noise.
    #
    # Per-user profile paths are deliberately EXCLUDED (ranked unusable): Intune evaluates detection as
    # SYSTEM on the device, which cannot see another user's profile, and the capture host's account name
    # (e.g. the Windows Sandbox 'WDAGUtilityAccount') is baked into the literal captured path and won't exist
    # on the target. A per-user file rule can therefore NEVER match — worse than no rule, because it makes
    # Intune reinstall the app on every evaluation cycle. For a genuinely per-user app we return @() and the
    # operator adds a detection rule by hand, exactly as before this broadening.
    $rankPath = {
        param($p)
        if ($p -match '^[A-Za-z]:\\Users\\')                 { return 99 } # per-user profile — SYSTEM can't see it
        if ($p -match '^[A-Za-z]:\\Program Files \(x86\)\\') { return 0 }
        if ($p -match '^[A-Za-z]:\\Program Files\\')         { return 1 }
        if ($p -match '^[A-Za-z]:\\')                        { return 2 }  # any other machine-wide absolute path
        if ($p -match '^\\\\')                               { return 3 }  # UNC
        return 99                                                          # relative / unusable
    }
    $noise = '\\(Temp|tmp|Windows\\Temp|Windows\\Installer|\$Recycle\.Bin|INetCache|WinSxS)\\|\\Temp\\'
    $candidate = $filePaths |
        Where-Object { $_ } |
        Where-Object { (& $rankPath $_) -lt 99 } |          # must be an absolute path
        Where-Object { $_ -notmatch $noise } |              # drop temp / installer scratch
        Sort-Object -Property @{ Expression = { & $rankPath $_ } }, @{ Expression = { $_.Length } } |
        Select-Object -First 1

    if ($candidate) {
        $folder   = Split-Path $candidate -Parent
        $fileName = Split-Path $candidate -Leaf
        Write-Verbose "  Detection rule (File): $candidate"
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

    Write-Warning '  No suitable detection rule candidates found.'
    return @()
}
