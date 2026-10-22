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
# Test shadows keep the real command names and signatures (C-4: no PSScriptAnalyzer warning in the suites).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitTestMode.ps1')          # mode resolver (Interactive/Unattended)
. (Join-Path $repo 'Private\Wait-Win32ToolkitSandboxFree.ps1')      # the guard now waits instead of throwing
function Get-Win32ToolkitSandboxEnvironment { $null }   # C-9: no wsb answer -> the process check decides (test campaign F1)
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')
# C-9 (installer-identity PR 2 follow-up F7): every test first asks for the uninstall cleanup paths Export refuses. No
# finding by default ([16] sets some); it records nothing in $script:order, so [3]'s call order stays as it is.
$script:cleanupCalls = 0
$script:cleanupFindings = @()
function Get-Win32ToolkitCleanupPathFinding { param($ProjectPath) $null = $ProjectPath; $script:cleanupCalls++; @($script:cleanupFindings) }
. (Join-Path $repo 'Private\Initialize-Win32ToolkitTestRunLog.ps1')   # C-9: each run keeps its logs in Sandbox\Logs\Runs\<run> (real)
. (Join-Path $repo 'Private\Save-Win32ToolkitTestRunLog.ps1')
function Wait-Win32ToolkitCollectedLog { param($TimeoutSeconds) $script:collectWaits += [int]$TimeoutSeconds; $true }   # no wait for a guest log collector
$script:collectWaits = @()
# Deterministic mode resolution regardless of the host running the tests (CI stdin is redirected,
# which would otherwise force Unattended and flip the interactive-default assertions below).
function Test-Win32ToolkitHostNonInteractive { $false }
function Test-Win32ToolkitNonInteractiveSwitch { $false }   # C-9: the Update version choice (test campaign F5)

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
function Write-Win32ToolkitTestOutcome { param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $LogFileName, $Notes, $Baseline, $LogFolder) $script:recorded = @{ Scenario = $Scenario; Backend = $Backend; Mode = $Mode; LogFileName = $LogFileName; Baseline = $Baseline; LogFolder = $LogFolder; Notes = $Notes } }
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
# C-9 (installer-identity PR 2): a Hyper-V UNATTENDED run asks the Intune-parity pre-check first. By default it does not
# block and found the PSADT 4.1 dialog risk (no processes to close; the install phase's 1460 hint is then 'Dialog41');
# a case sets $script:pre*.
$script:preCalls  = @()
$script:preBlocked = $false
$script:preShape  = 'Psadt41'
$script:preAtRisk = $true
$script:preProcessCount = 0
function Invoke-Win32ToolkitParityPrecheck {
    param($ProjectPath, $Scenario)
    $script:preCalls += "$Scenario|$ProjectPath"
    $script:order += 'pre'
    [pscustomobject]@{
        Blocked = $script:preBlocked; Risk = @{ AtRisk = $script:preAtRisk; Shape = $script:preShape; ProcessCount = $script:preProcessCount }; Guest = $null
        Message = $(if ($script:preBlocked) { 'PRECHECK-MESSAGE: was NOT started' } else { '' })
        Notes   = $(if ($script:preBlocked) { 'Not run (Intune-parity pre-check): PRECHECK-NOTES' } else { '' })
        NotRun  = $(if ($script:preBlocked) { @{ Code = 'PARITY-DIALOG-WAIT'; Shape = 'Psadt41'; ProcessesToClose = 0; Welcome = 'OrgUi'; SignedInSessions = 1 } } else { $null })
    }
}
$script:results = @()
function Add-Win32ToolkitTestResult {
    param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $Assertions, $Notes, $Baseline, $OldArpSurvivors, $LogFolder, [hashtable]$NotRun)
    $script:results += [pscustomobject]@{ Scenario = $Scenario; Backend = $Backend; Mode = $Mode; Verdict = $Verdict; Assertions = @($Assertions); Notes = $Notes; Baseline = $Baseline; NotRun = $NotRun }
}

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
# The 1460 hint key (installer-identity PR 2, L16) is for the Intune-parity phases only: no watched phase carries one.
if (@($script:hvPhase | Where-Object { $_.ContainsKey('ParityHint') }).Count -eq 0) { Ok 'watched (GUI, assertion, pause, log) phases carry no ParityHint' } else { Bad "hinted: $(@($script:hvPhase | Where-Object { $_.ContainsKey('ParityHint') } | ForEach-Object { $_.Label }) -join ',')" }
# F2 (installer-identity PR 2 follow-ups): only the unattended Intune-parity uninstall raises the runner limit; a watched
# run keeps the runner's 25 minutes (30 for the phase) on every phase.
$rtm2 = @($script:hvPhase | Where-Object { $_.ContainsKey('RunnerTimeoutMinutes') -or ([string]$_.Command) -match '-TimeoutMinutes' })
if ($rtm2.Count -eq 0) { Ok 'watched phases carry no RunnerTimeoutMinutes and pass no -TimeoutMinutes to the runner' } else { Bad "raised: $(@($rtm2.Label) -join ',')" }

