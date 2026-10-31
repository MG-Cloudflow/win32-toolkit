<#
    Export-Win32ToolkitIntuneWin -PassThru (TUI audit G2, S8-F3; tui-gaps-spec 6.3, Dv10).

    With -PassThru the export returns one { ProjectPath; IntuneWinPath; Published; Problems } object: the
    .intunewin it built, the objects Publish-Win32ToolkitIntuneApp returned, and the problems that did not stop
    it (no .intunewin after IntuneWinAppUtil.exe; the update app skipped for lack of an 'already installed'
    signal). Under -WhatIf it returns the object too (IntuneWinPath empty, no problems). Without -PassThru it
    still returns nothing.

    The real Export runs; IntuneWinAppUtil.exe (Start-Process), the staging cleanup, the advisory, the trust
    check and Publish are shadowed. [5] (lean deploy script PR 2): the Staging copy's toolkit extension is re-checked after
    the clean-up - the same bytes build the package, a changed copy is W32T.PackageNotReady before IntuneWinAppUtil.exe runs. Temp folders only; the repository's Tools\ folder is only read.

    Run:  pwsh -File Tests\ExportPassThru.unit.ps1
#>
# Test shadows keep the real command names and signatures.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Start-Process, Invoke-WebRequest and Invoke-RestMethod are shadowed: no IntuneWinAppUtil.exe run, no network')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitNonShippingFolders.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
# C-9 (TUI audit G4): the not-configured gate runs first (no marker here -> it returns nothing).
. (Join-Path $repo 'Private\Get-Win32ToolkitNotConfiguredMarker.ps1')
. (Join-Path $repo 'Private\Assert-Win32ToolkitProjectConfigured.ps1')
# C-9 (lean deploy script PR 2): the package gate and Export's Staging check read the toolkit extension.
. (Join-Path $repo 'Private\Get-Win32ToolkitDeployExtension.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitDeployExtension.ps1')
. (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1')

# -- shadows ------------------------------------------------------------------------------------------
function Assert-Win32ToolkitPackageReady { param([string]$ProjectPath, [string]$Stage, [switch]$AllowLegacyScript) [pscustomobject]@{ Ready = $true; Warnings = [string[]]@() } }
function Assert-Win32ToolkitTrustedBinary { param($Path, $ExpectedSubject, [switch]$RemoveOnFailure) }   # the repository's copy is only read
# [5] tampers the Staging copy of the toolkit extension after the clean-up, as a broken copy or a stray process would.
$script:tamperStaging = $false
function Optimize-Win32ToolkitProject { param($ProjectPath) if ($script:tamperStaging) { Add-Content -LiteralPath (Join-Path $ProjectPath 'PSAppDeployToolkit.Win32Toolkit\PSAppDeployToolkit.Win32Toolkit.psm1') -Value '# changed in Staging' } }
function Remove-Win32ToolkitPathWithRetry { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force; $true }
function Write-Win32ToolkitPackageAdvisory { param($ProjectPath, $Context, [switch]$ProbeIfMissing) }
function Invoke-WebRequest { throw 'no download in this suite' }
function Invoke-RestMethod { throw 'no download in this suite' }
# IntuneWinAppUtil.exe: writes the default package into the -o folder unless $script:writePackage is $false.
$script:writePackage = $true
$script:startCalls = 0
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow)
    $script:startCalls++
    if ($script:writePackage -and "$ArgumentList" -match '-o "([^"]+)"') { [System.IO.File]::WriteAllBytes((Join-Path $Matches[1] 'Invoke-AppDeployToolkit.intunewin'), [byte[]](1..32)) }
    [pscustomobject]@{ ExitCode = 0 }
}
$script:publishCalls = [System.Collections.Generic.List[string]]::new()
function Publish-Win32ToolkitIntuneApp {
    param($IntuneWinPath, $ProjectPath, [switch]$AsUpdate, $TimeoutSeconds)
    $script:publishCalls.Add($(if ($AsUpdate) { 'update' } else { 'install' }))
    [pscustomobject]@{ AppId = $(if ($AsUpdate) { 'app-update' } else { 'app-install' }); DisplayName = 'Tool'; IsUpdateApp = [bool]$AsUpdate; PortalUri = 'https://intune.example/app' }
}
$script:requirementRule = $null
function Get-Win32ToolkitRequirementRule { param($ProjectPath) $script:requirementRule }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32pt_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$base = Join-Path $tmp 'Base'
$proj = Join-Path $base 'Projects\Contoso\Tool_x64_1.0'
New-Item -ItemType Directory -Path (Join-Path $proj 'Files') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') '# PSADT v4 stub'
$package = Join-Path $base 'IntuneWin\Contoso\Tool_x64_1.0.intunewin'

