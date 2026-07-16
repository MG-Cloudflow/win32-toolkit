# TemplateAssets.unit.ps1 — B1/B7: org branding assets (logo + Classic banner) with icon precedence.
# Guards: logo becomes the base tile/dialog icon ONLY when nothing better is stamped; manual/winget/
# captured win; banner always copied; PSADT mirror; PNG validation; CustomAssets opt-in gate.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitPngBytes.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitIconSource.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitIconSource.ps1')
. (Join-Path $repo 'Private\Add-Win32ToolkitTemplateAssets.ps1')

$fail = 0
function Ok  { param($m) Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad { param($m) Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# Minimal valid 1x1 PNG.
$PNG = [byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
    0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
    0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,0x78,0x9C,0x62,0x00,0x01,0x00,0x00,0x05,0x00,0x01,
    0x0D,0x0A,0x2D,0xB4,0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82)

function Get-Win32ToolkitTemplateAssetFolder { param([string]$TemplateName,[string]$BasePath) $script:ASSET }

function New-Fixture {
    param([bool]$WithLogo=$true,[bool]$WithBanner=$true)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('tplassets_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $proj = Join-Path $root 'proj'
    $assetsSrc = Join-Path $root 'Templates\Contoso\Assets'
    New-Item -ItemType Directory -Path (Join-Path $proj 'Assets') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $proj 'PSAppDeployToolkit\Assets') -Force | Out-Null
    New-Item -ItemType Directory -Path $assetsSrc -Force | Out-Null
    if ($WithLogo)   { [System.IO.File]::WriteAllBytes((Join-Path $assetsSrc 'AppIcon.png'), $PNG) }
    if ($WithBanner) { [System.IO.File]::WriteAllBytes((Join-Path $assetsSrc 'Banner.Classic.png'), $PNG) }
    $script:ASSET = Join-Path $root 'Templates\Contoso'
    [pscustomobject]@{ Root=$root; Proj=$proj }
}
function Tmpl { param([bool]$Custom=$true) [pscustomobject]@{ TemplateName='Contoso'; CustomAssets=$Custom } }

Write-Host "`n[1] Nothing stamped -> org logo becomes the base (source='template'), banner copied, PSADT mirror" -ForegroundColor Cyan
$fx = New-Fixture
Add-Win32ToolkitTemplateAssets -ProjectPath $fx.Proj -Template (Tmpl) -WarningAction SilentlyContinue
if (Test-Path (Join-Path $fx.Proj 'Assets\AppIcon.png')) { Ok 'AppIcon.png written to project Assets' } else { Bad 'AppIcon.png missing' }
if ((Get-Win32ToolkitIconSource -ProjectPath $fx.Proj) -eq 'template') { Ok "source stamped 'template'" } else { Bad "source=[$(Get-Win32ToolkitIconSource -ProjectPath $fx.Proj)]" }
if (Test-Path (Join-Path $fx.Proj 'PSAppDeployToolkit\Assets\AppIcon.png')) { Ok 'logo mirrored into PSAppDeployToolkit\Assets' } else { Bad 'PSADT mirror missing' }
if (Test-Path (Join-Path $fx.Proj 'Assets\Banner.Classic.png')) { Ok 'Classic banner copied' } else { Bad 'banner missing' }

Write-Host "`n[2] A winget/manual icon already stamped -> org logo SKIPPED (precedence)" -ForegroundColor Cyan
foreach ($src in @('winget','manual','captured')) {
    $fx2 = New-Fixture
    # Simulate an app-specific icon already present.
    [System.IO.File]::WriteAllBytes((Join-Path $fx2.Proj 'Assets\AppIcon.png'), ([byte[]]@(1,2,3,4)))
    Set-Win32ToolkitIconSource -ProjectPath $fx2.Proj -Source $src
    Add-Win32ToolkitTemplateAssets -ProjectPath $fx2.Proj -Template (Tmpl) -WarningAction SilentlyContinue
    $srcNow = Get-Win32ToolkitIconSource -ProjectPath $fx2.Proj
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $fx2.Proj 'Assets\AppIcon.png'))
    if ($srcNow -eq $src -and $bytes.Length -eq 4) { Ok "'$src' icon preserved (org logo did not overwrite)" } else { Bad "'$src' clobbered: src=$srcNow len=$($bytes.Length)" }
}

Write-Host "`n[3] Banner still copied even when the logo is skipped (pure branding)" -ForegroundColor Cyan
$fx3 = New-Fixture
Set-Win32ToolkitIconSource -ProjectPath $fx3.Proj -Source 'winget'
Add-Win32ToolkitTemplateAssets -ProjectPath $fx3.Proj -Template (Tmpl) -WarningAction SilentlyContinue
if (Test-Path (Join-Path $fx3.Proj 'Assets\Banner.Classic.png')) { Ok 'banner copied regardless of icon precedence' } else { Bad 'banner not copied' }

Write-Host "`n[4] Re-apply is idempotent (source stays 'template', no error)" -ForegroundColor Cyan
$fx4 = New-Fixture
Add-Win32ToolkitTemplateAssets -ProjectPath $fx4.Proj -Template (Tmpl) -WarningAction SilentlyContinue
Add-Win32ToolkitTemplateAssets -ProjectPath $fx4.Proj -Template (Tmpl) -WarningAction SilentlyContinue
if ((Get-Win32ToolkitIconSource -ProjectPath $fx4.Proj) -eq 'template') { Ok 're-apply keeps source=template' } else { Bad 're-apply changed source' }

Write-Host "`n[5] CustomAssets=false -> nothing applied (opt-in gate)" -ForegroundColor Cyan
$fx5 = New-Fixture
Add-Win32ToolkitTemplateAssets -ProjectPath $fx5.Proj -Template (Tmpl -Custom $false) -WarningAction SilentlyContinue
if (-not (Test-Path (Join-Path $fx5.Proj 'Assets\Banner.Classic.png')) -and [string]::IsNullOrEmpty((Get-Win32ToolkitIconSource -ProjectPath $fx5.Proj))) { Ok 'disabled -> no assets applied' } else { Bad 'assets applied while disabled' }

Write-Host "`n[6] Invalid (non-image) logo -> warned, not stamped" -ForegroundColor Cyan
$fx6 = New-Fixture -WithLogo $false -WithBanner $false
[System.IO.File]::WriteAllBytes((Join-Path $script:ASSET 'Assets\AppIcon.png'), ([byte[]]@(0x00,0x01,0x02,0x03,0x04)))
Add-Win32ToolkitTemplateAssets -ProjectPath $fx6.Proj -Template (Tmpl) -WarningVariable wv6 -WarningAction SilentlyContinue
if ([string]::IsNullOrEmpty((Get-Win32ToolkitIconSource -ProjectPath $fx6.Proj)) -and $wv6) { Ok 'garbage logo rejected + warned, no stamp' } else { Bad "garbage logo mishandled (src=$(Get-Win32ToolkitIconSource -ProjectPath $fx6.Proj) wv=$($wv6 -join ';'))" }

Write-Host ""
if ($fail -eq 0) { Write-Host "TemplateAssets unit test PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILURE(S)" -ForegroundColor Red; exit 1 }
