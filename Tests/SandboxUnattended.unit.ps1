<#
    R1 + R3 — Sandbox unattended mode, the guard-wait, and the mode-gated auto-close.

      (a) Get-Win32ToolkitTestMode precedence: -Unattended > config Unattended > non-interactive host
          (forced Unattended + warning) > Interactive default.
      (b) Wait-Win32ToolkitSandboxFree: free -> immediate $true; frees mid-wait -> $true; never ->
          $false at the 90 s ceiling (no throw). Without a wsb answer (shadowed $null), as here, only the
          process check decides; the wsb-based close of a leftover client window: SandboxStaleClient.unit.ps1.
      (c) New-CountdownScript -Seconds honored; the 120 s watched default unchanged.
      (d) The generated Sandbox LogonCommands: watched keeps -NoExit + Countdown + interactive PSADT;
          unattended drops all three, runs -DeployMode Silent, and ends with Stop-Computer (after a 5 s
          VSMB flush) so a chained run's single-instance guard clears on its own. Both run every PSADT
          package through the guest runner (Invoke-PsadtPackage.ps1, one process per package).
      (e) The capture script's auto-close: 30 s watched / 5 s unattended (SandboxTestMode).

    Run:  pwsh -File Tests\SandboxUnattended.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitTestMode.ps1')
. (Join-Path $repo 'Private\Wait-Win32ToolkitSandboxFree.ps1')
function Get-Win32ToolkitSandboxEnvironment { $null }   # C-9: no wsb answer -> the process check decides (test campaign F1)
. (Join-Path $repo 'Private\New-CountdownScript.ps1')

function New-TempDir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('sbu_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }

# ── (a) mode resolver precedence ───────────────────────────────────────────────────────────────────
Write-Host '[a] Get-Win32ToolkitTestMode precedence' -ForegroundColor Cyan
$script:cfg = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
function Test-Win32ToolkitHostNonInteractive { $script:hostNonInteractive }
function Test-Win32ToolkitNonInteractiveSwitch { $false }   # C-9: the Update version choice (test campaign F5)
$script:hostNonInteractive = $false

if ((Get-Win32ToolkitTestMode -Backend Sandbox) -eq 'Interactive') { Ok 'default: Interactive (human-in-the-loop unchanged)' } else { Bad 'default not Interactive' }
if ((Get-Win32ToolkitTestMode -Backend Sandbox -Unattended) -eq 'Unattended') { Ok '-Unattended switch wins' } else { Bad 'switch ignored' }
$script:cfg['SandboxTestMode'] = 'Unattended'
if ((Get-Win32ToolkitTestMode -Backend Sandbox) -eq 'Unattended') { Ok 'SandboxTestMode=Unattended honored' } else { Bad 'Sandbox config ignored' }
$script:cfg.Clear(); $script:cfg['HyperVTestMode'] = 'Unattended'
if ((Get-Win32ToolkitTestMode -Backend HyperV) -eq 'Unattended') { Ok 'HyperVTestMode=Unattended honored' } else { Bad 'HyperV config ignored' }
if ((Get-Win32ToolkitTestMode -Backend Sandbox) -eq 'Interactive') { Ok 'config values are PER BACKEND (HyperV setting does not leak to Sandbox)' } else { Bad 'config leaked across backends' }
$script:cfg.Clear()
$script:hostNonInteractive = $true
$warnings = @()
$m = Get-Win32ToolkitTestMode -Backend HyperV -WarningVariable warnings 3>$null
if ($m -eq 'Unattended') { Ok 'non-interactive host -> forced Unattended (no forever-hang on Read-Host)' } else { Bad "host detect: $m" }
if ("$warnings" -match 'Intune-parity' -and "$warnings" -notmatch 'DeployMode Silent') { Ok 'the forced switch is LOUD and says what changes on Hyper-V (Intune-parity phase, not -DeployMode Silent)' } else { Bad "HyperV warning: '$warnings'" }
$warnings = @()
$m = Get-Win32ToolkitTestMode -Backend Sandbox -WarningVariable warnings 3>$null
if ($m -eq 'Unattended' -and "$warnings" -match '-DeployMode Silent' -and "$warnings" -notmatch 'Intune-parity') { Ok 'Sandbox warning says PSADT runs -DeployMode Silent' } else { Bad "Sandbox warning: mode=$m '$warnings'" }
$script:hostNonInteractive = $false

# ── (b) guard-wait ─────────────────────────────────────────────────────────────────────────────────
Write-Host '[b] Wait-Win32ToolkitSandboxFree' -ForegroundColor Cyan
$script:sleeps = @()
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:sleeps += $Seconds; $script:pollN++; if ($script:pollN -ge $script:freeAfter) { $script:sbRunning = $false } }
function Test-Win32ToolkitSandboxRunning { $script:sbRunning }