Write-Host '[3] HyperV -Unattended = SILENT (no pause, no interactive)' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall'; Unattended = $true }
if ((Pauses) -eq 0 -and (Inters) -eq 0 -and ($script:hvPhase.Label -contains 'Install (Intune parity)')) { Ok 'silent back-to-back phases' } else { Bad "pauses=$(Pauses) inter=$(Inters) labels=$($script:hvPhase.Label -join ',')" }
# Intune parity (TST-02): the install AND uninstall run the published command line through the runner
# (-IntuneParity), end in 'exit $LASTEXITCODE' (literal) and judge their codes against the PSADT set.
$inst3 = @($script:hvPhase | Where-Object { $_.Label -eq 'Install (Intune parity)' })[0]
$unin3 = @($script:hvPhase | Where-Object { $_.Label -eq 'Uninstall (Intune parity)' })[0]
if ($inst3.Command -eq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Install -Label app; exit $LASTEXITCODE') { Ok 'unattended install = Intune-parity runner phase (exact command, literal $LASTEXITCODE)' } else { Bad "install cmd: $($inst3.Command)" }
if ($unin3.Command -eq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Uninstall -TimeoutMinutes 35 -Label app; exit $LASTEXITCODE') { Ok 'unattended uninstall = Intune-parity runner phase with the 35-minute runner limit (F2)' } else { Bad "uninstall cmd: $($unin3.Command)" }
# F2 (installer-identity PR 2 follow-ups, spec 1b): the Intune-parity uninstall outlives the device's 30-minute EXE
# uninstaller limit, so a hung uninstaller ends with 69113 as on a device. The phase key (the provider sets the phase
# backstop 5 minutes above it) and the runner's -TimeoutMinutes are the SAME host int; no other phase is raised.
if ($unin3.RunnerTimeoutMinutes -is [int] -and $unin3.RunnerTimeoutMinutes -eq 35) { Ok 'the uninstall phase carries RunnerTimeoutMinutes 35 (an int: the provider sets the backstop to 40)' } else { Bad "uninstall RunnerTimeoutMinutes: '$($unin3.RunnerTimeoutMinutes)'" }
if ([string]$unin3.Command -match '-TimeoutMinutes (\d+) ' -and [int]$Matches[1] -eq $unin3.RunnerTimeoutMinutes) { Ok 'the runner gets the same limit as the phase key' } else { Bad "runner limit vs key: '$($unin3.Command)' / '$($unin3.RunnerTimeoutMinutes)'" }
$rtm3 = @($script:hvPhase | Where-Object { $_.Label -ne 'Uninstall (Intune parity)' -and ($_.ContainsKey('RunnerTimeoutMinutes') -or ([string]$_.Command) -match '-TimeoutMinutes') })
if (-not $inst3.ContainsKey('RunnerTimeoutMinutes') -and $rtm3.Count -eq 0) { Ok 'the install, assertion and log phases keep the default limits (no key, no -TimeoutMinutes)' } else { Bad "raised: $(@($rtm3.Label) -join ',')" }
if ((Test-CodesEqual $inst3.SuccessExitCodes) -and (Test-CodesEqual $unin3.SuccessExitCodes)) { Ok 'parity phases carry SuccessExitCodes 0,1707,3010,1641' } else { Bad "codes: $($inst3.SuccessExitCodes -join ',') / $($unin3.SuccessExitCodes -join ',')" }
# 1460 hint keys (L16): a dialog cause on the install (PSADT 4.1 welcome named: the pre-check found that risk), the
# uninstaller on the uninstall; the assertion and log phases none.
if ($inst3.ParityHint -eq 'Dialog41' -and $unin3.ParityHint -eq 'Uninstaller') { Ok "parity phases carry ParityHint (install '$($inst3.ParityHint)', uninstall '$($unin3.ParityHint)')" } else { Bad "hints: install '$($inst3.ParityHint)' uninstall '$($unin3.ParityHint)'" }
$other3 = @($script:hvPhase | Where-Object { $_.Label -notlike '* (Intune parity)' -and $_.ContainsKey('ParityHint') })
if ($other3.Count -eq 0) { Ok 'the assertion and log phases carry no ParityHint' } else { Bad "hinted: $(@($other3.Label) -join ',')" }
$cmds3 = @($script:hvPhase.Command) -join ' | '
if ($cmds3 -notmatch 'Invoke-AppDeployToolkit\.ps1' -and $cmds3 -notmatch '-DeployMode') { Ok 'no direct deploy-script call and no -DeployMode on the parity phases (D6)' } else { Bad "cmds=$cmds3" }
if ($script:runnerGen -eq 1 -and (($script:order -join '>') -match '^pre>runner>deps>hvrun$')) { Ok 'the Intune-parity pre-check first, then the runner, BEFORE dependency staging and any phase' } else { Bad "order=$($script:order -join '>') gen=$script:runnerGen" }

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
if (@($script:hvPhase | Where-Object { $_.ContainsKey('ParityHint') }).Count -eq 0) { Ok 'watched Update phases carry no ParityHint' } else { Bad 'a watched Update phase carries a ParityHint' }
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
$hinted7 = @($script:hvPhase | Where-Object { $_.ContainsKey('ParityHint') })
if ($upd7.ParityHint -eq 'Dialog41' -and $hinted7.Count -eq 1) { Ok "only the Update (Intune parity) phase carries a ParityHint ('$($upd7.ParityHint)')" } else { Bad "hints: $(@($hinted7 | ForEach-Object { "$($_.Label)=$($_.ParityHint)" }) -join ',')" }
# F2 raises the limit of the Intune-parity UNINSTALL only: the Update phases keep the runner's 25 minutes.
$rtm7 = @($script:hvPhase | Where-Object { $_.ContainsKey('RunnerTimeoutMinutes') -or ([string]$_.Command) -match '-TimeoutMinutes' })
if ($rtm7.Count -eq 0) { Ok 'no Update phase carries RunnerTimeoutMinutes or passes -TimeoutMinutes to the runner' } else { Bad "raised: $(@($rtm7.Label) -join ',')" }

Write-Host '[8] Update + HyperV but the assertions log never came back -> no 30-min hang' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:hvCopiesLog = $false; $script:waitArgs = $null
$verdict = $null
try { $verdict = Test-Win32ToolkitProject -ProjectPath $proj -Scenario 'Update' -BaselineProjectPath $base -Unattended *>$null } catch { }
if ($null -eq $script:waitArgs) { Ok 'waiter never entered (returns null instead of polling 30 min)' } else { Bad "waiter was called: $($script:waitArgs | Out-String)" }
$script:hvCopiesLog = $true

# Installer-identity PR 2 follow-up R6 #3: a parity uninstall that ended with 69113 (the device's limit) and one that hit the
# test's own limit (1460) looked alike in TestResults.json. The provider fills the caller's list (-ParityExitNote) with one
# sentence per failed Intune-parity phase; the record's Notes carry them, joined by a space, after any note of its own.
Write-Host '[8b] Hyper-V: the record''s Notes say how each failed Intune-parity phase ended (69113 vs 1460, R6 #3)' -ForegroundColor Cyan
$savedHv8b = ${function:Invoke-Win32ToolkitHyperVRun}
$script:hvNotes8b = @()
$script:hvList8b = $null
$script:hvLog8b = $true
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output, $BaselineProjectPath, [System.Collections.Generic.List[string]]$ParityExitNote)
    $script:hvCalled++; $script:hvPhase = $Phase; $script:hvList8b = $ParityExitNote
    if ($null -ne $ParityExitNote) { foreach ($n in $script:hvNotes8b) { $ParityExitNote.Add($n) } }
    if ($script:hvLog8b) {
        $ld = Join-Path $ProjectPath 'Sandbox\Logs'
        New-Item -ItemType Directory -Path $ld -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ld 'UpdateAssertions.log') -Value '[t] ASSERT Tattoo-PostUpdate = PASS'
    }
    $true
}
$n69 = "Intune-parity phase 'Uninstall (Intune parity)' exited with code 69113: the app's own uninstaller was still running at the device's 30-minute limit and was stopped."
$n1460 = "Intune-parity phase 'Install (Intune parity)' exited with code 1460: the test's own 25-minute limit for this phase was reached and the package was stopped."
$nUpd = "Intune-parity phase 'Update (Intune parity)' exited with code 1603."
foreach ($case in @(
        @{ Tag = 'InstallUninstall unattended, 1460 install + 69113 uninstall'; P = @{ Scenario = 'InstallUninstall'; Unattended = $true }; Notes = @($n1460, $n69); Log = $true; Want = "$n1460 $n69" }
        @{ Tag = 'InstallUninstall unattended, no failed parity phase';       P = @{ Scenario = 'InstallUninstall'; Unattended = $true }; Notes = @();               Log = $true; Want = '' }
        @{ Tag = 'Update unattended, failed parity update';                   P = @{ Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }; Notes = @($nUpd); Log = $true;  Want = $nUpd }
        @{ Tag = 'Update unattended, no assertions log + failed update';      P = @{ Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }; Notes = @($nUpd); Log = $false; Want = "Assertions log did not return from the VM. $nUpd" }
        @{ Tag = 'Update unattended, no assertions log, no failed phase';     P = @{ Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }; Notes = @();      Log = $false; Want = 'Assertions log did not return from the VM.' })) {
    $script:backend = 'HyperV'; $script:testMode = 'Interactive'; $script:depCount = 0; $script:procs = @(); $script:recorded = $null; $script:hvCalled = 0
    $script:hvNotes8b = $case.Notes; $script:hvLog8b = $case.Log; $script:hvList8b = $null
    $p8b = @{ ProjectPath = $proj } + $case.P
    try { $null = Test-Win32ToolkitProject @p8b 3>$null 6>$null } catch { Bad "$($case.Tag): threw $($_.Exception.Message)" }
    $listOk = $script:hvList8b -is [System.Collections.Generic.List[string]]
    if ($script:hvCalled -eq 1 -and $listOk -and $null -ne $script:recorded -and $script:recorded.Backend -eq 'HyperV' -and [string]$script:recorded.Notes -ceq $case.Want) {
        Ok "$($case.Tag): the provider gets a list and the record's Notes are '$($case.Want)'"
    } else { Bad "$($case.Tag): hv=$script:hvCalled list=$listOk recorded=$($null -ne $script:recorded) notes='$($script:recorded.Notes)'" }
}
${function:Invoke-Win32ToolkitHyperVRun} = $savedHv8b   # the Update shadow of [6]-[8] again for the tests below

