function Get-Win32ToolkitVersion {
    <#
    .SYNOPSIS
        Returns the installed win32-toolkit module version as a string (e.g. '1.0.1'), or '' if unknown.
    .DESCRIPTION
        Prefers the loaded module's version; falls back to reading ModuleVersion from the manifest next
        to this file. Never throws: an unknown version returns '' so callers can decide what to render.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $v = $null
    try { $v = (Get-Module 'win32-toolkit' | Select-Object -First 1).Version } catch { }
    if (-not $v) {
        try { $v = (Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'win32-toolkit.psd1')).ModuleVersion } catch { }
    }
    if ($v) { "$v" } else { '' }
}
