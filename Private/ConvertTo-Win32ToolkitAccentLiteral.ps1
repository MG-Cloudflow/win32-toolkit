function ConvertTo-Win32ToolkitAccentLiteral {
    <#
    .SYNOPSIS
        Normalizes a hex colour to a canonical PSADT FluentAccentColor literal (0xAARRGGBB), or $null.

    .DESCRIPTION
        PSADT's config.psd1 stores FluentAccentColor as a BARE numeric literal (e.g. 0xFF0078D7) that
        Import-PowerShellDataFile / Import-LocalizedData parse to an Int32. Only a 0x-prefixed hex form
        parses — a '#RRGGBB', bare 'RRGGBB', or bare 'FF0078D7' would either be an unparseable token or
        (for '#…') comment out the rest of the line, making the WHOLE config fail to load on-device and
        aborting the SYSTEM deploy with no fallback.

        So every accent value is funnelled through here before it is emitted bare. Accepted inputs, all
        returned as an upper-cased 0x literal:
          * 0x + 1..8 hex digits         -> as-is (canonicalized case)
          * 8 hex digits (AARRGGBB), #?  -> 0x<hex>
          * 6 hex digits (RRGGBB), #?    -> 0xFF<hex>  (opaque alpha)
        Anything else returns $null so the caller can warn and omit the key (degrading to the PSADT
        default accent) instead of shipping a config.psd1 that fails to parse.

    .OUTPUTS
        [string] a 0x… literal, or $null when the input is not a usable hex colour.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()

    if ($v -match '^0x[0-9A-Fa-f]{1,8}$') { return '0x' + $v.Substring(2).ToUpperInvariant() }

    $hex = $v -replace '^#', ''
    if ($hex -match '^[0-9A-Fa-f]{8}$') { return '0x'   + $hex.ToUpperInvariant() }
    if ($hex -match '^[0-9A-Fa-f]{6}$') { return '0xFF' + $hex.ToUpperInvariant() }

    return $null
}
