function Get-Win32ToolkitZipContentHash {
    <#
    .SYNOPSIS
        Returns a content hash of a zip that does not depend on the zip's timestamps or entry order.
    .DESCRIPTION
        Hyper-V speed-up PR 1 (A-3): the CopyInSha256 of a Hyper-V run's TestResults.json record. One line per
        entry, "<entry FullName><TAB><SHA256 of the entry's bytes, upper-case hex><LF>" (a folder entry, whose
        FullName ends with '/', is "<FullName><TAB>-<LF>"); the lines are sorted ordinally, joined, and hashed
        with SHA256 (upper-case hex). Two zips with the same entries and bytes give the same value, whatever
        their write times or order.

        Pure .NET (System.IO.Compression, SHA256): Invoke-Win32ToolkitHyperVRun rebuilds this function from its
        text inside the zip prebuild thread job, which has none of this module's functions. Never throws: a
        missing or unreadable zip returns $null.
    .PARAMETER ZipPath
        The zip to hash.
    .OUTPUTS
        [string] 64 upper-case hex characters, or $null.
    .EXAMPLE
        Get-Win32ToolkitZipContentHash -ZipPath $zip
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ZipPath
    )

    $archive = $null
    $sha = $null
    try {
        if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not [System.IO.File]::Exists($ZipPath)) { return $null }
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ($name.EndsWith('/')) {
                $lines.Add($name + "`t-`n")
                continue
            }
            $stream = $entry.Open()
            try { $entryHash = [System.Convert]::ToHexString($sha.ComputeHash($stream)) }
            finally { $stream.Dispose() }
            $lines.Add($name + "`t" + $entryHash + "`n")
        }
        $sorted = $lines.ToArray()
        [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]::Concat($sorted))
        return [System.Convert]::ToHexString($sha.ComputeHash($bytes))
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        return $null
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $sha) { $sha.Dispose() }
    }
}
