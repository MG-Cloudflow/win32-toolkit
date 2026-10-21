# Run-All self-test fixture (Tests\RunAllParallel.unit.ps1 runs it through Tests\Run-All.ps1 -Path). Not a suite:
# Run-All never searches sub-folders, so this file never runs in a normal pass. Writes only to stdout (and, when
# $env:W32T_RA_RENDEZVOUS names a folder, one marker file there).
# W32T-RUN-SERIAL: Run-All self-test fixture (serial-only suites run alone, after the parallel batch)
$tag = 'Mike'
function Mark([string]$What) { Write-Host ('RA|{0}|{1}|{2}' -f $tag, $What, [DateTime]::UtcNow.Ticks) }
Mark 'START'
for ($i = 1; $i -le 5; $i++) { Write-Host "RA|$tag|LINE $i"; Start-Sleep -Milliseconds 100 }
Mark 'END'
exit 0
