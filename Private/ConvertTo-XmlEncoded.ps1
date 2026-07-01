function ConvertTo-XmlEncoded {
    # Escape a value for safe embedding inside XML text. Used for the Windows Sandbox
    # (.wsb) <Command> element built in Test-Win32ToolkitProject.
    # See knowledge-base/07-security-review.md.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}