Write-Host '[9] declared dependencies install FIRST in BOTH scenarios' -ForegroundColor Cyan
$script:depCount = 1
$script:backend = 'HyperV'; $script:procs = @(); $script:testMode = 'Interactive'
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
if (@($script:hvPhase)[0].Label -eq 'Install dependencies') { Ok 'InstallUninstall: dependency is the FIRST phase' } else { Bad "first=$(@($script:hvPhase)[0].Label)" }
$depCmdIu = [string]@($script:hvPhase)[0].Command
if ($depCmdIu.StartsWith('& ''C:\PSADT\Sandbox\InstallDependencies.ps1''; $w32tDepRc = $LASTEXITCODE;') -and $depCmdIu.EndsWith('exit $w32tDepRc')) { Ok 'dependency phase passes the script''s exact exit code (exit $w32tDepRc)' } else { Bad "dep cmd=$depCmdIu" }
if ($depCmdIu -match [regex]::Escape('C:\PSADT\Sandbox\Logs\InstallAssertions.log') -and $depCmdIu -match 'DependenciesInstalled = FAIL' -and $depCmdIu -match 'RESULT COMPLETE') { Ok 'a failed dependency writes ASSERT DependenciesInstalled = FAIL + RESULT COMPLETE to InstallAssertions.log (S11-F1)' } else { Bad "dep cmd=$depCmdIu" }
if (@($script:hvPhase | Where-Object { $_.Label -eq 'CollectLogs' -and $_.Always }).Count -eq 1) { Ok 'CollectLogs is marked Always (it still runs after a failed dependency)' } else { Bad 'CollectLogs not Always' }
# Behaviour (S11-F1): run the generated phase command under Windows PowerShell 5.1 against a fake C:\PSADT whose
# InstallDependencies.ps1 fails with 60001 -> the exact code comes back and the assertion log says FAIL + COMPLETE.
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $ps51) {
    $fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32dep_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Sandbox') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeRoot 'Sandbox\InstallDependencies.ps1') -Value 'exit 60001' -Encoding ASCII
    $cmd = $depCmdIu.Replace('C:\PSADT', $fakeRoot)
    & $ps51 -NoProfile -ExecutionPolicy Bypass -Command $cmd | Out-Null
    $rcDep = $LASTEXITCODE
    $alog = Join-Path $fakeRoot 'Sandbox\Logs\InstallAssertions.log'
    $alines = if (Test-Path -LiteralPath $alog) { @(Get-Content -LiteralPath $alog) } else { @() }
    # Every line carries the '[yyyy-MM-dd HH:mm:ssZ] ' UTC prefix of the other assertion lines (re-verification
    # 2026-10-21, B3 #6: these two had none).
    $tsOk = $false
    if ($alines.Count -eq 2 -and $alines[0] -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)Z\] ASSERT DependenciesInstalled = FAIL \(exit 60001\)$') {
        $tsAt = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
        $tsOk = [math]::Abs(([datetime]::UtcNow - $tsAt).TotalSeconds) -lt 60 -and $alines[1] -match '^\[[^\]]+Z\] RESULT COMPLETE$'
    }
    if ($rcDep -eq 60001 -and $tsOk) { Ok 'Windows PowerShell 5.1: exit 60001 passed through; [<UTC>Z] FAIL + RESULT COMPLETE written (time within a minute of now)' } else { Bad "5.1 run: rc=$rcDep log=$($alines -join ' | ')" }
    Set-Content -LiteralPath (Join-Path $fakeRoot 'Sandbox\InstallDependencies.ps1') -Value 'exit 0' -Encoding ASCII
    Remove-Item -LiteralPath $alog -Force -ErrorAction SilentlyContinue
    & $ps51 -NoProfile -ExecutionPolicy Bypass -Command $cmd | Out-Null
    if ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $alog)) { Ok 'Windows PowerShell 5.1: a successful dependency writes nothing' } else { Bad "5.1 ok run: rc=$LASTEXITCODE log=$(Test-Path -LiteralPath $alog)" }
    Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base; Unattended = $true }
