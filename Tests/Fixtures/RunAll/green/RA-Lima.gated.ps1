# Run-All self-test fixture (Tests\RunAllParallel.unit.ps1 runs it through Tests\Run-All.ps1 -Path). Not a suite:
# Run-All never searches sub-folders, so this file never runs in a normal pass. Writes only to stdout (and, when
# $env:W32T_RA_RENDEZVOUS names a folder, one marker file there).
Write-Host 'RA|Lima|RAN'
if (-not $env:W32T_LIVE_RUNALL_FIXTURE) { Write-Host 'SKIP: set W32T_LIVE_RUNALL_FIXTURE=1 to run (never set by the self-test)'; exit 3 }
exit 1
