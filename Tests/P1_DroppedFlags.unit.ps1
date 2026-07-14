<#
    P1 — when the winget download fails, Invoke-Win32Toolkit silently DROPPED everything the user asked for.

    Rename / Configure / Get-AppIcon / Set-Win32ToolkitAppDependency / Invoke-Win32ToolkitFinalize are all
    gated on $downloadSuccess. The old else branch emitted ONE generic line:

        "Project was created but download failed. You can manually add the application files ..."

    A user who ran with -PublishIntune therefore got NO diagnostic that publishing never happened — they
    only found out when the app failed to show up in Intune. Same for -PackageIntune, -RunTest,
    -PublishUpdate and -DependsOn.

    These tests assert the failure path now NAMES every option the caller actually supplied, names ONLY
    those (no false noise about flags they never passed), and still returns instead of throwing — the
    project folder is deliberately kept so the run can be retried.

    Nothing heavy runs: winget, the base-path/template resolution, the scaffolder, the downloader and the
    finalize step are all shadowed. No network, no PSADT, no Intune.

    Run:  pwsh -File Tests\P1_DroppedFlags.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# System under test + the one real helper it needs for naming.
. (Join-Path $repo 'Private\Sanitize-ProjectName.ps1')
. (Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1')

# ── shadows: everything that would touch winget / the registry / the disk / Intune ───────────────
$script:tmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ('w32flags_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:tmpBase -Force | Out-Null

function Test-WingetInstalled { $true }
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure) $script:tmpBase }
function Get-OrgTemplate { param($TemplateName, $BasePath) [pscustomobject]@{ TemplateName = 'TestTpl' } }

# `winget show --id ... ` — the -Id fast path scrapes this text.
function winget {
    $global:LASTEXITCODE = 0
    'Found Git [Git.Git]'
    '  Version: 2.45.0'
}

function Get-WingetAppDetails { param($AppId) @('x64') }
function Select-Architecture  { param($Architectures, $AppName, $PreSelected) 'x64' }
function Get-Win32ToolkitPaths {
    param($BasePath)
    [pscustomobject]@{
        Templates = Join-Path $script:tmpBase 'Templates'
        Projects  = Join-Path $script:tmpBase 'Projects'
        Staging   = Join-Path $script:tmpBase 'Staging'
        IntuneWin = Join-Path $script:tmpBase 'IntuneWin'
    }
}
function Create-PSADTProject { param($ProjectName, $ProjectPath, [switch]$Force) $true }

# THE FAILURE UNDER TEST: the download does not succeed.
function Download-WingetApp { param($AppId, $AppName, $DownloadPath, $Architecture) $false }

# Anything downstream of the download must never run on this path — if it does, the test explodes loudly.
function Invoke-Win32ToolkitFinalize {
    param($ProjectPath, $ProjectName, $AppInfo, $RunTest, [switch]$PackageIntune, [switch]$PublishIntune, [switch]$PublishUpdate)
    throw 'Invoke-Win32ToolkitFinalize ran even though the download failed'
}
function Set-Win32ToolkitAppDependency {
    param($ProjectPath, $DependsOn, $DependencyType)
    throw 'Set-Win32ToolkitAppDependency ran even though the download failed'
}

# Runs the pipeline against the failing download and returns the warning stream as one string.
function Invoke-Failing {
    param([hashtable]$ExtraArgs = @{})
    $warnings = @()
    $threw    = $null
    try {
        Invoke-Win32Toolkit -Id 'Git.Git' -Architecture 'x64' -Force @ExtraArgs `
            -WarningAction SilentlyContinue -WarningVariable warnings 6>$null | Out-Null
    }
    catch { $threw = $_ }
    [pscustomobject]@{
        Threw = $threw
        Text  = (@($warnings) -join "`n")
    }
}

# ══ 1. every supplied flag is NAMED ══════════════════════════════════════════════════════════════
Write-Host '[P1] download failure must NAME every option the caller supplied' -ForegroundColor Cyan

