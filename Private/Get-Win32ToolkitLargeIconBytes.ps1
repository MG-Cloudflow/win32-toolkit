function Get-Win32ToolkitLargeIconBytes {
    <#
    .SYNOPSIS
        Returns genuine PNG bytes for a project's Assets\AppIcon.png, ready for the Intune largeIcon field.
    .DESCRIPTION
        Reads Assets\AppIcon.png and normalizes it to real PNG bytes via ConvertTo-Win32ToolkitPngBytes
        (already-PNG passes through; ICO/JPEG/BMP/GIF get decoded and re-encoded). Returns $null when there
        is no icon or it is not a decodable image, so Publish-Win32ToolkitIntuneApp can simply omit largeIcon
        and let Intune show the generic tile rather than uploading something invalid.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $icon = Join-Path $ProjectPath 'Assets\AppIcon.png'
    if (-not (Test-Path -LiteralPath $icon)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($icon)
    }
    catch {
        Write-Verbose "Get-Win32ToolkitLargeIconBytes: could not read '$icon' ($($_.Exception.Message))."
        return $null
    }
    return (ConvertTo-Win32ToolkitPngBytes -Bytes $bytes)
}
