<#
    Regression test for the "Selected: Git.Git vUnknown" / project named *_Unknown bug.

    CAUSE: winget sizes each result-table column to its longest cell and separates columns with a
    SINGLE space. Search-WingetApps split rows on 2+ spaces, so any row whose cells are the widest in
    their columns collapsed to <3 parts and was dropped. For a single-row result — exactly what the
    -Id fast path's exact search produces — EVERY cell defines its column width, so the ONLY row was
    always dropped: Resolve-Win32ToolkitWingetId fell back to Name=<Id>, Version='Unknown', the wizard
    printed "vUnknown" and the project folder got the _Unknown suffix (AppConfig.json was later
    correct because it reads the downloaded manifest, not the table).

    FIX: parsing moved to ConvertFrom-WingetTable — header-derived column offsets (labels are
    localized, their ORDER is not), slicing each row, keeping rows whose Id is non-empty and
    whitespace-free. Fixture [1] is a LITERAL capture of the real failing output (winget v1.29,
    single-row, single-space separators, source-auth preamble).

    Run:  pwsh -File Tests\WingetSearchParse.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertFrom-WingetTable.ps1')
. (Join-Path $repo 'Private\Search-WingetApps.ps1')
. (Join-Path $repo 'Private\Resolve-Win32ToolkitWingetId.ps1')

# Builds a table exactly the way winget does: each column padded to its longest cell, columns joined
# by ONE space, full-width dash separator under the header row.
function New-WingetTable([object[]]$rows) {
    $w = @(); for ($c = 0; $c -lt $rows[0].Count; $c++) { $w += ($rows | ForEach-Object { $_[$c].Length } | Measure-Object -Maximum).Maximum }
    $lines = foreach ($r in $rows) { @(0..($r.Count - 1) | ForEach-Object { $r[$_].PadRight($w[$_]) }) -join ' ' }
    (@($lines[0]; ('-' * $lines[0].TrimEnd().Length)) + @($lines[1..($lines.Count - 1)])) -join "`n"
}

# ══ [1] THE FIELD BUG — literal capture: single row, every separator a single space ════════════════
Write-Host '[1] literal single-row capture (winget 1.29): the row parses instead of being dropped' -ForegroundColor Cyan
$literal = @'
The CloudFlow source requires authentication. Authentication prompt may appear when necessary. Authenticated information will be shared with the source for access authorization.
Name Id      Version  Source
-----------------------------
Git  Git.Git 2.55.0.3 winget
'@
$r = @(ConvertFrom-WingetTable -Text $literal)
if ($r.Count -eq 1) { Ok 'exactly one row parsed (was: zero — the whole bug)' } else { Bad "parsed $($r.Count) row(s)" }
if ($r -and $r[0].Name -eq 'Git' -and $r[0].Id -eq 'Git.Git' -and $r[0].Version -eq '2.55.0.3' -and $r[0].Source -eq 'winget') {
    Ok "Name='Git' Id='Git.Git' Version='2.55.0.3' Source='winget'"
} else { Bad "row was: $($r[0] | ConvertTo-Json -Compress)" }

# ══ [2] multi-row: names WITH spaces and widest-cell rows (single-space separators) survive ════════
Write-Host '[2] multi-row table: spaced names + widest-cell rows all parse' -ForegroundColor Cyan
$multi = New-WingetTable @(
    @('Name', 'Id', 'Version', 'Source'),
    @('Git', 'Git.Git', '2.55.0.3', 'winget'),
    @('Git Extensions', 'GitExtensionsTeam.GitExtensions', '36.0.0', 'winget'),
    @('GitHub CLI', 'GitHub.cli', '2.63.0', 'winget')
)
$r2 = @(ConvertFrom-WingetTable -Text $multi)
if ($r2.Count -eq 3) { Ok 'all 3 rows parsed' } else { Bad "parsed $($r2.Count) row(s): $($r2.Id -join ',')" }
$ext = $r2 | Where-Object { $_.Id -eq 'GitExtensionsTeam.GitExtensions' }
if ($ext -and $ext.Name -eq 'Git Extensions' -and $ext.Version -eq '36.0.0') { Ok "spaced name intact ('Git Extensions'), version from the widest row" } else { Bad "widest row: $($ext | ConvertTo-Json -Compress)" }

