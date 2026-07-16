<#
    TUI progress-bar suppression during the Hyper-V run.

      Stock cmdlets emit console progress bars that tear the Spectre.Console TUI: Copy-Item -To/-FromSession
      (host) and Remove-Item -Recurse inside an Invoke-Command over PowerShell Direct (relayed to the host).
      The fix silences $ProgressPreference at two boundaries:
        - HOST: Invoke-Win32ToolkitHyperVRun sets it for the whole run and restores it in finally (so the
          intentional Azure-upload bar on the later publish path is untouched), and the copy/session helpers
          inherit it via dynamic scoping.
        - GUEST: each Invoke-Command scriptblock over PS Direct sets its own (a host preference doesn't cross
          the runspace boundary).

      This test proves the HOST guard functionally (no VM needed) and the GUEST guards by source scan.

    Run:  pwsh -File Tests\TuiProgressSuppression.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Invoke-Win32ToolkitHyperVRun.ps1')

# ── (a) HOST guard: silenced DURING the run, restored AFTER — even when the run fails ───────────────
Write-Host '[a] Invoke-Win32ToolkitHyperVRun silences $ProgressPreference during the run and restores it' -ForegroundColor Cyan

$script:insideProgress = '<unset>'
# Shadow the session helpers so no VM is touched. The session opener records what $ProgressPreference is
# at call time (i.e. INSIDE the guarded try, after the set), then throws to force the catch -> finally.
function New-Win32ToolkitHyperVSession { param($VMName, $Credential, $CheckpointName, [switch]$EnsureDesktop) $script:insideProgress = $ProgressPreference; throw 'simulated session failure' }
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert) }

$cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
$ProgressPreference = 'Continue'   # a distinctive non-default sentinel to prove exact restoration

$result = Invoke-Win32ToolkitHyperVRun -ProjectPath $env:TEMP -Phase @(@{ Label = 'noop'; Command = 'noop' }) `
    -VMName 'no-such-vm' -Credential $cred -CheckpointName 'clean-base' 3>$null

if ($script:insideProgress -eq 'SilentlyContinue') { Ok 'progress is SilentlyContinue INSIDE the run (host copy/checkpoint bars suppressed)' }
else { Bad "inside-run ProgressPreference was '$($script:insideProgress)', expected SilentlyContinue" }

if ($ProgressPreference -eq 'Continue') { Ok 'the caller''s $ProgressPreference is restored after the run (Azure-upload bar unaffected)' }
else { Bad "after the run ProgressPreference was '$ProgressPreference', expected the restored 'Continue'" }

if ($result -eq $false) { Ok 'a failed run still returns $false (unchanged behaviour)' }
else { Bad "expected `$false on session failure, got '$result'" }

$ProgressPreference = 'Continue'   # confirm restoration on the SUCCESS path too
function New-Win32ToolkitHyperVSession { param($VMName, $Credential, $CheckpointName, [switch]$EnsureDesktop) 'fake-session' }
function Copy-Win32ToolkitProjectToGuest { param($Session, $ProjectPath, $GuestPath, [switch]$ReadOnly) }
function Invoke-Win32ToolkitGuestPhase { param($Session, $Command, $Label) 0 }
function Copy-Win32ToolkitResultsFromGuest { param($Session, $GuestPath, $Destination, $GuestRoot) }
$okRun = Invoke-Win32ToolkitHyperVRun -ProjectPath $env:TEMP -Phase @(@{ Label = 'noop'; Command = 'noop' }) `
    -VMName 'no-such-vm' -Credential $cred -CheckpointName 'clean-base' 3>$null
if ($okRun -eq $true -and $ProgressPreference -eq 'Continue') { Ok 'restored on the success path too (and the run returns $true)' }
else { Bad "success path: run=$okRun, ProgressPreference='$ProgressPreference'" }

# ── (b) GUEST guards: each PS-Direct scriptblock self-silences (host preference doesn't cross runspaces) ─
Write-Host '[b] the guest Invoke-Command scriptblocks set $ProgressPreference = SilentlyContinue' -ForegroundColor Cyan
$guestGuards = @(
    @{ File = 'Private\Copy-Win32ToolkitProjectToGuest.ps1'; Param = 'param($zip, $dest)' },
    @{ File = 'Private\Copy-Win32ToolkitResultsFromGuest.ps1'; Param = 'param($globs, $rootPrefix)' }
)
foreach ($g in $guestGuards) {
    $src = Get-Content -LiteralPath (Join-Path $repo $g.File) -Raw
    # The guard must sit right after the scriptblock's param() so it applies before any progress-emitting
    # cmdlet. Single-quoted pattern so $ProgressPreference is NOT interpolated by PowerShell.
    $pattern = [regex]::Escape($g.Param) + '\s*\r?\n(?:\s*#[^\r\n]*\r?\n)*\s*\$ProgressPreference\s*=\s*''SilentlyContinue'''
    if ($src -match $pattern) { Ok "$($g.File): guest scriptblock self-silences progress" }
    else { Bad "$($g.File): guest Invoke-Command block does NOT set `$ProgressPreference right after $($g.Param)" }
}

