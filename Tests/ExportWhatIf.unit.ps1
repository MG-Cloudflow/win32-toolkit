<#
    Export-Win32ToolkitIntuneWin -WhatIf is a real dry run (test campaign 2026-10-21, S9-F1).

    Before: under -WhatIf the Staging folder was not created (New-Item honoured -WhatIf), so Optimize threw
    'Project path not found: ...\Staging\...' on a project that had never been exported; and when an older
    .intunewin existed, Export printed 'Package created : ...' for that stale file.

    Now ONE ShouldProcess gates the whole build: under -WhatIf nothing is downloaded, staged, optimised or
    built, a stale package is never reported as created, and a requested publish is only announced.

    Shadows: everything that could act (IntuneWinAppUtil, the web, Optimize, Publish, the advisory) is shadowed
    and fails the test if reached. Temp folders only; the repository's Tools\ folder is only read.

    Run:  pwsh -File Tests\ExportWhatIf.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
# C-9 (TUI audit G4): the not-configured gate runs first (no marker here -> it returns nothing).
. (Join-Path $repo 'Private\Get-Win32ToolkitNotConfiguredMarker.ps1')
. (Join-Path $repo 'Private\Assert-Win32ToolkitProjectConfigured.ps1')
. (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1')

# -- shadows: nothing real may act ------------------------------------------------------------------
function Assert-Win32ToolkitPackageReady { param([string]$ProjectPath, [string]$Stage, [switch]$AllowLegacyScript) [pscustomobject]@{ Ready = $true; Warnings = [string[]]@() } }
$script:trustChecks = 0
function Assert-Win32ToolkitTrustedBinary { param($Path, $ExpectedSubject, [switch]$RemoveOnFailure) $script:trustChecks++ }   # read-only check of an existing copy
function Optimize-Win32ToolkitProject     { throw 'Optimize-Win32ToolkitProject must not be reached under -WhatIf' }
function Remove-Win32ToolkitPathWithRetry { throw 'Remove-Win32ToolkitPathWithRetry must not be reached under -WhatIf' }
function Get-Win32ToolkitNonShippingFolders { throw 'Staging must not be built under -WhatIf' }
function Publish-Win32ToolkitIntuneApp    { throw 'Publish-Win32ToolkitIntuneApp must not be reached under -WhatIf' }
function Start-Process                    { throw 'IntuneWinAppUtil.exe must not run under -WhatIf' }
function Invoke-WebRequest                { throw 'no download under -WhatIf' }
function Invoke-RestMethod                { throw 'no download under -WhatIf' }
$script:advisories = 0
function Write-Win32ToolkitPackageAdvisory { param($ProjectPath, $Context, [switch]$ProbeIfMissing) $script:advisories++ }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32wi_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$base = Join-Path $tmp 'Base'
$proj = Join-Path $base 'Projects\CloudFlow\Notepad++_x64_8.9.8.1'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
Set-Content -LiteralPath (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') '# PSADT v4 stub'
$tools = Join-Path $repo 'Tools'
$toolsBefore = @(Get-ChildItem -LiteralPath $tools -Force -ErrorAction SilentlyContinue | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';'

function Invoke-WhatIfExport {
    $err = $null; $out = @()
    try { $out = @(Export-Win32ToolkitIntuneWin -ProjectPath $proj -PublishIntune -NoPublishPrompt -WhatIf 6>&1 | ForEach-Object { "$_" }) }
    catch { $err = $_ }
    [pscustomobject]@{ Error = $err; Out = $out }
}

try {
    Write-Host '[1] never exported before: -WhatIf does not throw and writes nothing' -ForegroundColor Cyan
    $r = Invoke-WhatIfExport
    if (-not $r.Error) { Ok 'no throw (was: Project path not found: ...\Staging\...)' } else { Bad "threw: $($r.Error.Exception.Message)" }
    if (-not (Test-Path -LiteralPath (Join-Path $base 'Staging')) -and -not (Test-Path -LiteralPath (Join-Path $base 'IntuneWin'))) { Ok 'no Staging\ and no IntuneWin\ folder created' } else { Bad 'Staging or IntuneWin written under -WhatIf' }
    if (($r.Out -match '^WhatIf: would refresh Staging .*Staging\\CloudFlow\\Notepad\+\+_x64_8\.9\.8\.1, optimize it and build .*IntuneWin\\CloudFlow\\Notepad\+\+_x64_8\.9\.8\.1\.intunewin')) { Ok 'says what it would stage and build' } else { Bad "output: $($r.Out -join ' | ')" }
    if (($r.Out -match '^WhatIf: would publish to Intune after packaging \(install app\)\.$')) { Ok 'a requested publish is only announced' } else { Bad "no publish note: $($r.Out -join ' | ')" }
    if ($script:advisories -eq 1) { Ok 'the read-only package advisory still runs' } else { Bad "advisory calls: $($script:advisories)" }

    Write-Host '[2] an older .intunewin exists: it is never reported as created' -ForegroundColor Cyan
    $iw = Join-Path $base 'IntuneWin\CloudFlow'
    New-Item -ItemType Directory -Path $iw -Force | Out-Null
    $old = Join-Path $iw 'Notepad++_x64_8.9.8.1.intunewin'
    [System.IO.File]::WriteAllBytes($old, [byte[]](1..64))
    $stamp = (Get-Item -LiteralPath $old).LastWriteTimeUtc
    $r = Invoke-WhatIfExport
    if (-not $r.Error -and -not ($r.Out -match 'Package created')) { Ok 'no "Package created" line for the stale package' } else { Bad "output: $($r.Out -join ' | ') err=$($r.Error)" }
    if ((Get-Item -LiteralPath $old).LastWriteTimeUtc -eq $stamp -and @(Get-ChildItem -LiteralPath $iw).Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $base 'Staging'))) { Ok 'the old package and the folders are untouched' } else { Bad 'files changed under -WhatIf' }

    $toolsAfter = @(Get-ChildItem -LiteralPath $tools -Force -ErrorAction SilentlyContinue | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';'
    if ($toolsAfter -eq $toolsBefore) { Ok 'the Tools\ folder is unchanged (no IntuneWinAppUtil.exe download)' } else { Bad 'Tools\ changed under -WhatIf' }

    Write-Host '[3] source: one ShouldProcess for the build, none inside it' -ForegroundColor Cyan
    $src = Get-Content -LiteralPath (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1') -Raw
    if (([regex]::Matches($src, '\$PSCmdlet\.ShouldProcess\(')).Count -eq 1 -and $src -match '\$doPackage\s+=\s+\$PSCmdlet\.ShouldProcess') { Ok 'exactly one ShouldProcess ($doPackage), so -Confirm asks once' } else { Bad 'ShouldProcess count changed' }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All ExportWhatIf tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail ExportWhatIf test(s) FAILED." -ForegroundColor Red; exit 1 }
