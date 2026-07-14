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

function Get-Win32ToolkitTestBackend { param($Backend) return $script:backend }
function Get-Process { param($Name, $ErrorAction) return $script:procs }
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
function Wait-Win32ToolkitUpdateAssertion { param($ProjectPath) return $true }
function Get-Win32ToolkitBaselineInstallCommand { param($InstallerSandboxPath, $InstallerType, $SilentArgs) "& '$InstallerSandboxPath'" }
$script:hvBaseline = $null
function Invoke-Win32ToolkitHyperVRun { param($ProjectPath, $Phase, $Output, $BaselineProjectPath) $script:hvCalled++; $script:hvPhase = $Phase; $script:hvOutput = $Output; $script:hvBaseline = $BaselineProjectPath; return $true }

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

Write-Host '[7] Update + HyperV + -Unattended = no pause' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:countdownMade = 0
Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }
if ((Pauses) -eq 0 -and $script:hvCalled -eq 1) { Ok 'silent Update run (no host pause)' } else { Bad "pauses=$(Pauses) hvCalled=$script:hvCalled" }

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestDispatch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestDispatch test(s) FAILED." -ForegroundColor Red; exit 1 }
