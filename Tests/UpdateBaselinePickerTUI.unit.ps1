<#
    TUI wiring for the update-test baseline picker (Show-Win32ToolkitProjectActions, 'test' action).

    When the user picks the Update scenario, they choose the OLD-version baseline source: download from
    winget, or use a LOCAL packaged project. This drives the Spectre prompts with scripted answers and
    asserts what reaches Test-Win32ToolkitProject:

      A. winget app + "local packaged project"  -> BaselineProjectPath = the chosen project's Path
      B. winget app + "winget download"          -> no BaselineProjectPath (unchanged default)
      C. manual (non-winget) app + a candidate   -> auto local baseline, BaselineProjectPath set
      D. manual app + NO candidate               -> aborts (Test-Win32ToolkitProject is never called)
      E. Hyper-V run mode                        -> the unattended choice says Intune parity, never Silent; the pick
                                                    is passed as -TestMode (E2), the effective mode is shown (E3), an
                                                    unready Hyper-V asks nothing, passes no mode and says so on the run
                                                    screen (E4), the configured mode is the first choice (E5) (TUI audit G3)

    Installer-identity PR 1 (WP-5, spec 2.13 / 3.5 task 4):
      F. winget baseline, two technologies       -> 'Baseline installer technology' (Auto / Both / Packaged)
                                                    reaches Test-Win32ToolkitProject -BaselineInstallerType
      G. one technology / local baseline / error -> no question (a grey 'Baseline technology:' line)
      H. failed verdict + a technology switch    -> the TECHNOLOGY SWITCH panel (escaped); without one, the
                                                    UPDATE TEST FAILED panel names each failed run's own log
                                                    folder (Sandbox\Logs\Runs\<run>, test campaign F2)
      I. publish                                 -> the advisory panel (red / yellow), printed once: Export
                                                    under the TUI publish action prints no second advisory
      K. install/uninstall test                  -> PASSED / FAILED (each failed check with its reason, the run's log)
                                                    / Inconclusive panels; INSTALL-FAILED and INSTALL-INCONCLUSIVE
                                                    make the publish panel red (TUI audit G1)
      J. winget baseline                         -> the TUI asks the baseline VERSION itself (previous version
                                                    first) and passes -SpecificVersion, also for a Hyper-V
                                                    'Unattended' run (test campaign F5: the test would otherwise
                                                    use the previous version without asking); no older version or a
                                                    failed lookup -> a panel, no test. Every Update splat from a winget
                                                    baseline carries -SpecificVersion or -VersionsBack.

    Every Spectre / helper call is shadowed (WP-4's Resolve-Win32ToolkitBaselineFamily and
    Get-Win32ToolkitTechnologySwitch by their spec 2.11 / 2.12 contracts); nothing renders, nothing runs a test.

    Run:  pwsh -File Tests\UpdateBaselinePickerTUI.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Get-WingetVersions is shadowed by its real name')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Show-Win32ToolkitProjectActions.ps1')
# Real: the Export-side writer (I proves it stays quiet under the TUI publish action) and its sanitiser.
. (Join-Path $repo 'Private\Write-Win32ToolkitPackageAdvisory.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
# Real (C-9, TUI audit G1): the FAILED install/uninstall panel reads the failed checks and their reasons from the run's log.
. (Join-Path $repo 'Private\Get-Win32ToolkitAssertionFailure.ps1')

# --- Spectre / rendering shadows (recorded, nothing renders) ---------------------------------------
$script:panels = New-Object System.Collections.Generic.List[object]
$script:hostLines = New-Object System.Collections.Generic.List[string]
# What the screen showed, in order (E4): 'CLEAR' for Clear-Host, 'RULE:<title>', 'HOST:<line>'. Only what follows the
# last CLEAR stays on the operator's screen.
$script:screen = New-Object System.Collections.Generic.List[string]
function Clear-Host { $script:screen.Add('CLEAR') }
function Write-SpectreRule { param($Title, $Color) $script:screen.Add("RULE:$Title") }
function Write-SpectreHost { param($Message) $script:hostLines.Add([string]$Message); $script:screen.Add("HOST:$Message") }
function Out-SpectreHost { param([Parameter(ValueFromPipeline)]$InputObject) process {} }
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) $script:panels.Add([pscustomobject]@{ Data = [string]$Data; Header = [string]$Header; Color = [string]$Color }) }
function Get-SpectreEscapedText { param($Text) ([string]$Text).Replace('[', '[[').Replace(']', ']]') }   # what Spectre's escaper does
function Read-SpectrePause { param($Message, [switch]$AnyKey) }
function Read-SpectreConfirm { param($Message, $DefaultAnswer) $true }   # yes: verify requirement rule

# scripted selection: object-choices (with -ChoiceLabelProperty) are matched by a queued .Key; plain
# label-choices default to the FIRST choice (a real built label, so $map/$bmap lookups resolve).
$script:keys = New-Object System.Collections.Queue
$script:prompts = New-Object System.Collections.Generic.List[object]
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, [switch]$EnableSearch, $PageSize)
    $script:prompts.Add([pscustomobject]@{ Message = $Message; Choices = @($Choices) })
    if ($Message -eq 'Hyper-V run mode') { $script:hvModeChoices = @($Choices) }
    if ($ChoiceLabelProperty) {
        # A script that ran out of answers leaves the action menu ('back') instead of looping on its first choice.
        $want = if ($script:keys.Count) { $script:keys.Dequeue() } elseif ($Message -eq 'What would you like to do?') { 'back' } else { $null }
        $m = @($Choices | Where-Object { $_.Key -eq $want })
        if ($m.Count) { return $m[0] }
        return @($Choices)[0]
    }
    if ($script:pickLabel) { $l = @($Choices | Where-Object { $_ -like $script:pickLabel }); if ($l.Count) { return $l[0] } }   # J: pick a label by pattern
    return @($Choices)[0]   # label-string list -> first
}

# --- domain shadows -------------------------------------------------------------------------------
$script:projects = @()
$script:wingetId = $null
function Get-PSADTProjects { param($BasePath) $script:projects }
function Get-WingetIdFromProject { param($FilesPath) $script:wingetId }
function Get-Win32ToolkitDependencies { param($ProjectPath) @() }
function Get-Win32ToolkitBackendInfo { [pscustomobject]@{ Label = 'Sandbox' } }
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ Version = '1.0'; Name = 'App'; Vendor = 'ACME' } } }

