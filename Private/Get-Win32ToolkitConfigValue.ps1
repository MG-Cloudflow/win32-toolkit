function Get-Win32ToolkitConfigValue {
    <#
    .SYNOPSIS
        Reads a win32-toolkit config value from the registry (HKCU:\Software\CloudFlow\win32-toolkit).
    .DESCRIPTION
        Generic reader for the per-user config hive that also backs BasePath. Returns $Default when the
        value is absent or blank, so callers get a stable fallback without repeating the registry
        boilerplate. Used by the test-backend config (TestBackend, HyperV* settings).
    .PARAMETER Name
        The registry value name (e.g. 'TestBackend', 'HyperVVMName').
    .PARAMETER Default
        Value to return when the setting is not present. Defaults to $null.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [string]$Default
    )

    $regKey = 'HKCU:\Software\CloudFlow\win32-toolkit'
    try {
        $val = (Get-ItemProperty -Path $regKey -Name $Name -ErrorAction Stop).$Name
        if (-not [string]::IsNullOrWhiteSpace($val)) { return [string]$val }
    }
    catch { }
    return $Default
}
