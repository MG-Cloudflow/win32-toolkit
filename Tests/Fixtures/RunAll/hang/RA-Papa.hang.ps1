# Run-All self-test fixture (Tests\RunAllParallel.unit.ps1 runs it through Tests\Run-All.ps1 -Path). Not a suite:
# Run-All never searches sub-folders, so this file never runs in a normal pass. Writes only to stdout (and, when
# $env:W32T_RA_RENDEZVOUS names a folder, one marker file there).
# Records itself as '<pid> <start time>' and hangs: the self-test stops the run (Ctrl+C) while it runs.
$tag = 'Papa'
function Mark([string]$What) { Write-Host ('RA|{0}|{1}|{2}' -f $tag, $What, [DateTime]::UtcNow.Ticks) }
Mark 'START'
$rec = '{0} {1}' -f $PID, (Get-Process -Id $PID).StartTime.ToFileTimeUtc()
if ($env:W32T_RA_RENDEZVOUS) { Set-Content -LiteralPath (Join-Path $env:W32T_RA_RENDEZVOUS "$tag.self") -Value $rec -Encoding ascii }
Write-Host "RA|$tag|SELF $rec"
Start-Sleep -Seconds 300
Mark 'END'
exit 0