$script:splat   = $null
$script:called  = 0
$script:verdict = $true
$script:updateSplats = New-Object System.Collections.Generic.List[object]   # J: every Update splat the TUI built
# TUI audit G3 (C-9): the 'test' action resolves the backend before the run-mode question and prints the run's effective
# test mode. The pick runs unless $script:hvNotReady; the mode is the pick's -TestMode, else the config value
# ($script:cfgMode); $script:hostCannotPrompt forces Unattended (as Get-Win32ToolkitTestMode does on such a host).
$script:hvNotReady = $false
$script:cfgMode = 'Interactive'
$script:hostCannotPrompt = $false
function Get-Win32ToolkitTestBackend { param($Backend) if ($script:hvNotReady -and $Backend -eq 'HyperV') { 'Sandbox' } else { $Backend } }
function Get-Win32ToolkitTestMode { param($Backend, [switch]$Unattended, $TestMode) $null = $Backend; if ($Unattended -or $script:hostCannotPrompt) { 'Unattended' } elseif ($TestMode) { $TestMode } else { $script:cfgMode } }
function Get-Win32ToolkitConfigValue { param($Name, $Default) $null = $Name, $Default; $script:cfgMode }
function Test-Win32ToolkitProject {
    param($ProjectPath, $Scenario, $Backend, $BaselineProjectPath, [switch]$Unattended, [switch]$SkipRequirementCheck, $BaselineInstallerType, $SpecificVersion, $VersionsBack, $TestMode)
    $script:called++
    $script:splat = $PSBoundParameters
    if ($Scenario -eq 'Update') { $h = @{}; foreach ($k in $PSBoundParameters.Keys) { $h[$k] = $PSBoundParameters[$k] }; $script:updateSplats.Add($h) }
    $script:verdict
}
# Test campaign F5 (C-9): the TUI asks the baseline version from the winget list (newest first) for a winget baseline.
$script:wingetVersions = @('1.9', '1.8', '1.7')
$script:versionCalls = New-Object System.Collections.Generic.List[object]
function Get-YAMLInstallerInfo { param($FilesPath) $null = $FilesPath; [pscustomobject]@{ PackageVersion = '2.0'; Architecture = 'x64' } }
function Get-WingetVersions {
    param($AppId, $CurrentVersion)
    $script:versionCalls.Add([pscustomobject]@{ AppId = $AppId; CurrentVersion = $CurrentVersion })
    if ($script:wingetVersions -is [scriptblock]) { return & $script:wingetVersions }
    $script:wingetVersions
}

# WP-4 contracts (spec 2.11 / 2.12), shadowed: the baseline legs and the technology switches.
$script:legs = @()
$script:legCalls = New-Object System.Collections.Generic.List[object]
function Resolve-Win32ToolkitBaselineFamily {
    param($ProjectPath, $Mode, [switch]$NoProbe)
    $script:legCalls.Add([pscustomobject]@{ ProjectPath = $ProjectPath; Mode = $Mode; NoProbe = [bool]$NoProbe })
    if ($script:legs -is [scriptblock]) { return & $script:legs }
    $script:legs
}
$script:switches = @()
$script:switchCalls = 0
function Get-Win32ToolkitTechnologySwitch { param($ProjectPath, $PackageType, $PackageFamily) $null = $ProjectPath, $PackageType, $PackageFamily; $script:switchCalls++; $script:switches }
# Test campaign F2 (C-9): a failed Update test names the run's own log folder(s), read back from TestResults.json.
$script:runFolders = @()
$script:runFolderCalls = New-Object System.Collections.Generic.List[object]
function Get-Win32ToolkitTestRunLogFolder { param($ProjectPath, $Scenario, $SinceUtc) $script:runFolderCalls.Add([pscustomobject]@{ ProjectPath = $ProjectPath; Scenario = $Scenario; SinceUtc = $SinceUtc }); $script:runFolders }
function Leg($Origin, $Type, $Family, $Label) { [pscustomobject]@{ Family = $Family; InstallerType = $Type; Scope = ''; Origin = $Origin; FallbackInstallerType = ''; FallbackScope = ''; Label = $Label; Note = '' } }
$twoLegs = @((Leg 'Packaged' 'wix' 'msi' 'wix (MSI) (packaged)'), (Leg 'Sibling' 'nullsoft' 'exe' 'nullsoft (vendor EXE, NSIS) (other technology [winget])'))

# The publish action: the advisory (shadowed contract, spec 2.13) and Export, which runs the REAL writer.
$script:advisory = $null
$script:advisoryCalls = New-Object System.Collections.Generic.List[object]
function Get-Win32ToolkitPackageAdvisory {
    param($ProjectPath, $Context, [switch]$ProbeIfMissing)
    $script:advisoryCalls.Add([pscustomobject]@{ ProjectPath = $ProjectPath; Context = $Context; ProbeIfMissing = [bool]$ProbeIfMissing })
    if ($script:advisory -is [scriptblock]) { return & $script:advisory }
    $script:advisory
}
function F($Code, $Severity, $Message) { [pscustomobject]@{ Code = $Code; Severity = $Severity; Source = 'UpdateTest'; Message = $Message } }
$script:exportCalls = 0
$script:exportResult = 'unset'
$script:exportWarnings = @()
$script:scopeInExport = $null
function Export-Win32ToolkitIntuneWin {
    param($ProjectPath, [switch]$PublishIntune, [switch]$PublishUpdate, [switch]$NoPublishPrompt)
    $null = $PublishIntune, $PublishUpdate, $NoPublishPrompt
    $script:exportCalls++
    $script:scopeInExport = $script:W32TAdvisoryRun
    $w = @()
    $script:exportResult = Write-Win32ToolkitPackageAdvisory -ProjectPath $ProjectPath -Context Export -ProbeIfMissing -WarningVariable w 3>$null
    $script:exportWarnings = @($w)
}

function P($template, $name) { [pscustomobject]@{ Template = $template; Name = $name; Path = "C:\Base\Projects\$template\$name" } }

# the project UNDER TEST sorts first (Template 'A'); the baseline candidate is Template 'B'.
$under = P 'A_App' 'App_x64_2.0'
$cand  = P 'B_App' 'App_x64_1.0'

function DriveUpdate([string[]]$objectKeys) {
    # objectKeys are the answers for object-choice prompts, in call order (action, backend, scenario, [source], back)
    $script:keys = New-Object System.Collections.Queue
    foreach ($k in $objectKeys) { $script:keys.Enqueue($k) }
    $script:splat = $null; $script:called = 0
    Show-Win32ToolkitProjectActions -BasePath 'C:\Base' 6>$null 3>$null | Out-Null
}

# ══ A. winget app + local baseline ════════════════════════════════════════════════════════════════
Write-Host '[A] winget app, choose a LOCAL packaged project -> BaselineProjectPath is the chosen project' -ForegroundColor Cyan
$script:projects = @($under, $cand)
$script:wingetId = 'Publisher.App'
DriveUpdate @('test', 'Sandbox', 'Update', 'project', 'back')
if ($script:called -eq 1) { Ok 'the test ran' } else { Bad "Test-Win32ToolkitProject called $script:called time(s)" }
if ($script:splat -and $script:splat['BaselineProjectPath'] -eq $cand.Path) { Ok "BaselineProjectPath = the picked project ($($cand.Path))" } else { Bad "BaselineProjectPath = $($script:splat['BaselineProjectPath'])" }
if ($script:splat['Scenario'] -eq 'Update') { Ok 'scenario forwarded as Update' } else { Bad "scenario=$($script:splat['Scenario'])" }

