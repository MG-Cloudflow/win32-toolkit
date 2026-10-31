# Run-All self-test fixture (Tests\RunAllParallel.unit.ps1 runs it through Tests\Run-All.ps1 -Path). Not a suite:
# Run-All never searches sub-folders, so this file never runs in a normal pass. Writes only to stdout (and, when
# $env:W32T_RA_RENDEZVOUS names a folder, one marker file there).
# Starts a child that inherits its output (the pipe stays open while it runs), records it as '<pid> <start time>',
# then hangs: Run-All -SuiteTimeoutMinutes must kill the whole process tree.
$tag = 'India'
function Mark([string]$What) { Write-Host ('RA|{0}|{1}|{2}' -f $tag, $What, [DateTime]::UtcNow.Ticks) }
Mark 'START'
$kid = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -NoNewWindow -PassThru
$rec = '{0} {1}' -f $kid.Id, $kid.StartTime.ToFileTimeUtc()
if ($env:W32T_RA_RENDEZVOUS) { Set-Content -LiteralPath (Join-Path $env:W32T_RA_RENDEZVOUS "$tag.kid") -Value $rec -Encoding ascii }
Write-Host "RA|$tag|KID $rec"
Start-Sleep -Seconds 300
Mark 'END'
exit 0
