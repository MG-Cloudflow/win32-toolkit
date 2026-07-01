function Get-YAMLInstallerInfo {
    param([string]$FilesPath)
    
    $yamlFiles = Get-ChildItem -Path $FilesPath -Filter "*.yaml" -File
    if ($yamlFiles.Count -eq 0) {
        return $null
    }
    
    try {
        $yamlContent = Get-Content $yamlFiles[0].FullName -Raw
        $installerInfo = @{
            PackageName = $null
            Publisher = $null
            PackageVersion = $null
            Architecture = $null
            SilentArgs = $null
            ProductCode = $null
            Scope = $null
            Description = $null
            InformationUrl = $null
        }
        
        # Parse basic package info
        if ($yamlContent -match 'PackageName:\s*(.+)') {
            $installerInfo.PackageName = $matches[1].Trim()
        }
        if ($yamlContent -match 'Publisher:\s*(.+)') {
            $installerInfo.Publisher = $matches[1].Trim()
        }
        if ($yamlContent -match 'PackageVersion:\s*(.+)') {
            $installerInfo.PackageVersion = $matches[1].Trim()
        }
        if ($yamlContent -match 'Architecture:\s*(.+)') {
            $installerInfo.Architecture = $matches[1].Trim()
        }
        if ($yamlContent -match 'ProductCode:\s*(.+)') {
            $installerInfo.ProductCode = $matches[1].Trim()
        }
        if ($yamlContent -match '(?m)^\s*Scope:\s*(.+)') {
            $installerInfo.Scope = $matches[1].Trim().ToLower()
        }
        
        # Parse installer switches (Silent: may appear after other keys under InstallerSwitches:)
        if ($yamlContent -match '(?s)InstallerSwitches:.*?\n\s+Silent:\s*([^\n]+)') {
            $installerInfo.SilentArgs = $matches[1].Trim()
        }

        # Description and information URL (used for the Intune app shell)
        if     ($yamlContent -match '(?m)^\s*ShortDescription:\s*(.+)') { $installerInfo.Description = $matches[1].Trim() }
        elseif ($yamlContent -match '(?m)^\s*Description:\s*(.+)')      { $installerInfo.Description = $matches[1].Trim() }
        if     ($yamlContent -match '(?m)^\s*PackageUrl:\s*(.+)')       { $installerInfo.InformationUrl = $matches[1].Trim() }
        elseif ($yamlContent -match '(?m)^\s*PublisherUrl:\s*(.+)')     { $installerInfo.InformationUrl = $matches[1].Trim() }

        return $installerInfo
    }
    catch {
        Write-Warning "Failed to parse YAML file: $($_.Exception.Message)"
        return $null
    }
}