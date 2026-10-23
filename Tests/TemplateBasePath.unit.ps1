<#
    The org template's own folder (Templates\<name>\: extension module, hooks, branding assets) is read from the
    run's -BasePath, not from the registry base folder (test campaign 2026-10-21, S10-F5).

    Two base folders: A (what the registry says) and B (the -BasePath of this run). Only B holds a valid template
    folder; A holds a broken extension module (psm1 only) that fails the gate if it is ever read.

    Run:  pwsh -File Tests\TemplateBasePath.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Get-Win32ToolkitPaths', 'Get-Win32ToolkitTemplateAssetFolder', 'Get-Win32ToolkitOrgExtensionLayoutFinding', 'Assert-Win32ToolkitOrgExtensionModule', 'Add-Win32ToolkitTemplateAssets') {
    . (Join-Path $repo "Private\$f.ps1")
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32tbp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$baseA = Join-Path $root 'A'   # the registry base folder
$baseB = Join-Path $root 'B'   # this run's -BasePath
# The registry says A; a lookup without -BasePath lands there.
function Get-Win32ToolkitBasePath { param([string]$BasePath, [switch]$NonInteractive, [switch]$Reconfigure) if ($BasePath) { $BasePath } else { $baseA } }
# Branding helpers Add-Win32ToolkitTemplateAssets uses (no image work here).
function ConvertTo-Win32ToolkitPngBytes { param($Bytes) $Bytes }
function Get-Win32ToolkitIconSource { param($ProjectPath) '' }
function Set-Win32ToolkitIconSource { param($ProjectPath, $Source) }

try {
    # A: a psm1-only extension module -> W32T.OrgExtensionInvalid if it is ever read.
    $extA = Join-Path $baseA 'Templates\Org\PSAppDeployToolkit.Org'
    New-Item -ItemType Directory -Path $extA -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $extA 'PSAppDeployToolkit.Org.psm1') -Value '# A'
    # B: a valid module and a banner.
    $extB = Join-Path $baseB 'Templates\Org\PSAppDeployToolkit.Org'
    New-Item -ItemType Directory -Path $extB, (Join-Path $baseB 'Templates\Org\Assets') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $extB 'PSAppDeployToolkit.Org.psm1') -Value '# B'
    Set-Content -LiteralPath (Join-Path $extB 'PSAppDeployToolkit.Org.psd1') -Value "@{ RootModule = 'PSAppDeployToolkit.Org.psm1'; ModuleVersion = '1.0' }"
    [System.IO.File]::WriteAllBytes((Join-Path $baseB 'Templates\Org\Assets\Banner.Classic.png'), [byte[]](1..16))
    $proj = Join-Path $baseB 'Projects\Org\App_x64_1.0'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $tpl = [pscustomobject]@{ TemplateName = 'Org'; ExtensionModule = $true; CustomAssets = $true }

    Write-Host '[1] the extension-module gate reads the -BasePath template folder' -ForegroundColor Cyan
    $e = $null; $dirs = @()
    try { $dirs = @(Assert-Win32ToolkitOrgExtensionModule -ProjectPath $proj -Template $tpl -BasePath $baseB) } catch { $e = $_ }
    if (-not $e -and $dirs.Count -eq 1 -and $dirs[0].FullName -eq $extB) { Ok "-BasePath B: the gate accepts B's module ($($dirs[0].FullName))" } else { Bad "B: err=$($e.FullyQualifiedErrorId) dirs=$(@($dirs | ForEach-Object FullName) -join ', ')" }
    $e = $null
    try { $null = Assert-Win32ToolkitOrgExtensionModule -ProjectPath $proj -Template $tpl } catch { $e = $_ }
    if ($e -and $e.FullyQualifiedErrorId -eq 'W32T.OrgExtensionInvalid') { Ok 'no -BasePath: the registry base A is read (its psm1-only module is refused) - the control case' } else { Bad "A: $($e.FullyQualifiedErrorId)" }

    Write-Host '[2] the branding assets are copied from the -BasePath template folder' -ForegroundColor Cyan
    Add-Win32ToolkitTemplateAssets -ProjectPath $proj -Template $tpl -BasePath $baseB
    if (Test-Path -LiteralPath (Join-Path $proj 'Assets\Banner.Classic.png')) { Ok "B's Banner.Classic.png is in the project" } else { Bad 'banner not copied from B' }

    Write-Host '[3] the -BasePath reaches every lookup (source)' -ForegroundColor Cyan
    $src = @{}
    foreach ($f in 'Private\Apply-OrgTemplate.ps1', 'Private\Add-Win32ToolkitOrgHooks.ps1', 'Private\Configure-PSADTForInstaller.ps1', 'Public\Invoke-Win32Toolkit.ps1', 'Public\New-Win32ToolkitManualApp.ps1') {
        $src[$f] = Get-Content -LiteralPath (Join-Path $repo $f) -Raw
    }
    if ($src['Private\Apply-OrgTemplate.ps1'] -match 'Assert-Win32ToolkitOrgExtensionModule -ProjectPath \$ProjectPath -Template \$Template -BasePath \$BasePath' -and
        $src['Private\Apply-OrgTemplate.ps1'] -match 'Add-Win32ToolkitTemplateAssets -ProjectPath \$ProjectPath -Template \$Template -BasePath \$BasePath' -and
        $src['Private\Apply-OrgTemplate.ps1'] -match 'Add-Win32ToolkitOrgHooks -ProjectPath \$ProjectPath -Template \$Template -BasePath \$BasePath') { Ok 'Apply-OrgTemplate passes -BasePath to the gate, the assets and the hooks' } else { Bad 'Apply-OrgTemplate does not pass -BasePath' }
    if ($src['Private\Add-Win32ToolkitOrgHooks.ps1'] -match 'Assert-Win32ToolkitOrgExtensionModule -ProjectPath \$ProjectPath -Template \$Template -BasePath \$BasePath' -and
        $src['Private\Add-Win32ToolkitOrgHooks.ps1'] -match 'Get-Win32ToolkitTemplateAssetFolder -TemplateName \$tn -BasePath \$BasePath') { Ok 'Add-Win32ToolkitOrgHooks uses -BasePath for the module gate and the hook folder' } else { Bad 'Add-Win32ToolkitOrgHooks ignores -BasePath' }
    if ($src['Private\Configure-PSADTForInstaller.ps1'] -match 'Apply-OrgTemplate -ProjectPath \$ProjectPath -Template \$script:OrgTemplate -BasePath \$BasePath' -and
        $src['Public\Invoke-Win32Toolkit.ps1'] -match 'Configure-PSADTForInstaller [^\r\n]*-BasePath \$BasePath' -and
        $src['Public\New-Win32ToolkitManualApp.ps1'] -match 'Apply-OrgTemplate -ProjectPath \$projectFullPath -Template \$script:OrgTemplate -BasePath \$BasePath') { Ok 'Invoke-Win32Toolkit and New-Win32ToolkitManualApp pass their resolved -BasePath down' } else { Bad 'a caller does not pass -BasePath' }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TemplateBasePath tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TemplateBasePath test(s) FAILED." -ForegroundColor Red; exit 1 }
