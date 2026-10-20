function New-Win32ToolkitProjectZip {
    <#
    .SYNOPSIS
        Builds the single NoCompression zip of a project's CONTENTS used for the Hyper-V guest copy-in.
    .DESCRIPTION
        Extracted from Copy-Win32ToolkitProjectToGuest so the zip can be built CONCURRENTLY with the
        checkpoint revert + ready-wait (Start-ThreadJob in Invoke-Win32ToolkitHyperVRun, which rebuilds this
        function from its text in the job) — the zip needs no session and 5-20 s of it used to sit serially in
        every run. The single-zip shape itself is a correctness fix (attribute replay, FILE_ATTRIBUTE_PINNED),
        not an optimization — see the copy helper's docs. NoCompression: the payload is installers (already
        compressed).

        Sandbox\Logs\Runs\ is left out: it holds the host's copy of every earlier run's logs (test campaign
        F2), which the guest never reads; carrying it in would also bring it back with every copy-out. Every
        other file and folder (empty ones too) is in the zip, at its path relative to the project.
    .PARAMETER ProjectPath
        The project folder whose contents are zipped.
    .PARAMETER ZipPath
        Where to write the zip (default: a new w32proj_*.zip in the temp folder).
    .OUTPUTS
        [string] the zip path (caller owns cleanup).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string]$ZipPath
    )

    Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
    if (-not $ZipPath) {
        $ZipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('w32proj_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
    }
    $root = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\') + '\'
    $skip = 'Sandbox\Logs\Runs'
    $isSkipped = { param($Rel) $Rel.Equals($skip, [System.StringComparison]::OrdinalIgnoreCase) -or $Rel.StartsWith($skip + '\', [System.StringComparison]::OrdinalIgnoreCase) }
    # Entries are relative to the project root ('/' separators), so the CONTENTS land directly under the guest path.
    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    $built = $false
    try {
        foreach ($dir in [System.IO.Directory]::EnumerateDirectories($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            $rel = $dir.Substring($root.Length)
            if (& $isSkipped $rel) { continue }
            $null = $archive.CreateEntry(($rel -replace '\\', '/') + '/')
        }
        foreach ($file in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            $rel = $file.Substring($root.Length)
            if (& $isSkipped $rel) { continue }
            $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file, ($rel -replace '\\', '/'), [System.IO.Compression.CompressionLevel]::NoCompression)
        }
        $built = $true
    }
    finally {
        $archive.Dispose()
        # A failed build (a locked file) leaves no half-written zip behind.
        if (-not $built) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
    }
    return $ZipPath
}