function Invoke-Export([hashtable]$ExtraArgs) {
    $script:publishCalls.Clear()
    $out = @(); $err = $null
    try { $out = @(Export-Win32ToolkitIntuneWin -ProjectPath $proj @ExtraArgs 6>$null 3>$null) } catch { $err = $_ }
    [pscustomobject]@{ Out = $out; Error = $err }
}

try {
    Write-Host '[1] a package is built' -ForegroundColor Cyan
    $script:writePackage = $true
    $r = Invoke-Export @{ NoPublishPrompt = $true; PassThru = $true }
    $o = $r.Out | Select-Object -First 1
    if (-not $r.Error -and $r.Out.Count -eq 1 -and $o.ProjectPath -eq $proj -and $o.IntuneWinPath -eq $package -and (Test-Path -LiteralPath $package) -and @($o.Problems).Count -eq 0 -and @($o.Published).Count -eq 0) {
        Ok '-PassThru -> one object: the renamed .intunewin, nothing published, no problem'
    } else { Bad "err=$($r.Error) out=$($r.Out | ConvertTo-Json -Compress -Depth 4)" }
    if ($o -and ($o.PSObject.Properties.Name -join ',') -eq 'ProjectPath,IntuneWinPath,Published,Problems' -and $o.Published -is [object[]] -and $o.Problems -is [string[]]) { Ok 'its properties: ProjectPath, IntuneWinPath, Published ([object[]]), Problems ([string[]])' } else { Bad "shape: $(if ($o) { $o.PSObject.Properties.Name -join ',' })" }

    $r = Invoke-Export @{ NoPublishPrompt = $true }
    if (-not $r.Error -and $r.Out.Count -eq 0) { Ok 'without -PassThru the export still returns nothing' } else { Bad "err=$($r.Error) out=$($r.Out.Count)" }

    Write-Host '[2] IntuneWinAppUtil.exe writes no package' -ForegroundColor Cyan
    Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
    $script:writePackage = $false
    $r = Invoke-Export @{ NoPublishPrompt = $true; PassThru = $true }
    $o = $r.Out | Select-Object -First 1
    $want = "IntuneWinAppUtil.exe finished, but $package was not found: no package was built."
    if (-not $r.Error -and $o.IntuneWinPath -eq '' -and @($o.Problems).Count -eq 1 -and $o.Problems[0] -ceq $want) { Ok "no package -> IntuneWinPath '' and the problem '$want'" } else { Bad "out=$($r.Out | ConvertTo-Json -Compress -Depth 4) err=$($r.Error)" }
    $r = Invoke-Export @{ PublishIntune = $true; PassThru = $true }
    $o = $r.Out | Select-Object -First 1
    if (-not $r.Error -and $o.Problems[0] -ceq "IntuneWinAppUtil.exe finished, but $package was not found: no package was built, so nothing was published." -and $script:publishCalls.Count -eq 0) { Ok 'with -PublishIntune the problem adds ", so nothing was published"; Publish is not called' } else { Bad "out=$($r.Out | ConvertTo-Json -Compress -Depth 4) publish=$($script:publishCalls -join ',')" }
    $script:writePackage = $true

    Write-Host '[3] publish' -ForegroundColor Cyan
    $r = Invoke-Export @{ PublishIntune = $true; PassThru = $true }
    $o = $r.Out | Select-Object -First 1
    if (-not $r.Error -and $r.Out.Count -eq 1 -and @($o.Published).Count -eq 1 -and $o.Published[0].AppId -eq 'app-install' -and $o.IntuneWinPath -eq $package -and @($o.Problems).Count -eq 0) { Ok '-PublishIntune -> Published holds the object Publish returned' } else { Bad "out=$($r.Out | ConvertTo-Json -Compress -Depth 4) err=$($r.Error)" }
    $r = Invoke-Export @{ PublishIntune = $true }
    if (-not $r.Error -and $r.Out.Count -eq 0 -and $script:publishCalls.Count -eq 1) { Ok "without -PassThru Publish's object still does not leak into the output" } else { Bad "out=$($r.Out.Count) publish=$($script:publishCalls -join ',')" }

    $script:requirementRule = $null
    $r = Invoke-Export @{ PublishIntune = $true; PublishUpdate = $true; PassThru = $true }
    $o = $r.Out | Select-Object -First 1
    $skip = "The update app was not published: this project has no reliable 'already installed' signal (no install tattoo, MSI UpgradeCode or app name)."
    if (-not $r.Error -and @($o.Published).Count -eq 1 -and @($o.Problems).Count -eq 1 -and $o.Problems[0] -ceq $skip -and ($script:publishCalls -join ',') -eq 'install') { Ok '-PublishUpdate without a requirement rule -> the update-skipped problem; the install app is still in Published' } else { Bad "out=$($r.Out | ConvertTo-Json -Compress -Depth 4) publish=$($script:publishCalls -join ',')" }
    $script:requirementRule = [pscustomobject]@{ Rule = 'x' }
    $r = Invoke-Export @{ PublishIntune = $true; PublishUpdate = $true; PassThru = $true }
    $o = $r.Out | Select-Object -First 1
    if (-not $r.Error -and (@($o.Published | ForEach-Object { $_.AppId }) -join ',') -eq 'app-install,app-update' -and @($o.Problems).Count -eq 0) { Ok 'install + update app -> both objects in Published, in publish order' } else { Bad "out=$($r.Out | ConvertTo-Json -Compress -Depth 4)" }

    Write-Host '[4] -WhatIf' -ForegroundColor Cyan
    $r = Invoke-Export @{ PublishIntune = $true; PassThru = $true; WhatIf = $true }
    $o = $r.Out | Select-Object -First 1
    if (-not $r.Error -and $r.Out.Count -eq 1 -and $o.IntuneWinPath -eq '' -and @($o.Problems).Count -eq 0 -and @($o.Published).Count -eq 0 -and $script:publishCalls.Count -eq 0) { Ok "-WhatIf -PassThru -> one object, IntuneWinPath '', no problems, nothing published" } else { Bad "out=$($r.Out | ConvertTo-Json -Compress -Depth 4) err=$($r.Error)" }
    Write-Host '[5] the Staging copy of the toolkit extension (lean deploy script PR 2)' -ForegroundColor Cyan
    Copy-Item -LiteralPath (Join-Path $repo 'DeployExtension\PSAppDeployToolkit.Win32Toolkit') -Destination (Join-Path $proj 'PSAppDeployToolkit.Win32Toolkit') -Recurse
    $script:tamperStaging = $false; $script:startCalls = 0
    $r = Invoke-Export @{ NoPublishPrompt = $true; PassThru = $true }
    if (-not $r.Error -and $script:startCalls -eq 1 -and ($r.Out | Select-Object -First 1).IntuneWinPath -eq $package) { Ok 'the same extension in Staging -> the package is built' } else { Bad "same: err=$($r.Error) start=$($script:startCalls)" }
    $script:tamperStaging = $true; $script:startCalls = 0
    $r = Invoke-Export @{ NoPublishPrompt = $true; PassThru = $true }
    if ($r.Error -and $r.Error.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and $r.Error.Exception.Message.Contains('cannot vouch for the Staging copy') -and $r.Error.Exception.Message.Contains('differs') -and $script:startCalls -eq 0) {
        Ok 'a changed Staging copy -> W32T.PackageNotReady before IntuneWinAppUtil.exe runs'
    } else { Bad "tampered: err=$($r.Error) start=$($script:startCalls)" }
    $script:tamperStaging = $false
    Remove-Item -LiteralPath (Join-Path $proj 'PSAppDeployToolkit.Win32Toolkit') -Recurse -Force}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All ExportPassThru tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail ExportPassThru test(s) FAILED." -ForegroundColor Red; exit 1 }
