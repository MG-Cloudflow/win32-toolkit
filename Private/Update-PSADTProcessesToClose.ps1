function Update-PSADTProcessesToClose {
    param(
        [string]$ProjectPath,
        [string]$JsonFilePath
    )

    try {
        $scriptPath = Join-Path $ProjectPath "Invoke-AppDeployToolkit.ps1"
        if (-not (Test-Path $scriptPath)) {
            Write-Warning "PSADT script not found: $scriptPath"
            return $false
        }

        $data = Get-Content -Path $JsonFilePath -Raw -Encoding UTF8 | ConvertFrom-Json

        $candidates  = [System.Collections.Generic.List[string]]::new()
        $excludePattern = 'uninstall|uninst|setup|install|update|patch|redist'

        # Get InstallLocation from Uninstall registry key (used as scope filter for fallback)
        $installLocation = $null
        foreach ($regKey in $data.NewRegistryKeys) {
            if ($regKey.Path -like '*Uninstall*' -and $regKey.Values -and $regKey.Values.InstallLocation) {
                $installLocation = $regKey.Values.InstallLocation.TrimEnd('\')
                break
            }
        }

        # Source 1 (preferred): App Paths registry keys — these are user-launchable executables
        foreach ($regKey in $data.NewRegistryKeys) {
            if ($regKey.Path -like '*App Paths*' -and $regKey.KeyName -like '*.exe') {
                $procName = [System.IO.Path]::GetFileNameWithoutExtension($regKey.KeyName)
                if ($procName -and $procName -notmatch $excludePattern -and (Test-Win32ToolkitProcessName $procName) -and $procName -notin $candidates) {
                    $candidates.Add($procName)
                }
            }
        }

        # Source 2 (fallback): DisplayIcon from Uninstall registry key
        if ($candidates.Count -eq 0) {
            foreach ($regKey in $data.NewRegistryKeys) {
                if ($regKey.Path -like '*Uninstall*' -and $regKey.Values -and $regKey.Values.DisplayIcon) {
                    $iconPath = $regKey.Values.DisplayIcon -replace ',\d+$', ''  # strip icon index
                    $procName = [System.IO.Path]::GetFileNameWithoutExtension($iconPath)
                    if ($procName -and $procName -notmatch $excludePattern -and (Test-Win32ToolkitProcessName $procName) -and $procName -notin $candidates) {
                        $candidates.Add($procName)
                    }
                    break
                }
            }
        }

        # Source 3 (fallback): EXE files under InstallLocation
        if ($candidates.Count -eq 0 -and $installLocation) {
            foreach ($file in $data.NewFiles) {
                if ($file.Type -eq 'File' -and
                    $file.Path -like '*.exe' -and
                    $file.Path.StartsWith($installLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
                    # Only files directly in InstallLocation, not subfolders
                    $fileDir = [System.IO.Path]::GetDirectoryName($file.Path)
                    if ($fileDir -ieq $installLocation) {
                        $procName = [System.IO.Path]::GetFileNameWithoutExtension($file.Path)
                        if ($procName -and $procName -notmatch $excludePattern -and (Test-Win32ToolkitProcessName $procName) -and $procName -notin $candidates) {
                            $candidates.Add($procName)
                        }
                    }
                }
            }
        }

        # Sort and build the replacement string. Names are validated above; escape as
        # well (defense-in-depth) since each is emitted into a single-quoted literal.
        $sorted = $candidates | Sort-Object
        $arrayContent = if ($sorted.Count -gt 0) {
            ($sorted | ForEach-Object { "'$(ConvertTo-PSSingleQuoted $_)'" }) -join ', '
        } else { '' }
        $replacement = "AppProcessesToClose = @($arrayContent)"

        # Regex-replace the existing AppProcessesToClose line (idempotent)
        $content = Get-Content -Path $scriptPath -Raw -Encoding UTF8
        $content = $content -replace 'AppProcessesToClose\s*=\s*@\([^)]*\)', $replacement
        Set-Content -Path $scriptPath -Value $content -Encoding UTF8

        if ($sorted.Count -gt 0) {
            Write-Host "✓ AppProcessesToClose set: @($arrayContent)" -ForegroundColor Green
        } else {
            Write-Host "AppProcessesToClose: no user-launchable processes detected, left as @()" -ForegroundColor DarkYellow
        }

        return $true
    }
    catch {
        Write-Warning "Failed to update AppProcessesToClose: $($_.Exception.Message)"
        return $false
    }
}