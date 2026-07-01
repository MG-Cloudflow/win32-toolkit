function Update-PSADTProcessesToClose {
    <#
    .SYNOPSIS
        Writes the ProcessesToClose section of SupportFiles\AppConfig.json from sandbox capture data.
    .DESCRIPTION
        Detects user-launchable executables installed by the app (App Paths registry keys, then a
        DisplayIcon fallback, then EXEs directly under InstallLocation), validates each name
        (Test-Win32ToolkitProcessName), and records them as DATA in AppConfig.json. The data-driven
        deploy script reads them into AppProcessesToClose at runtime — no code is generated.

        See knowledge-base/designs/data-driven-generation.md.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder.
    .PARAMETER JsonFilePath
        Full path to the InstallationChanges_*.json capture file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [string]$JsonFilePath
    )

    try {
        $data = Get-Content -Path $JsonFilePath -Raw -Encoding UTF8 | ConvertFrom-Json

        $candidates     = [System.Collections.Generic.List[string]]::new()
        $excludePattern = 'uninstall|uninst|setup|install|update|patch|redist'

        # InstallLocation (used as scope filter for the file fallback).
        $installLocation = $null
        foreach ($regKey in $data.NewRegistryKeys) {
            if ($regKey.Path -like '*Uninstall*' -and $regKey.Values -and $regKey.Values.InstallLocation) {
                $installLocation = $regKey.Values.InstallLocation.TrimEnd('\')
                break
            }
        }

        # Source 1 (preferred): App Paths registry keys.
        foreach ($regKey in $data.NewRegistryKeys) {
            if ($regKey.Path -like '*App Paths*' -and $regKey.KeyName -like '*.exe') {
                $procName = [System.IO.Path]::GetFileNameWithoutExtension($regKey.KeyName)
                if ($procName -and $procName -notmatch $excludePattern -and (Test-Win32ToolkitProcessName $procName) -and $procName -notin $candidates) {
                    $candidates.Add($procName)
                }
            }
        }

        # Source 2 (fallback): DisplayIcon from the Uninstall key.
        if ($candidates.Count -eq 0) {
            foreach ($regKey in $data.NewRegistryKeys) {
                if ($regKey.Path -like '*Uninstall*' -and $regKey.Values -and $regKey.Values.DisplayIcon) {
                    $iconPath = $regKey.Values.DisplayIcon -replace ',\d+$', ''
                    $procName = [System.IO.Path]::GetFileNameWithoutExtension($iconPath)
                    if ($procName -and $procName -notmatch $excludePattern -and (Test-Win32ToolkitProcessName $procName) -and $procName -notin $candidates) {
                        $candidates.Add($procName)
                    }
                    break
                }
            }
        }

        # Source 3 (fallback): EXE files directly under InstallLocation.
        if ($candidates.Count -eq 0 -and $installLocation) {
            foreach ($file in $data.NewFiles) {
                if ($file.Type -eq 'File' -and
                    $file.Path -like '*.exe' -and
                    $file.Path.StartsWith($installLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
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

        $sorted = @($candidates | Sort-Object)

        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $cfg | Add-Member -NotePropertyName ProcessesToClose -NotePropertyValue $sorted -Force
        Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg | Out-Null

        if ($sorted.Count -gt 0) {
            Write-Host "✓ ProcessesToClose data written: $($sorted -join ', ')" -ForegroundColor Green
        } else {
            Write-Host 'ProcessesToClose: no user-launchable processes detected, wrote @()' -ForegroundColor DarkYellow
        }
        return $true
    }
    catch {
        Write-Warning "Failed to write ProcessesToClose data: $($_.Exception.Message)"
        return $false
    }
}
