function ConvertTo-PSDoubleQuoted {
    # Escape a value for safe embedding INSIDE a double-quoted PowerShell literal ("...")
    # in GENERATED code, so it cannot expand a variable/subexpression or close the string.
    # Used for log-message interpolations in the generated PSADT scripts.
    # See knowledge-base/07-security-review.md.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.Replace('`', '``').Replace('"', '`"').Replace('$', '`$')
}