$script:sbRunning = $false; $script:pollN = 0; $script:freeAfter = 999; $script:sleeps = @()
if ((Wait-Win32ToolkitSandboxFree) -eq $true -and @($script:sleeps).Count -eq 0) { Ok 'already free -> immediate $true, zero sleeps' } else { Bad 'waited while free' }

$script:sbRunning = $true; $script:pollN = 0; $script:freeAfter = 3; $script:sleeps = @()
if ((Wait-Win32ToolkitSandboxFree 6>$null) -eq $true) { Ok 'sandbox exits mid-wait -> $true (chained runs proceed)' } else { Bad 'did not detect the exit' }

$script:sbRunning = $true; $script:pollN = 0; $script:freeAfter = 99999; $script:sleeps = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Wait-Win32ToolkitSandboxFree -TimeoutSeconds 3 -PollSeconds 1 6>$null
$sw.Stop()
if ($r -eq $false) { Ok 'never frees -> $false at the ceiling (caller throws with guidance)' } else { Bad "returned $r" }
# The shadowed Start-Sleep consumes no time, so the deadline is real wall-clock: prove it's BOUNDED by
# the ceiling (returns within ~the budget), not by poll counting.
if ($sw.Elapsed.TotalSeconds -lt 15) { Ok "bounded by the wall-clock ceiling ($([math]::Round($sw.Elapsed.TotalSeconds,1)) s for a 3 s budget)" } else { Bad "ran $([math]::Round($sw.Elapsed.TotalSeconds,1)) s" }

# ── (c) countdown parameterization ─────────────────────────────────────────────────────────────────
Write-Host '[c] New-CountdownScript -Seconds' -ForegroundColor Cyan
$p = New-TempDir
$null = New-CountdownScript -ProjectPath $p
$def = Get-Content -LiteralPath (Join-Path $p 'Sandbox\Countdown.ps1') -Raw
if ($def -match '\$secondsRemaining = 120\b' -and $def -match '2 minutes' -and $def -match '02:00') { Ok 'default stays 120 s / "2 minutes" / 02:00 (watched mode unchanged)' } else { Bad 'default countdown changed' }
$null = New-CountdownScript -ProjectPath $p -Seconds 45
$c45 = Get-Content -LiteralPath (Join-Path $p 'Sandbox\Countdown.ps1') -Raw
if ($c45 -match '\$secondsRemaining = 45\b' -and $c45 -match '45 seconds' -and $c45 -match '00:45') { Ok '-Seconds 45 honored (literal + labels)' } else { Bad '45 s variant wrong' }
if ($c45 -notmatch '__SECONDS__|__DURATION__|__INITIAL__') { Ok 'no placeholder leaked' } else { Bad 'placeholder left in output' }
Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue

# ── (d) the generated LogonCommands (source assertions — the shapes that run in the guest) ─────────
Write-Host '[d] Sandbox LogonCommand shapes (watched vs unattended)' -ForegroundColor Cyan
$src = Get-Content -LiteralPath (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1') -Raw

# Watched IU: -NoExit + Countdown, no Silent, no shutdown (comment lines may sit above the assignment).
$iuWatched = [regex]::Match($src, '(?s)if \(\$sbInteractive\) \{\s*(?:#[^\r\n]*\s*)*\$logonCommandXml = "(powershell\.exe -NoExit[^"]*Countdown\.ps1[^"]*)"').Groups[1].Value
if ($iuWatched) { Ok 'watched IU keeps -NoExit + Countdown' } else { Bad 'watched IU LogonCommand changed' }
if ($iuWatched -and $iuWatched -notmatch '-DeployMode' -and ([regex]::Matches($iuWatched, 'Invoke-PsadtPackage\.ps1')).Count -eq 2 -and $iuWatched -notmatch 'Invoke-AppDeployToolkit\.ps1') { Ok 'watched IU: install + uninstall through the runner (own process), PSADT Auto mode (no -DeployMode)' } else { Bad "watched IU shape: $iuWatched" }
# Unattended IU: Silent x2, Stop-Computer, 5 s flush, no -NoExit, no Countdown.
$iuUnattended = [regex]::Match($src, '(?s)else \{[^{]*?VSMB[^"]*?\$logonCommandXml = "(powershell\.exe -ExecutionPolicy[^"]+)"').Groups[1].Value
if ($iuUnattended -and $iuUnattended -notmatch '-NoExit' -and $iuUnattended -notmatch 'Countdown\.ps1') { Ok 'unattended IU: no -NoExit, no countdown' } else { Bad "unattended IU shape: $iuUnattended" }
if (([regex]::Matches($iuUnattended, '-DeployMode Silent')).Count -eq 2) { Ok 'unattended IU: install AND uninstall run Silent' } else { Bad 'missing Silent on a deploy' }
# Process isolation (TST-01): two runner calls, each -DeployMode Silent; the deploy script is never called
# directly in the LogonCommand process (a 'project:' dependency would already have loaded PSADT there).
$runnerSilent = [regex]::Matches($iuUnattended, 'C:\\PSADT\\Sandbox\\Invoke-PsadtPackage\.ps1 -DeploymentType (Install|Uninstall) -DeployMode Silent -Label app')
if ($runnerSilent.Count -eq 2 -and $runnerSilent[0].Groups[1].Value -eq 'Install' -and $runnerSilent[1].Groups[1].Value -eq 'Uninstall') { Ok 'unattended IU: two Invoke-PsadtPackage.ps1 ... -DeployMode Silent calls (install, then uninstall)' } else { Bad "runner calls: $($runnerSilent.Count) in $iuUnattended" }
if ($iuUnattended -notmatch 'Invoke-AppDeployToolkit\.ps1') { Ok 'unattended IU: no direct Invoke-AppDeployToolkit.ps1 call' } else { Bad "direct .ps1 call left: $iuUnattended" }
if ($iuUnattended -match 'Start-Sleep -Seconds 5; Stop-Computer -Force') { Ok 'unattended IU: 5 s VSMB flush then guest shutdown (guard clears for chained runs)' } else { Bad 'no flush+shutdown' }
if ($iuUnattended -match 'finally \{ C:\\PSADT\\Sandbox\\CollectLogs\.ps1') { Ok 'unattended IU: logs still collected before shutdown' } else { Bad 'CollectLogs lost' }

# Unattended Update: Silent on the PSADT update, shutdown, no countdown; assertions all still present.
$updUnattended = [regex]::Match($src, '(?s)Unattended: no -NoExit, no countdown, the PSADT update runs Silent.*?\$logonCommandXml = "(powershell\.exe -ExecutionPolicy[^"]+)"').Groups[1].Value
if ($updUnattended -and $updUnattended -notmatch 'Countdown\.ps1' -and $updUnattended -match "Invoke-PsadtPackage\.ps1' -DeploymentType Install -DeployMode Silent -Label update") { Ok 'unattended Update: countdown dropped, update runs Silent through the runner' } else { Bad "unattended Update shape: $updUnattended" }
if ($updUnattended -notmatch 'Invoke-AppDeployToolkit\.ps1') { Ok 'unattended Update: no direct deploy-script call in the LogonCommand process' } else { Bad "direct call left: $updUnattended" }
if ($updUnattended -match 'Start-Sleep -Seconds 5; Stop-Computer -Force') { Ok 'unattended Update: flush + shutdown kept' } else { Bad 'Update flush+shutdown lost' }
foreach ($phase in 'PreBaseline', 'PreUpdate', 'PostUpdate') {
    if ($updUnattended -match "-Phase $phase") { Ok "unattended Update still asserts $phase" } else { Bad "assertion $phase lost in unattended mode" }
}

# The guard now WAITS instead of throwing immediately.
if ($src -match 'Wait-Win32ToolkitSandboxFree -TimeoutSeconds 90') { Ok 'single-instance guard waits up to 90 s before failing' } else { Bad 'guard still throws immediately' }
# -BaselineInstallerType Both on watched Sandbox (installer-identity PR 1): the next leg waits for the operator to close
# the previous leg's sandbox, up to the helper's 600 s maximum.
if ($src -match 'Wait-Win32ToolkitSandboxFree -TimeoutSeconds 600') { Ok 'a Both leg on watched Sandbox waits up to 600 s for the previous sandbox' } else { Bad 'no 600 s wait between Both legs' }
# The documentation capture waits for a free Sandbox too, BEFORE it launches (test campaign 2026-10-21, S8-F4).
$ntdSrc = Get-Content -LiteralPath (Join-Path $repo 'Private\New-TargetedDocumentation.ps1') -Raw
$wIdx = $ntdSrc.IndexOf('Wait-Win32ToolkitSandboxFree -TimeoutSeconds 90'); $lIdx = $ntdSrc.IndexOf('Invoke-Win32ToolkitTestRun -Backend Sandbox')
if ($wIdx -ge 0 -and $lIdx -gt $wIdx) { Ok 'the capture waits for a free Sandbox (90 s) before Invoke-Win32ToolkitTestRun' } else { Bad "capture wait at $wIdx, launch at $lIdx" }

# ── (e) capture auto-close is mode-gated ───────────────────────────────────────────────────────────
# The duration now flows through the SHARED resolver (Get-Win32ToolkitTestMode), so -Unattended/config/
# host precedence cannot drift from the test scenarios; the resolver reads the shadowed config above.
Write-Host '[e] capture auto-close: 30 s watched / 5 s unattended' -ForegroundColor Cyan
. (Join-Path $repo 'Private\New-TargetedDocumentation.ps1')
function New-LogCollectorScript { param($ProjectPath) 'x' }
function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath) 0 }

