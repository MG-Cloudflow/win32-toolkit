# Run-All self-test fixture (Tests\RunAllParallel.unit.ps1 runs it through Tests\Run-All.ps1 -Path). Not a suite:
# Run-All never searches sub-folders, so this file never runs in a normal pass. Writes only to stdout (and, when
# $env:W32T_RA_RENDEZVOUS names a folder, one marker file there).
$tag = 'Quebec'
function Mark([string]$What) { Write-Host ('RA|{0}|{1}|{2}' -f $tag, $What, [DateTime]::UtcNow.Ticks) }
Mark 'START'
for ($i = 1; $i -le 3; $i++) { Write-Host "RA|$tag|LINE $i" }
Mark 'END'
exit 0
