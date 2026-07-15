<#
    Unit tests for Test-Win32ToolkitProject InstallUninstall backend routing (Phase 5).
    Backend resolver, Hyper-V provider, log-collector, config and process/launch cmdlets are shadowed;
    no sandbox, no VM. Proves the single-instance guard is Sandbox-only and the Hyper-V phase spec is
    interactive by default / silent under -Unattended (or HyperVTestMode=Unattended).

    Run:  pwsh -File Tests\TestDispatch.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')

# --- shadows --------------------------------------------------------------------------------------
$script:backend  = 'HyperV'
$script:procs    = @()
$script:testMode = 'Interactive'
$script:hvCalled = 0
$script:hvPhase  = $null
$script:hvOutput = $null
$script:launched = 0

$script:depCount = 0
function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath) return $script:depCount }
# InstallUninstall now generates an assertion script + records an outcome (both scenarios). Shadow them so
# the dispatch tests exercise the phase/logon wiring without writing real assertion scripts or result files.
$script:installAssertGen = 0
$script:recorded = $null
function New-InstallAssertionScript { param($ProjectPath) $script:installAssertGen++; 'fake' }
function Write-Win32ToolkitTestOutcome { param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $LogFileName, $Notes) $script:recorded = @{ Scenario = $Scenario; Backend = $Backend; Mode = $Mode; LogFileName = $LogFileName } }
function Get-Win32ToolkitTestBackend { param($Backend) return $script:backend }
function Get-Process { param($Name, $ErrorAction) return $script:procs }
# The single-instance guard goes through the Phase-0 seam helper, NOT Get-Process directly. Without this
# shadow it throws "not recognized", and the Sandbox guard test would pass for the WRONG reason (an error,
# not a guard). Driven by the same $script:procs so every test below reads naturally.
function Test-Win32ToolkitSandboxRunning { return (@($script:procs).Count -gt 0) }
function New-LogCollectorScript { param($ProjectPath) return 'fake' }
function Get-Win32ToolkitConfigValue { param($Name, $Default) return $script:testMode }
function Invoke-Win32ToolkitHyperVRun { param($ProjectPath, $Phase, $Output) $script:hvCalled++; $script:hvPhase = $Phase; $script:hvOutput = $Output; return $true }
function Start-Process { param($FilePath, $ArgumentList) $script:launched++ }

