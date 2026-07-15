function New-Win32ToolkitProjectZip {
    <#
    .SYNOPSIS
        Builds the single NoCompression zip of a project's CONTENTS used for the Hyper-V guest copy-in.
    .DESCRIPTION
        Extracted from Copy-Win32ToolkitProjectToGuest so the zip can be built CONCURRENTLY with the
        checkpoint revert + ready-wait (Start-ThreadJob in Invoke-Win32ToolkitHyperVRun) — the zip needs
        no session and 5-20 s of it used to sit serially in every run. The single-zip shape itself is a
        correctness fix (attribute replay, FILE_ATTRIBUTE_PINNED), not an optimization — see the copy
        helper's docs. NoCompression: the payload is installers (already compressed).
    .OUTPUTS
        [string] the zip path (caller owns cleanup).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('w32proj_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
    # $false = do not include the base directory, so the project CONTENTS land directly under the guest path.
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $ProjectPath, $zipPath, [System.IO.Compression.CompressionLevel]::NoCompression, $false)
    return $zipPath
}
