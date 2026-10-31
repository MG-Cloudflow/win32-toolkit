function Get-YAMLInstallerInfo {
<#
.SYNOPSIS
    Parses a winget manifest SET into the installer/package facts the toolkit needs.
.DESCRIPTION
    A winget package ships SEVERAL manifests and they do NOT hold the same keys:

      *.installer.yaml   InstallerType, Architecture, ProductCode, Scope, InstallerLocale,
                         InstallerSwitches/Silent          <- the installer data, nowhere else
      *.locale*.yaml     PackageName, Publisher, ShortDescription, PackageUrl, PublisherUrl
      <id>.yaml          PackageIdentifier, PackageVersion

    This used to read `Get-ChildItem '*.yaml'`[0] — whatever sorted first alphabetically, typically the
    LOCALE manifest — and so returned $null for every installer field. Each field group is now read from
    the manifest that owns it (Get-WingetManifestFile), with a fall back to the other manifests so a
    folder holding a single hand-made manifest still parses exactly as before.

    Manifests are UTF-8: read with -Encoding UTF8 or non-ASCII publisher/app names get mangled.

    YAML quotes: winget manifests often quote installer facts (ProductCode: '{GUID}', PackageVersion: "5.1").
    One matching pair of '...' (with '' -> ') or "..." is removed from the installer facts and ids
    (PackageIdentifier, PackageVersion, Architecture, ProductCode, Scope, InstallerType, InstallerLocale,
    UpgradeBehavior), so a quoted GUID passes Test-Win32ToolkitProductCode. PackageName, Publisher,
    Description, the URLs and SilentArgs are returned exactly as written: they feed App.Vendor /
    App.DisplayName, i.e. the install tattoo key, which must not change for existing packages.

    The switches an old, sibling or dependency installer is RUN with do not come from here: Download-OldVersionInstaller
    reads Silent and Custom with ConvertFrom-Win32ToolkitWingetManifest (YAML scalars decoded, root switches merged as
    winget merges them), so there is one reader of a command line (installer-identity PR 3b).
.OUTPUTS
    Hashtable of the parsed fields, or $null when the folder holds no manifest / cannot be parsed.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$FilesPath)

    $installerFile = Get-WingetManifestFile -Path $FilesPath -Kind Installer
    if (-not $installerFile) {
        return $null
    }

    try {
        # Installer facts: ONLY from the installer manifest (a locale manifest has none of them, and
        # anything that looks like one there is not the installer's).
        $yamlContent = Get-Content -LiteralPath $installerFile.FullName -Raw -Encoding UTF8

        # Package/display facts: locale manifest first, then the version manifest, then the installer
        # manifest as a last resort (single-manifest folders). Concatenated in that preference order so
        # the existing regexes — unchanged — hit the owning manifest's value first.
        $metaContent = ''
        $seen        = @{}
        foreach ($f in @(
                (Get-WingetManifestFile -Path $FilesPath -Kind Locale),
                (Get-WingetManifestFile -Path $FilesPath -Kind Version),
                $installerFile)) {
            if ($f -and -not $seen.ContainsKey($f.FullName)) {
                $seen[$f.FullName] = $true
                $metaContent += (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) + "`n"
            }
        }

        $installerInfo = @{
            PackageIdentifier = $null
            PackageName = $null
            Publisher = $null
            PackageVersion = $null
            Architecture = $null
            SilentArgs = $null
            ProductCode = $null
            Scope = $null
            InstallerType = $null
            InstallerLocale = $null
            UpgradeBehavior = $null
            Description = $null
            InformationUrl = $null
        }

        # Removes ONE matching pair of YAML quotes from an installer fact or id: '...' (a doubled '' inside
        # becomes ') or "..." (no escape processing). Anything else is returned trimmed and unchanged.
        # Local on purpose (not a Private\ helper): suites that load this file selectively need no new line.
        $unquote = {
            param([string]$Value)
            $v = $Value.Trim()
            if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[-1] -eq "'") { return $v.Substring(1, $v.Length - 2).Replace("''", "'") }
            if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[-1] -eq '"') { return $v.Substring(1, $v.Length - 2) }
            return $v
        }

        # PackageIdentifier appears in EVERY manifest in the set (installer, version and locale), so either
        # source is valid — prefer the installer manifest, fall back to the metadata ones.
        if     ($yamlContent -match '(?m)^\s*PackageIdentifier:\s*(.+)') { $installerInfo.PackageIdentifier = & $unquote $matches[1] }
        elseif ($metaContent -match '(?m)^\s*PackageIdentifier:\s*(.+)') { $installerInfo.PackageIdentifier = & $unquote $matches[1] }

        # Parse basic package info
        if ($metaContent -match '(?m)^\s*PackageName:\s*(.+)') {
            $installerInfo.PackageName = $matches[1].Trim()
        }
        if ($metaContent -match '(?m)^\s*Publisher:\s*(.+)') {
            $installerInfo.Publisher = $matches[1].Trim()
        }
        if ($metaContent -match '(?m)^\s*PackageVersion:\s*(.+)') {
            $installerInfo.PackageVersion = & $unquote $matches[1]
        }
        # These live in the INSTALLER manifest, where they are frequently the first key of a YAML list
        # item under `Installers:` — i.e. `  - Architecture: x64`. The anchor must therefore allow an
        # optional list dash between the leading whitespace and the key, or `^\s*Architecture` never matches
        # the dashed form and the field comes back empty.
        if ($yamlContent -match '(?m)^\s*-?\s*Architecture:\s*(.+)') {
            $installerInfo.Architecture = & $unquote $matches[1]
        }
        if ($yamlContent -match '(?m)^\s*-?\s*ProductCode:\s*(.+)') {
            $installerInfo.ProductCode = & $unquote $matches[1]
        }
        if ($yamlContent -match '(?m)^\s*-?\s*Scope:\s*(.+)') {
            $installerInfo.Scope = (& $unquote $matches[1]).ToLowerInvariant()
        }
        if ($yamlContent -match '(?m)^\s*-?\s*InstallerType:\s*(\S+)') {
            $installerInfo.InstallerType = (& $unquote $matches[1]).ToLowerInvariant()
        }
        if ($yamlContent -match '(?m)^\s*-?\s*InstallerLocale:\s*(\S+)') {
            $installerInfo.InstallerLocale = & $unquote $matches[1]
        }
        if ($yamlContent -match '(?m)^\s*-?\s*UpgradeBehavior:\s*(\S+)') {
            $installerInfo.UpgradeBehavior = & $unquote $matches[1]
        }

        # Parse installer switches (Silent: may appear after other keys under InstallerSwitches:)
        if ($yamlContent -match '(?s)InstallerSwitches:.*?\n\s+Silent:\s*([^\n]+)') {
            $installerInfo.SilentArgs = $matches[1].Trim()
        }

        # Description and information URL (used for the Intune app shell)
        if     ($metaContent -match '(?m)^\s*ShortDescription:\s*(.+)') { $installerInfo.Description = $matches[1].Trim() }
        elseif ($metaContent -match '(?m)^\s*Description:\s*(.+)')      { $installerInfo.Description = $matches[1].Trim() }
        if     ($metaContent -match '(?m)^\s*PackageUrl:\s*(.+)')       { $installerInfo.InformationUrl = $matches[1].Trim() }
        elseif ($metaContent -match '(?m)^\s*PublisherUrl:\s*(.+)')     { $installerInfo.InformationUrl = $matches[1].Trim() }

        return $installerInfo
    }
    catch {
        Write-Warning "Failed to parse YAML file: $($_.Exception.Message)"
        return $null
    }
}
