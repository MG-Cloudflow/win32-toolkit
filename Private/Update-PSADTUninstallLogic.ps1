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

        The app's own uninstall entries are recorded as Uninstall.PrimaryKeys (key name and registry view,
        from its primary key(s) only, machine-wide entries only: a per-user entry is never recorded); the
        install/uninstall test checks they are gone.

        The uninstallers of the app's own uninstall entry (its primary key(s)) are written first, so a
        co-installed product's uninstaller can no longer be the one that runs first; Uninstall.AppName is
        the primary entry's DisplayName. Every uninstaller carries Kind: the installer technology
        ('nullsoft' or 'inno': the winget manifest's InstallerType, else the installer file's signature,
        Get-Win32ToolkitInstallerTechnology) for an EXE uninstaller of a primary key whose uninstall entry
        agrees with it (an Inno Setup entry for 'inno'; no Inno Setup or Windows Installer entry and no
        unins###.exe uninstaller for 'nullsoft'), else ''. An EXE uninstaller with no switch gets the
        technology's silent switch; a 'nullsoft' one always carries '/S'. Catalog constants only - no text
        from the capture beyond the uninstaller's own path and arguments.

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
        $primaryName  = ''
        $productCodes = @()
        $primaryUninstallers = @()
        $otherUninstallers   = @()
        $cleanupPaths = @()

        # An EXE uninstaller whose UninstallString carries no switch (Firefox: '"...\uninstall\helper.exe"',
        # no QuietUninstallString) ran WITH its UI as SYSTEM: helper.exe returned 0 at once and the cleanup
        # deleted the folder under it (test campaign 2026-10-21, S12-F2). It gets the silent switch of the
        # package's installer technology - catalog constants only, never text from the capture.
        # The technology: the winget manifest's InstallerType when it names one; for a manual app or a winget
        # 'exe' label, the installer file's own signature (B2 #1).
        $cfg     = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $srcType = if ($cfg.Source) { ([string]$cfg.Source.InstallerType).Trim().ToLowerInvariant() } else { '' }
        $tech     = ''
        $techFrom = 'none'
        if ($srcType -in @('nullsoft', 'inno')) {
            $tech = $srcType
            $techFrom = 'winget manifest'
        }
        elseif ($srcType -in @('', 'exe') -and $cfg.Installer -and [string]$cfg.Installer.Type -eq 'exe' -and -not [string]::IsNullOrWhiteSpace([string]$cfg.Installer.FileName)) {
            $tech = Get-Win32ToolkitInstallerTechnology -Path (Join-Path (Join-Path $ProjectPath 'Files') ([System.IO.Path]::GetFileName([string]$cfg.Installer.FileName)))
            if ($tech) { $techFrom = 'installer file signature' }
        }
        $silentByTech = @{ nullsoft = '/S'; inno = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        $noSwitch = [System.Collections.Generic.List[string]]::new()
        $sanitize = { param([string]$Text) $Text -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?' }

        # The app's own install folders and primary uninstall key(s), from its own uninstall entry (V1, S18).
        $dn  = if ($cfg.App -and $cfg.App.DisplayName) { [string]$cfg.App.DisplayName } elseif ($cfg.App) { [string]$cfg.App.Name } else { '' }
        $ir  = Get-Win32ToolkitInstallRoot -Capture $data -ProjectPath $ProjectPath -DisplayName $dn
        # The HKLM Uninstall key pattern Get-Win32ToolkitInstallRoot selects primary keys from.
        $hklmUninstallKey = '^(HKEY_LOCAL_MACHINE|HKLM)\\SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$'

        if ($data.NewRegistryKeys) {
            foreach ($regKey in $data.NewRegistryKeys) {
                if ($regKey.Path -notlike '*Uninstall*') { continue }
                $keyPath = [string]$regKey.Path
                $keyLeaf = $keyPath.Substring($keyPath.LastIndexOf('\') + 1)
                $isPrimary = $keyPath -match $hklmUninstallKey -and $keyLeaf -in @($ir.PrimaryKeys)

                if ($regKey.Values) {
                    if ($regKey.Values.DisplayName) {
                        $appName = $regKey.Values.DisplayName
                        if ($isPrimary -and -not $primaryName) { $primaryName = $regKey.Values.DisplayName }
                    }

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
                        $uninstaller = $null
                        if ($selected -like '*msiexec*') {
                            if ($selected -match '\{[A-F0-9-]{36}\}' -and (Test-Win32ToolkitProductCode $matches[0])) {
                                $uninstaller = [pscustomobject]@{ Type = 'msi'; ProductCode = $matches[0]; Path = $null; Args = $null; Kind = '' }
                            }
                        }
                        elseif ($selected -like '*.exe*') {
                            $exePath = ''; $exeParams = ''
                            if ($selected -match '"([^"]*\.exe)"(.*)')      { $exePath = $matches[1]; $exeParams = $matches[2].Trim() }
                            elseif ($selected -match '([^\s]*\.exe)(.*)')   { $exePath = $matches[1]; $exeParams = $matches[2].Trim() }
                            else                                            { $exePath = $selected }
                            $exeLeaf = [System.IO.Path]::GetFileName($exePath)

                            # Kind: the INSTALLER's technology, kept for the app's own uninstaller only when its
                            # uninstall entry agrees (a wrapper whose entry belongs to an embedded Inno Setup,
                            # Windows Installer or other uninstaller must not get the wrong switches).
                            $kind = ''
                            $contradiction = ''
                            if ($isPrimary -and $tech) {
                                $values    = $regKey.Values
                                $innoEntry = $keyLeaf -like '*_is1' -or ($values -and $null -ne $values.PSObject.Properties['Inno Setup: App Path'])
                                $msiEntry  = $values -and [string]$values.WindowsInstaller -eq '1'
                                $innoLeaf  = $exeLeaf -match '^unins\d{3}\.exe$'
                                if ($tech -eq 'nullsoft') {
                                    if ($innoEntry)    { $contradiction = 'an Inno Setup entry' }
                                    elseif ($msiEntry) { $contradiction = 'a Windows Installer entry' }
                                    elseif ($innoLeaf) { $contradiction = 'an Inno Setup uninstaller name' }
                                }
                                elseif (-not $innoEntry) { $contradiction = 'not an Inno Setup entry' }
                                if ($contradiction) {
                                    Write-Verbose (& $sanitize "Uninstall: the installer technology '$tech' ($techFrom) does not match the app's uninstall entry '$keyLeaf' ($contradiction): its uninstaller gets no technology switch.")
                                }
                                else { $kind = $tech }
                            }

                            if (-not $fromQuiet -and [string]::IsNullOrWhiteSpace($exeParams)) {
                                if (-not $contradiction -and $silentByTech.ContainsKey($tech)) { $exeParams = $silentByTech[$tech] }
                                else { $noSwitch.Add($exeLeaf) }
                            }
                            # An NSIS uninstaller without '/S' shows its UI as SYSTEM (L5; the device enforces it too).
                            if ($kind -eq 'nullsoft' -and $exeParams -cnotmatch '(^|\s)/S(\s|$)') { $exeParams = ('/S ' + $exeParams).Trim() }
                            $uninstaller = [pscustomobject]@{ Type = 'exe'; ProductCode = $null; Path = $exePath; Args = $exeParams; Kind = $kind }
                        }
                        if ($uninstaller) {
                            if ($isPrimary) { $primaryUninstallers += $uninstaller } else { $otherUninstallers += $uninstaller }
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

        # I-3: the app's own uninstaller(s) first (capture order kept inside each list); I-4: its own name.
        $uninstallers = @($primaryUninstallers) + @($otherUninstallers)
        if ($primaryName) { $appName = $primaryName }

        if ($noSwitch.Count -gt 0) {
            $techText = if ($tech) { $tech } elseif ($srcType) { $srcType } else { 'unknown' }
            $msg = "Uninstaller(s) $(@($noSwitch) -join ', ') have no silent switch in the capture, and the installer technology ('$techText') has no known default: the uninstall would show its UI as SYSTEM. Set Uninstall.Uninstallers[].Args in SupportFiles\AppConfig.json."
            Write-Warning ($msg -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?')
        }
        $techShown = if ($tech) { $tech } else { 'unknown' }
        $primaryText = if (@($ir.PrimaryKeys).Count) { @($ir.PrimaryKeys) -join ', ' } else { 'none' }
        Write-Verbose (& $sanitize "Uninstall: installer technology '$techShown' ($techFrom); primary uninstall key(s): $primaryText.")

        # Install-folder cleanup paths (V1, S18): only folders the install created inside the app's own
        # install folders, which come from its own uninstall entry (a new folder alone never qualifies).
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

        # The app's own uninstall entries (key name + registry view): its primary key(s) only, never a co-installed
        # product's, and machine-wide (HKLM) only. The install/uninstall test checks that they are gone after the
        # uninstall (F13). A name that is not a plain key name, or another view, is not recorded.
        $uninstallKeyNameRule = '^[^\\/:*?"<>|\p{Cc}\p{Cf}\p{Zl}\p{Zp}]{1,255}\z'
        $primaryKeyData = @(foreach ($entry in @($ir.PrimaryKeyEntries | Where-Object { $_ })) {
                $keyName = [string]$entry.Name
                $keyView = [string]$entry.View
                if ($keyName -match $uninstallKeyNameRule -and $keyName -ne '.' -and $keyName -ne '..' -and $keyView -cin 'Registry64', 'Registry32') { [pscustomobject]@{ Name = $keyName; View = $keyView } }
                else { Write-Verbose (& $sanitize "Uninstall: the app's uninstall key '$keyName' is not a plain key name in Registry64 or Registry32; it is not recorded in Uninstall.PrimaryKeys.") }
            })

        $cfg | Add-Member -NotePropertyName Uninstall -NotePropertyValue ([pscustomobject]@{
            AppName      = $appName
            ProductCodes = $productCodes
            Uninstallers = $uninstallers
            CleanupPaths = $cleanupPaths
            InstallRoots = @($ir.Roots)
            PrimaryKeys  = $primaryKeyData
        }) -Force
        Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg | Out-Null

        $rootText = if (@($ir.Roots).Count) { @($ir.Roots) -join ', ' } else { 'none' }
        Write-Host "✓ Uninstall data written for '$appName' (product codes: $($productCodes.Count), uninstallers: $($uninstallers.Count), cleanup paths: $($cleanupPaths.Count), install roots: $rootText, technology: $techShown)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to write uninstall data: $($_.Exception.Message)"
        return $false
    }
}
