function ConvertTo-Win32ToolkitSafeText {
    <#
    .SYNOPSIS
        Neutralises an untrusted string before it reaches the console or a JSON file.
    .DESCRIPTION
        Untrusted strings (winget-pkgs manifests, capture JSON, guest log lines, other projects' AppConfig)
        are data. Before they are printed or stored for display (installer-identity PR 1, C-6):
          - $null becomes '';
          - every character of Unicode category Cc (control: ESC, NUL, CR, LF, TAB, ...) or Cf (format:
            bidi overrides such as U+202E, zero-width characters, the BOM), and the line/paragraph
            separators U+2028/U+2029, becomes '?' (no terminal escape sequence, no visual reordering, no
            forged extra line);
          - the result is trimmed;
          - a result longer than MaxLength keeps its first MaxLength-3 characters followed by '...'.
        Pure. The TUI still renders the result through Get-SpectreEscapedText (markup is not this helper's job).
    .PARAMETER Text
        The untrusted string.
    .PARAMETER MaxLength
        The longest result returned (default 256, at least 4).
    .OUTPUTS
        [string]
    .EXAMPLE
        ConvertTo-Win32ToolkitSafeText -Text $manifestValue -MaxLength 128
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateRange(4, 1048576)]
        [int]$MaxLength = 256
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $sb = [System.Text.StringBuilder]::new($Text.Length)
    foreach ($c in $Text.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($cat -eq [System.Globalization.UnicodeCategory]::Control -or
            $cat -eq [System.Globalization.UnicodeCategory]::Format -or
            $c -eq [char]0x2028 -or $c -eq [char]0x2029) {
            [void]$sb.Append('?')
        } else {
            [void]$sb.Append($c)
        }
    }
    $safe = $sb.ToString().Trim()
    if ($safe.Length -gt $MaxLength) { $safe = $safe.Substring(0, $MaxLength - 3) + '...' }
    return $safe
}