$lbl = @($script:hvPhase | ForEach-Object { $_.Label })
if ($lbl[0] -eq 'Install dependencies' -and $lbl[1] -eq 'Assert: PreBaseline') {
    Ok 'Update: dependency runs BEFORE the PreBaseline snapshot (its ARP entry belongs to the baseline)'
} else { Bad "order=$($lbl -join ' > ')" }
if ([string]@($script:hvPhase)[0].Command -match [regex]::Escape('C:\PSADT\Sandbox\Logs\UpdateAssertions.log') -and @($script:hvPhase | Where-Object { $_.Label -eq 'CollectLogs' -and $_.Always }).Count -eq 1) { Ok 'Update: a failed dependency writes to UpdateAssertions.log; CollectLogs is Always' } else { Bad "update dep cmd=$(@($script:hvPhase)[0].Command)" }

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
# A failed dependency stops the run before the app (S11-F1): the $LASTEXITCODE check sits between the two.
function Test-DepGuard([string]$Logon, [string]$LogName, [string]$Before) {
    $d = $Logon.IndexOf('InstallDependencies.ps1'); $g = $Logon.IndexOf('if ($LASTEXITCODE -ne 0)'); $r = $Logon.IndexOf('return }'); $b = $Logon.IndexOf($Before)
    $d -ge 0 -and $g -gt $d -and $r -gt $g -and $b -gt $r -and $Logon.Contains("C:\PSADT\Sandbox\Logs\$LogName") -and $Logon.Contains('DependenciesInstalled = FAIL') -and $Logon.Contains('RESULT COMPLETE')
}
if (Test-DepGuard $script:logon 'InstallAssertions.log' 'Invoke-PsadtPackage.ps1') { Ok 'Sandbox IU watched: a failed dependency writes FAIL + COMPLETE and returns before the app install' } else { Bad "logon=$script:logon" }
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall'; Unattended = $true }
if ((Test-DepGuard $script:logon 'InstallAssertions.log' 'Invoke-PsadtPackage.ps1') -and $script:logon -match 'finally \{ C:\\PSADT\\Sandbox\\CollectLogs\.ps1; Start-Sleep -Seconds 5; Stop-Computer -Force') { Ok 'Sandbox IU unattended: the same guard; the finally still collects logs and shuts down' } else { Bad "logon=$script:logon" }
# The guarded step parses under Windows PowerShell 5.1 once the XML entities are decoded.
$step = $script:logon.Substring($script:logon.IndexOf('&amp; ''C:\PSADT\Sandbox\InstallDependencies.ps1'''))
$step = $step.Substring(0, $step.IndexOf('return };') + 'return };'.Length).Replace('&amp;', '&')
$pe = $null; [void][System.Management.Automation.Language.Parser]::ParseInput("& { try { $step } finally { } }", [ref]$null, [ref]$pe)
if (-not $pe -or $pe.Count -eq 0) { Ok 'the guarded dependency step parses' } else { Bad "parse: $($pe[0].Message)" }
# ...and, run under Windows PowerShell 5.1 against a fake C:\PSADT whose dependency fails, writes both lines with the
# UTC prefix (re-verification 2026-10-21, B3 #6) and returns before anything after it.
if (Test-Path -LiteralPath $ps51) {
    $fakeSb = Join-Path ([System.IO.Path]::GetTempPath()) ('w32depsb_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    try {
        New-Item -ItemType Directory -Path (Join-Path $fakeSb 'Sandbox') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fakeSb 'Sandbox\InstallDependencies.ps1') -Value 'exit 60001' -Encoding ASCII
        $sbScript = Join-Path $fakeSb 'step.ps1'
        Set-Content -LiteralPath $sbScript -Encoding UTF8 -Value ("& { try { " + $step.Replace('C:\PSADT', $fakeSb) + " 'AFTER' | Set-Content -LiteralPath '" + (Join-Path $fakeSb 'after.txt') + "' } finally { } }")
        & $ps51 -NoProfile -ExecutionPolicy Bypass -File $sbScript | Out-Null
        $sbLines = @(Get-Content -LiteralPath (Join-Path $fakeSb 'Sandbox\Logs\InstallAssertions.log') -ErrorAction SilentlyContinue)
        if ($sbLines.Count -eq 2 -and $sbLines[0] -match '^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ\] ASSERT DependenciesInstalled = FAIL \(exit 60001\)$' -and $sbLines[1] -match '^\[[^\]]+Z\] RESULT COMPLETE$' -and -not (Test-Path -LiteralPath (Join-Path $fakeSb 'after.txt'))) {
            Ok 'Sandbox step under Windows PowerShell 5.1: [<UTC>Z] FAIL + RESULT COMPLETE written, nothing after it ran'
        } else { Bad "Sandbox 5.1 step: lines=$($sbLines -join ' | ') after=$(Test-Path -LiteralPath (Join-Path $fakeSb 'after.txt'))" }
    }
    finally { Remove-Item -LiteralPath $fakeSb -Recurse -Force -ErrorAction SilentlyContinue }
}
Run @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }   # back to the watched LogonCommand for the checks below
# Process isolation (TST-01): the app's install and uninstall each go through the runner (own process),
# watched = Auto (no -DeployMode); the deploy script is never called directly in the LogonCommand process.
if ($script:logon -match [regex]::Escape('C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Install -Label app;') -and
    $script:logon -match [regex]::Escape('C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Uninstall -Label app;')) { Ok 'Sandbox IU: install + uninstall via the runner, watched = Auto (no -DeployMode)' } else { Bad "logon=$script:logon" }
