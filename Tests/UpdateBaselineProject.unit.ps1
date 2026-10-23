<#
    -BaselineProject : the Update test can name a LOCAL packaged project as the old-version baseline by a
    friendly '<Template>\<Name>' reference (or 'project:<Template>\<Name>'), resolved to
    <BasePath>\Projects\<Template>\<Name> — exactly how a 'project:' dependency is referenced — instead of
    the full -BaselineProjectPath. It resolves into $BaselineProjectPath and then flows through the SAME
    validation + delivery + install machinery.

    The whole guest run is shadowed (Invoke-Win32ToolkitHyperVRun captures the resolved baseline path); the
    ref parser and the paths helper are the real ones. No sandbox, no VM, no BasePath registry write.

    Run:  pwsh -File Tests\UpdateBaselineProject.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitDependencyRef.ps1')   # real parser (project:/winget:/bare)
. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')                 # real tier resolver
. (Join-Path $repo 'Private\Get-Win32ToolkitTestMode.ps1')              # mode resolver (Interactive/Unattended)
. (Join-Path $repo 'Private\Wait-Win32ToolkitSandboxFree.ps1')          # the guard now waits instead of throwing
function Get-Win32ToolkitSandboxEnvironment { $null }   # C-9: no wsb answer -> the process check decides (test campaign F1)
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')
# C-9 (speed-up PR 3): TestProjectLease On would take the project's lease; inert doubles (never a lock file), never used while
# the config reads return the test modes.
function Enter-Win32ToolkitHyperVLease { param($VMName, $VMId, $ProjectPath, $Purpose) [pscustomobject]@{ Kind = 'Project'; Epoch = 'inert'; Generation = 1; PreviousGeneration = 0; Nested = $false } }
function Exit-Win32ToolkitHyperVLease { param($Lease) }
# C-9 (installer-identity PR 2 follow-up F7): every test first asks for the uninstall cleanup paths Export refuses (none here).
$script:cleanupCalls = 0
$script:cleanupFindings = @()
function Get-Win32ToolkitCleanupPathFinding { param($ProjectPath) $null = $ProjectPath; $script:cleanupCalls++; @($script:cleanupFindings) }
. (Join-Path $repo 'Private\Initialize-Win32ToolkitTestRunLog.ps1')   # C-9: each run keeps its logs in Sandbox\Logs\Runs\<run> (real)
. (Join-Path $repo 'Private\Save-Win32ToolkitTestRunLog.ps1')
function Wait-Win32ToolkitCollectedLog { param($TimeoutSeconds) $script:collectWaits += [int]$TimeoutSeconds; $true }   # no wait for a guest log collector
$script:collectWaits = @()
# Deterministic on any host (CI stdin is redirected, which would otherwise force Unattended).
function Test-Win32ToolkitHostNonInteractive { $false }
function Test-Win32ToolkitNonInteractiveSwitch { $false }   # C-9: the Update version choice (test campaign F5)

# --- BasePath + a real packaged baseline under <base>\Projects\<Template>\<Name> -------------------
$script:base = Join-Path ([System.IO.Path]::GetTempPath()) ('w32bp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$TEMPLATE = 'Contoso'
$NAME     = 'Git_x64_2.53.0'
$baseProj = Join-Path $script:base (Join-Path 'Projects' (Join-Path $TEMPLATE $NAME))
New-Item -ItemType Directory -Path (Join-Path $baseProj 'SupportFiles') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $baseProj 'Invoke-AppDeployToolkit.ps1') -Value '# psadt baseline'