# ══ B. winget app + winget download (default) ═════════════════════════════════════════════════════
Write-Host '[B] winget app, choose winget download -> NO BaselineProjectPath (unchanged default); [J] the TUI asks the version (-SpecificVersion, F5)' -ForegroundColor Cyan
$script:projects = @($under, $cand)
$script:wingetId = 'Publisher.App'
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
if ($script:called -eq 1 -and -not $script:splat.ContainsKey('BaselineProjectPath')) { Ok 'winget baseline: no BaselineProjectPath passed' } else { Bad "called=$script:called baseline=$($script:splat['BaselineProjectPath'])" }

# J. (test campaign F5) the baseline version is asked here for a winget baseline
$script:projects = @($under, $cand)
$script:wingetId = 'Publisher.App'
$script:legs = @()
$script:verdict = $true
$script:prompts.Clear(); $script:versionCalls.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
$vp = @($script:prompts | Where-Object Message -eq 'Baseline version (the OLDER version to upgrade FROM)')
if ($script:called -eq 1 -and $script:splat['SpecificVersion'] -eq '1.9' -and -not $script:splat.ContainsKey('VersionsBack') -and $vp.Count -eq 1) { Ok 'the default (first) choice is the previous version: -SpecificVersion 1.9' } else { Bad "default -> called=$script:called version=$($script:splat['SpecificVersion']) prompts=$($vp.Count)" }
if ($vp.Count -eq 1 -and (@($vp[0].Choices) -join '|') -ceq '1.9  (previous version)|1.8|1.7') { Ok "choices: newest first, the first marked '(previous version)'" } else { Bad "choices: $(@($vp[0].Choices) -join '|')" }
if ($script:versionCalls.Count -eq 1 -and $script:versionCalls[0].AppId -eq 'Publisher.App' -and $script:versionCalls[0].CurrentVersion -eq '2.0') { Ok 'Get-WingetVersions -AppId <id> -CurrentVersion <packaged version from the YAML>' } else { Bad "version calls: $($script:versionCalls | ConvertTo-Json -Compress)" }
$script:pickLabel = '1.8'
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
$script:pickLabel = $null
if ($script:splat['SpecificVersion'] -eq '1.8') { Ok 'picking another version passes it: -SpecificVersion 1.8' } else { Bad "pick 1.8 -> $($script:splat['SpecificVersion'])" }
# The review case: the Hyper-V 'Unattended' choice (and SandboxTestMode / HyperVTestMode = Unattended) made the test use
# the previous version without asking; the operator at the TUI is still asked.
$script:prompts.Clear()
DriveUpdate @('test', 'HyperV', 'Update', 'unattended', 'winget', 'back')
if ($script:called -eq 1 -and $script:splat['TestMode'] -eq 'Unattended' -and $script:splat['SpecificVersion'] -eq '1.9' -and @($script:prompts | Where-Object Message -eq 'Baseline version (the OLDER version to upgrade FROM)').Count -eq 1) {
    Ok "Hyper-V 'Unattended': the TUI still asks the version and passes -SpecificVersion with -TestMode Unattended"
} else { Bad "hyperv unattended -> called=$script:called testMode=$($script:splat['TestMode']) version=$($script:splat['SpecificVersion'])" }
# With two technologies the version is asked AFTER the technology (Dv5: the operator knows which technology it must ship).
$script:legs = $twoLegs
$script:prompts.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'Both', 'back')
$msgs = @($script:prompts | ForEach-Object Message)
$iTech = [array]::IndexOf($msgs, 'Baseline installer technology'); $iVer = [array]::IndexOf($msgs, 'Baseline version (the OLDER version to upgrade FROM)')
if ($iTech -ge 0 -and $iVer -gt $iTech -and $script:splat['BaselineInstallerType'] -eq 'Both' -and $script:splat['SpecificVersion'] -eq '1.9') { Ok 'technology first, then the version; both reach the test' } else { Bad "order: tech=$iTech version=$iVer" }
$script:legs = @()
# A local baseline project: no version question.
$script:prompts.Clear(); $script:versionCalls.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'project', 'back')
if ($script:versionCalls.Count -eq 0 -and -not $script:splat.ContainsKey('SpecificVersion') -and @($script:prompts | Where-Object Message -like 'Baseline version*').Count -eq 0) { Ok 'a local packaged baseline -> no version lookup, no question' } else { Bad "local -> calls=$($script:versionCalls.Count)" }
# No older version, or the lookup fails: a panel, the test does not run.
foreach ($case in @(@{ Label = 'no older version'; Answer = @(); Want = 'winget lists no version of Publisher.App older than the packaged one.' },
        @{ Label = 'the lookup fails'; Answer = { throw "winget 'show --versions' failed [x]" }; Want = "Could not list the older winget versions of Publisher.App (winget 'show --versions' failed [[x]])." })) {
    $script:wingetVersions = $case.Answer
    $script:panels.Clear()
    DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
    $nv = @($script:panels | Where-Object Header -eq 'No baseline version')
    if ($script:called -eq 0 -and $nv.Count -eq 1 -and $nv[0].Color -eq 'Yellow' -and $nv[0].Data.StartsWith($case.Want)) { Ok "$($case.Label) -> a 'No baseline version' panel (escaped), the test does not run" }
    else { Bad "$($case.Label) -> called=$script:called panels=$($script:panels | ConvertTo-Json -Compress)" }
}
$script:wingetVersions = @('1.9', '1.8', '1.7')

# ══ C. manual app + a candidate -> auto local baseline ════════════════════════════════════════════
Write-Host '[C] manual (non-winget) app with a candidate -> auto local baseline' -ForegroundColor Cyan
$script:projects = @($under, $cand)
$script:wingetId = $null    # no winget id => manual
DriveUpdate @('test', 'Sandbox', 'Update', 'back')   # no baseline-source prompt for manual
if ($script:called -eq 1 -and $script:splat['BaselineProjectPath'] -eq $cand.Path) { Ok 'manual app auto-uses the local candidate as baseline' } else { Bad "called=$script:called baseline=$($script:splat['BaselineProjectPath'])" }

# ══ D. manual app + NO candidate -> abort (test never runs) ═══════════════════════════════════════
Write-Host '[D] manual app with NO baseline candidate -> aborts, does NOT run the test' -ForegroundColor Cyan
$script:projects = @($under)      # only the project under test; nothing to use as a baseline
$script:wingetId = $null
DriveUpdate @('test', 'Sandbox', 'Update', 'back')
if ($script:called -eq 0) { Ok 'no baseline available -> the update test is not run (clean abort, no mid-run hard-error)' } else { Bad "Test-Win32ToolkitProject ran anyway ($script:called)" }

