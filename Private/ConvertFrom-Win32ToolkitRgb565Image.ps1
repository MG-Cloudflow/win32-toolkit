function ConvertFrom-Win32ToolkitRgb565Image {
    <#
    .SYNOPSIS
        Converts a raw RGB565 framebuffer (as returned by GetVirtualSystemThumbnailImage) to a PNG.
    .DESCRIPTION
        Pure byte→image conversion, factored out of Get-Win32ToolkitVMScreenshot so it can be unit-tested
        without a Hyper-V host. The wire bytes are little-endian 16bpp RGB565 (2 bytes/pixel), row-major,
        no padding. Copies them into a Format16bppRgb565 bitmap (whole-buffer when the bitmap stride equals
        width*2 — true for every even width — else row-by-row) and saves a PNG. HOST-ONLY (PowerShell 7).
    .PARAMETER Bytes
        The RGB565 pixel bytes. Length must be at least Width*Height*2.
    .PARAMETER Width / Height
        Image dimensions in pixels.
    .PARAMETER Path
        Output PNG path; the parent directory is created if missing.
    .OUTPUTS
        [System.IO.FileInfo] of the written PNG.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [byte[]]$Bytes,
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Path
    )

    Add-Type -AssemblyName System.Drawing.Common -ErrorAction SilentlyContinue
    if (-not $Bytes -or $Bytes.Length -lt ($Width * $Height * 2)) {
        throw "Empty or short image data ($($Bytes.Length) bytes) for ${Width}x${Height} (need $($Width * $Height * 2))."
    }

    $bmp = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    try {
        $rect = [System.Drawing.Rectangle]::new(0, 0, $Width, $Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
        try {
            if ($data.Stride -eq $Width * 2) {
                [System.Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $data.Scan0, $Width * $Height * 2)
            }
            else {
                for ($y = 0; $y -lt $Height; $y++) {
                    $dst = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
                    [System.Runtime.InteropServices.Marshal]::Copy($Bytes, $y * $Width * 2, $dst, $Width * 2)
                }
            }
        }
        finally { $bmp.UnlockBits($data) }

        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bmp.Dispose() }

    Get-Item -LiteralPath $Path
}
