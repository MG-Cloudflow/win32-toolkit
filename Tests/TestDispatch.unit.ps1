<#
    Unit tests for Test-Win32ToolkitProject InstallUninstall backend routing (Phase 5).
    Backend resolver, Hyper-V provider, log-collector, config and process/launch cmdlets are shadowed;
    no sandbox, no VM. Proves the single-instance guard is Sandbox-only and the Hyper-V phase spec is
    interactive by default / Intune-parity under -Unattended (or HyperVTestMode=Unattended), and that
    every PSADT package (app, Update baseline project) runs through the guest runner Invoke-PsadtPackage.ps1
    in its own process (no direct deploy-script call in a LogonCommand / phase process).

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

. (Join-Path $repo 'Private\Get-Win32ToolkitTestMode.ps1')          # mode resolver (Interactive/Unattended)
. (Join-Path $repo 'Private\Wait-Win32ToolkitSandboxFree.ps1')      # the guard now waits instead of throwing
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')
. (Join-Path $repo 'Private\Initialize-Win32ToolkitTestRunLog.ps1')   # C-9: each run keeps its logs in Sandbox\Logs\Runs\<run> (real)
. (Join-Path $repo 'Private\Save-Win32ToolkitTestRunLog.ps1')
function Wait-Win32ToolkitCollectedLog { param($TimeoutSeconds) $script:collectWaits += [int]$TimeoutSeconds; $true }   # no wait for a guest log collector
$script:collectWaits = @()
# Deterministic mode resolution regardless of the host running the tests (CI stdin is redirected,
# which would otherwise force Unattended and flip the interactive-default assertions below).
function Test-Win32ToolkitHostNonInteractive { $false }

# --- shadows --------------------------------------------------------------------------------------
$script:backend  = 'HyperV'
$script:procs    = @()
$script:testMode = 'Interactive'
$script:hvCalled = 0
$script:hvPhase  = $null
$script:hvOutput = $null
$script:launched = 0

$script:depCount = 0
$script:order = @()
function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath) $script:order += 'deps'; return $script:depCount }
# The guest package runner (one process per PSADT package) must be written before any scenario builds a
# command; record the call order (its content is covered by PackageRunner.unit.ps1). Defined through the
# function: drive, like a plain test double (PSScriptAnalyzer's ShouldProcess rule targets product code).
$script:runnerGen = 0
${function:New-Win32ToolkitPackageRunnerScript} = { param($ProjectPath) $script:runnerGen++; $script:order += 'runner'; Join-Path $ProjectPath 'Sandbox\Invoke-PsadtPackage.ps1' }
# InstallUninstall now generates an assertion script + records an outcome (both scenarios). Shadow them so
# the dispatch tests exercise the phase/logon wiring without writing real assertion scripts or result files.
$script:installAssertGen = 0
$script:recorded = $null
function New-InstallAssertionScript { param($ProjectPath) $script:installAssertGen++; 'fake' }
function Write-Win32ToolkitTestOutcome { param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $LogFileName, $Notes, $Baseline, $LogFolder) $script:recorded = @{ Scenario = $Scenario; Backend = $Backend; Mode = $Mode; LogFileName = $LogFileName; Baseline = $Baseline; LogFolder = $LogFolder } }
function Get-Win32ToolkitTestBackend { param($Backend) return $script:backend }
function Get-Process { param($Name, $ErrorAction) return $script:procs }
# The single-instance guard goes through the Phase-0 seam helper, NOT Get-Process directly. Without this
# shadow it throws "not recognized", and the Sandbox guard test would pass for the WRONG reason (an error,
# not a guard). Driven by the same $script:procs so every test below reads naturally.
function Test-Win32ToolkitSandboxRunning { return (@($script:procs).Count -gt 0) }
function New-LogCollectorScript { param($ProjectPath) return 'fake' }
function Get-Win32ToolkitConfigValue { param($Name, $Default) return $script:testMode }
function Invoke-Win32ToolkitHyperVRun { param($ProjectPath, $Phase, $Output) $script:hvCalled++; $script:order += 'hvrun'; $script:hvPhase = $Phase; $script:hvOutput = $Output; return $true }
function Start-Process { param($FilePath, $ArgumentList) $script:launched++ }

