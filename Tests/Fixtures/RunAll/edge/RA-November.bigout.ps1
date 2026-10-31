# Run-All self-test fixture (Tests\RunAllParallel.unit.ps1 runs it through Tests\Run-All.ps1 -Path). Not a suite:
# Run-All never searches sub-folders, so this file never runs in a normal pass. Writes only to stdout (and, when
# $env:W32T_RA_RENDEZVOUS names a folder, one marker file there).
# 6,000 lines of output in one go (more than Run-All prints line by line: the chunked path), then one line with a
# non-ASCII letter (U+00E9, written from code so this file stays ASCII).
$tag = 'November'
function Mark([string]$What) { Write-Host ('RA|{0}|{1}|{2}' -f $tag, $What, [DateTime]::UtcNow.Ticks) }
Mark 'START'
Write-Host ((1..6000 | ForEach-Object { "RA|$tag|LINE $_" }) -join [Environment]::NewLine)
Write-Host ("RA|$tag|GLYPH " + [char]0x00E9)
Mark 'END'
exit 0