$r = Invoke-Failing -ExtraArgs @{
    PackageIntune = $true
    PublishIntune = $true
    RunTest       = @('InstallUninstall')
}

if ($null -eq $r.Threw) { Ok 'the download-failure path returns without throwing (project folder is kept for a retry)' }
else { Bad "it threw: $($r.Threw.Exception.Message)" }

if ($r.Text -match '(?i)download\s+failed') { Ok 'the warning still says the download failed' }
else { Bad "no download-failure warning. Got:`n$($r.Text)" }

foreach ($flag in '-PackageIntune', '-PublishIntune', '-RunTest') {
    if ($r.Text -match [regex]::Escape($flag)) { Ok "$flag is named as SKIPPED (was: silently dropped)" }
    else { Bad "$flag was silently dropped - not named in:`n$($r.Text)" }
}

# The user must be told plainly that nothing reached Intune, not left to infer it.
if ($r.Text -match '(?i)nothing was published|no app was uploaded') { Ok 'it states plainly that nothing was published to Intune' }
else { Bad "no explicit 'nothing was published' statement:`n$($r.Text)" }
if ($r.Text -match '(?i)nothing was packaged|no \.intunewin') { Ok 'it states plainly that no .intunewin was produced' }
else { Bad "no explicit 'nothing was packaged' statement:`n$($r.Text)" }
if ($r.Text -match '(?i)re-run|retry') { Ok 'it says what to do next (retry / re-run)' }
else { Bad "no next-step guidance:`n$($r.Text)" }

# ── the other two gated options ─────────────────────────────────────────────────────────────────
$r2 = Invoke-Failing -ExtraArgs @{ PublishUpdate = $true; DependsOn = @('winget:Microsoft.VCRedist.2015+.x64') }
if ($r2.Text -match [regex]::Escape('-PublishUpdate')) { Ok '-PublishUpdate is named as SKIPPED' }
else { Bad "-PublishUpdate silently dropped:`n$($r2.Text)" }
if ($r2.Text -match [regex]::Escape('-DependsOn')) { Ok '-DependsOn is named as SKIPPED' }
else { Bad "-DependsOn silently dropped:`n$($r2.Text)" }
if ($r2.Text -match [regex]::Escape('Microsoft.VCRedist.2015+.x64')) { Ok 'the declared dependency refs are echoed back' }
else { Bad "dependency refs not echoed:`n$($r2.Text)" }

# ══ 2. NO false noise ════════════════════════════════════════════════════════════════════════════
Write-Host '[P1] a run that supplied NO such flags must not name them' -ForegroundColor Cyan

$bare = Invoke-Failing
if ($null -eq $bare.Threw) { Ok 'the bare run also returns without throwing' }
else { Bad "bare run threw: $($bare.Threw.Exception.Message)" }

$noise = @()
foreach ($flag in '-PackageIntune', '-PublishIntune', '-PublishUpdate', '-RunTest', '-DependsOn') {
    if ($bare.Text -match [regex]::Escape($flag)) { $noise += $flag }
}
if ($noise.Count -eq 0) { Ok 'no flag the user never passed is mentioned (no false noise)' }
else { Bad "warned about flags that were never supplied: $($noise -join ', ')" }

if ($bare.Text -match '(?i)download\s+failed') { Ok 'the bare run still reports the download failure itself' }
else { Bad "bare run lost the download-failure warning:`n$($bare.Text)" }

# ── an explicit -PackageIntune:$false is 'bound' but not requested: it must not be reported ──────
$off = Invoke-Failing -ExtraArgs @{ PackageIntune = $false }
if ($off.Text -notmatch [regex]::Escape('-PackageIntune')) { Ok '-PackageIntune:$false is bound but NOT reported as skipped' }
else { Bad "reported -PackageIntune even though it was explicitly `$false:`n$($off.Text)" }

Remove-Item -LiteralPath $script:tmpBase -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_DroppedFlags tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_DroppedFlags test(s) FAILED." -ForegroundColor Red; exit 1 }