# real temp project so the internal Test-Path / Split-Path succeed
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('w32td_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $proj -Force | Out-Null
function Run { param([hashtable]$P) $script:hvCalled = 0; $script:hvPhase = $null; $script:hvOutput = $null; $script:launched = 0; try { Test-Win32ToolkitProject @P *>$null } catch { } }
function Pauses { @($script:hvPhase | Where-Object { $_.Pause }).Count }
function Inters { @($script:hvPhase | Where-Object { $_.Interactive }).Count }

Write-Host '[1] HyperV skips the single-instance guard (runs even if a sandbox is "open")' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:procs = @([pscustomobject]@{ Name = 'WindowsSandbox' }); $script:testMode = 'Interactive'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if ($script:hvCalled -eq 1 -and $script:launched -eq 0) { Ok 'HyperV ran; no Sandbox guard, no WindowsSandbox.exe' } else { Bad "hvCalled=$script:hvCalled launched=$script:launched" }

Write-Host '[2] HyperV default = INTERACTIVE (GUI install + test pause + GUI uninstall)' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if ((Pauses) -ge 1 -and (Inters) -ge 2) { Ok 'interactive phases: a Pause + GUI install/uninstall' } else { Bad "pauses=$(Pauses) inter=$(Inters)" }
if ($script:hvOutput -contains 'Sandbox\Logs\*') { Ok 'collects Sandbox\Logs back' } else { Bad "output=$($script:hvOutput -join ',')" }

Write-Host '[3] HyperV -Unattended = SILENT (no pause, no interactive)' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall'; Unattended = $true }
if ((Pauses) -eq 0 -and (Inters) -eq 0 -and ($script:hvPhase.Label -contains 'Install')) { Ok 'silent back-to-back phases' } else { Bad "pauses=$(Pauses) inter=$(Inters) labels=$($script:hvPhase.Label -join ',')" }

Write-Host '[4] HyperVTestMode=Unattended config also forces silent' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Unattended'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if ((Pauses) -eq 0 -and (Inters) -eq 0) { Ok 'config Unattended honored' } else { Bad "pauses=$(Pauses) inter=$(Inters)" }

Write-Host '[5] Sandbox + a running sandbox = guard fires (no Hyper-V run, no launch)' -ForegroundColor Cyan
$script:backend = 'Sandbox'; $script:procs = @([pscustomobject]@{ Name = 'WindowsSandbox' })
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if ($script:hvCalled -eq 0 -and $script:launched -eq 0) { Ok 'guard blocked the run before launch' } else { Bad "hvCalled=$script:hvCalled launched=$script:launched" }

# --- Update scenario on Hyper-V -------------------------------------------------------------------
# Shadow the Update-scenario machinery so we reach the HyperV branch without winget/downloads.
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ Version = '1.0'; DisplayName = 'App' } } }
function Get-Win32ToolkitRequirementRule { param($ProjectPath) 'rule' }
function New-UpdateAssertionScript { param($ProjectPath, [switch]$SkipRequirement, $OldVersion, [switch]$ExpectBaselineTattoo) 'assert.ps1' }
function New-CountdownScript { param($ProjectPath) $script:countdownMade++; 'cd.ps1' }
$script:waitArgs = $null
function Wait-Win32ToolkitUpdateAssertion { param($ProjectPath, $Backend, $TimeoutMinutes, $PollSeconds, $LogFileName, $Label) $script:waitArgs = @{ Backend = $Backend; TimeoutMinutes = $TimeoutMinutes; LogFileName = $LogFileName }; return $true }
function Get-Win32ToolkitBaselineInstallCommand { param($InstallerSandboxPath, $InstallerType, $SilentArgs) "& '$InstallerSandboxPath'" }
$script:hvBaseline = $null
$script:hvCopiesLog = $true    # simulate the provider copying UpdateAssertions.log back out of the guest
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output, $BaselineProjectPath)
    $script:hvCalled++; $script:hvPhase = $Phase; $script:hvOutput = $Output; $script:hvBaseline = $BaselineProjectPath
    if ($script:hvCopiesLog) {
        $ld = Join-Path $ProjectPath 'Sandbox\Logs'
        New-Item -ItemType Directory -Path $ld -Force | Out-Null
        Set-Content -Path (Join-Path $ld 'UpdateAssertions.log') -Value 'ASSERT Tattoo = PASS'
    }
    return $true
}

# a baseline project so -BaselineProjectPath validates (needs Invoke-AppDeployToolkit.ps1 + differing path)
$base = Join-Path ([System.IO.Path]::GetTempPath()) ('w32base_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base -Force | Out-Null
Set-Content -Path (Join-Path $base 'Invoke-AppDeployToolkit.ps1') -Value '# psadt'

Write-Host '[6] Update + HyperV = full assertion phase sequence, host pause, no Countdown.ps1' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'; $script:countdownMade = 0
Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base }
$labels = @($script:hvPhase.Label)
$cmds   = @($script:hvPhase.Command) -join ' | '
if ($script:hvCalled -eq 1) { Ok 'Update routed to the Hyper-V provider' } else { Bad "hvCalled=$script:hvCalled" }
if ($cmds -match 'PreBaseline' -and $cmds -match 'PreUpdate' -and $cmds -match 'PostUpdate') { Ok 'PreBaseline/PreUpdate/PostUpdate assertions present' } else { Bad "cmds=$cmds" }
if ((Pauses) -eq 1) { Ok 'host Pause replaces the in-guest countdown' } else { Bad "pauses=$(Pauses)" }
if ($script:countdownMade -eq 0) { Ok 'Countdown.ps1 NOT generated for HyperV' } else { Bad 'Countdown.ps1 was generated' }
if ($script:hvBaseline -eq $base) { Ok 'baseline project forwarded (-> C:\PSADTOld)' } else { Bad "baseline=$script:hvBaseline" }
if ($labels -contains 'CollectLogs' -and $script:hvOutput -contains 'Sandbox\Logs\*') { Ok 'logs collected + copied back' } else { Bad "labels=$($labels -join ',')" }
# REGRESSION GUARDS for bugs found in review: without Interactive the provider never opens vmconnect
# (the pause would point at a window that doesn't exist), and PSADT as SYSTEM/session-0 needs an
# EXPLICIT -DeployMode (its interactive default only works on the Sandbox's real desktop).
if ((Inters) -ge 1) { Ok 'interactive Update marks phases Interactive (=> desktop + vmconnect)' } else { Bad "no Interactive phase — vmconnect would never open" }
if ($cmds -match '-DeployMode Interactive') { Ok 'update runs with an EXPLICIT -DeployMode Interactive' } else { Bad "update phase has no explicit DeployMode: $cmds" }
if ($script:waitArgs.Backend -eq 'HyperV' -and $script:waitArgs.TimeoutMinutes -le 1) { Ok 'waiter told HyperV + short timeout (no 30-min hang)' } else { Bad "waitArgs=$($script:waitArgs | Out-String)" }

