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
            Where-Object { $_.Extension -in '.msix', '.appx' })
        if ($shadowed.Count -gt 0) {
            Write-Warning "Files\ contains both an EXE and a package file ($(($shadowed | ForEach-Object Name) -join ', ')) — using the EXE '$($exeFiles[0].Name)' as the installer. If the MSIX/APPX is the real installer, remove the stray EXE from Files\."
        }
        $installerInfo.FileName = $exeFiles[0].Name
        $installerInfo.Type = 'exe'
        $installerInfo.FullPath = $exeFiles[0].FullName
        return $installerInfo
    }
    
    # Check for MSIX/APPX files
    $msixFiles = Get-ChildItem -Path $FilesPath -Filter "*.msix" -File
    if ($msixFiles) {
        $installerInfo.FileName = $msixFiles[0].Name
        $installerInfo.Type = 'msix'
        $installerInfo.FullPath = $msixFiles[0].FullName
        return $installerInfo
    }
    
    $appxFiles = Get-ChildItem -Path $FilesPath -Filter "*.appx" -File
    if ($appxFiles) {
        $installerInfo.FileName = $appxFiles[0].Name
        $installerInfo.Type = 'appx'
        $installerInfo.FullPath = $appxFiles[0].FullName
        return $installerInfo
    }

    # Nothing supported matched. If the folder holds ONLY a bundle, say exactly that: bundles are not
    # supported (tracked in knowledge-base/TODO.md), and the caller's generic "No installer
    # (msi/exe/msix/appx) detected" would send the operator hunting for a missing file that is right there.
    $bundleFiles = @(Get-ChildItem -Path $FilesPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.msixbundle', '.appxbundle' })
    if ($bundleFiles.Count -gt 0) {
        Write-Error "Files\ contains only bundle package(s) ($(($bundleFiles | ForEach-Object Name) -join ', ')) — .msixbundle/.appxbundle bundle packages are not supported (tracked in knowledge-base/TODO.md). Supply a single .msi/.exe/.msix/.appx installer instead."
    }

    return $installerInfo
}