# ══ E. Hyper-V run mode wording (F-04) ════════════════════════════════════════════════════════════
# Hyper-V unattended is the Intune-parity run (published command line, 32-bit parent, SYSTEM), not a
# '-DeployMode Silent' run: the TUI must not call it silent, and labels must carry no Spectre markup.
Write-Host '[E] Hyper-V run mode: the unattended choice says Intune parity, not Silent' -ForegroundColor Cyan
$script:projects = @($under, $cand)
$script:wingetId = 'Publisher.App'
$script:hvModeChoices = @()
DriveUpdate @('test', 'HyperV', 'InstallUninstall', 'unattended', 'back')
$ua = @($script:hvModeChoices | Where-Object { $_.Key -eq 'unattended' })
if ($ua.Count -eq 1 -and $ua[0].Label -match 'Intune parity' -and $ua[0].Label -notmatch '(?i)silent|no GUI') { Ok "unattended label: '$($ua[0].Label)'" } else { Bad "unattended label: '$($ua.Label)'" }
if ($script:hvModeChoices.Count -eq 2 -and -not @($script:hvModeChoices | Where-Object { $_.Label -match '[\[\]]' }).Count) { Ok 'no Spectre markup brackets in the Hyper-V run mode labels' } else { Bad "labels: $($script:hvModeChoices.Label -join ' | ')" }
if ($script:called -eq 1 -and $script:splat['TestMode'] -eq 'Unattended' -and -not $script:splat.ContainsKey('Unattended')) { Ok 'choosing it passes -TestMode Unattended (no -Unattended key)' } else { Bad "called=$script:called testMode=$($script:splat['TestMode']) unattended=$($script:splat['Unattended'])" }

# TUI audit G3: the pick is this run's -TestMode, so Interactive wins over HyperVTestMode=Unattended.
Write-Host '[E2] Hyper-V run mode Interactive with HyperVTestMode=Unattended -> -TestMode Interactive' -ForegroundColor Cyan
$script:cfgMode = 'Unattended'
DriveUpdate @('test', 'HyperV', 'InstallUninstall', 'interactive', 'back')
$script:cfgMode = 'Interactive'
if ($script:called -eq 1 -and $script:splat['TestMode'] -eq 'Interactive' -and -not $script:splat.ContainsKey('Unattended')) { Ok 'the Interactive pick passes -TestMode Interactive (it overrides HyperVTestMode)' } else { Bad "called=$script:called testMode=$($script:splat['TestMode']) unattended=$($script:splat['Unattended'])" }

Write-Host '[E3] the run''s effective test mode is shown before the run starts' -ForegroundColor Cyan
$modeCases = @(
    @{ Tag = 'Hyper-V, Interactive pick';        Keys = @('test', 'HyperV', 'InstallUninstall', 'interactive', 'back'); Cfg = 'Unattended'; NoPrompt = $false
       Want = '[grey]Test mode: Interactive (your choice for this run): watch the PSADT dialogs in the VM window.[/]' }
    @{ Tag = 'Hyper-V, Unattended pick';         Keys = @('test', 'HyperV', 'InstallUninstall', 'unattended', 'back'); Cfg = 'Interactive'; NoPrompt = $false
       Want = '[grey]Test mode: Unattended (your choice for this run): the Intune command line as SYSTEM, no pause.[/]' }
    @{ Tag = 'Hyper-V, Interactive pick, a console that cannot prompt'; Keys = @('test', 'HyperV', 'InstallUninstall', 'interactive', 'back'); Cfg = 'Interactive'; NoPrompt = $true
       Want = '[yellow]Test mode: Unattended. This console cannot answer prompts, so the run cannot be watched.[/]' }
    @{ Tag = 'Sandbox, SandboxTestMode=Unattended'; Keys = @('test', 'Sandbox', 'InstallUninstall', 'back'); Cfg = 'Unattended'; NoPrompt = $false
       Want = '[grey]Test mode: Unattended (SandboxTestMode = Unattended): a silent run, the sandbox closes itself.[/]' }
    @{ Tag = 'Sandbox, default';                 Keys = @('test', 'Sandbox', 'InstallUninstall', 'back'); Cfg = 'Interactive'; NoPrompt = $false
       Want = '[grey]Test mode: Interactive (watched: a 2-minute countdown, the sandbox stays open; SandboxTestMode changes the default).[/]' })
foreach ($mc in $modeCases) {
    $script:cfgMode = $mc.Cfg; $script:hostCannotPrompt = $mc.NoPrompt; $script:hostLines.Clear()
    DriveUpdate $mc.Keys
    $modeLines = @($script:hostLines | Where-Object { $_ -match 'Test mode: ' })
    if ($script:called -eq 1 -and $modeLines.Count -eq 1 -and $modeLines[0] -ceq $mc.Want) { Ok "$($mc.Tag): '$($mc.Want)'" } else { Bad "$($mc.Tag): $($modeLines -join ' | ')" }
}
$script:cfgMode = 'Interactive'; $script:hostCannotPrompt = $false

