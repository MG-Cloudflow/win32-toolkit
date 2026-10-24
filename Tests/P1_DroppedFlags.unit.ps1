<#
    P1 — when the winget download fails, Invoke-Win32Toolkit silently DROPPED everything the user asked for.

    Rename / Configure / Get-AppIcon / Set-Win32ToolkitAppDependency / Invoke-Win32ToolkitFinalize are all
    gated on $downloadSuccess. The old else branch emitted ONE generic line:

        "Project was created but download failed. You can manually add the application files ..."

    A user who ran with -PublishIntune therefore got NO diagnostic that publishing never happened — they
    only found out when the app failed to show up in Intune. Same for -PackageIntune, -RunTest,
    -PublishUpdate and -DependsOn.

    These tests assert the failure path now NAMES every option the caller actually supplied, names ONLY
    those (no false noise about flags they never passed), and then stops with the terminating error
    W32T.DownloadFailed (TUI audit G2) after those warnings — the project folder is deliberately kept so
    the run can be retried.

    Also (installer-identity PR 1): -InstallerType reaches the download as the pin (parameter); without it
    the download is unpinned (winget-default). The rebuild self-anchor is read before Create-PSADTProject
    (which removes an existing project folder) and the pin is resolved after it.

    Nothing heavy runs: winget, the base-path/template resolution, the scaffolder, the installer pin, the
    downloader and the finalize step are all shadowed. No network, no PSADT, no Intune.

    Run:  pwsh -File Tests\P1_DroppedFlags.unit.ps1
#>
# Test shadows keep the real command names and signatures.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# System under test + the one real helper it needs for naming.
. (Join-Path $repo 'Private\Sanitize-ProjectName.ps1')
# C-9: a -DependsOn run validates its references before anything is downloaded or created (B3 r2.1; real, pure).
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Assert-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Initialize-Win32ToolkitRunResult.ps1')   # C-9: the result object (TUI audit G2, S8-F3)
. (Join-Path $repo 'Private\Complete-Win32ToolkitRunResult.ps1')
# C-9 (TUI audit G4): every error after the scaffold, before the end of the configure step, marks the project (temp folders).
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Write-Win32ToolkitNotConfiguredMarker.ps1')
. (Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1')

# ── shadows: everything that would touch winget / the registry / the disk / Intune ───────────────
$script:tmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ('w32flags_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:tmpBase -Force | Out-Null

function Test-WingetInstalled { $true }
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure) $script:tmpBase }
function Get-OrgTemplate { param($TemplateName, $BasePath) [pscustomobject]@{ TemplateName = 'TestTpl' } }
# C-9 (speed-up PR 4, V-14): Invoke-Win32Toolkit registers as the asynchronous-teardown owner and joins in its finally;
# inert doubles: no live owner, a join that emits nothing.
function Get-Win32ToolkitAsyncTeardownOwner { $null }
function Wait-Win32ToolkitHyperVTeardown { param($VMName, $ReleaseOwner, [switch]$Prewarm) }
# ...and the capture pre-warm it starts after the base folder (HyperVCapturePrewarm), inert.
function Start-Win32ToolkitHyperVPrewarm { }

# The -Id fast path resolves via Resolve-Win32ToolkitWingetId. This test is about the DOWNLOAD failure,
# not id resolution, so shadow the resolver to a valid app and let the pipeline reach the failing download.
function Resolve-Win32ToolkitWingetId { param($Id) [pscustomobject]@{ Name = 'Git'; Id = $Id; Version = '2.45.0'; Source = 'winget' } }

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
$script:order = [System.Collections.Generic.List[string]]::new()
function Create-PSADTProject { param($ProjectName, $ProjectPath, [switch]$Force) $script:order.Add('create'); $true }

# Rebuild self-anchor (installer-identity PR 1, C-9): read before Create-PSADTProject removes an old folder.
$script:selfSeen = $null
function Get-Win32ToolkitSelfAnchor { param($ProjectPath, $TenantId) $script:order.Add('self'); $script:selfSeen = $PSBoundParameters; $null }