# project UNDER TEST (a different folder)
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ut_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $proj -Force | Out-Null
Set-Content -LiteralPath (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') -Value '# psadt under test'

# --- shadows (mirrors TestDispatch.unit.ps1's Update-on-HyperV set) --------------------------------
$script:baseNull = $false   # simulate an unconfigured BasePath (NonInteractive -> $null)
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure, [switch]$NonInteractive, $Set) if ($script:baseNull) { $null } else { $script:base } }
function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath) 0 }
# The guest package runner is generated before every scenario (PackageRunner.unit.ps1 covers it). Defined
# through the function: drive, like a plain test double (the ShouldProcess lint rule targets product code).
${function:New-Win32ToolkitPackageRunnerScript} = { param($ProjectPath) Join-Path $ProjectPath 'Sandbox\Invoke-PsadtPackage.ps1' }
function Get-Win32ToolkitTestBackend { param($Backend) 'HyperV' }
function Get-Win32ToolkitConfigValue { param($Name, $Default) 'Interactive' }
function New-LogCollectorScript { param($ProjectPath) 'fake' }
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ Version = '1.0'; DisplayName = 'App' } } }
function Get-Win32ToolkitRequirementRule { param($ProjectPath) 'rule' }
function New-UpdateAssertionScript { param($ProjectPath, [switch]$SkipRequirement, $OldVersion, [switch]$ExpectBaselineTattoo) 'assert.ps1' }
function New-CountdownScript { param($ProjectPath) 'cd.ps1' }
function Get-Win32ToolkitBaselineInstallCommand { param($InstallerSandboxPath, $InstallerType, $SilentArgs) "& '$InstallerSandboxPath'" }
function Wait-Win32ToolkitUpdateAssertion { param($ProjectPath, $Backend, $TimeoutMinutes, $PollSeconds, $LogFileName, $Label) $true }
# The Update arm now records its outcome via this helper — shadow it (and keep the baseline it records).
$script:recordedBaseline = $null
function Write-Win32ToolkitTestOutcome { param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $LogFileName, $Notes, $Baseline) $script:recordedBaseline = $Baseline }
# Installer-identity PR 1 (C-9): the project baseline's technology for the record, the technology-switch check
# after a failed run (never reached here: the waiter passes).
$script:sourceCalls = 0
function Get-Win32ToolkitProjectSource { $script:sourceCalls++; [pscustomobject]@{ InstallerType = 'inno'; Family = 'exe'; Scope = 'machine'; Locale = '' } }
function Get-Win32ToolkitTechnologySwitch { @() }
function Resolve-Win32ToolkitBaselineFamily { throw 'a project baseline never resolves a winget baseline technology' }
# C-9 (installer-identity PR 2): an unattended Hyper-V Update asks the Intune-parity pre-check before the baseline is
# touched. Not blocked by default (PSADT 4.1 dialog risk found, no processes to close); [5] blocks it, or clears the
# risk. A blocked run is recorded directly.
$script:preBlocked = $false
$script:preAtRisk  = $true
$script:preProcessCount = 0
$script:preCalls   = @()
$script:prePaths   = @()
function Invoke-Win32ToolkitParityPrecheck {
    param($ProjectPath, $Scenario)
    $script:preCalls += $Scenario
    $script:prePaths += $ProjectPath
    [pscustomobject]@{
        Blocked = $script:preBlocked; Risk = @{ AtRisk = $script:preAtRisk; Shape = 'Psadt41'; ProcessCount = $script:preProcessCount }; Guest = $null
        Message = $(if ($script:preBlocked) { 'PRECHECK-MESSAGE' } else { '' }); Notes = $(if ($script:preBlocked) { 'Not run (Intune-parity pre-check): x' } else { '' })
        NotRun  = $(if ($script:preBlocked) { @{ Code = 'PARITY-DIALOG-WAIT'; Shape = 'Psadt41'; ProcessesToClose = 0; Welcome = 'Script'; SignedInSessions = 1 } } else { $null })
    }
}
$script:results = @()
function Add-Win32ToolkitTestResult {
    param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $Assertions, $Notes, $Baseline, $OldArpSurvivors, $LogFolder, [hashtable]$NotRun)
    $script:results += [pscustomobject]@{ Scenario = $Scenario; Backend = $Backend; Mode = $Mode; Verdict = $Verdict; Baseline = $Baseline; NotRun = $NotRun; HasBaseline = $PSBoundParameters.ContainsKey('Baseline') }
}

$script:hvBaseline = $null
$script:hvCalled   = 0
$script:hvPhase    = $null
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output, $BaselineProjectPath)
    $script:hvCalled++
    $script:hvPhase = $Phase
    $script:hvBaseline = $BaselineProjectPath
    $ld = Join-Path $ProjectPath 'Sandbox\Logs'
    New-Item -ItemType Directory -Path $ld -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ld 'UpdateAssertions.log') -Value 'ASSERT Tattoo = PASS'
    $true
}

