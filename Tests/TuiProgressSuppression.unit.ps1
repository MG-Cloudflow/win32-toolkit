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

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
