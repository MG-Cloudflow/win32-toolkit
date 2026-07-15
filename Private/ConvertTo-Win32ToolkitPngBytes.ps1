function ConvertTo-Win32ToolkitPngBytes {
    <#
    .SYNOPSIS
        Normalizes arbitrary image bytes to genuine PNG bytes (or $null if they are not a decodable image).
    .DESCRIPTION
        Intune's win32LobApp largeIcon is a mimeContent of type image/png — the bytes MUST actually be a
        PNG, not merely a file named .png. Two things in this toolkit can hand us non-PNG bytes in an
        AppIcon.png:

          * Get-AppIconFromWinget historically wrote the fetched bytes verbatim (a winget IconUrl can be
            ICO/JPEG/BMP/GIF), and
          * a manual -IconPath can be any image copied over AppIcon.png.

        This helper returns the input unchanged when it is already a PNG (cheap, no GDI needed), otherwise
        decodes it with System.Drawing and re-encodes as PNG. Returns $null when the bytes are empty or not
        a decodable image — callers treat that as "no usable icon" and skip it rather than uploading garbage.

        GDI (System.Drawing) is Windows-only; the decode is wrapped so a non-Windows / headless host simply
        yields $null instead of throwing.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -lt 4) { return $null }

    # Already a PNG? (89 50 4E 47) — pass straight through, no decode/re-encode.
    if ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47) {
        return $Bytes
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $inStream = New-Object System.IO.MemoryStream (, $Bytes)
        try {
            $img = [System.Drawing.Image]::FromStream($inStream)
            try {
                $outStream = New-Object System.IO.MemoryStream
                try {
                    $img.Save($outStream, [System.Drawing.Imaging.ImageFormat]::Png)
                    return $outStream.ToArray()
                }
                finally { $outStream.Dispose() }
            }
            finally { $img.Dispose() }
        }
        finally { $inStream.Dispose() }
    }
    catch {
        Write-Verbose "ConvertTo-Win32ToolkitPngBytes: not a decodable image ($($_.Exception.Message))."
        return $null
    }
}
