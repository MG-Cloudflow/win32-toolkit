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

        Cleanup paths are only the top-most folders the install created inside the app's own install
        folders, taken from its own uninstall entry (Get-Win32ToolkitInstallRoot), and every one passes
        the allowlist (Test-Win32ToolkitCleanupPath): the uninstall deletes them recursively as SYSTEM.
        The install folders are stored next to them as Uninstall.InstallRoots.

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

        # An EXE uninstaller whose UninstallString carries no switch (Firefox: '"...\uninstall\helper.exe"',
        # no QuietUninstallString) ran WITH its UI as SYSTEM: helper.exe returned 0 at once and the cleanup
        # deleted the folder under it (test campaign 2026-10-21, S12-F2). It gets the silent switch of the
        # package's installer technology - catalog constants only, never text from the capture.
        $cfg  = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $tech = if ($cfg.Source) { ([string]$cfg.Source.InstallerType).Trim().ToLowerInvariant() } else { '' }
        $silentByTech = @{ nullsoft = '/S'; inno = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        $noSwitch = [System.Collections.Generic.List[string]]::new()

        if ($data.NewRegistryKeys) {
            foreach ($regKey in $data.NewRegistryKeys) {
                if ($regKey.Path -notlike '*Uninstall*') { continue }

                if ($regKey.Values) {
                    if ($regKey.Values.DisplayName) { $appName = $regKey.Values.DisplayName }

                    # Prefer QuietUninstallString, then UninstallString (exe), then msiexec string.
                    $selected = $null
                    $fromQuiet = $false
                    if ($regKey.Values.QuietUninstallString -and $regKey.Values.QuietUninstallString -like '*.exe*') {
                        $selected = $regKey.Values.QuietUninstallString
                        $fromQuiet = $true
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
                            if (-not $fromQuiet -and [string]::IsNullOrWhiteSpace($exeParams)) {
                                if ($silentByTech.ContainsKey($tech)) { $exeParams = $silentByTech[$tech] }
                                else { $noSwitch.Add([System.IO.Path]::GetFileName($exePath)) }
                            }
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

        if ($noSwitch.Count -gt 0) {
            $techText = if ($tech) { $tech } else { 'unknown' }
            $msg = "Uninstaller(s) $(@($noSwitch) -join ', ') have no silent switch in the capture, and the installer technology ('$techText') has no known default: the uninstall would show its UI as SYSTEM. Set Uninstall.Uninstallers[].Args in SupportFiles\AppConfig.json."
            Write-Warning ($msg -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?')
        }

        # Install-folder cleanup paths (V1, S18): only folders the install created inside the app's own
        # install folders, which come from its own uninstall entry (a new folder alone never qualifies).
        $dn  = if ($cfg.App -and $cfg.App.DisplayName) { [string]$cfg.App.DisplayName } elseif ($cfg.App) { [string]$cfg.App.Name } else { '' }
        $ir  = Get-Win32ToolkitInstallRoot -Capture $data -ProjectPath $ProjectPath -DisplayName $dn
        $keep = @($ir.CreatedDirectories | Where-Object {
                    (Test-Win32ToolkitCleanupPath -Path $_ -InstallRoot $ir.Roots -CreatedDirectory $ir.CreatedDirectories).Valid })
        # top-most only: drop any kept folder that lies below another kept folder
        $cleanupPaths = @($keep | Where-Object { $d = $_; -not ($keep | Where-Object { $_ -ne $d -and ($d + '\').StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }) } | Sort-Object)

        $rejectedText = @($ir.Rejected | ForEach-Object {
                $why = if (@($_.Reasons).Count) { ": $(@($_.Reasons) -join ', ')" } else { '' }
                "$($_.Candidate) ($($_.Origin)$why)"
            })
        $verboseText = "Cleanup paths: $(@($ir.CreatedDirectories).Count - $keep.Count) created folder(s) outside the app's install folders were not kept; rejected uninstall keys and install-folder candidates: $(if ($rejectedText.Count) { $rejectedText -join '; ' } else { 'none' })."
        Write-Verbose ($verboseText -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?')

        $cfg | Add-Member -NotePropertyName Uninstall -NotePropertyValue ([pscustomobject]@{
            AppName      = $appName
            ProductCodes = $productCodes
            Uninstallers = $uninstallers
            CleanupPaths = $cleanupPaths
            InstallRoots = @($ir.Roots)
        }) -Force
        Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg | Out-Null

        $rootText = if (@($ir.Roots).Count) { @($ir.Roots) -join ', ' } else { 'none' }
        Write-Host "✓ Uninstall data written for '$appName' (product codes: $($productCodes.Count), uninstallers: $($uninstallers.Count), cleanup paths: $($cleanupPaths.Count), install roots: $rootText)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to write uninstall data: $($_.Exception.Message)"
        return $false
    }
}
