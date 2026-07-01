function ConvertTo-PSLiteral {
    # Return a COMPLETE, escaped single-quoted PowerShell string literal.
    #   O'Reilly  ->  'O''Reilly'      (null/empty -> '')
    # Convenience wrapper over ConvertTo-PSSingleQuoted for the app-variable substitutions
    # in Configure-PSADTForInstaller. See knowledge-base/07-security-review.md.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    return "'" + (ConvertTo-PSSingleQuoted $Value) + "'"
}