Write-Host '[E4] Hyper-V picked but not ready -> no run-mode question, no -TestMode, the Sandbox mode line' -ForegroundColor Cyan
$notReadyText = '[yellow]Hyper-V is not ready, so Windows Sandbox runs this test (it follows SandboxTestMode). See Settings for the reasons.[/]'
# The run screen: from the Clear-Host before the 'Running the … test…' rule to the next Clear-Host (the action menu after
# the run), which is all the operator sees while the test runs. Get-RunScreenStart = the index of that Clear-Host.
function Get-RunScreenStart {
    $r = [array]::FindLastIndex([string[]]$script:screen, [Predicate[string]] { param($l) $l -like 'RULE:Running the *' })
    if ($r -lt 0) { return -1 }
    $script:screen.LastIndexOf('CLEAR', $r)
}
function Get-RunScreen {
    $c = Get-RunScreenStart
    if ($c -lt 0) { return @() }
    $n = $script:screen.IndexOf('CLEAR', $c + 1)
    $end = if ($n -lt 0) { $script:screen.Count } else { $n }
    @($script:screen.GetRange($c + 1, $end - $c - 1))
}
$script:hvNotReady = $true; $script:hostLines.Clear(); $script:prompts.Clear(); $script:screen.Clear()
DriveUpdate @('test', 'HyperV', 'InstallUninstall', 'back')
$script:hvNotReady = $false
$notReady = @($script:hostLines | Where-Object { $_ -ceq $notReadyText })
$e4Mode = @($script:hostLines | Where-Object { $_ -match 'Test mode: ' })
if ($script:called -eq 1 -and @($script:prompts | Where-Object Message -eq 'Hyper-V run mode').Count -eq 0 -and -not $script:splat.ContainsKey('TestMode') -and -not $script:splat.ContainsKey('Unattended')) {
    Ok 'no Hyper-V run-mode question; neither -TestMode nor -Unattended (the Sandbox run follows SandboxTestMode)'
} else { Bad "not ready -> called=$script:called prompts=$(@($script:prompts | ForEach-Object Message) -join ' | ') keys=$(@($script:splat.Keys) -join ',')" }
if ($notReady.Count -eq 1 -and $e4Mode.Count -eq 1 -and $e4Mode[0] -match 'sandbox stays open' -and $e4Mode[0] -notmatch 'VM window') { Ok 'one yellow "Hyper-V is not ready" line, then the Sandbox mode line (not the VM-window line)' } else { Bad "not ready lines: $($script:hostLines -join ' | ')" }
# On the run screen (after its Clear-Host): the rule names what runs, then the yellow line, then the mode line. Before the
# fix the yellow line came before that Clear-Host (never seen) and the rule said 'Running the HyperV test…'.
$e4Run = @(Get-RunScreen)
$e4Rule = [array]::IndexOf([string[]]$e4Run, 'RULE:Running the Sandbox test…')
$e4Yellow = [array]::IndexOf([string[]]$e4Run, "HOST:$notReadyText")
$e4ModeAt = [array]::FindIndex([string[]]$e4Run, [Predicate[string]] { param($l) $l -like 'HOST:*Test mode: *' })
if ($e4Rule -eq 0 -and $e4Yellow -gt $e4Rule -and $e4ModeAt -gt $e4Yellow -and @($e4Run | Where-Object { $_ -like 'RULE:*HyperV*' }).Count -eq 0) {
    Ok "the run screen: 'Running the Sandbox test…', then the yellow line, then the Sandbox mode line (all after its Clear-Host)"
} else { Bad "run screen: $($e4Run -join ' | ')" }
if ($script:splat['Backend'] -eq 'HyperV') { Ok 'the splat keeps the operator''s pick as -Backend (the test resolves it again)' } else { Bad "backend: $($script:splat['Backend'])" }
# Update: the line also stands above the baseline questions on the first screen, and again on the run screen.
$script:hvNotReady = $true; $script:hostLines.Clear(); $script:prompts.Clear(); $script:screen.Clear()
DriveUpdate @('test', 'HyperV', 'Update', 'project', 'back')
$script:hvNotReady = $false
$e4uRun = @(Get-RunScreen)
$e4uFirst = $script:screen.IndexOf("HOST:$notReadyText")
$e4uRunClear = Get-RunScreenStart
if ($script:called -eq 1 -and $e4uFirst -ge 0 -and $e4uFirst -lt $e4uRunClear -and $e4uRun.Count -ge 3 -and $e4uRun[0] -eq 'RULE:Running the Sandbox test…' -and $e4uRun[1] -eq "HOST:$notReadyText" -and $e4uRun[2] -like 'HOST:*Test mode: *sandbox stays open*') {
    Ok 'Update, Hyper-V not ready: the yellow line above the baseline questions, and again on the run screen under ''Running the Sandbox test…'''
} else { Bad "update not ready: called=$script:called screen=$($script:screen -join ' | ')" }
# Hyper-V ready: the rule names Hyper-V, no yellow line.
$script:screen.Clear()
DriveUpdate @('test', 'HyperV', 'InstallUninstall', 'interactive', 'back')
$e4hRun = @(Get-RunScreen)
if ($e4hRun.Count -ge 2 -and $e4hRun[0] -eq 'RULE:Running the HyperV test…' -and $e4hRun[1] -like 'HOST:*Test mode: Interactive*' -and @($script:screen | Where-Object { $_ -eq "HOST:$notReadyText" }).Count -eq 0) {
    Ok "Hyper-V ready: 'Running the HyperV test…', then the mode line, no not-ready line"
} else { Bad "ready run screen: $($e4hRun -join ' | ')" }

# The run-mode list offers the mode a run without -TestMode would get first (the highlighted default), so Enter on the
# first item keeps HyperVTestMode's meaning; the labels are the ones Test E pins.
Write-Host '[E5] Hyper-V run mode: the configured mode is the first (default) choice' -ForegroundColor Cyan
foreach ($case in @(@{ Cfg = 'Unattended'; First = 'unattended'; Mode = 'Unattended' }, @{ Cfg = 'Interactive'; First = 'interactive'; Mode = 'Interactive' })) {
    $script:cfgMode = $case.Cfg; $script:hvModeChoices = @()
    DriveUpdate @('test', 'HyperV', 'InstallUninstall', '(enter: the first choice)', 'back')
    $keys5 = @($script:hvModeChoices | ForEach-Object Key)
    if ($keys5.Count -eq 2 -and $keys5[0] -eq $case.First -and $script:called -eq 1 -and $script:splat['TestMode'] -eq $case.Mode) {
        Ok "HyperVTestMode=$($case.Cfg): '$($case.First)' is offered first; Enter passes -TestMode $($case.Mode)"
    } else { Bad "HyperVTestMode=$($case.Cfg): order=$($keys5 -join ',') testMode=$($script:splat['TestMode'])" }
}
$script:cfgMode = 'Interactive'

# ══ F. baseline installer technology: asked only with two or more technologies ══════════════════════
Write-Host '[F] winget baseline with two technologies -> "Baseline installer technology" reaches -BaselineInstallerType' -ForegroundColor Cyan
$script:projects = @($under, $cand)
$script:wingetId = 'Publisher.App'
$script:legs = $twoLegs
foreach ($pick in 'Auto', 'Both', 'Packaged') {
    $script:prompts.Clear(); $script:legCalls.Clear()
    DriveUpdate @('test', 'Sandbox', 'Update', 'winget', $pick, 'back')
    $tech = @($script:prompts | Where-Object Message -eq 'Baseline installer technology')
    if ($script:called -eq 1 -and $script:splat['BaselineInstallerType'] -eq $pick -and $tech.Count -eq 1) { Ok "'$pick' -> Test-Win32ToolkitProject -BaselineInstallerType $pick" } else { Bad "pick $pick -> called=$script:called type=$($script:splat['BaselineInstallerType']) prompts=$($tech.Count)" }
}
$labels = @($tech[0].Choices | ForEach-Object Label)
if ((@($tech[0].Choices | ForEach-Object Key) -join ',') -eq 'Auto,Both,Packaged' -and
    $labels[0] -ceq 'Auto - start from the other technology (nullsoft (vendor EXE, NSIS) (other technology [[winget]]))' -and
    $labels[1] -ceq 'Test both technologies (2 runs)' -and $labels[2] -ceq 'Only the packaged technology (wix (MSI) (packaged))') {
    Ok 'choices: Auto (the other technology, escaped) / Test both technologies (2 runs) / Only the packaged technology'
} else { Bad "choices: $($labels -join ' | ')" }
if ($script:legCalls.Count -eq 1 -and $script:legCalls[0].Mode -eq 'Both' -and $script:legCalls[0].ProjectPath -eq $under.Path) { Ok 'the legs come from Resolve-Win32ToolkitBaselineFamily -Mode Both for the project' } else { Bad "leg calls: $($script:legCalls | ConvertTo-Json -Compress)" }

