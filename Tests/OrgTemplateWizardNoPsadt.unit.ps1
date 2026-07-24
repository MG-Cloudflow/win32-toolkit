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

    This test drives the wizard end-to-end with PSADT hidden (Get-Module returns nothing) and Read-Host
    shadowed to accept all defaults, and asserts it completes with PsadtVersion = 'unknown' instead of
    throwing. A positive control confirms the real version is still embedded when PSADT IS present.

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
. (Join-Path $repo 'Private\New-OrgTemplate.ps1')

# The wizard embeds the module-level schema version; supply it in the dot-sourced scope.
$script:TemplateSchemaVersion = '4.0'

# --- shadows -------------------------------------------------------------------------------------
# Get-Module reads a script variable so we can flip "PSADT absent" vs "PSADT present" per case.
$script:fakePsadt = $null
function Get-Module { param([string]$Name, [switch]$ListAvailable) if ($null -ne $script:fakePsadt) { $script:fakePsadt } else { @() } }
# Every prompt returns blank, so the wizard uses every default and never blocks on input.
function Read-Host { param([Parameter(Position = 0)]$Prompt, [switch]$AsSecureString) '' }

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('orgtpl_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base -Force | Out-Null

try {
    Write-Host "`n[1] PSADT NOT installed: the wizard completes instead of crashing (issue #49)" -ForegroundColor Cyan
    $script:fakePsadt = $null
    $err = $null; $tpl = $null
    try { $tpl = New-OrgTemplate -BasePath $base -TemplateName 'TestOrgA' 6>$null }
    catch { $err = $_.Exception.Message }

    if (-not $err) { Ok 'wizard ran to completion with PSADT absent' }
    else { Bad "threw: $err" }
    if ($err -notmatch 'null-valued expression') { Ok "no 'method on a null-valued expression' error" }
    else { Bad 'THE issue #49 BUG IS BACK' }
    if ($tpl -and $tpl.PsadtVersion -eq 'unknown') { Ok "PsadtVersion falls back to 'unknown' when PSADT is absent" }
    else { Bad "expected PsadtVersion 'unknown', got '$($tpl.PsadtVersion)'" }
    $saved = Join-Path (Join-Path $base 'Templates') 'TestOrgA.json'
    if (Test-Path $saved) { Ok 'template JSON was written' } else { Bad "template not saved at $saved" }

    Write-Host "`n[2] PSADT installed: the real version is still embedded (positive control)" -ForegroundColor Cyan
    $script:fakePsadt = [pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = [version]'4.1.8' }
    $err2 = $null; $tpl2 = $null
    try { $tpl2 = New-OrgTemplate -BasePath $base -TemplateName 'TestOrgB' 6>$null }
    catch { $err2 = $_.Exception.Message }
    if (-not $err2) { Ok 'wizard ran to completion with PSADT present' } else { Bad "threw: $err2" }
    if ($tpl2 -and $tpl2.PsadtVersion -eq '4.1.8') { Ok "PsadtVersion reflects the installed module ('4.1.8')" }
    else { Bad "expected PsadtVersion '4.1.8', got '$($tpl2.PsadtVersion)'" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All OrgTemplateWizardNoPsadt tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail OrgTemplateWizardNoPsadt test(s) FAILED." -ForegroundColor Red; exit 1 }
