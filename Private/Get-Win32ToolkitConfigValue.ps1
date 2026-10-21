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
    # An absent optional value (or key) is the normal case: read it so that it leaves NO record in $Error,
    # in a caller's -ErrorVariable or in a transcript ('TerminatingError(Get-ItemProperty)'). So: Get-Item
    # with -ErrorAction Ignore (not SilentlyContinue, which still records) and RegistryKey.GetValue, which
    # returns $null for an absent value - never Get-ItemProperty -Name -ErrorAction Stop inside try/catch
    # (test campaign 2026-10-21). GetValue expands REG_EXPAND_SZ like Get-ItemProperty; [string] keeps
    # DWORD/MULTI_SZ output as before. Fail-open: anything unreadable returns $Default.
    $val = $null
    $key = Get-Item -LiteralPath $regKey -ErrorAction Ignore
    if ($key) {
        try { $val = $key.GetValue($Name) }
        catch { $val = $null }
        finally { $key.Close() }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$val)) { return [string]$val }
    return $Default
}
