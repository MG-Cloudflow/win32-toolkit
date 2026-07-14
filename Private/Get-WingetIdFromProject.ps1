function Get-WingetIdFromProject {
<#
.SYNOPSIS
    Reads the Winget PackageIdentifier from the YAML manifest stored in a
    win32-toolkit project's Files directory.
.DESCRIPTION
    PackageIdentifier appears in EVERY manifest of a winget set, so this used to work by luck off the
    alphabetically-first file. It now asks for the version manifest (its owner) and, if that one somehow
    lacks the key, walks the remaining manifests in preference order rather than giving up. Manifests are
    read as UTF-8.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilesPath
    )

    $yamlFiles = @(Get-WingetManifestFile -Path $FilesPath -Kind Version -All)
    if ($yamlFiles.Count -eq 0) {
        return $null
    }

    foreach ($yamlFile in $yamlFiles) {
        $content = Get-Content -LiteralPath $yamlFile.FullName -Raw -Encoding UTF8
        if ($content -match 'PackageIdentifier:\s*(.+)') {
            return $matches[1].Trim()
        }
    }

    return $null
}
