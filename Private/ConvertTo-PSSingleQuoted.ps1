function ConvertTo-PSSingleQuoted {
    # Escape a value for safe embedding INSIDE a single-quoted PowerShell literal ('...').
    #
    # Used by the script/.wsb generators (Configure-PSADTForInstaller,
    # Update-PSADTUninstallLogic, Update-PSADTProcessesToClose, New-IntuneRequirementScript,
    # Test-Win32ToolkitProject) so untrusted winget/registry values placed into generated
    # code are treated as DATA, not code. Also fixes benign apostrophe breakage (e.g.
    # Publisher "O'Reilly"). See knowledge-base/07-security-review.md.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.Replace("'", "''")
}