# real temp project so the internal Test-Path / Split-Path succeed
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('w32td_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $proj -Force | Out-Null
function Run { param([hashtable]$P) $script:hvCalled = 0; $script:hvPhase = $null; $script:hvOutput = $null; $script:launched = 0; $script:order = @(); $script:runnerGen = 0; try { Test-Win32ToolkitProject @P *>$null } catch { } }
$psadtOk = @(0, 1707, 3010, 1641)
function Test-CodesEqual($a) { (@($a) -join ',') -eq ($psadtOk -join ',') }
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
$gui2 = @($script:hvPhase | Where-Object { $_.Interactive -and $_.Command })
if ($gui2.Count -eq 2 -and @($gui2 | Where-Object { $_.Command -like "& 'C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1' -DeploymentType * -DeployMode Interactive -Label app; exit `$LASTEXITCODE" -and $_.Command -notmatch 'IntuneParity' -and (Test-CodesEqual $_.SuccessExitCodes) }).Count -eq 2) { Ok 'GUI phases run the package through the runner with -DeployMode Interactive (no parity), exact exit codes' } else { Bad "gui cmds: $(@($gui2.Command) -join ' | ')" }
if ($script:hvOutput -contains 'Sandbox\Logs\*') { Ok 'collects Sandbox\Logs back' } else { Bad "output=$($script:hvOutput -join ',')" }

Write-Host '[3] HyperV -Unattended = SILENT (no pause, no interactive)' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall'; Unattended = $true }
if ((Pauses) -eq 0 -and (Inters) -eq 0 -and ($script:hvPhase.Label -contains 'Install (Intune parity)')) { Ok 'silent back-to-back phases' } else { Bad "pauses=$(Pauses) inter=$(Inters) labels=$($script:hvPhase.Label -join ',')" }
# Intune parity (TST-02): the install AND uninstall run the published command line through the runner
# (-IntuneParity), end in 'exit $LASTEXITCODE' (literal) and judge their codes against the PSADT set.
$inst3 = @($script:hvPhase | Where-Object { $_.Label -eq 'Install (Intune parity)' })[0]
$unin3 = @($script:hvPhase | Where-Object { $_.Label -eq 'Uninstall (Intune parity)' })[0]
if ($inst3.Command -eq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Install -Label app; exit $LASTEXITCODE') { Ok 'unattended install = Intune-parity runner phase (exact command, literal $LASTEXITCODE)' } else { Bad "install cmd: $($inst3.Command)" }
if ($unin3.Command -eq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Uninstall -Label app; exit $LASTEXITCODE') { Ok 'unattended uninstall = Intune-parity runner phase' } else { Bad "uninstall cmd: $($unin3.Command)" }
if ((Test-CodesEqual $inst3.SuccessExitCodes) -and (Test-CodesEqual $unin3.SuccessExitCodes)) { Ok 'parity phases carry SuccessExitCodes 0,1707,3010,1641' } else { Bad "codes: $($inst3.SuccessExitCodes -join ',') / $($unin3.SuccessExitCodes -join ',')" }
$cmds3 = @($script:hvPhase.Command) -join ' | '
if ($cmds3 -notmatch 'Invoke-AppDeployToolkit\.ps1' -and $cmds3 -notmatch '-DeployMode') { Ok 'no direct deploy-script call and no -DeployMode on the parity phases (D6)' } else { Bad "cmds=$cmds3" }
if ($script:runnerGen -eq 1 -and (($script:order -join '>') -match '^runner>deps>hvrun$')) { Ok 'runner written BEFORE dependency staging and any phase' } else { Bad "order=$($script:order -join '>') gen=$script:runnerGen" }

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
# Installer-identity PR 1 (C-9): the Update arm records the baseline project's technology (its source facts), checks
# for a technology switch after a failed run, and resolves a winget baseline's technology before the version pick.
$script:baselineSource = [pscustomobject]@{ InstallerType = 'nullsoft'; Family = 'exe'; Scope = 'machine'; Locale = 'en-US' }
function Get-Win32ToolkitProjectSource { $script:baselineSource }
function Get-Win32ToolkitTechnologySwitch { @() }
function Resolve-Win32ToolkitBaselineFamily { [pscustomobject]@{ Family = 'msi'; InstallerType = 'wix'; Scope = ''; Origin = 'Packaged'; FallbackInstallerType = ''; FallbackScope = ''; Label = 'wix (MSI) (packaged technology)'; Note = '' } }
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
$upd6 = @($script:hvPhase | Where-Object { $_.Label -eq 'Update (PSADT GUI)' })[0]
if ($upd6.Command -eq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -DeploymentType Install -DeployMode Interactive -Label update; exit $LASTEXITCODE') { Ok 'interactive update goes through the runner (-Label update), no parity' } else { Bad "update cmd: $($upd6.Command)" }
$base6 = @($script:hvPhase | Where-Object { $_.Label -like 'Install baseline*' })[0]
if ($base6.Command -eq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -Path ''C:\PSADTOld\Invoke-AppDeployToolkit.ps1'' -DeployMode Silent -Label baseline; exit $LASTEXITCODE' -and (Test-CodesEqual $base6.SuccessExitCodes)) { Ok 'baseline project runs in its OWN process via the runner (-Label baseline), exact exit code' } else { Bad "baseline cmd: $($base6.Command)" }
if ($script:waitArgs.Backend -eq 'HyperV' -and $script:waitArgs.TimeoutMinutes -le 1) { Ok 'waiter told HyperV + short timeout (no 30-min hang)' } else { Bad "waitArgs=$($script:waitArgs | Out-String)" }
# The record names the baseline variant: a project baseline carries Source = project and that project's technology.
$bl6 = $script:recorded.Baseline
if ($bl6 -and $bl6.Source -eq 'project' -and $bl6.ProjectName -eq (Split-Path -Leaf $base) -and $bl6.Origin -eq 'Project' -and $bl6.InstallerType -eq 'nullsoft' -and $bl6.Family -eq 'exe' -and $bl6.Version -eq '1.0' -and $bl6.Unavailable -eq $false) { Ok 'the project-baseline record carries Baseline.Source = project, its folder leaf and its technology' } else { Bad "baseline record: $($bl6 | ConvertTo-Json -Compress)" }

Write-Host '[7] Update + HyperV + -Unattended = no pause, explicit SILENT deploy mode' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:countdownMade = 0
Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }
$cmds7 = @($script:hvPhase.Command) -join ' | '
if ((Pauses) -eq 0 -and $script:hvCalled -eq 1) { Ok 'silent Update run (no host pause)' } else { Bad "pauses=$(Pauses) hvCalled=$script:hvCalled" }
if ($cmds7 -match '-DeployMode Silent' -and (Inters) -eq 0) { Ok 'baseline runs -DeployMode Silent, no interactive phases' } else { Bad "cmds=$cmds7 inter=$(Inters)" }
$upd7 = @($script:hvPhase | Where-Object { $_.Label -eq 'Update (Intune parity)' })[0]
if ($upd7.Command -eq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Install -Label update; exit $LASTEXITCODE' -and (Test-CodesEqual $upd7.SuccessExitCodes)) { Ok 'unattended update = Intune-parity runner phase with exit $LASTEXITCODE' } else { Bad "update cmd: $($upd7.Command)" }
if ($cmds7 -notmatch "'C:\\PSADT\\Invoke-AppDeployToolkit\.ps1'") { Ok 'no direct call of the deploy script left in the Update phases' } else { Bad "cmds=$cmds7" }

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
if (@($script:hvPhase)[0].Command -eq '& ''C:\PSADT\Sandbox\InstallDependencies.ps1''; exit $LASTEXITCODE') { Ok 'dependency phase passes the script''s exact exit code (exit $LASTEXITCODE)' } else { Bad "dep cmd=$(@($script:hvPhase)[0].Command)" }

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
$ai = $script:logon.IndexOf('Invoke-PsadtPackage.ps1')
if ($di -ge 0 -and $ai -gt $di) { Ok 'Sandbox InstallUninstall: dependencies before the app install (runner)' } else { Bad "logon=$script:logon" }
# Process isolation (TST-01): the app's install and uninstall each go through the runner (own process),
# watched = Auto (no -DeployMode); the deploy script is never called directly in the LogonCommand process.
if ($script:logon -match [regex]::Escape('C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Install -Label app;') -and
    $script:logon -match [regex]::Escape('C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Uninstall -Label app;')) { Ok 'Sandbox IU: install + uninstall via the runner, watched = Auto (no -DeployMode)' } else { Bad "logon=$script:logon" }
if ($script:logon -notmatch 'Invoke-AppDeployToolkit\.ps1') { Ok 'Sandbox IU: no direct deploy-script call in the LogonCommand process' } else { Bad "logon=$script:logon" }

Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base }
$di = $script:logon.IndexOf('InstallDependencies.ps1')
$pb = $script:logon.IndexOf('PreBaseline')
if ($di -ge 0 -and $pb -gt $di) { Ok 'Sandbox Update: dependencies before the PreBaseline snapshot' } else { Bad "logon=$script:logon" }

# The baseline project chain (analysis 9.10): baseline and update each run in their OWN process through the
# runner; neither the old nor the new deploy script is dot-called in the LogonCommand process.
$script:depCount = 0
Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base }
$bl = $script:logon.IndexOf("Invoke-PsadtPackage.ps1' -Path 'C:\PSADTOld\Invoke-AppDeployToolkit.ps1' -DeployMode Silent -Label baseline")
$up = $script:logon.IndexOf("Invoke-PsadtPackage.ps1' -DeploymentType Install -Label update")
if ($bl -ge 0) { Ok 'Sandbox Update: baseline = runner -Path C:\PSADTOld\... -DeployMode Silent -Label baseline' } else { Bad "logon=$script:logon" }
if ($up -gt $bl) { Ok 'Sandbox Update: the update is a SEPARATE runner call (-Label update) after the baseline' } else { Bad "baseline=$bl update=$up logon=$script:logon" }
if ($script:logon -notmatch "(&|&amp;)\s*'C:\\PSADTOld\\Invoke-AppDeployToolkit\.ps1'" -and $script:logon -notmatch "(&|&amp;)\s*'C:\\PSADT\\Invoke-AppDeployToolkit\.ps1'") { Ok 'Sandbox Update: no direct & ''C:\PSADTOld\...ps1'' / & ''C:\PSADT\Invoke-AppDeployToolkit.ps1'' left' } else { Bad "logon=$script:logon" }
Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }
if ($script:logon -match [regex]::Escape("Invoke-PsadtPackage.ps1' -DeploymentType Install -DeployMode Silent -Label update") -and $script:logon -notmatch "(&|&amp;)\s*'C:\\PSADT(Old)?\\Invoke-AppDeployToolkit\.ps1'") { Ok 'Sandbox Update unattended: update via the runner -DeployMode Silent' } else { Bad "logon=$script:logon" }
$script:depCount = 1

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
$aiIdx = $script:logon.IndexOf('Invoke-PsadtPackage.ps1'); $paIdx = $script:logon.IndexOf('PostInstall')
if ($aiIdx -ge 0 -and $paIdx -gt $aiIdx) { Ok 'PostInstall assert runs AFTER the install' } else { Bad "logon order ai=$aiIdx pa=$paIdx" }
if ($script:waitArgs -and $script:waitArgs.LogFileName -eq 'InstallAssertions.log') { Ok 'the verdict waiter reads InstallAssertions.log' } else { Bad "waitArgs=$($script:waitArgs | Out-String)" }
if ($script:recorded -and $script:recorded.Scenario -eq 'InstallUninstall' -and $script:recorded.Backend -eq 'Sandbox') { Ok 'Sandbox run recorded for the docs' } else { Bad "recorded=$($script:recorded | Out-String)" }

Write-Host '[12] the runner''s exit codes are printed after a run; a previous run''s log is cleared first' -ForegroundColor Cyan
$script:depCount = 0; $script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
$logs12 = Join-Path $proj 'Sandbox\Logs'
New-Item -ItemType Directory -Path $logs12 -Force | Out-Null
$codes12 = Join-Path $logs12 'PsadtExitCodes.log'
Set-Content -LiteralPath $codes12 -Value '[2020-01-01 00:00:00] app Install parent=x64-direct exit=1 result=Failed STALE-RUN'
$script:staleSeen = $null
$script:hv12 = $null
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output, $BaselineProjectPath)
    $script:hv12 = @{ Phases = @($Phase).Count; Output = $Output; Baseline = $BaselineProjectPath }
    $f = Join-Path $ProjectPath 'Sandbox\Logs\PsadtExitCodes.log'
    $script:staleSeen = (Test-Path -LiteralPath $f) -and ((Get-Content -LiteralPath $f -Raw) -match 'STALE-RUN')
    Add-Content -LiteralPath $f -Value '[2026-10-15 10:00:00] app Install parent=x86-cmd exit=3010 result=SoftReboot'
    Add-Content -LiteralPath $f -Value '[2026-10-15 10:01:00] app Uninstall parent=x86-cmd exit=60008 result=Failed'
    $true
}
$out12 = @(Test-Win32ToolkitProject -ProjectPath $proj -Scenario 'InstallUninstall' -Unattended 6>&1 3>$null | ForEach-Object { "$_" })
if ($script:hv12 -and $script:hv12.Phases -ge 4 -and $script:hv12.Output -contains 'Sandbox\Logs\*' -and -not $script:hv12.Baseline) { Ok 'the run copies Sandbox\Logs back (where PsadtExitCodes.log lives)' } else { Bad "hv12=$($script:hv12 | Out-String)" }
if ($script:staleSeen -eq $false) { Ok 'a previous run''s PsadtExitCodes.log is cleared before the run' } else { Bad "stale log seen by the run: $script:staleSeen" }
if (($out12 -match 'app Install parent=x86-cmd exit=3010 result=SoftReboot') -and ($out12 -match 'app Uninstall parent=x86-cmd exit=60008 result=Failed')) { Ok 'both exit-code lines printed after the Hyper-V run' } else { Bad "output: $($out12 -join ' / ')" }
if (-not ($out12 -match 'STALE-RUN')) { Ok 'no stale line printed' } else { Bad 'stale line printed' }

