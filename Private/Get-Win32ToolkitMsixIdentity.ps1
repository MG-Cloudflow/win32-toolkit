function Get-Win32ToolkitMsixIdentity {
    <#
    .SYNOPSIS
        Reads the package identity (Name/Publisher/Version) from an .msix/.appx file's AppxManifest.xml.
    .DESCRIPTION
        Host-side (PS 7.2+). Opens the package as a ZIP and parses the ROOT AppxManifest.xml only
        (FullName match — a bundle's nested per-package manifests can never match; .msixbundle /
        .appxbundle files carry AppxBundleManifest.xml instead and are out of scope — see TODO).

        The identity Name is what the device resolves at uninstall time (Get-AppxPackage .Name /
        Get-AppxProvisionedPackage .DisplayName), so no PackageFamilyName hash computation is needed.
        Values are returned as DATA for AppConfig.json — they never enter a code position.
    .PARAMETER Path
        Full path to the .msix/.appx file.
    .OUTPUTS
        [pscustomobject] @{ PackageName; Publisher; Version } — or $null (with a warning) on any failure.
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
        $entry = $zip.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1
        if (-not $entry) {
            Write-Warning "No root AppxManifest.xml in '$([System.IO.Path]::GetFileName($Path))' — not a plain .msix/.appx (bundles are not supported yet)."
            return $null
        }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }

        $identity = $manifest.Package.Identity
        # GetAttribute, not property access: on a nameless <Identity>, PowerShell's XML adapter falls
        # back to the base XmlNode.Name property and '$identity.Name' returns the literal 'Identity' —
        # which would flow into AppConfig as a bogus PackageName and make the device-side uninstall
        # report success without removing anything. GetAttribute returns '' when absent.
        $name = if ($identity -is [System.Xml.XmlElement]) { $identity.GetAttribute('Name') } else { $null }
        if ([string]::IsNullOrEmpty($name)) {
            Write-Warning "AppxManifest.xml in '$([System.IO.Path]::GetFileName($Path))' has no Package/Identity Name."
            return $null
        }

        return [pscustomobject]@{
            PackageName = $name
            Publisher   = $identity.GetAttribute('Publisher')
            Version     = $identity.GetAttribute('Version')
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
