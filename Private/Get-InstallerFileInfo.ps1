function Get-InstallerFileInfo {
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
    
    # Check for EXE files
    $exeFiles = Get-ChildItem -Path $FilesPath -Filter "*.exe" -File | Where-Object { 
        $_.Name -notlike "*Setup*" -and 
        $_.Name -notlike "*Invoke-AppDeployToolkit*" -and
        $_.Name -notlike "*ServiceUI*"
    }
    if ($exeFiles) {
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