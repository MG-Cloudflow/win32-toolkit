function ConvertTo-Win32ToolkitByteSize {
<#
.SYNOPSIS
    Parses a human size string ('6GB', '6144MB', '6442450944') into bytes.
.DESCRIPTION
    For interactive prompts, where PowerShell size literals (6GB) are not evaluated from a typed string.
    A bare number with no unit is treated as GB (the common case for VM memory); explicit B/KB/MB/GB/TB win.
    Returns $null when the text is empty or not a recognisable size, so callers can validate and re-prompt.
.OUTPUTS
    [uint64] bytes, or $null.
#>
    [CmdletBinding()]
    [OutputType([System.Nullable[uint64]])]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text.Trim() -notmatch '^(?<n>\d+(?:\.\d+)?)\s*(?<u>[KMGT]?B)?$') { return $null }

    $n = [double]$matches['n']
    $u = if ($matches['u']) { $matches['u'].ToUpperInvariant() } else { 'GB' }
    $mult = switch ($u) {
        'B'  { 1 }
        'KB' { 1KB }
        'MB' { 1MB }
        'GB' { 1GB }
        'TB' { 1TB }
        default { 1GB }
    }
    # A large bare number defaults to GB, so a value like 20000000000 would overflow [uint64] and THROW on the
    # cast — return $null instead (the documented contract) so the caller validates and re-prompts rather than
    # crashing the menu.
    $product = [double]($n * $mult)
    if ($product -gt [uint64]::MaxValue) { return $null }
    return [uint64]$product
}
