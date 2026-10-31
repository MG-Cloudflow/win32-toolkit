<#
    The assertion-log parser (Wait-Win32ToolkitUpdateAssertion) must only read a REAL assertion line —
    "[timestamp] ASSERT <name> = <result>" with ASSERT as the first token — and never a mid-line
    occurrence inside a DIAGNOSTIC line that echoes an untrusted value (an app DisplayName from a winget
    manifest is untrusted). Without anchoring, a DisplayName like "Widget ASSERT Rigged = FAIL" echoed into
    a diagnostic line would forge a FAIL and corrupt the recorded verdict shown in the customer doc.
    [5] Get-Win32ToolkitAssertionFailure (the TUI's FAILED install/uninstall panel, TUI audit G1) reads the
    failed checks and their reasons with the same anchor and the same first-result-per-name rule.

    Run:  pwsh -File Tests\AssertionParsingAnchor.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Wait-Win32ToolkitUpdateAssertion.ps1')
function Start-Sleep { param($Seconds) }   # don't actually sleep; the deadline loop still exits on its own

function NewProjWithLog([string[]]$lines) {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32anc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $ld = Join-Path $p 'Sandbox\Logs'
    New-Item -ItemType Directory -Path $ld -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ld 'InstallAssertions.log') -Value $lines -Encoding UTF8
    $p
}
function Verdict($p) {
    # HyperV backend reads the already-present log; tiny timeout so a non-complete log returns fast.
    Wait-Win32ToolkitUpdateAssertion -ProjectPath $p -Backend HyperV -TimeoutMinutes 0.05 -PollSeconds 1 -LogFileName 'InstallAssertions.log' -Label 'INSTALL TEST' 6>$null 3>$null
}

$ts = '[2026-07-15 09:12:00]'

# ══ [1] a hostile DisplayName in a DIAGNOSTIC line does not forge a FAIL ═══════════════════════════
Write-Host '[1] a mid-line "ASSERT X = FAIL" inside a diagnostic line is ignored' -ForegroundColor Cyan
$p1 = NewProjWithLog @(
    "$ts === Phase: PostInstall ==="
    "$ts ARP scan DisplayName=[Widget ASSERT Rigged = FAIL] found=[True]"   # hostile name echoed into a diagnostic
    "$ts ASSERT InstallDetected-PostInstall = PASS"
    "$ts === Phase: PostUninstall ==="
    "$ts ASSERT UninstallClean-PostUninstall = PASS"
    "$ts RESULT COMPLETE"
)
$v1 = Verdict $p1
if ($v1 -eq $true) { Ok 'verdict is PASS — the injected FAIL was NOT parsed as an assertion' }
else { Bad "verdict=$v1 (the mid-line FAIL corrupted the result)" }

# ══ [2] a hostile "RESULT COMPLETE" mid-line does not mark the run complete ════════════════════════
Write-Host '[2] a mid-line "RESULT COMPLETE" inside a diagnostic line does not fake completion' -ForegroundColor Cyan
$p2 = NewProjWithLog @(
    "$ts === Phase: PostInstall ==="
    "$ts ARP scan DisplayName=[App RESULT COMPLETE Edition] found=[True]"   # hostile name contains the marker
    "$ts ASSERT InstallDetected-PostInstall = PASS"
    # NOTE: no real RESULT COMPLETE — the run never finished (e.g. sandbox closed early)
)
$v2 = Verdict $p2
if ($null -eq $v2) { Ok 'verdict is INCONCLUSIVE — a faked completion marker did not turn a partial run into a pass' }
else { Bad "verdict=$v2 (a mid-line RESULT COMPLETE was treated as real completion)" }

# ══ [3] a genuine, clean run still passes (no regression to normal parsing) ════════════════════════
Write-Host '[3] a normal timestamped log still parses to a PASS verdict' -ForegroundColor Cyan
$p3 = NewProjWithLog @(
    "$ts ASSERT InstallDetected-PostInstall = PASS"
    "$ts ASSERT UninstallClean-PostUninstall = PASS"
    "$ts RESULT COMPLETE"
)
$v3 = Verdict $p3
if ($v3 -eq $true) { Ok 'a clean run still passes' } else { Bad "verdict=$v3" }