Write-Host '[13] each run keeps its own logs in Sandbox\Logs\Runs\<run> (test campaign F2); a Both leg keeps the earlier lines' -ForegroundColor Cyan
# (a) Hyper-V: the run folder holds this run's two exit-code lines, the record names it, nothing waits for a guest collector.
$script:collectWaits = @(); $script:recorded = $null
Set-Content -LiteralPath $codes12 -Value '[2020-01-01 00:00:00] app Install parent=x64-direct exit=1 result=Failed STALE-RUN'
$out13 = @(Test-Win32ToolkitProject -ProjectPath $proj -Scenario 'InstallUninstall' -Unattended 6>&1 3>$null | ForEach-Object { "$_" })
$rf13 = [string]$script:recorded.LogFolder
$rfCodes = if ($rf13 -and (Test-Path -LiteralPath (Join-Path $proj "$rf13\PsadtExitCodes.log"))) { @(Get-Content -LiteralPath (Join-Path $proj "$rf13\PsadtExitCodes.log")) } else { @() }
if ($rf13 -match '^Sandbox\\Logs\\Runs\\\d{8}-\d{6}_InstallUninstall(-\d+)?$' -and $rfCodes.Count -eq 2 -and $rfCodes[0] -match 'exit=3010' -and $rfCodes[1] -match 'exit=60008') {
    Ok "Hyper-V: the record names the run folder ($rf13), which holds this run's two exit-code lines"
} else { Bad "hv run folder: '$rf13' codes=$($rfCodes -join ' | ')" }
if (@($script:collectWaits).Count -eq 0) { Ok 'Hyper-V: no wait for a guest log collector (the logs came back with the copy-out)' } else { Bad "collector waits: $($script:collectWaits -join ',')" }
if (@($out13 | Where-Object { $_ -like 'Run logs         : *' }).Count -eq 1) { Ok "the host prints 'Run logs : <folder>'" } else { Bad "no 'Run logs' line: $($out13 -join ' / ')" }
$top13 = @(Get-Content -LiteralPath $codes12)
if ($top13.Count -eq 3 -and $top13[0] -match '^\[[^\]]*\] -- test run \S+ --$' -and -not ($top13 -match 'STALE-RUN')) { Ok 'an outer call clears the exit-code log, then starts it with the run marker' } else { Bad "top: $($top13 -join ' | ')" }
# (b) a call made inside a Both leg (leg context set) keeps the earlier leg's lines and prints only its own.
Set-Content -LiteralPath $codes12 -Value '[2026-10-20 09:00:00] update Install parent=x86-cmd exit=0 result=Success EARLIER-LEG'
$script:W32TUpdateLegContext = @{ Mode = 'Both'; Origin = 'Sibling'; Index = 2; Count = 2 }
try { $out13b = @(Test-Win32ToolkitProject -ProjectPath $proj -Scenario 'InstallUninstall' -Unattended 6>&1 3>$null | ForEach-Object { "$_" }) }
finally { $script:W32TUpdateLegContext = $null }
$top13b = @(Get-Content -LiteralPath $codes12)
if ($top13b.Count -eq 4 -and $top13b[0] -match 'EARLIER-LEG' -and $top13b[1] -match ' -- test run ') { Ok 'inside a Both leg the exit-code log is NOT cleared: the earlier leg''s line stays, then this run''s marker' } else { Bad "leg top: $($top13b -join ' | ')" }
if (-not ($out13b -match 'EARLIER-LEG') -and ($out13b -match 'exit=3010 result=SoftReboot') -and -not ($out13b -match ' -- test run ')) { Ok 'only this run''s exit-code lines are printed (no earlier leg, no marker)' } else { Bad "leg output: $($out13b -join ' / ')" }
# (c) Sandbox: wait (60 s max) for the guest log collector before keeping the logs; no wait when the sandbox did not launch.
$script:backend = 'Sandbox'; $script:procs = @()
$script:sbLaunch = $true
function Invoke-Win32ToolkitTestRun {
    Set-Content -LiteralPath (Join-Path $proj 'Sandbox\Logs\InstallAssertions.log') -Value '[t] ASSERT InstallDetected-PostInstall = PASS'
    [pscustomobject]@{ Launched = $script:sbLaunch }
}
$script:collectWaits = @(); $script:recorded = $null
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
$rf13c = [string]$script:recorded.LogFolder
if (($script:collectWaits -join ',') -eq '60' -and $rf13c -and (Test-Path -LiteralPath (Join-Path $proj "$rf13c\InstallAssertions.log"))) { Ok 'Sandbox: waits up to 60 s for the collector, then keeps the run''s InstallAssertions.log in its folder' }
else { Bad "sandbox: waits=$($script:collectWaits -join ',') folder='$rf13c'" }
$script:sbLaunch = $false; $script:collectWaits = @()
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if (@($script:collectWaits).Count -eq 0) { Ok 'Sandbox did not launch -> no wait for a collector' } else { Bad "not launched: waits=$($script:collectWaits -join ',')" }
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestDispatch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestDispatch test(s) FAILED." -ForegroundColor Red; exit 1 }
