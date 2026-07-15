<#
    TUI wiring for the update-test baseline picker (Show-Win32ToolkitProjectActions, 'test' action).

    When the user picks the Update scenario, they choose the OLD-version baseline source: download from
    winget, or use a LOCAL packaged project. This drives the Spectre prompts with scripted answers and
    asserts what reaches Test-Win32ToolkitProject:

      A. winget app + "local packaged project"  -> BaselineProjectPath = the chosen project's Path
      B. winget app + "winget download"          -> no BaselineProjectPath (unchanged default)
      C. manual (non-winget) app + a candidate   -> auto local baseline, BaselineProjectPath set
      D. manual app + NO candidate               -> aborts (Test-Win32ToolkitProject is never called)

    Every Spectre / helper call is shadowed; nothing renders, nothing runs a test.

    Run:  pwsh -File Tests\UpdateBaselinePickerTUI.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Show-Win32ToolkitProjectActions.ps1')

# --- Spectre / rendering shadows (no-ops) ---------------------------------------------------------
function Clear-Host {}
function Write-SpectreRule { param($Title, $Color) }
function Write-SpectreHost { param($Message) }
function Out-SpectreHost { param([Parameter(ValueFromPipeline)]$InputObject) process {} }
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) }
function Get-SpectreEscapedText { param($Text) $Text }
function Read-SpectrePause { param($Message, [switch]$AnyKey) }
function Read-SpectreConfirm { param($Message, $DefaultAnswer) $true }   # yes: verify requirement rule

# scripted selection: object-choices (with -ChoiceLabelProperty) are matched by a queued .Key; plain
# label-choices default to the FIRST choice (a real built label, so $map/$bmap lookups resolve).
$script:keys = New-Object System.Collections.Queue
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, [switch]$EnableSearch, $PageSize)
    if ($ChoiceLabelProperty) {
        $want = if ($script:keys.Count) { $script:keys.Dequeue() } else { $null }
        $m = @($Choices | Where-Object { $_.Key -eq $want })
        if ($m.Count) { return $m[0] }
        return @($Choices)[0]
    }
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

$script:splat  = $null
$script:called = 0
function Test-Win32ToolkitProject {
    param($ProjectPath, $Scenario, $Backend, $BaselineProjectPath, [switch]$Unattended, [switch]$SkipRequirementCheck)
    $script:called++
    $script:splat = $PSBoundParameters
    $true
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
Write-Host '[B] winget app, choose winget download -> NO BaselineProjectPath (unchanged default)' -ForegroundColor Cyan
$script:projects = @($under, $cand)
$script:wingetId = 'Publisher.App'
DriveUpdate @('test', 'Sandbox', 'Update', 'winget', 'back')
if ($script:called -eq 1 -and -not $script:splat.ContainsKey('BaselineProjectPath')) { Ok 'winget baseline: no BaselineProjectPath passed' } else { Bad "called=$script:called baseline=$($script:splat['BaselineProjectPath'])" }

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

Write-Host ''
if ($fail -eq 0) { Write-Host 'All UpdateBaselinePickerTUI tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail UpdateBaselinePickerTUI test(s) FAILED." -ForegroundColor Red; exit 1 }
