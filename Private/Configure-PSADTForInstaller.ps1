function Configure-PSADTForInstaller {
    <#
    .SYNOPSIS
        Configures a scaffolded PSADT v4 project for its installer (data-driven).
    .DESCRIPTION
        Writes the App and Installer sections of SupportFiles\AppConfig.json (values are stored as
        DATA via ConvertTo-Json, never interpolated into generated code) and patches
        Invoke-AppDeployToolkit.ps1 with fixed, value-free routines that read that data at runtime
        (see Set-PSADTDataDrivenScript). MSI installers keep an empty App.Name so PSADT Zero-Config
        MSI still applies. Org-template branding is applied afterwards, unchanged.

        See knowledge-base/designs/data-driven-generation.md.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (contains Invoke-AppDeployToolkit.ps1 and Files\).
    .PARAMETER AppInfo
        App metadata resolved from winget (used as a fallback for Name/Version).
    .PARAMETER Architecture
        Target architecture string (x64/x86/arm64).
    #>
    [CmdletBinding()]
    param(
        [string]$ProjectPath,
        [PSCustomObject]$AppInfo,
        [string]$Architecture
    )

    try {
        $filesPath  = Join-Path $ProjectPath 'Files'
        $scriptPath = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'

        if (-not (Test-Path $scriptPath)) {
            Write-Warning "PSADT script not found: $scriptPath"
            return $false
        }

        # Detect installer type
        $fileInfo = Get-InstallerFileInfo -FilesPath $filesPath
        if (-not $fileInfo.FileName) {
            Write-Warning 'No installer files detected in Files folder'
            return $false
        }
        Write-Host "Detected installer: $($fileInfo.FileName) ($($fileInfo.Type.ToUpper()))" -ForegroundColor Green

        # Winget manifest metadata (may be absent)
        $yamlInfo = Get-YAMLInstallerInfo -FilesPath $filesPath

        # ---- Resolve values (kept as DATA — never emitted as code) ----
        $isMsi   = ($fileInfo.Type -eq 'msi')
        $vendor  = if ($yamlInfo.Publisher) { $yamlInfo.Publisher } else { '' }
        $version = if ($yamlInfo.PackageVersion) { $yamlInfo.PackageVersion } elseif ($AppInfo.Version) { $AppInfo.Version } else { '' }
        # Empty AppName for MSI => Zero-Config MSI stays enabled.
        $name    = if ($isMsi) { '' } elseif ($yamlInfo.PackageName) { $yamlInfo.PackageName } else { $AppInfo.Name }
        # msix/appx never take silent switches (installed via Add-AppxPackage/provisioning) — storing
        # YAML args for them would be dead, confusing data.
        $silent  = if ($isMsi -or $fileInfo.Type -in @('msix', 'appx')) { '' }
                   elseif ($yamlInfo.SilentArgs) { $yamlInfo.SilentArgs }
                   else { '/S' }
        # DisplayName is the real product name — always populated (incl. MSI, where App.Name is empty for
        # Zero-Config). Drives the install tattoo + Intune detection key so both cover MSI.
        $display = if ($yamlInfo.PackageName) { $yamlInfo.PackageName } elseif ($AppInfo.Name) { $AppInfo.Name } else { '' }

        # ---- Write App + Installer sections into AppConfig.json (merge-preserving) ----
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $cfg | Add-Member -NotePropertyName App -NotePropertyValue ([pscustomobject]@{
            Vendor         = $vendor
            Name           = $name
            DisplayName    = $display
            Version        = $version
            Arch           = $Architecture
            ScriptAuthor   = if ($script:OrgTemplate -and $script:OrgTemplate.AppScriptAuthor) { $script:OrgTemplate.AppScriptAuthor } else { '' }
            ScriptDate     = (Get-Date -Format 'yyyy-MM-dd')
            Description    = if ($yamlInfo -and $yamlInfo.Description)    { $yamlInfo.Description }    else { '' }
            InformationUrl = if ($yamlInfo -and $yamlInfo.InformationUrl) { $yamlInfo.InformationUrl } else { '' }
        }) -Force
        $cfg | Add-Member -NotePropertyName Installer -NotePropertyValue ([pscustomobject]@{
            Type       = $fileInfo.Type
            FileName   = $fileInfo.FileName
            SilentArgs = $silent
        }) -Force
        if (-not ($cfg.PSObject.Properties.Name -contains 'ProcessesToClose')) {
            $cfg | Add-Member -NotePropertyName ProcessesToClose -NotePropertyValue @() -Force
        }
        Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg | Out-Null
        Write-Host '✓ Wrote SupportFiles\AppConfig.json (App + Installer)' -ForegroundColor Green

        # MSIX/APPX: write the identity-driven Uninstall section NOW (host-manifest-driven — it needs
        # nothing from the sandbox capture, so the uninstall works even if the capture times out).
        if ($fileInfo.Type -in @('msix', 'appx')) {
            if (-not (Update-PSADTMsixUninstallLogic -ProjectPath $ProjectPath)) {
                Write-Warning 'MSIX uninstall data could not be written — the package would have no working uninstall.'
            }
        }

        # ---- Patch the deploy script to be data-driven (fixed, value-free) ----
        if (Set-PSADTDataDrivenScript -ScriptPath $scriptPath) {
            Write-Host '✓ Deploy script patched to data-driven' -ForegroundColor Green
        } else {
            Write-Warning 'Data-driven patching of the deploy script did not complete cleanly'
        }

        # ---- Org template branding and dialog settings (unchanged) ----
        if ($script:OrgTemplate) {
            Write-Host 'Applying org template...' -ForegroundColor Cyan
            Apply-OrgTemplate -ProjectPath $ProjectPath -Template $script:OrgTemplate | Out-Null
        }

        Write-Host '✓ PSADT project configured (data-driven)!' -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to configure PSADT: $($_.Exception.Message)"
        return $false
    }
}
