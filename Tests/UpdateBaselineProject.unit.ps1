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
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')
# Deterministic on any host (CI stdin is redirected, which would otherwise force Unattended).
function Test-Win32ToolkitHostNonInteractive { $false }

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
function Get-Win32ToolkitTestBackend { param($Backend) 'HyperV' }
function Get-Win32ToolkitConfigValue { param($Name, $Default) 'Interactive' }
function New-LogCollectorScript { param($ProjectPath) 'fake' }
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ Version = '1.0'; DisplayName = 'App' } } }
function Get-Win32ToolkitRequirementRule { param($ProjectPath) 'rule' }
function New-UpdateAssertionScript { param($ProjectPath, [switch]$SkipRequirement, $OldVersion, [switch]$ExpectBaselineTattoo) 'assert.ps1' }
function New-CountdownScript { param($ProjectPath) 'cd.ps1' }
function Get-Win32ToolkitBaselineInstallCommand { param($InstallerSandboxPath, $InstallerType, $SilentArgs) "& '$InstallerSandboxPath'" }
function Wait-Win32ToolkitUpdateAssertion { param($ProjectPath, $Backend, $TimeoutMinutes, $PollSeconds, $LogFileName, $Label) $true }
# The Update arm now records its outcome via this helper — shadow it (the resolution/guard tests don't care).
function Write-Win32ToolkitTestOutcome { param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $LogFileName, $Notes) }

$script:hvBaseline = $null
$script:hvCalled   = 0
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output, $BaselineProjectPath)
    $script:hvCalled++
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

Remove-Item -LiteralPath $script:base, $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All UpdateBaselineProject tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail UpdateBaselineProject test(s) FAILED." -ForegroundColor Red; exit 1 }
