function Test-Win32ToolkitProcessName {
    # A process / executable base name should be a simple token. Reject anything that
    # could break out of a generated string literal (quotes, $, backtick, etc.) before it
    # is written into AppProcessesToClose. See knowledge-base/07-security-review.md.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    return [bool]($Value -match '^[\w .\-+()]+$')
}
