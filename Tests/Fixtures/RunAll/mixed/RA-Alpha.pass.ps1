# Run-All self-test fixture (Tests\RunAllParallel.unit.ps1 runs it through Tests\Run-All.ps1 -Path). Not a suite:
# Run-All never searches sub-folders, so this file never runs in a normal pass. Writes only to stdout (and, when
# $env:W32T_RA_RENDEZVOUS names a folder, one marker file there).
$tag = 'Alpha'; $peer = 'Bravo'
function Mark([string]$What) { Write-Host ('RA|{0}|{1}|{2}' -f $tag, $What, [DateTime]::UtcNow.Ticks) }
Mark 'START'
if ($env:W32T_RA_RENDEZVOUS) {
    New-Item -ItemType File -Path (Join-Path $env:W32T_RA_RENDEZVOUS "$tag.started") -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath (Join-Path $env:W32T_RA_RENDEZVOUS "$peer.started")) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (Test-Path -LiteralPath (Join-Path $env:W32T_RA_RENDEZVOUS "$peer.started")) { Mark 'PEER' } else { Mark 'NO-PEER' }
} else { Mark 'SOLO' }
for ($i = 1; $i -le 15; $i++) { Write-Host "RA|$tag|LINE $i"; Start-Sleep -Milliseconds 100 }
Mark 'END'
exit 0