# helper: run and detect a rejection (the function's top-level catch turns a guard `throw` into a
# terminating Write-Error under $ErrorActionPreference='Stop'; the message carries the guard text).
function ExpectThrow {
    param([hashtable]$P, [string]$Needle)
    $script:hvCalled = 0; $script:hvBaseline = $null
    $msg = $null
    try { Test-Win32ToolkitProject @P *>$null } catch { $msg = $_.Exception.Message }
    return ($null -ne $msg -and $msg -like "*$Needle*" -and $script:hvCalled -eq 0)
}

$EXPECTED = Join-Path (Join-Path (Join-Path $script:base 'Projects') $TEMPLATE) $NAME

# ══ [1] resolves a friendly ref and forwards the resolved path ════════════════════════════════════
Write-Host '[1] -BaselineProject ''<Template>\<Name>'' resolves under Projects\ and feeds the baseline path' -ForegroundColor Cyan
$script:hvCalled = 0; $script:hvBaseline = $null
Test-Win32ToolkitProject -ProjectPath $proj -Scenario Update -BaselineProject "$TEMPLATE\$NAME" *>$null
if ($script:hvCalled -eq 1) { Ok 'the Update run reached the provider (validation + resolution passed)' } else { Bad "hvCalled=$script:hvCalled (validation/resolution rejected a valid ref)" }
if ($script:hvBaseline -eq $EXPECTED) { Ok "forwarded the resolved baseline path ($EXPECTED)" } else { Bad "baseline=$script:hvBaseline expected=$EXPECTED" }
$rb = $script:recordedBaseline
if ($rb -and $rb.Source -eq 'project' -and $rb.ProjectName -eq $NAME -and $rb.Origin -eq 'Project' -and $rb.Mode -eq 'Auto' -and $rb.InstallerType -eq 'inno' -and $rb.Family -eq 'exe') { Ok 'the record''s Baseline says Source = project, the project''s folder leaf and its technology' } else { Bad "recorded baseline: $($rb | ConvertTo-Json -Compress)" }

# ══ [2] the 'project:' prefix form is accepted identically ════════════════════════════════════════
Write-Host '[2] -BaselineProject ''project:<Template>\<Name>'' resolves the same way' -ForegroundColor Cyan
$script:hvCalled = 0; $script:hvBaseline = $null
Test-Win32ToolkitProject -ProjectPath $proj -Scenario Update -BaselineProject "project:$TEMPLATE\$NAME" *>$null
if ($script:hvBaseline -eq $EXPECTED) { Ok 'the project: prefix resolves to the same path' } else { Bad "baseline=$script:hvBaseline" }

# ══ [3] guards ════════════════════════════════════════════════════════════════════════════════════
Write-Host '[3] mutual-exclusion + resolution guards throw clearly' -ForegroundColor Cyan
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\$NAME"; BaselineProjectPath = $baseProj } 'mutually exclusive') { Ok '-BaselineProject + -BaselineProjectPath -> throws (use one)' } else { Bad 'both baseline params were accepted together' }
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\$NAME"; VersionsBack = 1 } 'mutually exclusive') { Ok '-BaselineProject + -VersionsBack -> throws' } else { Bad '-VersionsBack accepted with -BaselineProject' }
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\$NAME"; SpecificVersion = '2.0' } 'mutually exclusive') { Ok '-BaselineProject + -SpecificVersion -> throws' } else { Bad '-SpecificVersion accepted with -BaselineProject' }

# a bare winget-looking ref (no backslash) is NOT a project reference
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = 'Microsoft.Something' } 'packaged project') { Ok 'a non-project ref (no ''\'') is rejected with a clear message' } else { Bad 'a winget-shaped ref was accepted as a baseline project' }

# a project ref that does not exist under Projects\
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\DoesNotExist_x64_9.9" } 'not found under Projects') { Ok 'an unresolved project ref -> clear "not found, package it first" error' } else { Bad 'a missing baseline project did not error clearly' }

# a FULL PATH passed to -BaselineProject (contains '\' so it parses as a project ref) must not be joined onto Projects\
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = 'C:\Win32Apps\Contoso\Git_x64_2.53.0' } 'not a full path') { Ok 'an absolute path -> rejected, points at -BaselineProjectPath (no garbage doubled path)' } else { Bad 'a full path was joined onto Projects\ into a garbage path' }

