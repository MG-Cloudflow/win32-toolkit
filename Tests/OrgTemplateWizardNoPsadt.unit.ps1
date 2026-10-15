<#
    Regression test for issue #49: the Org Template Wizard crashed at first run with
    "You cannot call a method on a null-valued expression."

    Cause: New-OrgTemplate read the installed PSADT version with

        $psadtVer = (Get-Module -Name PSAppDeployToolkit -ListAvailable |
            Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()

    On a fresh machine PSADT is not installed yet (it is pulled in later, during packaging), so the
    pipeline is $null and .Version.ToString() calls a method on nothing. The crash happens before the
    wizard prints its header, and the `if (-not $psadtVer)` fallback below it is dead code because the
    exception fires on the line above. This blocked EVERY new user at first run.

    Since PSADT 4.1/4.2 support (ORG-14) the wizard records what Select-Win32ToolkitPsadtModule would use
    for new projects (informational only). This test drives the wizard end-to-end with the selector
    shadowed - no PSADT installed, only an unsupported one, a selector that throws, a stable and a
    prerelease selection - and Read-Host shadowed to accept all defaults, and asserts it always
    completes, with PsadtVersion = 'unknown' when nothing usable is selected. Get-Module is shadowed to
    throw, proving the wizard no longer picks the newest installed copy itself (that could be a 4.3).

    Run:  pwsh -File Tests\OrgTemplateWizardNoPsadt.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitOrgTemplateText.ps1')   # D9 validation of every typed answer
. (Join-Path $repo 'Private\New-OrgTemplate.ps1')

# The wizard embeds the module-level schema version; supply it in the dot-sourced scope.
$script:TemplateSchemaVersion = '4.0'

# --- shadows -------------------------------------------------------------------------------------
# Select-Win32ToolkitPsadtModule (WP-A contract, spec 2.3) is shadowed per case: $script:selMode picks
# 'NoneInstalled', 'NoneInRange', 'Throw' or a Selected result carrying $script:selVersion.
$script:selMode    = 'NoneInstalled'
$script:selVersion = ''
$script:selCalls   = 0
function Select-Win32ToolkitPsadtModule {
    $script:selCalls++
    switch ($script:selMode) {
        'Throw'         { throw 'selector exploded' }
        'NoneInstalled' { [pscustomobject]@{ Status = 'NoneInstalled'; Module = $null; VersionText = ''; Reason = 'No PSAppDeployToolkit installed (supported: 4.1.x and 4.2.x).' } }
        'NoneInRange'   { [pscustomobject]@{ Status = 'NoneInRange'; Module = $null; VersionText = ''; NewestInstalledText = '4.3.0'; Reason = 'PSAppDeployToolkit 4.3.0 is installed but not supported.' } }
        default         { [pscustomobject]@{ Status = 'Selected'; Module = [pscustomobject]@{ Name = 'PSAppDeployToolkit' }; VersionText = $script:selVersion; Reason = '' } }
    }
}
# The wizard must not pick "the newest installed PSADT" on its own any more (it could be out of range).
function Get-Module { throw 'Get-Module must not be called by the wizard (use Select-Win32ToolkitPsadtModule)' }
# Every prompt returns blank, so the wizard uses every default and never blocks on input.
function Read-Host { param([Parameter(Position = 0)]$Prompt, [switch]$AsSecureString) '' }

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('orgtpl_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base -Force | Out-Null

function Invoke-Wizard {
    param([string]$Name)
    $res = [pscustomobject]@{ Template = $null; Error = $null }
    try { $res.Template = New-OrgTemplate -BasePath $base -TemplateName $Name 6>$null }
    catch { $res.Error = $_.Exception.Message }
    $res
}

try {
    Write-Host "`n[1] PSADT NOT installed: the wizard completes instead of crashing (issue #49)" -ForegroundColor Cyan
    $script:selMode = 'NoneInstalled'
    $r1 = Invoke-Wizard 'TestOrgA'
    if (-not $r1.Error) { Ok 'wizard ran to completion with PSADT absent' }
    else { Bad "threw: $($r1.Error)" }
    if ($r1.Error -notmatch 'null-valued expression') { Ok "no 'method on a null-valued expression' error" }
    else { Bad 'THE issue #49 BUG IS BACK' }
    if ($r1.Template -and $r1.Template.PsadtVersion -eq 'unknown') { Ok "PsadtVersion falls back to 'unknown' when PSADT is absent" }
    else { Bad "expected PsadtVersion 'unknown', got '$($r1.Template.PsadtVersion)'" }
    if ($script:selCalls -ge 1) { Ok 'the PSADT selector was consulted' } else { Bad 'Select-Win32ToolkitPsadtModule was not called' }
    $saved = Join-Path (Join-Path $base 'Templates') 'TestOrgA.json'
    if (Test-Path $saved) { Ok 'template JSON was written' } else { Bad "template not saved at $saved" }
    # Enter keeps every yes/no default. Regression: Read-TB's '$d' hint variable overwrote its [bool]$D
    # parameter (names are case-insensitive), so Enter turned every "no" default into "yes".
    $t1 = $r1.Template
    $noDefaults = [ordered]@{
        'WelcomeDialog.CheckDiskSpace'          = $t1.WelcomeDialog.CheckDiskSpace
        'WelcomeDialog.CustomText'              = $t1.WelcomeDialog.CustomText
        'UninstallWelcomeDialog.PersistPrompt'  = $t1.UninstallWelcomeDialog.PersistPrompt
        'UninstallWelcomeDialog.BlockExecution' = $t1.UninstallWelcomeDialog.BlockExecution
        'CompletionPrompt.Enabled'              = $t1.CompletionPrompt.Enabled
        'Hooks.Enabled'                         = $t1.Hooks.Enabled
        'ExtensionModule'                       = $t1.ExtensionModule
        'CustomAssets'                          = $t1.CustomAssets
    }
    $flipped = @($noDefaults.Keys | Where-Object { $noDefaults[$_] -ne $false })
    if ($t1 -and $flipped.Count -eq 0) { Ok "Enter keeps all $($noDefaults.Count) 'no' defaults (no yes/no answer flips to yes)" } else { Bad "flipped to yes on Enter: $($flipped -join ', ')" }
    if ($t1 -and $t1.WelcomeDialog.Enabled -eq $true -and $t1.WelcomeDialog.AllowDefer -eq $true -and $t1.ProgressDialog.Enabled -eq $true) { Ok "Enter keeps the 'yes' defaults" } else { Bad 'a yes default was lost' }

    Write-Host "`n[2] PSADT installed (4.1.8 selected): the selected version is embedded (positive control)" -ForegroundColor Cyan
    $script:selMode = 'Selected'; $script:selVersion = '4.1.8'
    $r2 = Invoke-Wizard 'TestOrgB'
    if (-not $r2.Error) { Ok 'wizard ran to completion with PSADT present' } else { Bad "threw: $($r2.Error)" }
    if ($r2.Template -and $r2.Template.PsadtVersion -eq '4.1.8') { Ok "PsadtVersion reflects the selected module ('4.1.8')" }
    else { Bad "expected PsadtVersion '4.1.8', got '$($r2.Template.PsadtVersion)'" }

    Write-Host "`n[3] A prerelease selection is recorded with its label" -ForegroundColor Cyan
    $script:selMode = 'Selected'; $script:selVersion = '4.2.0-rc2'
    $r3 = Invoke-Wizard 'TestOrgC'
    if ($r3.Template -and $r3.Template.PsadtVersion -eq '4.2.0-rc2') { Ok "PsadtVersion = '4.2.0-rc2'" }
    else { Bad "expected '4.2.0-rc2', got '$($r3.Template.PsadtVersion)' (error: $($r3.Error))" }

    Write-Host "`n[4] Only an unsupported PSADT installed (NoneInRange): 'unknown', not the out-of-range version" -ForegroundColor Cyan
    $script:selMode = 'NoneInRange'
    $r4 = Invoke-Wizard 'TestOrgD'
    if (-not $r4.Error -and $r4.Template.PsadtVersion -eq 'unknown') { Ok "PsadtVersion = 'unknown' (4.3.0 is not recorded)" }
    else { Bad "got '$($r4.Template.PsadtVersion)' (error: $($r4.Error))" }

    Write-Host "`n[5] The selector throws: the wizard still completes" -ForegroundColor Cyan
    $script:selMode = 'Throw'
    $r5 = Invoke-Wizard 'TestOrgE'
    if (-not $r5.Error -and $r5.Template.PsadtVersion -eq 'unknown') { Ok "selector failure -> PsadtVersion 'unknown', wizard completes" }
    else { Bad "got '$($r5.Template.PsadtVersion)' (error: $($r5.Error))" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All OrgTemplateWizardNoPsadt tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail OrgTemplateWizardNoPsadt test(s) FAILED." -ForegroundColor Red; exit 1 }
