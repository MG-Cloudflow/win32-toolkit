function Get-Win32ToolkitWrappedText {
    <#
    .SYNOPSIS
        Word-wraps a string to a maximum line width, so a long value cannot blow out a Spectre table
        column and squeeze the others into mid-word wrapping.
    .DESCRIPTION
        Splits on whitespace and re-flows into lines no wider than MaxWidth, hard-breaking any single
        word longer than MaxWidth. Returns the text unchanged when it already fits. Never throws.
        Used for the health table's Detail column, where a failed check (e.g. the Hyper-V backend not
        being elevated) can otherwise produce one very long cell.
    .PARAMETER Text
        The text to wrap.
    .PARAMETER MaxWidth
        Maximum characters per line. Defaults to 50.
    .OUTPUTS
        [string] with embedded newlines at the wrap points.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Text,
        [int]$MaxWidth = 50
    )

    if ([string]::IsNullOrEmpty($Text) -or $MaxWidth -le 0 -or $Text.Length -le $MaxWidth) { return "$Text" }

    $lines = [System.Collections.Generic.List[string]]::new()
    $line = ''
    foreach ($word in ($Text -split '\s+')) {
        $w = $word
        # Hard-break a single word that is itself longer than the column.
        while ($w.Length -gt $MaxWidth) {
            if ($line) { $lines.Add($line); $line = '' }
            $lines.Add($w.Substring(0, $MaxWidth))
            $w = $w.Substring($MaxWidth)
        }
        if (-not $line) { $line = $w }
        elseif (($line.Length + 1 + $w.Length) -le $MaxWidth) { $line = "$line $w" }
        else { $lines.Add($line); $line = $w }
    }
    if ($line) { $lines.Add($line) }
    return ($lines -join "`n")
}