Write-Host '[G] one technology -> a grey line, no question; a local baseline or a resolver error -> no question' -ForegroundColor Cyan
$script:legs = @(Leg 'Packaged' 'inno' 'exe' 'inno (vendor EXE, Inno Setup) (packaged)')
$script:prompts.Clear(); $script:hostLines.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
if ($script:called -eq 1 -and -not $script:splat.ContainsKey('BaselineInstallerType') -and @($script:prompts | Where-Object Message -eq 'Baseline installer technology').Count -eq 0 -and
    $script:hostLines -ccontains '[grey]Baseline technology: inno (vendor EXE, Inno Setup) (packaged)[/]') {
    Ok "one leg -> '[grey]Baseline technology: <label>[/]', no question, no -BaselineInstallerType"
} else { Bad "one leg -> type=$($script:splat['BaselineInstallerType']) lines=$($script:hostLines -join ' | ')" }
$script:legs = $twoLegs
$script:legCalls.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'project', 'back')
if ($script:legCalls.Count -eq 0 -and -not $script:splat.ContainsKey('BaselineInstallerType') -and $script:splat['BaselineProjectPath'] -eq $cand.Path) { Ok 'a local packaged baseline -> no technology lookup, no question' } else { Bad "local -> legCalls=$($script:legCalls.Count)" }
$script:legs = { throw 'resolver exploded' }
$script:hostLines.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
if ($script:called -eq 1 -and -not $script:splat.ContainsKey('BaselineInstallerType') -and @($script:hostLines | Where-Object { $_ -match '^\[grey\]Baseline technology: not resolved here \(resolver exploded\)' }).Count -eq 1) {
    Ok 'a resolver error -> one grey line, the test still runs (it resolves the technology itself)'
} else { Bad "resolver error -> called=$script:called lines=$($script:hostLines -join ' | ')" }
$script:legs = @()

Write-Host '[H] a failed Update test with a technology switch -> the TECHNOLOGY SWITCH panel' -ForegroundColor Cyan
$esc = [char]0x1B
$script:switches = @([pscustomobject]@{ Code = 'ID-TECH-SWITCH'; Message = "Technology switch: [red]v8.8.9[/] (Notepad++ ${esc}x) was still registered." })
$script:verdict = $false; $script:panels.Clear(); $script:switchCalls = 0
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
$p = @($script:panels | Where-Object Header -eq 'TECHNOLOGY SWITCH')
if ($p.Count -eq 1 -and $p[0].Color -eq 'Red' -and $p[0].Data.StartsWith('Technology switch: [[red]]v8.8.9[[/]]') -and @($script:panels | Where-Object Header -eq 'UPDATE TEST FAILED').Count -eq 0) {
    Ok 'FAILED + a switch -> a red TECHNOLOGY SWITCH panel with the escaped message (instead of UPDATE TEST FAILED)'
} else { Bad "panels: $($script:panels | ConvertTo-Json -Compress)" }
$script:switches = @(); $script:panels.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
if (@($script:panels | Where-Object Header -eq 'UPDATE TEST FAILED').Count -eq 1 -and @($script:panels | Where-Object Header -eq 'TECHNOLOGY SWITCH').Count -eq 0) { Ok 'FAILED without a switch -> the existing UPDATE TEST FAILED panel' } else { Bad "no switch -> $($script:panels.Header -join ',')" }
$uf = @($script:panels | Where-Object Header -eq 'UPDATE TEST FAILED')
if ($uf.Count -eq 1 -and $uf[0].Data -ceq 'One or more assertions FAILED - see Sandbox\Logs\UpdateAssertions.log in the project folder.' -and $script:runFolderCalls.Count -ge 1 -and
    $script:runFolderCalls[-1].Scenario -eq 'Update' -and $script:runFolderCalls[-1].SinceUtc -is [datetime]) { Ok 'no recorded run folder -> the panel names Sandbox\Logs\UpdateAssertions.log (the lookup asked for Update records since the test started)' }
else { Bad "no run folder -> $($uf | ConvertTo-Json -Compress)" }
$script:runFolders = @('C:\Base\Projects\A\App [x]\Sandbox\Logs\Runs\20261020-221500_Update_msi', 'C:\Base\Projects\A\App [x]\Sandbox\Logs\Runs\20261020-222000_Update_exe')
$script:panels.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
$uf = @($script:panels | Where-Object Header -eq 'UPDATE TEST FAILED')
$wantUf = 'One or more assertions FAILED - see C:\Base\Projects\A\App [[x]]\Sandbox\Logs\Runs\20261020-221500_Update_msi\UpdateAssertions.log and C:\Base\Projects\A\App [[x]]\Sandbox\Logs\Runs\20261020-222000_Update_exe\UpdateAssertions.log.'
if ($uf.Count -eq 1 -and $uf[0].Data -ceq $wantUf) { Ok "a failed run with its own log folder(s) -> the panel names each run's UpdateAssertions.log (escaped)" } else { Bad "run folders -> $($uf | ConvertTo-Json -Compress)" }
$script:runFolders = @()
$script:verdict = $true; $script:switchCalls = 0; $script:panels.Clear()
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
if ($script:switchCalls -eq 0 -and @($script:panels | Where-Object Header -eq 'UPDATE TEST PASSED').Count -eq 1) { Ok 'PASSED -> no switch lookup, UPDATE TEST PASSED' } else { Bad "passed -> switchCalls=$($script:switchCalls)" }

Write-Host '[I] publish: the advisory panel before "Publish which app?", printed once (Export stays quiet)' -ForegroundColor Cyan
$script:W32TAdvisoryRun = $null
$script:advisory = [pscustomobject]@{ Findings = @(
        (F 'UNSAFE-CLEANUP' 'Warning' "UNSAFE-CLEANUP: this project's uninstall would delete 1 folder(s) [C:\Program Files (x86)]"),
        (F 'ID-NO-ANCHOR' 'Warning' 'winget chose wix (MSI) ...'),
        (F 'UPDATE-INCONCLUSIVE' 'Info' 'The latest Update test gave no verdict [x]')) }