# ── (c) TUI ROOT guard: the whole text UI runs with progress silenced ───────────────────────────────
# Per-site guards are whack-a-mole — a bar leaked back into the menu (Remove-Item's "Removed N of M
# files") because progress comes from ~14 places, explicit (Write-Progress in New-TargetedDocumentation
# / Invoke-AzBlobUpload) and implicit (Invoke-WebRequest, Expand-Archive, Copy-Item, Remove-Item
# -Recurse, Install-Module). PowerShell's progress renderer owns a screen region, paints over the
# Spectre UI, and survives Clear-Host. $ProgressPreference is dynamically scoped, so ONE guard at the
# TUI root covers every command the menu launches. Source-asserted: Show-Win32Toolkit refuses to run
# without an interactive console, so it cannot be invoked from a test host.
Write-Host '[c] Show-Win32Toolkit silences progress for the whole TUI and restores it on exit' -ForegroundColor Cyan
$tui = Get-Content -LiteralPath (Join-Path $repo 'Public\Show-Win32Toolkit.ps1') -Raw

if ($tui -match '\$prevProgress\s*=\s*\$ProgressPreference\s*\r?\n\s*\$ProgressPreference\s*=\s*''SilentlyContinue''') {
    Ok 'the TUI saves the caller preference and sets SilentlyContinue'
} else { Bad 'Show-Win32Toolkit does not silence $ProgressPreference at the root' }

if ($tui -match 'finally\s*\{\s*\$ProgressPreference\s*=\s*\$prevProgress\s*\}') {
    Ok 'restored in a finally (a scripted caller keeps its bars, even if the TUI throws)'
} else { Bad 'Show-Win32Toolkit does not restore $ProgressPreference in a finally' }

# The guard must wrap the MENU LOOP — a guard set after it would leave the UI unprotected.
$setIdx  = $tui.IndexOf("`$ProgressPreference = 'SilentlyContinue'")
$loopIdx = $tui.IndexOf('Show-Win32ToolkitMainMenu')
$finIdx  = $tui.LastIndexOf('$ProgressPreference = $prevProgress')
if ($setIdx -ge 0 -and $loopIdx -gt $setIdx -and $finIdx -gt $loopIdx) {
    Ok 'the guard encloses the main menu loop (set -> loop -> restore)'
} else { Bad "guard does not enclose the menu loop (set=$setIdx loop=$loopIdx restore=$finIdx)" }

# Nothing inside the module may force progress back ON — that would defeat the root guard.
$forcers = @(Get-ChildItem (Join-Path $repo 'Private'), (Join-Path $repo 'Public') -Filter *.ps1 -Recurse |
    Select-String -Pattern '\$ProgressPreference\s*=\s*''Continue''' |
    ForEach-Object { $_.Path })
if ($forcers.Count -eq 0) { Ok "no module code forces `$ProgressPreference back to 'Continue'" }
else { Bad "these force progress back on inside the TUI: $(($forcers | Split-Path -Leaf) -join ', ')" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
