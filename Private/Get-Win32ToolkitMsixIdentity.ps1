function Get-Win32ToolkitMsixIdentity {
    <#
    .SYNOPSIS
        Reads the package identity (Name/Publisher/Version) from an .msix/.appx package OR a
        .msixbundle/.appxbundle — detected from the file's CONTENT, never its extension.
    .DESCRIPTION
        Host-side (PS 7.2+). Opens the package as a ZIP and reads whichever identity manifest it
        actually carries:
          * plain package -> ROOT AppxManifest.xml       (<Package><Identity .../>)
          * bundle        -> AppxMetadata/AppxBundleManifest.xml  (<Bundle><Identity .../>)
        Both carry the same Identity Name/Publisher, which is the whole point of a bundle: one identity,
        several architectures.

        CONTENT, not extension, decides — because the extension lies. winget names Microsoft's
        PowerShell download '.msix' (its manifest says InstallerType: msix) even though the URL is a
        .msixbundle. Trusting the extension is exactly what previously made identity extraction return
        $null for such packages, which left the project with NO Uninstall section at all: the app
        installed and its uninstall then silently did nothing.

        A bundle's Identity VERSION is the bundle's own version (often date-stamped) and does NOT track
        the app version — so it is returned for information only. Nothing keys off it: the device
        resolves the package at uninstall time by NAME (Get-AppxPackage .Name /
        Get-AppxProvisionedPackage .DisplayName), which is identical for a bundle and its nested
        packages, so no PackageFamilyName hash computation is needed.

        Values are returned as DATA for AppConfig.json — they never enter a code position.
    .PARAMETER Path
        Full path to the .msix/.appx/.msixbundle/.appxbundle file.
    .OUTPUTS
        [pscustomobject] @{ PackageName; Publisher; Version; IsBundle } — or $null (with a warning) on
        any failure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "MSIX package not found: $Path"
        return $null
    }

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)

        # Content detection: a plain package has a ROOT AppxManifest.xml; a bundle has
        # AppxMetadata/AppxBundleManifest.xml instead. FullName match — a bundle's NESTED per-package
        # manifests live under a path and can never be mistaken for the root one.
        $entry = $zip.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1
        $isBundle = $false
        if (-not $entry) {
            $entry = $zip.Entries | Where-Object { $_.FullName -ieq 'AppxMetadata/AppxBundleManifest.xml' } | Select-Object -First 1
            if ($entry) { $isBundle = $true }
        }
        if (-not $entry) {
            Write-Warning "No AppxManifest.xml or AppxMetadata/AppxBundleManifest.xml in '$([System.IO.Path]::GetFileName($Path))' — not a readable MSIX/APPX package or bundle."
            return $null
        }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }

        # Root element differs (<Package> vs <Bundle>) and the two manifests use different XML
        # namespaces, so select the Identity by LOCAL name among the root's DIRECT CHILDREN.
        # Deliberately NOT GetElementsByTagName: that is a DESCENDANT search on the QUALIFIED name, so
        # (a) a nested <Identity> appearing earlier in document order (e.g. inside <Properties>, or a
        # decoy) would win over the real one, and (b) a namespace-PREFIXED manifest (<b:Identity ...>)
        # would not match 'Identity' at all and the whole package would read as identity-less. Matching
        # LocalName on direct children is both namespace-agnostic and immune to nested decoys — and
        # preserves the old $manifest.Package.Identity child-access semantics.
        $identity = $manifest.DocumentElement.ChildNodes |
            Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq 'Identity' } |
            Select-Object -First 1

        # GetAttribute, not property access: on a nameless <Identity>, PowerShell's XML adapter falls
        # back to the base XmlNode.Name property and '$identity.Name' returns the literal 'Identity' —
        # which would flow into AppConfig as a bogus PackageName and make the device-side uninstall
        # report success without removing anything. GetAttribute returns '' when absent.
        $name = if ($identity -is [System.Xml.XmlElement]) { $identity.GetAttribute('Name') } else { $null }
        if ([string]::IsNullOrEmpty($name)) {
            $which = if ($isBundle) { 'AppxBundleManifest.xml' } else { 'AppxManifest.xml' }
            Write-Warning "$which in '$([System.IO.Path]::GetFileName($Path))' has no Identity Name."
            return $null
        }

        return [pscustomobject]@{
            PackageName = $name
            Publisher   = $identity.GetAttribute('Publisher')
            # For a bundle this is the BUNDLE's version (often date-stamped), not the app's — nothing
            # keys off it; uninstall resolves by Name.
            Version     = $identity.GetAttribute('Version')
            IsBundle    = $isBundle
        }
    }
    catch {
        Write-Warning "Could not read MSIX identity from '$Path': $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }
}