# a directory-traversal ref is rejected
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\..\..\Windows" } 'not a full path') { Ok 'a ..\ traversal ref is rejected' } else { Bad 'a traversal ref was accepted' }

# ══ [3b] Update-only params with a non-Update scenario throw instead of silently no-op'ing ═════════
Write-Host '[3b] baseline/version params with -Scenario InstallUninstall are rejected (not silently ignored)' -ForegroundColor Cyan
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'InstallUninstall'; BaselineProject = "$TEMPLATE\$NAME" } 'apply only to -Scenario Update') { Ok '-BaselineProject + InstallUninstall -> clear "Update only" error' } else { Bad '-BaselineProject silently ignored under InstallUninstall' }
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'InstallUninstall'; VersionsBack = 1 } 'apply only to -Scenario Update') { Ok '-VersionsBack + InstallUninstall -> rejected too (fixes the pre-existing silent no-op)' } else { Bad '-VersionsBack silently ignored under InstallUninstall' }

# ══ [3b2] -BaselineInstallerType applies to a winget baseline only ════════════════════════════════════
Write-Host '[3b2] -BaselineInstallerType with a baseline project: only Auto (the default) is accepted' -ForegroundColor Cyan
$techNeedle = '-BaselineInstallerType applies to a winget baseline; the baseline project has its own technology.'
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\$NAME"; BaselineInstallerType = 'nullsoft' } $techNeedle) { Ok '-BaselineProject + -BaselineInstallerType nullsoft -> the new error, before anything runs' } else { Bad '-BaselineInstallerType accepted with -BaselineProject' }
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProjectPath = $baseProj; BaselineInstallerType = 'Both' } $techNeedle) { Ok '-BaselineProjectPath + -BaselineInstallerType Both -> the new error' } else { Bad '-BaselineInstallerType accepted with -BaselineProjectPath' }
$script:hvCalled = 0
Test-Win32ToolkitProject -ProjectPath $proj -Scenario Update -BaselineProject "$TEMPLATE\$NAME" -BaselineInstallerType Auto *>$null
if ($script:hvCalled -eq 1) { Ok 'an explicit -BaselineInstallerType Auto (the default) is accepted with a baseline project' } else { Bad 'explicit Auto rejected with a baseline project' }
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'InstallUninstall'; BaselineInstallerType = 'Auto' } 'apply only to -Scenario Update') { Ok '-BaselineInstallerType + InstallUninstall -> the Update-only error' } else { Bad '-BaselineInstallerType silently ignored under InstallUninstall' }

# ══ [3c] an unconfigured BasePath fails clearly instead of prompting ═══════════════════════════════
Write-Host '[3c] -BaselineProject with no configured BasePath -> clear error (never a Read-Host hang)' -ForegroundColor Cyan
$script:baseNull = $true
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\$NAME" } 'configured BasePath') { Ok 'unconfigured BasePath -> actionable error, no interactive prompt' } else { Bad 'unconfigured BasePath did not fail clearly' }
$script:baseNull = $false

# ══ [4] the resolved baseline still goes through the existing validation ═══════════════════════════
Write-Host '[4] a resolved ref that is not a real PSADT project is rejected by the existing validation' -ForegroundColor Cyan
# create a Projects\<T>\<bad> folder WITHOUT Invoke-AppDeployToolkit.ps1
$badName = 'Bad_x64_1.0'
New-Item -ItemType Directory -Path (Join-Path $script:base (Join-Path 'Projects' (Join-Path $TEMPLATE $badName))) -Force | Out-Null
if (ExpectThrow @{ ProjectPath = $proj; Scenario = 'Update'; BaselineProject = "$TEMPLATE\$badName" } 'no Invoke-AppDeployToolkit.ps1') { Ok 'resolved-but-not-a-PSADT-project -> existing validation still fires' } else { Bad 'a non-PSADT folder passed as a baseline' }