if ($script:logon -notmatch 'Invoke-AppDeployToolkit\.ps1') { Ok 'Sandbox IU: no direct deploy-script call in the LogonCommand process' } else { Bad "logon=$script:logon" }

Run @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $base }
$di = $script:logon.IndexOf('InstallDependencies.ps1')
$pb = $script:logon.IndexOf('PreBaseline')
if ($di -ge 0 -and $pb -gt $di) { Ok 'Sandbox Update: dependencies before the PreBaseline snapshot' } else { Bad "logon=$script:logon" }
if (Test-DepGuard $script:logon 'UpdateAssertions.log' 'PreBaseline') { Ok 'Sandbox Update: a failed dependency writes FAIL + COMPLETE to UpdateAssertions.log and returns before PreBaseline' } else { Bad "logon=$script:logon" }

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
# An unattended run announces no countdown (test campaign 2026-10-21): the scenario header is mode-neutral.
$sc12 = @($out12 | Where-Object { $_ -like '*Scenario:*' })
if ($sc12.Count -eq 1 -and $sc12[0].Trim() -eq 'Scenario: Install → Uninstall' -and ($out12 -match 'Running an UNATTENDED Install')) { Ok "unattended header: '$($sc12[0].Trim())' (no countdown claimed)" } else { Bad "scenario header: $($sc12 -join ' | ')" }

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

# A W32T.* error inside the command (a declared dependency that cannot be staged) reaches the caller as a
# TERMINATING error with its own id - not a non-terminating Write-Error and a $null verdict that Finalize would
# package anyway (re-verification 2026-10-21, B3 #1). Nothing reaches a guest.
Write-Host '[14] W32T.DependencyNotStaged from the staging stops the call as a terminating W32T error (C-2)' -ForegroundColor Cyan
$savedStaging14 = ${function:Initialize-Win32ToolkitDependencyStaging}
foreach ($be in 'HyperV', 'Sandbox') {
    $script:backend = $be; $script:procs = @(); $script:testMode = 'Unattended'; $script:hvCalled = 0; $script:launched = 0
    function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath)
        throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("Dependency 'project:Contoso\Missing' of $ProjectPath could not be staged: the project was not found."), 'W32T.DependencyNotStaged', [System.Management.Automation.ErrorCategory]::ObjectNotFound, 'project:Contoso\Missing')
    }
    $out14 = 'not-set'; $e14 = $null; $ev14 = $null
    try { $out14 = Test-Win32ToolkitProject -ProjectPath $proj -Scenario InstallUninstall -ErrorAction Continue -ErrorVariable ev14 *>$null } catch { $e14 = $_ }
    $nonTerm14 = @($ev14 | Where-Object { "$($_.FullyQualifiedErrorId)" -like '*WriteErrorException*' })
    if ($e14 -and $e14.FullyQualifiedErrorId -eq 'W32T.DependencyNotStaged' -and $out14 -eq 'not-set' -and $nonTerm14.Count -eq 0 -and $script:hvCalled -eq 0 -and $script:launched -eq 0) {
        Ok "$be`: terminating W32T.DependencyNotStaged (no Write-Error, no verdict returned), no guest started"
    } else { Bad "$be`: caught='$($e14.FullyQualifiedErrorId)' out='$out14' writeErrors=$($nonTerm14.Count) hv=$script:hvCalled launched=$script:launched" }
}
# A non-W32T error keeps the Write-Error behaviour (non-terminating under -ErrorAction Continue).
$script:backend = 'HyperV'
function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath) throw "disk full (plain error) for $ProjectPath" }
$e14b = $null; $ev14b = $null
try { $null = Test-Win32ToolkitProject -ProjectPath $proj -Scenario InstallUninstall -ErrorAction SilentlyContinue -ErrorVariable ev14b *>$null } catch { $e14b = $_ }
if (-not $e14b -and @($ev14b | Where-Object { "$_" -match 'Test-Win32ToolkitProject failed: disk full' }).Count -ge 1) { Ok 'a plain error is still a non-terminating "Test-Win32ToolkitProject failed: ..." (unchanged)' } else { Bad "plain: caught='$e14b' ev=[$(@($ev14b) -join ' | ')]" }
${function:Initialize-Win32ToolkitDependencyStaging} = $savedStaging14

