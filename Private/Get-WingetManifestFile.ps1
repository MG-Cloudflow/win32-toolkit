function Get-WingetManifestFile {
<#
.SYNOPSIS
    Picks the RIGHT winget YAML manifest out of a folder that holds several of them.
.DESCRIPTION
    `winget download` writes a manifest SET next to the installer, e.g.

        Publisher.App.installer.yaml      installer data: Installers:, InstallerType, Architecture,
                                          ProductCode, InstallerSwitches/Silent, Scope, InstallerLocale
        Publisher.App.locale.en-US.yaml   display strings: PackageName, Publisher, ShortDescription,
                                          PackageUrl, PublisherUrl
        Publisher.App.yaml                version manifest: PackageIdentifier, PackageVersion

    Callers used to do `Get-ChildItem -Filter '*.yaml' | Select-Object -First 1`, i.e. take whatever
    sorted FIRST ALPHABETICALLY — which is usually the *.installer.yaml only by luck and, for the very
    common `Vendor.App.locale.en-US.yaml` layout, is frequently the LOCALE manifest, which carries none
    of the installer data. This helper makes the choice explicit and deterministic so the three callers
    (Get-YAMLInstallerInfo, Get-WingetIdFromProject, Download-OldVersionInstaller) cannot drift apart.

    Read whatever this returns with `-Encoding UTF8` — winget manifests are UTF-8 and the default
    Get-Content encoding of Windows PowerShell mangles non-ASCII publisher/app names.
.PARAMETER Path
    Folder holding the manifest set (a project's Files\ folder, or a winget download directory).
.PARAMETER Kind
    Which manifest the caller actually wants:
      Installer  the *.installer.yaml   (default — installer data lives there and nowhere else)
      Locale     the *.locale*.yaml     (display strings)
      Version    the version manifest   (neither .installer. nor .locale.)
      Any        no preference; installer > version > locale
    A folder may legitimately hold only one manifest (hand-made projects, older captures), so every
    Kind FALLS BACK to the other manifests rather than returning nothing.
.PARAMETER All
    Return every manifest, ordered best-first for the requested Kind, instead of just the best one.
    Lets a caller keep looking for a key that appears in more than one manifest.
.OUTPUTS
    System.IO.FileInfo (or an array of them with -All). $null / empty when the folder holds no *.yaml.
#>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Installer', 'Locale', 'Version', 'Any')]
        [string]$Kind = 'Installer',

        [Parameter(Mandatory = $false)]
        [switch]$All
    )

    # Nothing to pick from: $null (or an EMPTY ARRAY with -All, so callers can foreach it safely).
    $none = if ($All) { @() } else { $null }

    if (-not (Test-Path -LiteralPath $Path)) { return $none }

    # Sort by name so the pick is stable when a set holds several files of the same kind
    # (e.g. locale.en-US + locale.fr-FR).
    $yaml = @(
        Get-ChildItem -LiteralPath $Path -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name
    )
    if ($yaml.Count -eq 0) { return $none }

    $installer = @($yaml | Where-Object { $_.Name -like '*.installer.yaml' })
    $locale    = @($yaml | Where-Object { $_.Name -like '*.locale*.yaml' })
    $version   = @($yaml | Where-Object { $_.Name -notlike '*.installer.yaml' -and $_.Name -notlike '*.locale*.yaml' })

    $ordered = switch ($Kind) {
        'Installer' { $installer + $version + $locale }
        'Locale'    { $locale    + $version + $installer }
        'Version'   { $version   + $installer + $locale }
        default     { $installer + $version + $locale }
    }

    if ($All) { return $ordered }
    return ($ordered | Select-Object -First 1)
}