# ══ [5] Intune-parity pre-check (installer-identity PR 2, A1 hv r1.2) ═══════════════════════════════
Write-Host '[5] an unattended Hyper-V Update with a project baseline asks the pre-check first; a blocked run is not started' -ForegroundColor Cyan
$script:preBlocked = $true; $script:preCalls = @(); $script:prePaths = @(); $script:results = @(); $script:hvCalled = 0; $script:sourceCalls = 0; $script:recordedBaseline = $null
$ret5 = 'not-set'
$ret5 = Test-Win32ToolkitProject -ProjectPath $proj -Scenario Update -BaselineProject "$TEMPLATE\$NAME" -Unattended 3>$null 6>$null
if (($script:preCalls -join ',') -eq 'Update' -and ($script:prePaths -join ',') -eq $proj -and $script:hvCalled -eq 0 -and $script:sourceCalls -eq 0 -and $null -eq $ret5) { Ok 'blocked: pre-check asked once, for the project under test (not the baseline); no baseline copy (no run), the baseline project is not read; returns $null' } else { Bad "blocked: pre=$($script:preCalls -join ',') hv=$script:hvCalled source=$script:sourceCalls ret=$ret5" }
$r5 = @($script:results)
if ($r5.Count -eq 1 -and $r5[0].Scenario -eq 'Update' -and $r5[0].Backend -eq 'HyperV' -and $r5[0].Mode -eq 'Unattended' -and $r5[0].Verdict -eq 'Inconclusive' -and $r5[0].NotRun.Code -eq 'PARITY-DIALOG-WAIT' -and -not $r5[0].HasBaseline -and $null -eq $script:recordedBaseline) {
    Ok 'one Update record with NotRun and no Baseline (the outcome writer is not used)'
} else { Bad "records: $($r5 | ConvertTo-Json -Compress -Depth 4)" }
$script:preBlocked = $false; $script:preCalls = @(); $script:results = @(); $script:hvCalled = 0
$null = Test-Win32ToolkitProject -ProjectPath $proj -Scenario Update -BaselineProject "$TEMPLATE\$NAME" -Unattended 3>$null 6>$null
$upd5 = @($script:hvPhase | Where-Object { $_.Label -eq 'Update (Intune parity)' })[0]
if ($script:preCalls.Count -eq 1 -and $script:hvCalled -eq 1 -and $script:hvBaseline -eq $EXPECTED -and $upd5.ParityHint -eq 'Dialog41' -and $script:results.Count -eq 0) { Ok "not blocked: today's flow (baseline forwarded); the Update (Intune parity) phase carries ParityHint 'Dialog41'" } else { Bad "not blocked: pre=$($script:preCalls.Count) hv=$script:hvCalled baseline=$script:hvBaseline hint='$($upd5.ParityHint)' records=$($script:results.Count)" }
# A PSADT 4.1 project that lists a process to close is not at risk: the generic 'Dialog' hint, not the 4.1 welcome text (L16).
$script:preAtRisk = $false; $script:preProcessCount = 1; $script:preCalls = @(); $script:results = @(); $script:hvCalled = 0; $script:hvPhase = $null
$null = Test-Win32ToolkitProject -ProjectPath $proj -Scenario Update -BaselineProject "$TEMPLATE\$NAME" -Unattended 3>$null 6>$null
$upd5b = @($script:hvPhase | Where-Object { $_.Label -eq 'Update (Intune parity)' })[0]
if ($script:preCalls.Count -eq 1 -and $script:hvCalled -eq 1 -and $upd5b.ParityHint -eq 'Dialog') { Ok "not at risk (PSADT 4.1, a process to close): the Update (Intune parity) phase carries the generic 'Dialog' hint" } else { Bad "not at risk: pre=$($script:preCalls.Count) hv=$script:hvCalled hint='$($upd5b.ParityHint)'" }
$script:preAtRisk = $true; $script:preProcessCount = 0
$script:preCalls = @()
Test-Win32ToolkitProject -ProjectPath $proj -Scenario Update -BaselineProject "$TEMPLATE\$NAME" *>$null
if ($script:preCalls.Count -eq 0) { Ok 'a watched Hyper-V Update never asks the pre-check' } else { Bad "watched: pre=$($script:preCalls.Count)" }

Remove-Item -LiteralPath $script:base, $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All UpdateBaselineProject tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail UpdateBaselineProject test(s) FAILED." -ForegroundColor Red; exit 1 }