Write-Host '[7] Update + HyperV + -Unattended = no pause, explicit SILENT deploy mode' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:countdownMade = 0
Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }
$cmds7 = @($script:hvPhase.Command) -join ' | '
if ((Pauses) -eq 0 -and $script:hvCalled -eq 1) { Ok 'silent Update run (no host pause)' } else { Bad "pauses=$(Pauses) hvCalled=$script:hvCalled" }
if ($cmds7 -match '-DeployMode Silent' -and (Inters) -eq 0) { Ok 'explicit -DeployMode Silent, no interactive phases' } else { Bad "cmds=$cmds7 inter=$(Inters)" }

Write-Host '[8] Update + HyperV but the assertions log never came back -> no 30-min hang' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:hvCopiesLog = $false; $script:waitArgs = $null
$verdict = $null
try { $verdict = Test-Win32ToolkitProject -ProjectPath $proj -Scenario 'Update' -BaselineProjectPath $base -Unattended *>$null } catch { }
if ($null -eq $script:waitArgs) { Ok 'waiter never entered (returns null instead of polling 30 min)' } else { Bad "waiter was called: $($script:waitArgs | Out-String)" }
$script:hvCopiesLog = $true

Write-Host '[9] declared dependencies install FIRST in BOTH scenarios' -ForegroundColor Cyan
$script:depCount = 1
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if (@($script:hvPhase)[0].Label -eq 'Install dependencies') { Ok 'InstallUninstall: dependency is the FIRST phase' } else { Bad "first=$(@($script:hvPhase)[0].Label)" }

Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }
$lbl = @($script:hvPhase | ForEach-Object { $_.Label })
if ($lbl[0] -eq 'Install dependencies' -and $lbl[1] -eq 'Assert: PreBaseline') {
    Ok 'Update: dependency runs BEFORE the PreBaseline snapshot (its ARP entry belongs to the baseline)'
} else { Bad "order=$($lbl -join ' > ')" }

$script:depCount = 0
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if (@($script:hvPhase)[0].Label -ne 'Install dependencies') { Ok 'none declared -> no dependency phase (unchanged behaviour)' } else { Bad 'phantom dependency phase' }

Write-Host '[10] SANDBOX backend: the .wsb LogonCommand also installs dependencies FIRST' -ForegroundColor Cyan
# The Hyper-V phase order is covered above, but the Sandbox path builds a LogonCommand STRING — a separate
# code path with its own ordering. Without this guard the dependency could be moved after the install (or
# after PreBaseline) on Sandbox and every test would still pass.
$script:logon = $null
function New-Win32ToolkitSandboxConfig { param($Mount, $LogonCommandXml) $script:logon = $LogonCommandXml; '<Configuration/>' }
function Invoke-Win32ToolkitTestRun { param($Backend, $SandboxConfigPath) [pscustomobject]@{ Launched = $true } }
function ConvertTo-XmlEncoded { param($Value) $Value }