$script:panels.Clear(); $script:hostLines.Clear(); $script:advisoryCalls.Clear(); $script:prompts.Clear(); $script:exportCalls = 0
DriveUpdate @('publish', 'install', 'back')
$ap = @($script:panels | Where-Object { $_.Header -in 'Review before you publish', 'Check before you publish' })
$whichIdx = [array]::IndexOf(@($script:prompts | ForEach-Object Message), 'Publish which app?')
if ($script:advisoryCalls.Count -eq 1 -and $script:advisoryCalls[0].Context -eq 'Tui' -and $script:advisoryCalls[0].ProbeIfMissing -and $script:advisoryCalls[0].ProjectPath -eq $under.Path -and $whichIdx -ge 0) {
    Ok 'Get-Win32ToolkitPackageAdvisory -Context Tui -ProbeIfMissing once, then "Publish which app?"'
} else { Bad "advisory calls: $($script:advisoryCalls | ConvertTo-Json -Compress) which=$whichIdx" }
if ($ap.Count -eq 1 -and $ap[0].Header -eq 'Review before you publish' -and $ap[0].Color -eq 'Red' -and $ap[0].Data -match 'would delete 1 folder\(s\) \[\[C:\\Program Files \(x86\)\]\]' -and $ap[0].Data -match 'winget chose wix') {
    Ok 'UNSAFE-CLEANUP -> one RED panel with every warning, escaped'
} else { Bad "advisory panel: $($ap | ConvertTo-Json -Compress)" }
if ($script:hostLines -ccontains '[grey]The latest Update test gave no verdict [[x]][/]') { Ok 'an Info finding -> one grey line, escaped' } else { Bad "info line: $($script:hostLines -join ' | ')" }
if ($script:exportCalls -eq 1 -and $null -eq $script:exportResult -and $script:exportWarnings.Count -eq 0 -and $script:advisoryCalls.Count -eq 1 -and $script:scopeInExport -is [hashtable]) {
    Ok 'Export under the TUI publish action: the run scope is open, the writer returns $null, prints nothing and asks for no second advisory'
} else { Bad "export: calls=$($script:exportCalls) result=$($script:exportResult) warnings=$($script:exportWarnings.Count) advisoryCalls=$($script:advisoryCalls.Count)" }
if ($null -eq $script:W32TAdvisoryRun) { Ok 'the TUI closed the run scope after Export returned' } else { Bad 'the run scope leaked out of the TUI publish action' }

