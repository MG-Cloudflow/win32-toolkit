<#
    Tests build/Publish-ToPSGallery.ps1 staging.

    THE FOOTGUN THIS GUARDS: Publish-PSResource packs EVERY file under -Path (no -Exclude, and a
    manifest FileList does not filter). The repo root mixes the module with docs/, Tests/, build/,
    .github/, mkdocs.yml, CLAUDE.md and the release-please files. If the publish script ever pointed at
    the repo root, or its copy list drifted, we would ship all of that to the Gallery. So this runs the
    real staging (real Copy-Item) with only the Gallery/analyzer cmdlets shadowed, and asserts the
    staged payload contains the module files and NONE of the repo scaffolding.

    Run:  pwsh -File Tests\PublishStaging.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$script = Join-Path $repo 'build\Publish-ToPSGallery.ps1'

# ── shadows: capture the staged payload at the moment of "publish", skip the heavy/real cmdlets ────
# $global: (not $script:) so the capture survives the `& external.ps1` scope boundary.
$global:w32tStaged = @()
function Publish-PSResource {
    param([string]$Path, [Parameter(ValueFromRemainingArguments)]$rest)
    $global:w32tStaged = @(Get-ChildItem $Path -Recurse -File | ForEach-Object { $_.FullName.Substring($Path.Length + 1).Replace('\', '/') })
}
function Test-ModuleManifest { param([Parameter(ValueFromRemainingArguments)]$a) [pscustomobject]@{ Version = '1.0.1' } }
# PSScriptAnalyzer absent -> lint block skipped; PSResourceGet present -> install skipped.
function Get-Module { param([switch]$ListAvailable, $Name, [Parameter(ValueFromRemainingArguments)]$rest) if ($Name -eq 'Microsoft.PowerShell.PSResourceGet') { [pscustomobject]@{ Name = $Name } } else { $null } }
function Import-Module { param([Parameter(ValueFromRemainingArguments)]$a) }
function Install-Module { param([Parameter(ValueFromRemainingArguments)]$a) }

function Run-Staging([switch]$IncludeTools) {
    $global:w32tStaged = @()
    if ($IncludeTools) { & $script -DryRun -IncludeTools 6>$null } else { & $script -DryRun 6>$null }
    return $global:w32tStaged
}

Write-Host "`n[1] default staging: module files present, repo scaffolding absent" -ForegroundColor Cyan
$staged = Run-Staging

$mustInclude = @('win32-toolkit.psd1', 'win32-toolkit.psm1', 'LICENSE', 'README.md')
foreach ($f in $mustInclude) {
    if ($staged -contains $f) { Ok "ships $f" } else { Bad "MISSING $f from the package" }
}
if (@($staged | Where-Object { $_ -like 'Public/*.ps1' }).Count -gt 0) { Ok 'ships Public/*.ps1' } else { Bad 'no Public/ scripts staged' }
if (@($staged | Where-Object { $_ -like 'Private/*.ps1' }).Count -gt 0) { Ok 'ships Private/*.ps1' } else { Bad 'no Private/ scripts staged' }

# The whole point: none of this may reach the Gallery.
$mustExclude = @('docs', 'Tests', 'build', '.github', 'knowledge-base')
foreach ($dir in $mustExclude) {
    if (@($staged | Where-Object { $_ -like "$dir/*" }).Count -eq 0) { Ok "excludes $dir/" } else { Bad "LEAKED $dir/ into the package" }
}
foreach ($file in 'mkdocs.yml', 'CLAUDE.md', 'PSScriptAnalyzerSettings.psd1', 'release-please-config.json', '.release-please-manifest.json', 'Launch-Win32Toolkit.cmd') {
    if ($staged -notcontains $file) { Ok "excludes $file" } else { Bad "LEAKED $file into the package" }
}

Write-Host "`n[2] Tools/ is omitted by default (downloaded on demand, not redistributed)" -ForegroundColor Cyan
if (@($staged | Where-Object { $_ -like 'Tools/*' }).Count -eq 0) { Ok 'Tools/ omitted by default' } else { Bad 'Tools/ shipped by default (should require -IncludeTools)' }

Write-Host "`n[3] -IncludeTools ships Tools/ when the binary exists" -ForegroundColor Cyan
if (Test-Path (Join-Path $repo 'Tools\IntuneWinAppUtil.exe')) {
    $stagedT = Run-Staging -IncludeTools
    if (@($stagedT | Where-Object { $_ -like 'Tools/*' }).Count -gt 0) { Ok '-IncludeTools ships Tools/' } else { Bad '-IncludeTools did not ship Tools/' }
} else {
    Write-Host '  SKIP: Tools/IntuneWinAppUtil.exe not present locally' -ForegroundColor DarkGray
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PublishStaging tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PublishStaging test(s) FAILED." -ForegroundColor Red; exit 1 }