# ══ [3] localized headers + the extra Match column: order beats labels ═════════════════════════════
Write-Host '[3] German headers with a Match column: Version stays column 3, Source is the LAST column' -ForegroundColor Cyan
$german = New-WingetTable @(
    @('Name', 'ID', 'Version', 'Übereinstimmung', 'Quelle'),
    @('Git', 'Git.Git', '2.55.0.3', 'Moniker: git', 'winget')
)
$r3 = @(ConvertFrom-WingetTable -Text $german)
if ($r3.Count -eq 1 -and $r3[0].Version -eq '2.55.0.3' -and $r3[0].Source -eq 'winget') { Ok 'localized 5-column table parses (Match ignored)' } else { Bad "got: $($r3 | ConvertTo-Json -Compress)" }

# ══ [4] footer sentences and short/garbage lines are rejected, not parsed as rows ══════════════════
Write-Host '[4] footer/noise rejection' -ForegroundColor Cyan
$noisy = $literal + "`nMore than 50 results available.`nMehr als 50 Ergebnisse gefunden.`nGit"
$r4 = @(ConvertFrom-WingetTable -Text $noisy)
if ($r4.Count -eq 1 -and $r4[0].Id -eq 'Git.Git') { Ok 'footers and a too-short line yield no fake rows' } else { Bad "parsed $($r4.Count) row(s): $($r4.Id -join ',')" }

# ══ [5] no table at all (message-only output) -> empty, no throw ═══════════════════════════════════
Write-Host '[5] "no package found" message-only output' -ForegroundColor Cyan
$r5 = @(ConvertFrom-WingetTable -Text 'No package found matching input criteria.')
if ($r5.Count -eq 0) { Ok 'no rows, no error' } else { Bad "parsed $($r5.Count) row(s)" }
$r5b = @(ConvertFrom-WingetTable -Text '')
if ($r5b.Count -eq 0) { Ok 'empty input -> empty result' } else { Bad 'empty input produced rows' }

# ══ [6] msstore row with an EMPTY Version cell ═════════════════════════════════════════════════════
Write-Host '[6] msstore row with empty version' -ForegroundColor Cyan
$store = New-WingetTable @(
    @('Name', 'Id', 'Version', 'Source'),
    @('Git', '9WZDNCRDXF41', '', 'msstore')
)
$r6 = @(ConvertFrom-WingetTable -Text $store)
if ($r6.Count -eq 1 -and $r6[0].Id -eq '9WZDNCRDXF41' -and $r6[0].Version -eq '' -and $r6[0].Source -eq 'msstore') { Ok 'empty version tolerated, source kept' } else { Bad "got: $($r6 | ConvertTo-Json -Compress)" }

# ══ [7] end-to-end: Resolve-Win32ToolkitWingetId over the REAL parser + a shadowed winget ══════════
Write-Host '[7] Resolve-Win32ToolkitWingetId resolves Git.Git v2.55.0.3 (was: vUnknown)' -ForegroundColor Cyan
function winget {
    param([Parameter(ValueFromRemainingArguments)]$a)
    $global:LASTEXITCODE = 0
    if ("$a" -match '^show') { 'Gefunden Git [Git.Git]' } else { $script:searchText }
}
$script:searchText = $literal
$res = Resolve-Win32ToolkitWingetId -Id 'Git.Git'
if ($res -and $res.Name -eq 'Git' -and $res.Version -eq '2.55.0.3') { Ok "resolves Name='Git' Version='2.55.0.3' from the single-row table" } else { Bad "resolved: $($res | ConvertTo-Json -Compress)" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All WingetSearchParse tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail WingetSearchParse test(s) FAILED." -ForegroundColor Red; exit 1 }
