<#
    Compare-Win32ToolkitUiToTemplate — turns the guest driver's state-log into PASS/WARN/FAIL/GAP checks
    against the org template.

      Covers: a fully-branded run (every structural check PASS, the 4 visual expectations GAP), the
      negative paths (wrong company → WARN, completion expected but never reached → FAIL, deferral expected
      but no Defer button → FAIL), the visual GAP set, and the field parser's robustness against values
      that themselves contain apostrophes and '&'/'=' (which the naive single-quote split would break on).

    Run:  pwsh -File Tests\CompareUiToTemplate.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m) { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Compare-Win32ToolkitUiToTemplate.ps1')

function New-TempDir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('cmpu_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
$dir = New-TempDir
function Write-Log { param([string[]]$Lines) $p = Join-Path $dir ('log_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log'); $Lines | Set-Content -LiteralPath $p -Encoding UTF8; return $p }
function Status { param($Report, [string]$Name) ($Report.Checks | Where-Object Name -eq $Name).Status }

$fullTemplate = [pscustomobject]@{
    TemplateName = 'Contoso'; CompanyName = 'Contoso IT'; DialogStyle = 'Fluent'; FluentAccentColor = '0xFF0078D7'
    LanguageOverride = 'nl'; CustomAssets = $true
    ProgressMessage = [pscustomobject]@{ Install = 'Installation in progress. Please wait...'; Uninstall = 'Uninstallation in progress. Please wait...' }
    BalloonComplete = [pscustomobject]@{ Install = 'Installation complete.'; Uninstall = 'Uninstallation complete.' }
    WelcomeDialog = [pscustomobject]@{ Enabled = $true; AllowDefer = $true; DeferTimes = 3; CloseProcessesCountdown = 120 }
    UninstallWelcomeDialog = [pscustomobject]@{ Enabled = $true; CloseProcessesCountdown = 60 }
    ProgressDialog = [pscustomobject]@{ Enabled = $true; StatusMessage = ''; StatusMessageDetail = '' }
    CompletionPrompt = [pscustomobject]@{ Enabled = $true; Message = 'The installation has completed successfully.'; ButtonRightText = 'OK' }
}

# ── (a) fully-branded install: structural PASS, visual GAP ─────────────────────────────────────────
Write-Host '[a] a fully-branded install run passes every structural check' -ForegroundColor Cyan
$log = Write-Log @(
    "2026-08-05T10:00:00.0+00:00 SESSION_START host=WIN user=t type=Install"
    "2026-08-05T10:00:05.0+00:00 STATE Welcome app='Firefox' subtitle='Contoso IT - App Installation' msg='' custom='' buttons='ButtonLeft=Close Apps & Install(enabled);ButtonRight=Defer(enabled);' defers='3' countdown='120' hasIcon=1 hasProgress=0 hasAppsList=1 shot='01_Welcome.png'"
    "2026-08-05T10:00:10.0+00:00 STATE Progress app='Firefox' subtitle='Installation in progress. Please wait...' msg='' custom='' buttons='' defers='' countdown='' hasIcon=1 hasProgress=1 hasAppsList=0 shot='02_Progress.png'"
    "2026-08-05T10:00:40.0+00:00 STATE CompletionPrompt app='Firefox' subtitle='' msg='The installation has completed successfully.' custom='' buttons='ButtonRight=OK(enabled);' defers='' countdown='' hasIcon=1 hasProgress=0 hasAppsList=0 shot='03_Done.png'"
    "2026-08-05T10:00:45.0+00:00 RESULT COMPLETE deployExited=1"
)
$rep = Compare-Win32ToolkitUiToTemplate -StateLogPath $log -Template $fullTemplate -DeploymentType Install
if ($rep.Summary.Fail -eq 0) { Ok "no FAILs ($($rep.Summary.Pass) pass)" } else { Bad "$($rep.Summary.Fail) unexpected FAIL(s)" }
if ((Status $rep 'Company name in subtitle') -eq 'PASS') { Ok 'company subtitle PASS' } else { Bad 'company subtitle not PASS' }
if ((Status $rep 'Deferral offered') -eq 'PASS') { Ok 'deferral offered PASS' } else { Bad 'deferral not PASS' }
if ((Status $rep 'Completion prompt reached') -eq 'PASS') { Ok 'completion reached PASS' } else { Bad 'completion not PASS' }
if ($rep.Summary.Gap -eq 4) { Ok '4 visual GAP checks (accent/logo/language/toast)' } else { Bad "expected 4 GAP, got $($rep.Summary.Gap)" }

# ── (b) wrong company → WARN ───────────────────────────────────────────────────────────────────────
Write-Host '[b] a subtitle without the company name warns' -ForegroundColor Cyan
$log = Write-Log @(
    "t SESSION_START host=WIN user=t type=Install"
    "t STATE Welcome app='Firefox' subtitle='Wrong Corp - App Installation' msg='' custom='' buttons='ButtonLeft=Install(enabled);ButtonRight=Defer(enabled);' defers='3' countdown='120' hasIcon=1 hasProgress=0 hasAppsList=1 shot='01.png'"
    "t RESULT COMPLETE deployExited=1"
)
$rep = Compare-Win32ToolkitUiToTemplate -StateLogPath $log -Template $fullTemplate
if ((Status $rep 'Company name in subtitle') -eq 'WARN') { Ok 'wrong company → WARN' } else { Bad "expected WARN, got $(Status $rep 'Company name in subtitle')" }

# ── (c) completion expected but never shown → FAIL ─────────────────────────────────────────────────
Write-Host '[c] completion prompt configured but not reached → FAIL' -ForegroundColor Cyan
$log = Write-Log @(
    "t SESSION_START host=WIN user=t type=Install"
    "t STATE Welcome app='Firefox' subtitle='Contoso IT - App Installation' msg='' custom='' buttons='ButtonLeft=Install(enabled);ButtonRight=Defer(enabled);' defers='3' countdown='120' hasIcon=1 hasProgress=0 hasAppsList=1 shot='01.png'"
    "t STATE Progress app='Firefox' subtitle='Installation in progress. Please wait...' msg='' custom='' buttons='' defers='' countdown='' hasIcon=1 hasProgress=1 hasAppsList=0 shot='02.png'"
    "t RESULT COMPLETE deployExited=1"
)
$rep = Compare-Win32ToolkitUiToTemplate -StateLogPath $log -Template $fullTemplate
if ((Status $rep 'Completion prompt reached') -eq 'FAIL') { Ok 'missing completion → FAIL' } else { Bad "expected FAIL, got $(Status $rep 'Completion prompt reached')" }

# ── (d) deferral expected but no Defer button → FAIL ───────────────────────────────────────────────
Write-Host '[d] AllowDefer but the Welcome shows no Defer button → FAIL' -ForegroundColor Cyan
$log = Write-Log @(
    "t SESSION_START host=WIN user=t type=Install"
    "t STATE Welcome app='Firefox' subtitle='Contoso IT - App Installation' msg='' custom='' buttons='ButtonLeft=Install(enabled);' defers='' countdown='120' hasIcon=1 hasProgress=0 hasAppsList=1 shot='01.png'"
    "t RESULT COMPLETE deployExited=1"
)
$rep = Compare-Win32ToolkitUiToTemplate -StateLogPath $log -Template $fullTemplate
if ((Status $rep 'Deferral offered') -eq 'FAIL') { Ok 'no Defer button → FAIL' } else { Bad "expected FAIL, got $(Status $rep 'Deferral offered')" }

# ── (e) parser robustness: apostrophes and '&'/'=' inside values ───────────────────────────────────
Write-Host "[e] a value containing an apostrophe and '&' parses correctly" -ForegroundColor Cyan
$log = Write-Log @(
    "t SESSION_START host=WIN user=t type=Install"
    "t STATE Welcome app='Bob's Editor & More' subtitle='O'Brien IT - App Installation' msg='' custom='' buttons='ButtonLeft=Close Apps & Install(enabled);ButtonRight=Defer(enabled);' defers='3' countdown='120' hasIcon=1 hasProgress=0 hasAppsList=1 shot='01.png'"
    "t RESULT COMPLETE deployExited=1"
)
$rep = Compare-Win32ToolkitUiToTemplate -StateLogPath $log -Template $fullTemplate
$w = $rep.States | Where-Object State -eq 'Welcome'
if ($w.Subtitle -eq "O'Brien IT - App Installation") { Ok "apostrophe subtitle parsed intact ('$($w.Subtitle)')" } else { Bad "subtitle mangled: '$($w.Subtitle)'" }
if ($w.Defers -eq '3') { Ok 'field AFTER the tricky value still parsed (defers=3)' } else { Bad "downstream field lost: defers='$($w.Defers)'" }

# ── (f) uninstall run selects the uninstall welcome section ────────────────────────────────────────
Write-Host '[f] an uninstall run validates against UninstallWelcomeDialog' -ForegroundColor Cyan
$log = Write-Log @(
    "t SESSION_START host=WIN user=t type=Uninstall"
    "t STATE UninstallWelcome app='Firefox' subtitle='Contoso IT - App Uninstallation' msg='' custom='' buttons='ButtonLeft=Close Apps & Uninstall(enabled);' defers='' countdown='60' hasIcon=1 hasProgress=0 hasAppsList=1 shot='01.png'"
    "t STATE Progress app='Firefox' subtitle='Uninstallation in progress. Please wait...' msg='' custom='' buttons='' defers='' countdown='' hasIcon=1 hasProgress=1 hasAppsList=0 shot='02.png'"
    "t RESULT COMPLETE deployExited=1"
)
$rep = Compare-Win32ToolkitUiToTemplate -StateLogPath $log -Template $fullTemplate -DeploymentType Uninstall
if ((Status $rep 'Welcome dialog reached') -eq 'PASS') { Ok 'uninstall welcome reached PASS' } else { Bad "uninstall welcome not PASS: $(Status $rep 'Welcome dialog reached')" }
if ($rep.Summary.Fail -eq 0) { Ok 'uninstall run has no FAILs' } else { Bad "$($rep.Summary.Fail) FAIL(s) on uninstall" }

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
