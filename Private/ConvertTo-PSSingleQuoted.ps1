function ConvertTo-PSSingleQuoted {
    # Escape a value for safe embedding INSIDE a single-quoted PowerShell literal ('...').
    #
    # PowerShell (5.1 and 7) ends a single-quoted literal at the ASCII apostrophe U+0027 AND at the
    # typographic quotes U+2018, U+2019, U+201A and U+201B; a doubled quote of any of these kinds
    # yields one literal character. So EVERY PowerShell single-quote character is doubled - not only
    # the apostrophe - with PowerShell's own escaper (CodeGeneration.EscapeSingleQuotedStringContent),
    # and the value round-trips exactly (the 5.1 parser on the device reads it back verbatim).
    #
    # Used by every generator that splices a value into a single-quoted literal of a generated script
    # (e.g. New-IntuneRequirementScript, Get-Win32ToolkitRequirementRule, New-UpdateAssertionScript,
    # Get-Win32ToolkitBaselineInstallCommand) so untrusted winget/registry/MSI values placed into
    # generated code are treated as DATA, not code. Also fixes benign breakage (e.g. Publisher
    # "O'Reilly", or a name with a typographic apostrophe). See knowledge-base/07-security-review.md.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value)
}
