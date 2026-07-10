function Set-Win32ToolkitConfigValue {
    <#
    .SYNOPSIS
        Writes a win32-toolkit config value to the registry (HKCU:\Software\CloudFlow\win32-toolkit).
    .DESCRIPTION
        Generic writer for the per-user config hive that also backs BasePath. Creates the key on first
        use. Mirrors the persistence style of Get-Win32ToolkitBasePath (warn, don't throw, if the write
        fails). Used by the test-backend config setters.
    .PARAMETER Name
        The registry value name to write.
    .PARAMETER Value
        The string value to store (empty string is allowed, e.g. to clear a setting).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $regKey = 'HKCU:\Software\CloudFlow\win32-toolkit'
    try {
        if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
        Set-ItemProperty -Path $regKey -Name $Name -Value $Value
    }
    catch {
        Write-Warning "Could not save '$Name' to the registry: $($_.Exception.Message)"
    }
}
