function Get-Win32ToolkitMsixApplication {
    <#
    .SYNOPSIS
        Reads the executables an MSIX/APPX package (or bundle) declares — the processes to close.

    .DESCRIPTION
        Host-side (PS 7.2+). An MSIX declares its apps in the manifest:
            <Applications><Application Id="App" Executable="pwsh.exe" ... /></Applications>
        That is the ONLY reliable source for an MSIX, because the capture-based detector
        (Update-PSADTProcessesToClose) looks exclusively for classic Win32 artifacts — App Paths keys,
        the Uninstall key's DisplayIcon, and EXEs under InstallLocation — and an MSIX writes NONE of
        them: it is registry-virtualized and its payload lands in %ProgramFiles%\WindowsApps\<PFN>\.
        So every MSIX silently ended up with ProcessesToClose = @(), and the install never offered to
        close the running app.

        Same lesson as the uninstall identity: read it from the manifest at CONFIGURE time and the
        answer is capture-independent.

        BUNDLES: a bundle manifest declares NO <Applications> — the apps live in the nested
        per-architecture packages. So for a bundle we open the first nested Type="application" package
        and read its manifest. Every architecture declares the same executables (that is the point of a
        bundle), so which one we pick does not matter. Nested entries are read into a MemoryStream
        first: ZipArchive entry streams are forward-only, and opening a zip-inside-a-zip needs a
        seekable stream.

    .PARAMETER Path
        Full path to the .msix/.appx/.msixbundle/.appxbundle file.

    .OUTPUTS
        [string[]] process names WITHOUT the .exe extension (e.g. 'pwsh'), or @() on any failure.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "MSIX package not found: $Path"
        return @()
    }

    # Pulls Application/@Executable out of an AppxManifest.xml document, as bare process names.
    function Read-ApplicationExecutable {
        param([xml]$Manifest)
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($appNode in @($Manifest.DocumentElement.GetElementsByTagName('Application'))) {
            if ($appNode -isnot [System.Xml.XmlElement]) { continue }
            $exe = $appNode.GetAttribute('Executable')
            if ([string]::IsNullOrWhiteSpace($exe)) { continue }
            # Executable may carry a path ("bin\app.exe") — take the leaf, drop the extension.
            $leaf = $exe.Replace('/', '\').Split('\')[-1]
            $name = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
            if ($name -and $name -notin $names) { $names.Add($name) }
        }
        return $names
    }

    function Read-ManifestFromEntry {
        param($Entry)
        $reader = New-Object System.IO.StreamReader($Entry.Open())
        try { [xml]$doc = $reader.ReadToEnd(); return $doc } finally { $reader.Dispose() }
    }

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)

        # Plain package: the root manifest carries <Applications> directly.
        $root = $zip.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1
        if ($root) {
            return @(Read-ApplicationExecutable -Manifest (Read-ManifestFromEntry -Entry $root))
        }

        # Bundle: find a nested application package via the bundle manifest, then read ITS manifest.
        $bundleEntry = $zip.Entries | Where-Object { $_.FullName -ieq 'AppxMetadata/AppxBundleManifest.xml' } | Select-Object -First 1
        if (-not $bundleEntry) {
            Write-Warning "No AppxManifest.xml or AppxBundleManifest.xml in '$([System.IO.Path]::GetFileName($Path))' — cannot read its applications."
            return @()
        }
        $bundleManifest = Read-ManifestFromEntry -Entry $bundleEntry

        # Prefer Type="application" packages; resource packages carry no apps. Some manifests omit Type
        # (application is the default), so treat a missing Type as an application too.
        $nestedNames = foreach ($p in @($bundleManifest.DocumentElement.GetElementsByTagName('Package'))) {
            if ($p -isnot [System.Xml.XmlElement]) { continue }
            $type = $p.GetAttribute('Type')
            if ($type -and $type -ine 'application') { continue }
            $fn = $p.GetAttribute('FileName')
            if ($fn) { $fn }
        }

        foreach ($nested in @($nestedNames)) {
            $entry = $zip.Entries | Where-Object { $_.FullName -ieq $nested } | Select-Object -First 1
            if (-not $entry) { continue }
            # Copy the nested package into memory — a zip inside a zip needs a SEEKABLE stream.
            $ms = New-Object System.IO.MemoryStream
            try {
                $es = $entry.Open()
                try { $es.CopyTo($ms) } finally { $es.Dispose() }
                $ms.Position = 0
                $inner = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
                try {
                    $innerRoot = $inner.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1
                    if (-not $innerRoot) { continue }
                    $apps = @(Read-ApplicationExecutable -Manifest (Read-ManifestFromEntry -Entry $innerRoot))
                    if ($apps.Count -gt 0) { return $apps }   # all architectures declare the same apps
                }
                finally { $inner.Dispose() }
            }
            finally { $ms.Dispose() }
        }

        return @()
    }
    catch {
        Write-Warning "Could not read applications from '$([System.IO.Path]::GetFileName($Path))': $($_.Exception.Message)"
        return @()
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }
}