$script:depCount = 1; $script:backend = 'Sandbox'; $script:procs = @()
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
$di = $script:logon.IndexOf('InstallDependencies.ps1')
$ai = $script:logon.IndexOf('Invoke-AppDeployToolkit.ps1')
if ($di -ge 0 -and $ai -gt $di) { Ok 'Sandbox InstallUninstall: dependencies before the app install' } else { Bad "logon=$script:logon" }

Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base }
$di = $script:logon.IndexOf('InstallDependencies.ps1')
$pb = $script:logon.IndexOf('PreBaseline')
if ($di -ge 0 -and $pb -gt $di) { Ok 'Sandbox Update: dependencies before the PreBaseline snapshot' } else { Bad "logon=$script:logon" }

$script:depCount = 0
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if ($script:logon -notmatch 'InstallDependencies') { Ok 'none declared -> no dependency step in the .wsb' } else { Bad 'phantom dependency step' }

Write-Host '[11] InstallUninstall now has real PASS/FAIL assertions wired on both backends' -ForegroundColor Cyan
# HyperV: the assertion script is generated, PostInstall/PostUninstall phases surround the install/uninstall,
# and the outcome is recorded as an InstallUninstall run.
$script:depCount = 0; $script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
$script:installAssertGen = 0; $script:recorded = $null
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
$iuLabels = @($script:hvPhase.Label)
if ($script:installAssertGen -ge 1) { Ok 'the install-assertion script is generated' } else { Bad 'New-InstallAssertionScript was not called' }
if ($iuLabels -contains 'Assert: installed' -and $iuLabels -contains 'Assert: uninstalled') { Ok 'PostInstall + PostUninstall assertion phases present' } else { Bad "labels=$($iuLabels -join ',')" }
$pi = [array]::IndexOf($iuLabels, 'Assert: installed'); $ui = [array]::IndexOf($iuLabels, 'Assert: uninstalled')
if ($pi -ge 0 -and $ui -gt $pi) { Ok 'installed-assert precedes uninstalled-assert' } else { Bad "order pi=$pi ui=$ui" }
if ($script:recorded -and $script:recorded.Scenario -eq 'InstallUninstall' -and $script:recorded.Backend -eq 'HyperV') { Ok 'the run is recorded for the docs (InstallUninstall/HyperV)' } else { Bad "recorded=$($script:recorded | Out-String)" }

# Sandbox: the .wsb LogonCommand runs both assertion phases, and the verdict waiter reads InstallAssertions.log.
$script:backend = 'Sandbox'; $script:procs = @(); $script:recorded = $null; $script:waitArgs = $null
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if ($script:logon -match 'InstallAssertions\.ps1 -Phase PostInstall' -and $script:logon -match 'InstallAssertions\.ps1 -Phase PostUninstall') { Ok 'Sandbox LogonCommand runs both assertion phases' } else { Bad "logon=$script:logon" }
$aiIdx = $script:logon.IndexOf('Invoke-AppDeployToolkit.ps1'); $paIdx = $script:logon.IndexOf('PostInstall')
if ($aiIdx -ge 0 -and $paIdx -gt $aiIdx) { Ok 'PostInstall assert runs AFTER the install' } else { Bad "logon order ai=$aiIdx pa=$paIdx" }
if ($script:waitArgs -and $script:waitArgs.LogFileName -eq 'InstallAssertions.log') { Ok 'the verdict waiter reads InstallAssertions.log' } else { Bad "waitArgs=$($script:waitArgs | Out-String)" }
if ($script:recorded -and $script:recorded.Scenario -eq 'InstallUninstall' -and $script:recorded.Backend -eq 'Sandbox') { Ok 'Sandbox run recorded for the docs' } else { Bad "recorded=$($script:recorded | Out-String)" }

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestDispatch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestDispatch test(s) FAILED." -ForegroundColor Red; exit 1 }
