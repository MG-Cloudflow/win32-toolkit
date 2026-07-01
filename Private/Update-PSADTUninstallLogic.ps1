function Update-PSADTUninstallLogic {
    <#
    .SYNOPSIS
        Writes the Uninstall section of SupportFiles\AppConfig.json from sandbox capture data.
    .DESCRIPTION
        Parses the InstallationChanges_*.json produced by the documentation sandbox and records the
        uninstall inputs (MSI product codes, registry uninstall strings split into exe/msi
        uninstallers, and install-folder cleanup paths) as DATA in AppConfig.json. The static,
        data-driven deploy script consumes these at runtime — no PowerShell is generated here, so
        there is no injection surface and the operation is idempotent (re-running just overwrites the
        Uninstall section; there is no marker to consume).

        Product codes are validated as strict GUIDs (Test-Win32ToolkitProductCode). Only EXE-based
        projects call this; MSI stays on PSADT Zero-Config MSI.

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

        $appName      = 'Unknown App'
        $productCodes = @()
        $uninstallers = @()
        $cleanupPaths = @()

        if ($data.NewRegistryKeys) {
            foreach ($regKey in $data.NewRegistryKeys) {
                if ($regKey.Path -notlike '*Uninstall*') { continue }

                if ($regKey.Values) {
                    if ($regKey.Values.DisplayName) { $appName = $regKey.Values.DisplayName }

                    # Prefer QuietUninstallString, then UninstallString (exe), then msiexec string.
                    $selected = $null
                    if ($regKey.Values.QuietUninstallString -and $regKey.Values.QuietUninstallString -like '*.exe*') {
                        $selected = $regKey.Values.QuietUninstallString
                    }
                    elseif ($regKey.Values.UninstallString -and $regKey.Values.UninstallString -like '*.exe*') {
                        $selected = $regKey.Values.UninstallString
                    }
                    elseif ($regKey.Values.UninstallString -and $regKey.Values.UninstallString -like '*msiexec*') {
                        $selected = $regKey.Values.UninstallString
                    }

                    if ($selected) {
                        if ($selected -like '*msiexec*') {
                            if ($selected -match '\{[A-F0-9-]{36}\}' -and (Test-Win32ToolkitProductCode $matches[0])) {
                                $uninstallers += [pscustomobject]@{ Type = 'msi'; ProductCode = $matches[0]; Path = $null; Args = $null }
                            }
                        }
                        elseif ($selected -like '*.exe*') {
                            $exePath = ''; $exeParams = ''
                            if ($selected -match '"([^"]*\.exe)"(.*)')      { $exePath = $matches[1]; $exeParams = $matches[2].Trim() }
                            elseif ($selected -match '([^\s]*\.exe)(.*)')   { $exePath = $matches[1]; $exeParams = $matches[2].Trim() }
                            else                                            { $exePath = $selected }
                            $uninstallers += [pscustomobject]@{ Type = 'exe'; ProductCode = $null; Path = $exePath; Args = $exeParams }
                        }
                    }
                }

                # Product code from the Uninstall key path itself (strict GUID only).
                if ($regKey.Path -match '\{[A-F0-9-]{36}\}') {
                    $pc = [regex]::Match($regKey.Path, '\{[A-F0-9-]{36}\}').Value
                    if ((Test-Win32ToolkitProductCode $pc) -and $pc -notin $productCodes) {
                        $productCodes += $pc
                    }
                }
            }
        }

        # Install-folder cleanup candidates (avoid the shared roots).
        if ($data.NewFiles) {
            foreach ($file in $data.NewFiles) {
                if ($file.Path -like '*Program Files*') {
                    $dir = Split-Path $file.Path -Parent
                    if ($dir -notin $cleanupPaths -and
                        $dir -notlike '*Program Files' -and $dir -notlike '*ProgramData' -and
                        $dir -ne 'C:\Program Files' -and $dir -ne 'C:\ProgramData') {
                        $cleanupPaths += $dir
                    }
                }
            }
        }

        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $cfg | Add-Member -NotePropertyName Uninstall -NotePropertyValue ([pscustomobject]@{
            AppName      = $appName
            ProductCodes = $productCodes
            Uninstallers = $uninstallers
            CleanupPaths = $cleanupPaths
        }) -Force
        Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg | Out-Null

        Write-Host "✓ Uninstall data written for '$appName' (product codes: $($productCodes.Count), uninstallers: $($uninstallers.Count), cleanup paths: $($cleanupPaths.Count))" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to write uninstall data: $($_.Exception.Message)"
        return $false
    }
}
