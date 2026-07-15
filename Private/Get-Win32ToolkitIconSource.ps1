function Get-Win32ToolkitIconSource {
    <#
    .SYNOPSIS
        Reads the Assets\.iconsource marker written by Set-Win32ToolkitIconSource ($null when absent).
    .DESCRIPTION
        Returns the trimmed marker string ('winget' | 'manual' | 'captured') or $null when no marker exists
        or it cannot be read. See Set-Win32ToolkitIconSource for why this exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $marker = Join-Path $ProjectPath 'Assets\.iconsource'
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    try {
        $value = (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim()
        if ($value) { return $value } else { return $null }
    }
    catch { return $null }
}