$script:cfg.Clear()
$proj = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $proj 'Files') -Force | Out-Null
$null = New-TargetedDocumentation -ProjectPath $proj -ProjectName 'T' -Backend HyperV -SkipLaunch 6>$null
$gen = Get-Content -LiteralPath (Join-Path $proj 'SupportFiles\TargetedDocumentationScript.ps1') -Raw
if ($gen -match "\[int\]'30'" -and $gen -notmatch '__AUTOCLOSE__') { Ok 'watched default: 30 s auto-close (Ctrl+C inspect window kept)' } else { Bad 'watched auto-close wrong' }

$script:cfg['SandboxTestMode'] = 'Unattended'
$null = New-TargetedDocumentation -ProjectPath $proj -ProjectName 'T' -Backend HyperV -SkipLaunch 6>$null
$gen2 = Get-Content -LiteralPath (Join-Path $proj 'SupportFiles\TargetedDocumentationScript.ps1') -Raw
if ($gen2 -match "\[int\]'5'") { Ok 'unattended: 5 s auto-close (VSMB flush only)' } else { Bad 'unattended auto-close wrong' }
# And the generated script must still parse (placeholder replacement can't break the here-string).
$t=$null;$e=$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $proj 'SupportFiles\TargetedDocumentationScript.ps1'),[ref]$t,[ref]$e)
if (-not $e) { Ok 'generated guest script still parses cleanly' } else { Bad "guest script parse errors: $($e[0].Message)" }

# A non-interactive host forces Unattended (5 s), but the capture must NOT print the resolver's "this
# changes what is tested" warning: the capture always runs -DeployMode Silent, and on Hyper-V the warning
# would name the wrong backend.
$script:cfg.Clear()
$script:hostNonInteractive = $true
# Check the warning STREAM (what the operator sees), not -WarningVariable: an outer -WarningVariable also
# records nested warnings that were ignored and never displayed.
$capWarn = @(New-TargetedDocumentation -ProjectPath $proj -ProjectName 'T' -Backend HyperV -SkipLaunch 3>&1 6>$null |
    Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
$script:hostNonInteractive = $false
$gen3 = Get-Content -LiteralPath (Join-Path $proj 'SupportFiles\TargetedDocumentationScript.ps1') -Raw
if ($gen3 -match "\[int\]'5'" -and -not @($capWarn | Where-Object { "$_" -match 'changes what is tested' }).Count) { Ok 'non-interactive capture: 5 s auto-close, no misleading "changes what is tested" warning' }
else { Bad "non-interactive capture: autoclose5=$($gen3 -match "\[int\]'5'") warnings=$(@($capWarn) -join ' | ')" }
Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
