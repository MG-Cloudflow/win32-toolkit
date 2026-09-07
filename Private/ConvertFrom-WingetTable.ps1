function ConvertFrom-WingetTable {
    <#
    .SYNOPSIS
        Parses winget's console result table into {Name, Id, Version, Source} objects by
        header-derived COLUMN OFFSETS — locale-independent and safe for content-width columns.
    .DESCRIPTION
        winget sizes every column to its longest cell and separates columns with a SINGLE space. The
        old "split on 2+ spaces" heuristic therefore failed whenever a cell was the widest in its
        column — and for a single-row result (the -Id fast path) EVERY cell is, so the whole row
        collapsed into 2 parts and was dropped. Resolve-Win32ToolkitWingetId then fell back to
        Name=<Id> and Version='Unknown' ("Selected: Git.Git vUnknown", project named *_Unknown) even
        though winget printed the version.

        Column LABELS are localized (Name/ID/Version/Quelle, ...) but their ORDER is stable:
        Name, Id, Version, [Match], Source. So the parser:
          1. finds the dash separator line and takes the line above it as the header;
          2. uses the header tokens' character offsets as column starts;
          3. slices each data row at those offsets (a Name containing spaces stays intact);
          4. keeps a row only when the sliced Id is non-empty and contains no whitespace — which
             also rejects localized footer sentences without matching any localized text.
        Source is the LAST column when one exists (a fuzzy search inserts a Match column before it);
        rows on tables without a Source column default to 'winget'. When no separator/header is
        present (error text, "no package found" messages), it falls back to the old 2+-space split,
        which yields no rows for such output.

        KNOWN LIMIT (pre-existing): winget aligns by DISPLAY width, so a row whose Name holds
        double-width glyphs (e.g. CJK) can slice one cell off. Values truncated by winget keep their
        trailing ellipsis.
    .PARAMETER Text
        The raw console text of a winget table command (e.g. `winget search ... | Out-String`).
    .OUTPUTS
        [pscustomobject] { Name; Id; Version; Source } per data row (possibly none).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text
    )

    $apps = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $apps }

    # Keep raw lines — leading positions matter for offset slicing. Only drop blank ones later.
    $lines = $Text -split "`r?`n"

    # Locate the dash separator; the line directly above it is the (localized) header.
    $sepIndex = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^-{2,}$') { $sepIndex = $i; break }
    }

    if ($sepIndex -ge 1 -and -not [string]::IsNullOrWhiteSpace($lines[$sepIndex - 1])) {
        # ── Primary: slice data rows at the header tokens' offsets ────────────────────────────────
        $starts = @([regex]::Matches($lines[$sepIndex - 1], '\S+') | ForEach-Object { $_.Index })
        if ($starts.Count -ge 3) {
            for ($i = $sepIndex + 1; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line.Trim() -match '^-{2,}$') { continue }

                $vals = for ($k = 0; $k -lt $starts.Count; $k++) {
                    $s = $starts[$k]
                    $e = if ($k + 1 -lt $starts.Count) { [Math]::Min($starts[$k + 1], $line.Length) } else { $line.Length }
                    if ($s -ge $line.Length) { '' } else { $line.Substring($s, $e - $s).Trim() }
                }

                # A real row has a non-empty, whitespace-free Id; localized footer sentences
                # ("More than N results...", "N Übereinstimmungen...") slice to spaced/empty text.
                $id = $vals[1]
                if (-not $id -or $id -match '\s') { continue }

                $apps += [PSCustomObject]@{
                    Name    = $vals[0]
                    Id      = $id
                    Version = $vals[2]
                    Source  = if ($starts.Count -gt 3 -and $vals[$starts.Count - 1]) { $vals[$starts.Count - 1] } else { 'winget' }
                }
            }
            return $apps
        }
    }

    # ── Fallback (no separator/header found): the old 2+-space split. Yields nothing for plain
    #    message output ("No package found ..."), which is the correct empty result. ───────────────
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -and
            $line -notmatch '^[-\s]+$' -and
            $line -notmatch '^\d+\s+matches?\s+found' -and
            $line -notmatch '^More\s+than' -and
            $line -notmatch '^Name\s+Id\s+') {
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 3) {
                $apps += [PSCustomObject]@{
                    Name    = $parts[0].Trim()
                    Id      = $parts[1].Trim()
                    Version = $parts[2].Trim()
                    Source  = if ($parts.Count -gt 3) { $parts[$parts.Count - 1].Trim() } else { 'winget' }
                }
            }
        }
    }
    return $apps
}