$script:advisory = [pscustomobject]@{ Findings = @((F 'ID-SIBLING-UNTESTED' 'Warning' 'winget also ships nullsoft ...')) }
$script:panels.Clear()
DriveUpdate @('publish', 'install', 'back')
$ap = @($script:panels | Where-Object { $_.Header -in 'Review before you publish', 'Check before you publish' })
if ($ap.Count -eq 1 -and $ap[0].Color -eq 'Yellow' -and $ap[0].Header -eq 'Check before you publish') { Ok 'other warnings only -> a YELLOW panel' } else { Bad "yellow: $($ap | ConvertTo-Json -Compress)" }
# TUI audit G1: a failed install/uninstall test, or one without a verdict, is red too (decision: red in the panel).
foreach ($code in 'UPDATE-FAILED', 'ID-TECH-SWITCH', 'INSTALL-FAILED', 'INSTALL-INCONCLUSIVE') {
    $script:advisory = [pscustomobject]@{ Findings = @((F $code 'Warning' "$code text")) }
    $script:panels.Clear()
    DriveUpdate @('publish', 'install', 'back')
    if (@($script:panels | Where-Object { $_.Header -eq 'Review before you publish' -and $_.Color -eq 'Red' }).Count -eq 1) { Ok "$code -> a RED panel" } else { Bad "$code -> $($script:panels | ConvertTo-Json -Compress)" }
}
$script:advisory = [pscustomobject]@{ Findings = @((F 'ID-SIBLING-UNTESTABLE' 'Info' 'zip-wrapped')) }
$script:panels.Clear()
DriveUpdate @('publish', 'cancel', 'back')
if (@($script:panels | Where-Object { $_.Header -in 'Review before you publish', 'Check before you publish' }).Count -eq 0 -and $null -eq $script:W32TAdvisoryRun) { Ok 'no warning -> no advisory panel; Cancel still closes the run scope' } else { Bad 'no-warning panel / scope after cancel' }
$script:advisory = { throw 'advisory exploded' }
$script:prompts.Clear()
$script:keys = New-Object System.Collections.Queue
foreach ($k in 'publish', 'install', 'back') { $script:keys.Enqueue($k) }
$script:exportCalls = 0
$w = @(Show-Win32ToolkitProjectActions -BasePath 'C:\Base' 3>&1 6>$null | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
if (@($w | Where-Object { "$_" -match '^Could not check the Update test and identity warnings: advisory exploded' }).Count -eq 1 -and $script:exportCalls -eq 1) {
    Ok 'a failing advisory -> one "Could not check ..." warning, the publish still goes ahead'
} else { Bad "advisory failure: warnings=$(@($w).Count) export=$($script:exportCalls)" }
$script:advisory = $null

# ══ K. install/uninstall verdict panels (TUI audit G1) ═══════════════════════════════════════════════
Write-Host '[K] install/uninstall test: PASSED / FAILED (each failed check with its reason, the run folder) / Inconclusive' -ForegroundColor Cyan
$kRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32tuik_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$underK = [pscustomobject]@{ Template = 'A_App'; Name = 'App_x64_2.0'; Path = (Join-Path $kRoot 'Projects\A_App\App_x64_2.0') }
$kRun = Join-Path $underK.Path 'Sandbox\Logs\Runs\20261023-101500_InstallUninstall'
$kTop = Join-Path $underK.Path 'Sandbox\Logs'
New-Item -ItemType Directory -Path $kRun -Force | Out-Null
$kTs = '[2026-10-23 10:15:00Z]'
$writeLog = { param($Path, [string[]]$Lines) Set-Content -LiteralPath $Path -Value $Lines -Encoding UTF8 }
$iuPanel = { param($Header) @($script:panels | Where-Object Header -eq $Header) }
$kSentence = 'Do not publish this package until you know why: Publish to Intune shows this failure again under "Review before you publish" (a warning; it does not block).'
try {
    $script:projects = @($underK, $cand)
    $script:wingetId = 'Publisher.App'

    $script:verdict = $true; $script:panels.Clear(); $script:runFolders = @()
    DriveUpdate @('test', 'Sandbox', 'InstallUninstall', 'back')
    $kp = @(& $iuPanel 'INSTALL/UNINSTALL TEST PASSED')
    if ($script:called -eq 1 -and $kp.Count -eq 1 -and $kp[0].Color -eq 'Green' -and $kp[0].Data -ceq 'All install and uninstall assertions passed.') { Ok 'PASSED -> a green INSTALL/UNINSTALL TEST PASSED panel' } else { Bad "passed -> $($script:panels | ConvertTo-Json -Compress)" }

    & $writeLog (Join-Path $kRun 'InstallAssertions.log') @(
        "$kTs ASSERT Detected-PostInstall = PASS"
        "$kTs ASSERT AppArpGone-PostUninstall = FAIL (app still in Add/Remove Programs after uninstall: Contoso [x] 1.0)"
        "$kTs RESULT COMPLETE")
    $script:verdict = $false; $script:panels.Clear(); $script:runFolders = @($kRun); $script:runFolderCalls.Clear()
    DriveUpdate @('test', 'Sandbox', 'InstallUninstall', 'back')
    $kf = @(& $iuPanel 'INSTALL/UNINSTALL TEST FAILED')
    $wantKf = ("One or more assertions FAILED - see $kRun\InstallAssertions.log.`n- AppArpGone-PostUninstall: app still in Add/Remove Programs after uninstall: Contoso [x] 1.0`n`n$kSentence").Replace('[', '[[').Replace(']', ']]')
    if ($kf.Count -eq 1 -and $kf[0].Color -eq 'Red' -and $kf[0].Data -ceq $wantKf) { Ok 'FAILED with a run folder -> a red panel: the run''s InstallAssertions.log, each failed check with its reason (escaped), the "shown again before you publish" sentence' } else { Bad "failed -> $($kf | ConvertTo-Json -Compress)" }
    if ($script:runFolderCalls.Count -ge 1 -and $script:runFolderCalls[-1].Scenario -eq 'InstallUninstall' -and $script:runFolderCalls[-1].ProjectPath -eq $underK.Path -and $script:runFolderCalls[-1].SinceUtc -is [datetime]) { Ok 'the run folder is looked up for InstallUninstall records since the test started' } else { Bad "run folder calls: $($script:runFolderCalls | ConvertTo-Json -Compress)" }

    & $writeLog (Join-Path $kTop 'InstallAssertions.log') @("$kTs ASSERT Detected-PostInstall = FAIL")
    $script:panels.Clear(); $script:runFolders = @()
    DriveUpdate @('test', 'Sandbox', 'InstallUninstall', 'back')
    $kf = @(& $iuPanel 'INSTALL/UNINSTALL TEST FAILED')
    $wantKf2 = "One or more assertions FAILED - see Sandbox\Logs\InstallAssertions.log in the project folder.`n- Detected-PostInstall: no reason given`n`n$kSentence"
    if ($kf.Count -eq 1 -and $kf[0].Data -ceq $wantKf2) { Ok 'FAILED without a run folder -> names Sandbox\Logs\InstallAssertions.log in the project folder and reads its FAIL lines (no reason -> "no reason given")' } else { Bad "no run folder -> $($kf | ConvertTo-Json -Compress)" }

    foreach ($noFail in @(@{ Tag = 'only PASS lines'; Lines = @("$kTs ASSERT Detected-PostInstall = PASS") },
            @{ Tag = 'a PASS before a FAIL of the same name'; Lines = @("$kTs ASSERT Detected-PostInstall = PASS", "$kTs ASSERT Detected-PostInstall = FAIL (later)") })) {
        & $writeLog (Join-Path $kRun 'InstallAssertions.log') $noFail.Lines
        $script:panels.Clear(); $script:runFolders = @($kRun)
        DriveUpdate @('test', 'Sandbox', 'InstallUninstall', 'back')
        $kf = @(& $iuPanel 'INSTALL/UNINSTALL TEST FAILED')
        $wantKf3 = "One or more assertions FAILED - see $kRun\InstallAssertions.log.`n- no FAIL line was found in $kRun\InstallAssertions.log`n`n$kSentence"
        if ($kf.Count -eq 1 -and $kf[0].Data -ceq $wantKf3) { Ok "FAILED, the log has $($noFail.Tag) -> '- no FAIL line was found in <log>', never an empty list" } else { Bad "$($noFail.Tag) -> $($kf | ConvertTo-Json -Compress)" }
    }

    $hint = 'If the Intune-parity pre-check did not start it, run it again with the Interactive Hyper-V run mode.'
    $script:verdict = $null; $script:panels.Clear(); $script:runFolders = @()
    DriveUpdate @('test', 'HyperV', 'InstallUninstall', 'unattended', 'back')
    $ki = @(& $iuPanel 'Inconclusive')
    $wantKi = "No conclusive assertion results (the run was closed early, timed out, skipped every assertion, or was not started; see the messages above).`n$hint"
    if ($ki.Count -eq 1 -and $ki[0].Color -eq 'Yellow' -and $ki[0].Data -ceq $wantKi) { Ok 'no verdict, Hyper-V Unattended -> a yellow Inconclusive panel with the Interactive-run-mode hint' } else { Bad "inconclusive hv -> $($ki | ConvertTo-Json -Compress)" }
    $script:panels.Clear()
    DriveUpdate @('test', 'Sandbox', 'InstallUninstall', 'back')
    $ki = @(& $iuPanel 'Inconclusive')
    if ($ki.Count -eq 1 -and $ki[0].Data -notmatch 'Intune-parity' -and $ki[0].Data -match '^No conclusive assertion results') { Ok 'no verdict on Sandbox -> the Inconclusive panel without the Hyper-V hint' } else { Bad "inconclusive sandbox -> $($ki | ConvertTo-Json -Compress)" }
    # Dv14: the Update branch's Inconclusive panel gets the same hint for a Hyper-V Unattended run.
    $script:panels.Clear()
    DriveUpdate @('test', 'HyperV', 'Update', 'unattended', 'winget', 'back')
    $ku = @(& $iuPanel 'Inconclusive')
    if ($ku.Count -eq 1 -and $ku[0].Data -ceq "No conclusive assertion results (sandbox closed early, timeout, or everything skipped).`n$hint") { Ok 'Update, no verdict, Hyper-V Unattended -> the same hint (Dv14)' } else { Bad "update inconclusive -> $($ku | ConvertTo-Json -Compress)" }
    if (@($script:panels | Where-Object { $_.Header -like 'UPDATE TEST*' -or $_.Header -like 'INSTALL/UNINSTALL*' }).Count -eq 0) { Ok 'an Update run shows no install/uninstall panel' } else { Bad "update panels: $($script:panels.Header -join ',')" }
}
finally {
    $script:verdict = $true; $script:runFolders = @(); $script:projects = @($under, $cand)
    Remove-Item -LiteralPath $kRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# The invariant over every Update run this suite drove: a winget baseline always carries a version.
$wingetSplats = @($script:updateSplats | Where-Object { -not $_.ContainsKey('BaselineProjectPath') })
$noVersion = @($wingetSplats | Where-Object { -not ($_.ContainsKey('SpecificVersion') -or $_.ContainsKey('VersionsBack')) })
if ($wingetSplats.Count -ge 5 -and $noVersion.Count -eq 0) { Ok "every Update splat from a winget baseline ($($wingetSplats.Count)) carries -SpecificVersion or -VersionsBack" } else { Bad "$($noVersion.Count) of $($wingetSplats.Count) winget Update splat(s) without a version" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All UpdateBaselinePickerTUI tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail UpdateBaselinePickerTUI test(s) FAILED." -ForegroundColor Red; exit 1 }