# Installer-identity PR 2 (A1 hv r1.2): an unattended Hyper-V run of a package that would only wait on a PSADT 4.1
# dialog is NOT started - warning first, one Inconclusive record with NotRun, $null. Watched runs and Sandbox never ask.
Write-Host '[15] Hyper-V unattended InstallUninstall: the Intune-parity pre-check runs first; a blocked run is not started' -ForegroundColor Cyan
$script:depCount = 0; $script:procs = @(); $script:testMode = 'Interactive'
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output, $BaselineProjectPath)
    $script:hvCalled++; $script:hvPhase = $Phase
    $ld = Join-Path $ProjectPath 'Sandbox\Logs'
    New-Item -ItemType Directory -Path $ld -Force | Out-Null
    Set-Content -Path (Join-Path $ld 'UpdateAssertions.log') -Value 'ASSERT Tattoo = PASS'
    $true
}
$isStream = { param($o) $o -is [System.Management.Automation.WarningRecord] -or $o -is [System.Management.Automation.InformationRecord] }
# (a) blocked
$script:backend = 'HyperV'; $script:preBlocked = $true; $script:preShape = 'Psadt41'
$script:preCalls = @(); $script:results = @(); $script:recorded = $null; $script:hvCalled = 0
$script:order = @(); $script:runnerGen = 0; $script:installAssertGen = 0; $script:depCount = 1
# The previous run's top-level logs: a blocked run must leave them as they are (live P5: it removed these two).
$logs15 = Join-Path $proj 'Sandbox\Logs'
New-Item -ItemType Directory -Path $logs15 -Force | Out-Null
foreach ($n in 'PsadtExitCodes.log', 'InstallAssertions.log') { Set-Content -LiteralPath (Join-Path $logs15 $n) -Value "previous run: $n" }
$all15 = @(Test-Win32ToolkitProject -ProjectPath $proj -Scenario InstallUninstall -Unattended 3>&1 6>&1)
$script:depCount = 0
if (($script:order -join '>') -eq 'pre' -and $script:runnerGen -eq 0 -and $script:installAssertGen -eq 0) { Ok 'blocked: asked before anything is written or staged (no runner script, no dependency staging, no assertion script)' } else { Bad "blocked order=$($script:order -join '>') runner=$script:runnerGen assert=$script:installAssertGen" }
if (@('PsadtExitCodes.log', 'InstallAssertions.log' | Where-Object { (Get-Content -LiteralPath (Join-Path $logs15 $_) -Raw -ErrorAction SilentlyContinue) -match "previous run: $([regex]::Escape($_))" }).Count -eq 2) { Ok 'blocked: the previous run''s top-level exit-code and assertion logs are left in place' } else { Bad 'blocked: a previous top-level log was cleared' }
foreach ($n in 'PsadtExitCodes.log', 'InstallAssertions.log') { Remove-Item -LiteralPath (Join-Path $logs15 $n) -Force -ErrorAction SilentlyContinue }
$lines15 = @($all15 | Where-Object { & $isStream $_ } | ForEach-Object { "$_" })
$ret15 = @($all15 | Where-Object { -not (& $isStream $_) -and $null -ne $_ })
if (($script:preCalls -join ';') -eq "InstallUninstall|$proj") { Ok 'the pre-check is asked once, for this project and InstallUninstall' } else { Bad "pre-check calls: $($script:preCalls -join ';')" }
if ($script:hvCalled -eq 0 -and $ret15.Count -eq 0) { Ok 'blocked: Invoke-Win32ToolkitHyperVRun is NOT called and the call returns $null' } else { Bad "blocked: hvCalled=$script:hvCalled returned=[$($ret15 -join ',')]" }
$r15 = @($script:results)
if ($r15.Count -eq 1 -and $r15[0].Scenario -eq 'InstallUninstall' -and $r15[0].Backend -eq 'HyperV' -and $r15[0].Mode -eq 'Unattended' -and $r15[0].Verdict -eq 'Inconclusive' -and
    @($r15[0].Assertions).Count -eq 0 -and $r15[0].Notes -eq 'Not run (Intune-parity pre-check): PRECHECK-NOTES' -and $r15[0].NotRun.Code -eq 'PARITY-DIALOG-WAIT' -and $null -eq $r15[0].Baseline) {
    Ok 'one Inconclusive InstallUninstall/HyperV/Unattended record with the pre-check''s Notes and NotRun, no assertions'
} else { Bad "records: $($r15 | ConvertTo-Json -Compress -Depth 4)" }
if ($null -eq $script:recorded) { Ok 'the outcome writer (which reads the assertions log) is not used for it' } else { Bad 'Write-Win32ToolkitTestOutcome was called' }
$wAt = [array]::IndexOf($lines15, 'PRECHECK-MESSAGE: was NOT started')
$nrAt = [array]::IndexOf($lines15, 'Install/uninstall test: NOT RUN (Intune-parity pre-check).')
if ($wAt -ge 0 -and $nrAt -gt $wAt -and -not ($lines15 -match 'Running an UNATTENDED')) { Ok 'the pre-check warning comes first, then ''NOT RUN''; no ''Running an UNATTENDED'' line' } else { Bad "lines: $($lines15 -join ' / ')" }
# (b) not blocked: the run starts once; the install phase's 1460 hint follows the pre-check's risk (AtRisk, never the shape
# alone: a PSADT 4.1 project that lists a process to close, or whose welcome cannot defer, gets the generic text), the
# uninstall one does not
foreach ($case in @(
        @{ Shape = 'Psadt41';           AtRisk = $true;  ProcessCount = 0; Hint = 'Dialog41'; Why = 'at risk (nobody signed in)' }
        @{ Shape = 'Psadt41';           AtRisk = $false; ProcessCount = 1; Hint = 'Dialog';   Why = 'lists a process to close' }
        @{ Shape = 'Psadt41';           AtRisk = $false; ProcessCount = 0; Hint = 'Dialog';   Why = 'welcome cannot defer' }
        @{ Shape = 'Psadt42ZeroConfig'; AtRisk = $false; ProcessCount = 0; Hint = 'Dialog';   Why = 'PSADT 4.2' })) {
    $script:preBlocked = $false; $script:preShape = $case.Shape; $script:preAtRisk = $case.AtRisk; $script:preProcessCount = $case.ProcessCount
    $script:preCalls = @(); $script:results = @(); $script:hvCalled = 0
    $null = Test-Win32ToolkitProject -ProjectPath $proj -Scenario InstallUninstall -Unattended 3>$null 6>$null
    $i15 = @($script:hvPhase | Where-Object { $_.Label -eq 'Install (Intune parity)' })[0]
    $u15 = @($script:hvPhase | Where-Object { $_.Label -eq 'Uninstall (Intune parity)' })[0]
    if ($script:preCalls.Count -eq 1 -and $script:hvCalled -eq 1 -and $i15.ParityHint -eq $case.Hint -and $u15.ParityHint -eq 'Uninstaller' -and $script:results.Count -eq 0) {
        Ok "not blocked, $($case.Shape) $($case.Why) (ProcessCount $($case.ProcessCount)): the run starts once; install hint '$($case.Hint)', uninstall 'Uninstaller'"
    } else { Bad "$($case.Shape) $($case.Why): pre=$($script:preCalls.Count) hv=$script:hvCalled install='$($i15.ParityHint)' uninstall='$($u15.ParityHint)' records=$($script:results.Count)" }
}
$script:preAtRisk = $true; $script:preProcessCount = 0
# (c) watched Hyper-V and Sandbox (watched or unattended) never ask, for either scenario
$base15 = Join-Path ([System.IO.Path]::GetTempPath()) ('w32base_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base15 -Force | Out-Null
Set-Content -Path (Join-Path $base15 'Invoke-AppDeployToolkit.ps1') -Value '# psadt'
$script:preBlocked = $true
foreach ($case in @(
        @{ Backend = 'HyperV';  Mode = 'Interactive'; P = @{ Scenario = 'InstallUninstall' } }
        @{ Backend = 'HyperV';  Mode = 'Interactive'; P = @{ Scenario = 'Update'; BaselineProjectPath = $base15 } }
        @{ Backend = 'Sandbox'; Mode = 'Interactive'; P = @{ Scenario = 'InstallUninstall'; Unattended = $true } }
        @{ Backend = 'Sandbox'; Mode = 'Interactive'; P = @{ Scenario = 'Update'; BaselineProjectPath = $base15; Unattended = $true } }
        @{ Backend = 'Sandbox'; Mode = 'Interactive'; P = @{ Scenario = 'InstallUninstall' } })) {
    $script:backend = $case.Backend; $script:testMode = $case.Mode; $script:preCalls = @(); $script:results = @()
    $p15 = @{ ProjectPath = $proj } + $case.P
    Run $p15
    $tag = "$($case.Backend) $($case.P.Scenario) $(if ($case.P.Unattended) { 'unattended' } else { 'watched' })"
    if ($script:preCalls.Count -eq 0 -and $script:results.Count -eq 0) { Ok "${tag}: no pre-check, nothing recorded as not run" } else { Bad "${tag}: pre-check calls=$($script:preCalls.Count) records=$($script:results.Count)" }
}
$script:preBlocked = $false; $script:preShape = 'Psadt41'; $script:backend = 'HyperV'
Remove-Item -LiteralPath $base15 -Recurse -Force -ErrorAction SilentlyContinue

# Installer-identity PR 2 follow-up F7 (P3-guard-sb #2): a project whose uninstall cleanup paths Export refuses is still
# tested, after ONE warning with Export's own findings, on every backend and in every mode; Export stays the only hard stop.
Write-Host '[16] cleanup paths Export refuses: one warning with its findings first, then the test runs (F7)' -ForegroundColor Cyan
$script:depCount = 0; $script:procs = @(); $script:preBlocked = $false; $script:preAtRisk = $true
function Invoke-Win32ToolkitTestRun {
    param($Backend, $SandboxConfigPath)
    $script:launched++
    New-Item -ItemType Directory -Path (Join-Path $proj 'Sandbox\Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $proj 'Sandbox\Logs\InstallAssertions.log') -Value '[t] ASSERT InstallDetected-PostInstall = PASS'
    [pscustomobject]@{ Launched = $true }
}
$unsafe16 = @([pscustomobject]@{ Kind = 'CleanupPath'; Message = 'UNSAFE-A' }, [pscustomobject]@{ Kind = 'CleanupPath'; Message = 'UNSAFE-B' })
$head16 = 'Export refuses this project (2 uninstall cleanup-path finding(s)); the test runs anyway. '
$run16 = {
    param([string]$Backend, [bool]$Unattended, $Findings)
    $script:backend = $Backend; $script:testMode = 'Interactive'
    $script:cleanupFindings = @($Findings); $script:cleanupCalls = 0; $script:hvCalled = 0; $script:launched = 0
    $p = @{ ProjectPath = $proj; Scenario = 'InstallUninstall' }
    if ($Unattended) { $p['Unattended'] = $true }
    $all = @(Test-Win32ToolkitProject @p 3>&1 6>&1)
    $lines = @($all | Where-Object { & $isStream $_ } | ForEach-Object { "$_" })
    $warnAt = -1; $startAt = -1; $preAt = -1
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($warnAt -lt 0 -and $lines[$k].StartsWith('Export refuses this project')) { $warnAt = $k }
        if ($startAt -lt 0 -and $lines[$k] -match '^\s*(Running an|Launching)') { $startAt = $k }
        if ($preAt -lt 0 -and $lines[$k] -eq 'PRECHECK-MESSAGE: was NOT started') { $preAt = $k }
    }
    [pscustomobject]@{
        Warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and "$_".StartsWith('Export refuses this project') } | ForEach-Object { "$_" })
        WarnAt = $warnAt; StartAt = $startAt; PreAt = $preAt; Ran = $script:hvCalled + $script:launched; Calls = $script:cleanupCalls
    }
}
foreach ($case in @(
        @{ Tag = 'Hyper-V watched';    Backend = 'HyperV';  Unattended = $false }
        @{ Tag = 'Hyper-V unattended'; Backend = 'HyperV';  Unattended = $true }
        @{ Tag = 'Sandbox unattended'; Backend = 'Sandbox'; Unattended = $true })) {
    $r16 = & $run16 $case.Backend $case.Unattended $unsafe16
    $w16 = if ($r16.Warnings.Count) { $r16.Warnings[0] } else { '' }
    if ($r16.Warnings.Count -eq 1 -and $w16.StartsWith($head16) -and $w16.Contains('UNSAFE-A') -and $w16.Contains('UNSAFE-B') -and $w16.EndsWith('the uninstall of an older project deletes them there.')) {
        Ok "$($case.Tag): exactly one 'Export refuses this project (2 ...)' warning with both of Export's findings"
    } else { Bad "$($case.Tag): warnings=$($r16.Warnings -join ' | ')" }
    if ($r16.WarnAt -ge 0 -and $r16.StartAt -gt $r16.WarnAt -and $r16.Ran -eq 1 -and $r16.Calls -eq 1) { Ok "$($case.Tag): the warning comes before the run starts, the test still runs, one finding check" }
    else { Bad "$($case.Tag): warnAt=$($r16.WarnAt) startAt=$($r16.StartAt) ran=$($r16.Ran) calls=$($r16.Calls)" }
    $r16n = & $run16 $case.Backend $case.Unattended @()
    if ($r16n.Warnings.Count -eq 0 -and $r16n.Ran -eq 1 -and $r16n.Calls -eq 1) { Ok "$($case.Tag): no finding -> no such warning, the test runs" } else { Bad "$($case.Tag) clean: warnings=$($r16n.Warnings.Count) ran=$($r16n.Ran) calls=$($r16n.Calls)" }
}
# Before the Intune-parity pre-check too (Fd3): a run the pre-check does not start still shows the finding first.
$script:preBlocked = $true; $script:results = @()
$r16p = & $run16 'HyperV' $true $unsafe16
$script:preBlocked = $false; $script:results = @()
if ($r16p.Warnings.Count -eq 1 -and $r16p.WarnAt -ge 0 -and $r16p.PreAt -gt $r16p.WarnAt -and $r16p.Ran -eq 0) { Ok 'Hyper-V unattended, not started by the pre-check: the cleanup-path warning still comes first' }
else { Bad "pre-check blocked: warnings=$($r16p.Warnings.Count) warnAt=$($r16p.WarnAt) preAt=$($r16p.PreAt) ran=$($r16p.Ran)" }
# Once per outer call: a call made inside an Update 'Both' leg (leg context set) does not check again.
$script:W32TUpdateLegContext = @{ Mode = 'Both'; Origin = 'Sibling'; Index = 2; Count = 2 }
try { $r16l = & $run16 'HyperV' $true $unsafe16 }
finally { $script:W32TUpdateLegContext = $null }
if ($r16l.Calls -eq 0 -and $r16l.Warnings.Count -eq 0 -and $r16l.Ran -eq 1) { Ok 'inside a Both leg: no second check, no second warning (the outer call already warned)' } else { Bad "leg: calls=$($r16l.Calls) warnings=$($r16l.Warnings.Count) ran=$($r16l.Ran)" }
$script:cleanupFindings = @(); $script:backend = 'HyperV'

Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestDispatch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestDispatch test(s) FAILED." -ForegroundColor Red; exit 1 }