# Installer technology (installer-identity PR 1, C-9): the pin is resolved before the download. The shadow
# mirrors the real resolver for an explicit -InstallerType (parameter) and for none (winget-default).
function Resolve-Win32ToolkitInstallerPin {
    param($TemplateDirectory, $WingetId, $Version, $InstallerType, $ExcludePath, $TenantId, $SelfAnchor)
    $script:order.Add('pin')
    [pscustomobject]@{
        InstallerType = [string]$InstallerType; Family = ''; Predecessor = $null; WingetClient = '1.29.380'
        PinnedBy      = if ($InstallerType) { 'parameter' } else { 'winget-default' }
        Reason        = if ($InstallerType) { 'requested' } else { "winget's choice" }
    }
}

# THE FAILURE UNDER TEST: the download does not succeed. It records what it was asked to download.
$script:dlSeen = $null
function Download-WingetApp { param($AppId, $AppName, $DownloadPath, $Architecture, $InstallerType, $PinnedBy, $PinReason) $script:dlSeen = $PSBoundParameters; $false }

# Anything downstream of the download must never run on this path — if it does, the test explodes loudly.
function Invoke-Win32ToolkitFinalize {
    param($ProjectPath, $ProjectName, $AppInfo, $RunTest, $UpdateVersionsBack, $UpdateSpecificVersion, $UpdateBaselineInstallerType,
        [switch]$PackageIntune, [switch]$PublishIntune, [switch]$PublishUpdate, $BasePath, $Result)
    throw 'Invoke-Win32ToolkitFinalize ran even though the download failed'
}
function Write-Win32ToolkitIdentityDelta {
    param($ProjectPath, $TenantId, [switch]$Quiet)
    throw 'Write-Win32ToolkitIdentityDelta ran even though the download failed'
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

if ($r.Threw -and $r.Threw.FullyQualifiedErrorId -eq 'W32T.DownloadFailed') { Ok 'the download-failure path stops with W32T.DownloadFailed (terminating; the project folder is kept for a retry)' }
else { Bad "expected W32T.DownloadFailed, got: $(if ($r.Threw) { "$($r.Threw.FullyQualifiedErrorId): $($r.Threw.Exception.Message)" } else { 'no error' })" }
$wantStart = "Download FAILED for 'Git.Git' (x64): nothing was configured, tested, packaged or published."
if ($r.Threw -and $r.Threw.Exception.Message.StartsWith($wantStart) -and $r.Threw.Exception.Message.Contains((Join-Path $script:tmpBase 'Projects\TestTpl\Git_x64_2.45.0'))) { Ok 'the error message names the app, the architecture and the kept project folder' }
else { Bad "message: $(if ($r.Threw) { $r.Threw.Exception.Message })" }
if ($r.Threw -and [string]$r.Threw.TargetObject -eq (Join-Path $script:tmpBase 'Projects\TestTpl\Git_x64_2.45.0')) { Ok 'its TargetObject is the project path' } else { Bad "TargetObject: $(if ($r.Threw) { $r.Threw.TargetObject })" }
# TUI audit G4: the kept folder is marked not configured (Stage Download, the W32T id), and the message says so.
$markerFile = Join-Path $script:tmpBase 'Projects\TestTpl\Git_x64_2.45.0\Documentation\NotConfigured.json'
$marker = if (Test-Path -LiteralPath $markerFile) { Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json } else { $null }
if ($marker -and $marker.Stage -eq 'Download' -and $marker.ErrorId -eq 'W32T.DownloadFailed' -and ([string]$marker.Reason).StartsWith("Download FAILED for 'Git.Git' (x64)")) { Ok 'the kept project folder is marked not configured: Stage Download, ErrorId W32T.DownloadFailed' }
else { Bad "marker: $(if ($marker) { $marker | ConvertTo-Json -Compress } else { 'none' })" }
if ($r.Threw -and $r.Threw.Exception.Message.Contains('The project folder was kept for a retry and marked not configured: ')) { Ok "the message says 'kept for a retry and marked not configured'" } else { Bad "message: $(if ($r.Threw) { $r.Threw.Exception.Message })" }
if ($r.Text -match '(?i)download\s+failed' -and $r.Text -match [regex]::Escape('-PublishIntune')) { Ok 'the warnings were written before the error (the error does not replace them)' }
else { Bad "warnings before the error:`n$($r.Text)" }

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

$script:OrgTemplate = [pscustomobject]@{ TemplateName = 'stale' }
$bare = Invoke-Failing
if ($bare.Threw -and $bare.Threw.FullyQualifiedErrorId -eq 'W32T.DownloadFailed') { Ok 'the bare run also stops with W32T.DownloadFailed' }
else { Bad "bare run: $(if ($bare.Threw) { "$($bare.Threw.FullyQualifiedErrorId): $($bare.Threw.Exception.Message)" } else { 'no error' })" }
if ($null -eq $script:OrgTemplate) { Ok 'the finally still clears $script:OrgTemplate after W32T.DownloadFailed' } else { Bad 'org template leaked after W32T.DownloadFailed' }

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

# ══ 3. installer technology reaches the download (installer-identity PR 1) ═════════════════════════
Write-Host '[P1] -InstallerType reaches the download; without it winget chooses' -ForegroundColor Cyan
$script:dlSeen = $null
$t = Invoke-Failing -ExtraArgs @{ InstallerType = 'nullsoft'; UpdateBaselineInstallerType = 'Both'; RunTest = @('Update') }
if ($t.Threw -and $t.Threw.FullyQualifiedErrorId -eq 'W32T.DownloadFailed' -and $script:dlSeen -and $script:dlSeen['InstallerType'] -eq 'nullsoft' -and $script:dlSeen['PinnedBy'] -eq 'parameter' -and $script:dlSeen['PinReason'] -eq 'requested') {
    Ok '-InstallerType nullsoft -> Download-WingetApp -InstallerType nullsoft -PinnedBy parameter -PinReason requested'
} else { Bad "threw=$($t.Threw) download saw: $(if ($script:dlSeen) { ($script:dlSeen.Keys | ForEach-Object { "$_=$($script:dlSeen[$_])" }) -join '; ' })" }
if ($t.Text -match [regex]::Escape('-RunTest (Update)')) { Ok 'the failed download still names the skipped -RunTest' } else { Bad "warnings:`n$($t.Text)" }
$script:dlSeen = $null
$null = Invoke-Failing
if ($script:dlSeen -and $script:dlSeen['InstallerType'] -eq '' -and $script:dlSeen['PinnedBy'] -eq 'winget-default') { Ok "no -InstallerType -> the download gets -InstallerType '' (winget chooses, unpinned arguments)" } else { Bad "download saw: $(if ($script:dlSeen) { ($script:dlSeen.Keys | ForEach-Object { "$_=$($script:dlSeen[$_])" }) -join '; ' })" }

$script:order.Clear(); $script:selfSeen = $null
$null = Invoke-Failing
$wantSelf = Join-Path $script:tmpBase 'Projects\TestTpl\Git_x64_2.45.0'
if (($script:order -join ',') -eq 'self,create,pin' -and $script:selfSeen -and $script:selfSeen['ProjectPath'] -eq $wantSelf) { Ok 'the rebuild self-anchor is read for the project path BEFORE Create-PSADTProject, the pin after it' }
else { Bad "order=[$($script:order -join ',')] self path=[$(if ($script:selfSeen) { $script:selfSeen['ProjectPath'] })]" }

Remove-Item -LiteralPath $script:tmpBase -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_DroppedFlags tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_DroppedFlags test(s) FAILED." -ForegroundColor Red; exit 1 }
