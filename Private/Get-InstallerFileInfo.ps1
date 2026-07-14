function Get-InstallerFileInfo {
    [CmdletBinding()]
    param([string]$FilesPath)
    
    $installerInfo = @{
        FileName = $null
        Type = $null
        FullPath = $null
    }
    
    # Check for MSI files first (Zero-Config MSI priority)
    $msiFiles = Get-ChildItem -Path $FilesPath -Filter "*.msi" -File
    if ($msiFiles) {
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
    $exeFiles = Get-ChildItem -Path $FilesPath -Filter "*.exe" -File | Where-Object {
        $_.Name -notlike "*Invoke-AppDeployToolkit*" -and
        $_.Name -notlike "*ServiceUI*"
    }
    if ($exeFiles) {
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
    
    return $installerInfo
}