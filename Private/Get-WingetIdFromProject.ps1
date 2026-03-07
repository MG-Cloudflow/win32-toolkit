function Get-WingetIdFromProject {
<#
.SYNOPSIS
    Reads the Winget PackageIdentifier from the YAML manifest stored in a
    win32-toolkit project's Files directory.
#>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilesPath
    )

    $yamlFiles = Get-ChildItem -Path $FilesPath -Filter '*.yaml' -File
    if ($yamlFiles.Count -eq 0) {
        return $null
    }

    $content = Get-Content -Path $yamlFiles[0].FullName -Raw
    if ($content -match 'PackageIdentifier:\s*(.+)') {
        return $matches[1].Trim()
    }

    return $null
}