# ══ [4] a genuine FAIL is still honoured ══════════════════════════════════════════════════════════
Write-Host '[4] a real FAIL still produces a FAIL verdict' -ForegroundColor Cyan
$p4 = NewProjWithLog @(
    "$ts ASSERT InstallDetected-PostInstall = PASS"
    "$ts ASSERT UninstallClean-PostUninstall = FAIL (tattoo key still present after uninstall: HKLM:\SOFTWARE\x)"
    "$ts RESULT COMPLETE"
)
$v4 = Verdict $p4
if ($v4 -eq $false) { Ok 'a real FAIL is still detected (anchoring did not over-tighten)' } else { Bad "verdict=$v4" }

# ══ [5] Get-Win32ToolkitAssertionFailure: the failed checks and their reasons, same anchor (TUI audit G1) ═══
Write-Host '[5] Get-Win32ToolkitAssertionFailure: anchored FAIL lines, first result per name wins, reasons sanitised' -ForegroundColor Cyan
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAssertionFailure.ps1')
$failLog = { param($p) Join-Path $p 'Sandbox\Logs\InstallAssertions.log' }
$p5 = NewProjWithLog @(
    "$ts ARP scan DisplayName=[Widget ASSERT Rigged = FAIL] found=[True]"
    "Widget ASSERT Rigged2 = FAIL (echoed)"
    "$ts ASSERT InstallDetected-PostInstall = PASS"
    "$ts ASSERT AppArpGone-PostUninstall = FAIL (app still in Add/Remove Programs after uninstall: Contoso [x] 1.0)"
    "$ts ASSERT FirstFail = FAIL (first)"
    "$ts ASSERT FirstFail = PASS"
    "$ts ASSERT FirstPass = PASS"
    "$ts ASSERT FirstPass = FAIL (later)"
    "$ts ASSERT NoReason = FAIL"
    "$ts RESULT COMPLETE"
)
$r5 = @(Get-Win32ToolkitAssertionFailure -LogPath (& $failLog $p5))
if ((@($r5 | ForEach-Object Name) -join ',') -ceq 'AppArpGone-PostUninstall,FirstFail,NoReason') { Ok 'FAIL lines in first-seen order; diagnostic lines (mid-line ASSERT) never count' } else { Bad "names: $(@($r5 | ForEach-Object Name) -join ',')" }
if ($r5.Count -ge 1 -and $r5[0].Reason -ceq 'app still in Add/Remove Programs after uninstall: Contoso [x] 1.0') { Ok 'the reason in parentheses is returned without the outer pair' } else { Bad "reason: '$($r5[0].Reason)'" }
if (@($r5 | Where-Object Name -eq 'FirstFail').Count -eq 1 -and @($r5 | Where-Object Name -eq 'FirstPass').Count -eq 0) { Ok 'the first result of a name wins, as in the verdict''s reader: FAIL then PASS is returned, PASS then FAIL is not' } else { Bad "first-wins: $(@($r5 | ForEach-Object Name) -join ',')" }
if (@($r5 | Where-Object { $_.Name -eq 'NoReason' -and $_.Reason -eq '' }).Count -eq 1) { Ok 'a FAIL without a reason -> Reason empty' } else { Bad 'NoReason' }
$esc = [char]0x1B; $rlo = [char]0x202E
$p6 = NewProjWithLog @("$ts ASSERT Evil${esc}Name = FAIL (bad ${esc}[2J reason $rlo here)")
$r6 = @(Get-Win32ToolkitAssertionFailure -LogPath (& $failLog $p6))
if ($r6.Count -eq 1 -and $r6[0].Name -ceq 'Evil?Name' -and $r6[0].Reason -ceq 'bad ?[2J reason ? here') { Ok 'ESC and U+202E in the name and the reason become ?' } else { Bad "sanitised: $($r6 | ConvertTo-Json -Compress)" }
$r7 = @(Get-Win32ToolkitAssertionFailure -LogPath (Join-Path ([System.IO.Path]::GetTempPath()) ('w32none_' + [guid]::NewGuid().ToString('N') + '.log')) -ErrorVariable e7)
if ($r7.Count -eq 0 -and @($e7).Count -eq 0) { Ok 'a missing log -> nothing, no error' } else { Bad "missing log: $($r7.Count) result(s), $(@($e7).Count) error(s)" }

Remove-Item -LiteralPath $p1, $p2, $p3, $p4, $p5, $p6 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All AssertionParsingAnchor tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail AssertionParsingAnchor test(s) FAILED." -ForegroundColor Red; exit 1 }
