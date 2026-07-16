function Get-InstallerFileInfo {
    [CmdletBinding()]
    param([string]$FilesPath)
    
    $installerInfo = @{
        FileName = $null
        Type = $null
        FullPath = $null
    }
    
    # Check for MSI files first (Zero-Config MSI priority)
    $msiFiles = @(Get-ChildItem -Path $FilesPath -Filter "*.msi" -File)
    if ($msiFiles) {
        # There is NO content inspection here — with several candidates we simply take the first BY NAME. Say so
        # out loud: the file chosen here becomes AppConfig.Installer.FileName, i.e. the binary the generated
        # deploy script runs on every targeted device. Silently guessing is how you ship the wrong installer.
        if ($msiFiles.Count -gt 1) {
            Write-Warning "Files\ contains $($msiFiles.Count) .msi files ($(($msiFiles | ForEach-Object Name) -join ', ')) — using '$($msiFiles[0].Name)' as the installer (first by name; nothing here can tell which is the real one). If that is wrong, remove the extra .msi from Files\."
        }
        $installerInfo.FileName = $msiFiles[0].Name
        $installerInfo.Type = 'msi'
        $installerInfo.FullPath = $msiFiles[0].FullName
        return $installerInfo
    }
    
    # Check for EXE files.
    # Exclude only PSADT'S OWN binaries. There used to be a '*Setup*' exclusion here, which silently
    # discarded the installer for any app whose EXE is called setup.exe / acme-setup.exe / VLCSetup.exe —
    # i.e. the single most common name an installer has. Such a project failed outright with
    # "No installer (msi/exe/msix/appx) detected", and a manual app could not be packaged at all.
    $exeFiles = @(Get-ChildItem -Path $FilesPath -Filter "*.exe" -File | Where-Object {
        $_.Name -notlike "*Invoke-AppDeployToolkit*" -and
        $_.Name -notlike "*ServiceUI*"
    })
    if ($exeFiles) {
        # Same ambiguity as MSI above — first BY NAME, no content inspection. Rename-InstallerFile now refuses
        # to collapse two same-extension files (it used to delete one), so this is where a genuinely ambiguous
        # Files\ folder surfaces. Name every candidate rather than quietly picking one.
        if ($exeFiles.Count -gt 1) {
            Write-Warning "Files\ contains $($exeFiles.Count) .exe files ($(($exeFiles | ForEach-Object Name) -join ', ')) — using '$($exeFiles[0].Name)' as the installer (first by name; nothing here can tell which is the real one). If that is wrong, remove the extra .exe from Files\."
        }
        # Visibility: an EXE outranks package files by design (detection order), but a vendor bundle
        # with App.msix + helper.exe would silently get the EXE flow (no identity uninstall, possibly
        # "hard app") — name the ignored package so the operator can remove the stray EXE if the
        # package is the real installer.
        $shadowed = @(Get-ChildItem -Path $FilesPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in (Get-Win32ToolkitInstallerExtension -PackagesOnly) })
        if ($shadowed.Count -gt 0) {
            Write-Warning "Files\ contains both an EXE and a package file ($(($shadowed | ForEach-Object Name) -join ', ')) — using the EXE '$($exeFiles[0].Name)' as the installer. If the MSIX/APPX is the real installer, remove the stray EXE from Files\."
        }
        $installerInfo.FileName = $exeFiles[0].Name
        $installerInfo.Type = 'exe'
        $installerInfo.FullPath = $exeFiles[0].FullName
        return $installerInfo
    }
    
    # Check for Appx-family packages: .msix/.appx AND their bundles. A bundle installs and uninstalls
    # exactly like a plain package (Add-AppxProvisionedPackage takes a bundle path; removal is by the
    # same Name), so it reports the SAME Type — 'msix' for .msix/.msixbundle, 'appx' for .appx/.appxbundle.
    # Type is install semantics; bundle-ness is content-detected later by Get-Win32ToolkitMsixIdentity.
    # Families derived from the single extension->Type owner (Get-Win32ToolkitInstallerType), so this
    # and Download-OldVersionInstaller can never disagree about what a '.msixbundle' is.
    foreach ($family in @(
        @{ Type = 'msix'; Extensions = @((Get-Win32ToolkitInstallerExtension -PackagesOnly) | Where-Object { (Get-Win32ToolkitInstallerType -Extension $_) -eq 'msix' }) }
        @{ Type = 'appx'; Extensions = @((Get-Win32ToolkitInstallerExtension -PackagesOnly) | Where-Object { (Get-Win32ToolkitInstallerType -Extension $_) -eq 'appx' }) }
    )) {
        $pkgFiles = @(Get-ChildItem -Path $FilesPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in $family.Extensions } | Sort-Object Name)
        if ($pkgFiles.Count -eq 0) { continue }

        # Same first-BY-NAME ambiguity the .msi/.exe branches call out — and it bites harder here:
        # `winget download` fetches an app's framework dependencies (VCLibs, WinUI, .NET Native) into
        # Files\ alongside the app, so a dependency package can sort ahead of the real installer and
        # silently BECOME the installer. Name every candidate rather than quietly picking one.
        if ($pkgFiles.Count -gt 1) {
            Write-Warning "Files\ contains $($pkgFiles.Count) $($family.Type) package files ($(($pkgFiles | ForEach-Object Name) -join ', ')) — using '$($pkgFiles[0].Name)' as the installer (first by name; nothing here can tell which is the real one). Framework dependencies downloaded next to the app look exactly like this — if '$($pkgFiles[0].Name)' is not the app, remove the extra package(s) from Files\."
        }

        $installerInfo.FileName = $pkgFiles[0].Name
        $installerInfo.Type     = $family.Type
        $installerInfo.FullPath = $pkgFiles[0].FullName
        return $installerInfo
    }

    return $installerInfo
}