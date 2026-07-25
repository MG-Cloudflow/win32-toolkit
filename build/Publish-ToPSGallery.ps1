#Requires -Version 7.2
<#
.SYNOPSIS
    Stage the win32-toolkit module payload and publish it to the PowerShell Gallery.
.DESCRIPTION
    The repo root mixes the module (win32-toolkit.psd1/.psm1, Public\, Private\) with things that must
    NOT ship: docs\, Tests\, build\, .github\, mkdocs.yml, CLAUDE.md, PSScriptAnalyzerSettings.psd1,
    the release-please files, and so on. Publish-PSResource has no -Exclude and a manifest FileList
    does NOT filter the package, so this stages a clean folder named exactly 'win32-toolkit' holding
    only the shippable files, validates it (Test-ModuleManifest + PSScriptAnalyzer), then publishes
    THAT folder.

    Safe by default:
      - a blank/absent -ApiKey is treated as "not configured": it SKIPS (returns, exit 0) rather than
        failing the release. PowerShell Gallery publishing is secondary to the GitHub release, so a
        missing secret must not block a release.
      - -DryRun stages and validates, then runs Publish-PSResource -WhatIf (no upload).
.PARAMETER ApiKey
    The PowerShell Gallery API key. Defaults to $env:PSGALLERY_API_KEY. Empty => skip (not an error).
.PARAMETER IncludeTools
    Also ship Tools\IntuneWinAppUtil.exe. Default omits it: the toolkit downloads it on demand, which
    keeps the package lean and avoids redistributing a Microsoft binary through the Gallery.
.PARAMETER DryRun
    Stage + validate, then Publish-PSResource -WhatIf instead of a real upload.
.EXAMPLE
    ./build/Publish-ToPSGallery.ps1 -DryRun
    Local rehearsal: stages, validates, and previews the publish without uploading.
#>
[CmdletBinding()]
param(
    [string]$ApiKey = $env:PSGALLERY_API_KEY,
    [switch]$IncludeTools,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ApiKey) -and -not $DryRun) {
    Write-Host 'PSGALLERY_API_KEY is not set - skipping the PowerShell Gallery publish (this is not an error).' -ForegroundColor Yellow
    return
}

$repoRoot = Split-Path $PSScriptRoot -Parent
# The leaf name MUST equal the module / manifest base name or Publish-PSResource rejects it.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) 'win32-toolkit'
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null

# Copy ONLY the module payload - never the repo root.
foreach ($file in 'win32-toolkit.psd1', 'win32-toolkit.psm1', 'LICENSE', 'README.md') {
    Copy-Item -Path (Join-Path $repoRoot $file) -Destination $staging
}
Copy-Item -Path (Join-Path $repoRoot 'Public')  -Destination $staging -Recurse
Copy-Item -Path (Join-Path $repoRoot 'Private') -Destination $staging -Recurse
if ($IncludeTools) { Copy-Item -Path (Join-Path $repoRoot 'Tools') -Destination $staging -Recurse }

Write-Host "Staged module payload at: $staging" -ForegroundColor Cyan
Get-ChildItem $staging -Recurse -File |
    ForEach-Object { Write-Verbose ("  {0}" -f $_.FullName.Substring($staging.Length + 1)) }

# Validate the STAGED copy so a bad manifest fails here, not at the Gallery.
$null = Test-ModuleManifest -Path (Join-Path $staging 'win32-toolkit.psd1')

# Lint gate: the Gallery scans server-side anyway; failing in CI is faster and clearer. Mirrors the
# repo's own PSScriptAnalyzerSettings and fails only on Error severity.
if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    $settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
    $issues = if (Test-Path $settings) {
        Invoke-ScriptAnalyzer -Path $staging -Recurse -Settings $settings
    } else {
        Invoke-ScriptAnalyzer -Path $staging -Recurse -Severity Error
    }
    $errors = @($issues | Where-Object { $_.Severity -eq 'Error' })
    if ($errors.Count -gt 0) {
        $errors | Format-Table RuleName, ScriptName, Line, Message -AutoSize | Out-String | Write-Host
        throw "PSScriptAnalyzer found $($errors.Count) error(s) in the staged module - refusing to publish."
    }
    Write-Host 'PSScriptAnalyzer: no errors in the staged module.' -ForegroundColor Green
}

# PSResourceGet ships with PS 7.4+, but install it if the runner is older.
if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet)) {
    Install-Module -Name Microsoft.PowerShell.PSResourceGet -Scope CurrentUser -Force -AllowClobber
}
Import-Module -Name Microsoft.PowerShell.PSResourceGet

if ($DryRun) {
    Write-Host 'DRY RUN: previewing Publish-PSResource -WhatIf (nothing is uploaded).' -ForegroundColor Yellow
    $key = if ([string]::IsNullOrWhiteSpace($ApiKey)) { 'DRYRUN-PLACEHOLDER' } else { $ApiKey }
    Publish-PSResource -Path $staging -Repository PSGallery -ApiKey $key -WhatIf -Verbose
}
else {
    Publish-PSResource -Path $staging -Repository PSGallery -ApiKey $ApiKey -Verbose
    Write-Host 'Published win32-toolkit to the PowerShell Gallery.' -ForegroundColor Green
}

Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
