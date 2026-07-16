<#
    Integration test for the MANUAL (non-winget) app scaffold — the committed test owed by Phase E of the
    manual-app-packaging feature.

    Exercises New-Win32ToolkitManualApp against a real temp filesystem (real project folder, real
    AppConfig.json, real installer copy) with only the PSADT scaffold, org template and the finalize tail
    shadowed — so the parts that are unique to the manual path are genuinely executed:

      * easy vs advanced mode selection (the "EXE with no silent args is HARD" rule)
      * the installer (file OR folder) actually lands in Files\
      * AppConfig.App is populated as DATA (the contract Publish reads)
      * -Advanced scaffolds and STOPS (finalize is deferred to Complete-Win32ToolkitManualApp)
      * dependencies declared on a manual app land in AppConfig, exactly as on the winget path

    Run:  pwsh -File Tests\ManualApp.integration.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Sanitize-ProjectName.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')  # installer-extension source of truth (bundle support)
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Add-Win32ToolkitInstallerFiles.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitDependencies.ps1')
. (Join-Path $repo 'Public\Set-Win32ToolkitAppDependency.ps1')
. (Join-Path $repo 'Public\New-Win32ToolkitManualApp.ps1')

# --- shadow only what is NOT under test -----------------------------------------------------------
$BASE = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ma_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure) $BASE }
function Get-OrgTemplate { param($BasePath, $TemplateName) [pscustomobject]@{ TemplateName = 'Contoso'; AppScriptAuthor = 'IT' } }
function Apply-OrgTemplate { param($ProjectPath, $Template) $true }

# A real PSADT scaffold is a network/module dependency — fake the folder shape it produces.
function Create-PSADTProject {
    param($ProjectPath, $AppName, $AppVersion, $Architecture, $Force)
    New-Item -ItemType Directory -Path $ProjectPath -Force | Out-Null
    foreach ($d in 'Files', 'SupportFiles') { New-Item -ItemType Directory -Path (Join-Path $ProjectPath $d) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1') -Value '## <Perform Installation tasks here>'
    return $true
}
$script:patched = $null
function Set-PSADTDataDrivenScript { param($ScriptPath, [switch]$ManualInstall) $script:patched = [bool]$ManualInstall; $true }
$script:finalized = $false
function Invoke-Win32ToolkitFinalize { param($ProjectPath, $ProjectName, $AppInfo, $RunTest, [switch]$PackageIntune, [switch]$PublishIntune, [switch]$PublishUpdate) $script:finalized = $true }

function New-Src { param([string]$Name) $d = Join-Path $BASE ('src_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $d -Force | Out-Null; $f = Join-Path $d $Name; Set-Content -LiteralPath $f 'binary'; $f }

Write-Host '[1] EASY: an MSI scaffolds; finalize is GATED on -Continue/-RunTest/-PackageIntune' -ForegroundColor Cyan
$script:finalized = $false; $script:patched = $null
$msi = New-Src 'qastor.msi'
$r = New-Win32ToolkitManualApp -Name 'Qastor' -Version '3.16.0' -Architecture x64 -SourcePath $msi -TemplateName 'Contoso' -Force 6>$null 3>$null
$proj = Join-Path $BASE 'Projects\Contoso\Qastor_x64_3.16.0'
if (Test-Path $proj) { Ok 'project scaffolded at Projects\<Template>\<App>_<arch>_<version>' } else { Bad "no project at $proj" }
if (Test-Path (Join-Path $proj 'Files\qastor.msi')) { Ok 'installer copied into Files\' } else { Bad 'installer not in Files\' }
if ($script:patched -eq $false) { Ok 'MSI => data-driven install (NOT the manual region)' } else { Bad "ManualInstall=$script:patched" }
if (-not $script:finalized) { Ok 'no finalize flags -> scaffold only (tells you to add -Continue)' } else { Bad 'finalize ran unbidden' }

$cfg = Get-Win32ToolkitAppConfig -ProjectPath $proj
if ($cfg.App.DisplayName -eq 'Qastor' -and $cfg.App.Version -eq '3.16.0') { Ok 'AppConfig.App populated as DATA (what Publish reads)' } else { Bad ($cfg.App | Out-String) }

$script:finalized = $false
$msiB = New-Src 'qastor2.msi'
$null = New-Win32ToolkitManualApp -Name 'Qastor Two' -Version '1.0' -Architecture x64 -SourcePath $msiB -TemplateName 'Contoso' -Force -PackageIntune 6>$null 3>$null
if ($script:finalized) { Ok '-PackageIntune runs the finalize tail inline (capture -> uninstall -> package)' } else { Bad 'finalize did not run with -PackageIntune' }

Write-Host '[2] EASY: an EXE WITH -SilentArgs is still easy' -ForegroundColor Cyan
$script:patched = $null
$exe = New-Src 'acme-setup.exe'
$null = New-Win32ToolkitManualApp -Name 'Acme Reader' -Version '7.1' -Architecture x64 -SourcePath $exe -SilentArgs '/S /norestart' -TemplateName 'Contoso' -Force 6>$null 3>$null
$p2 = Join-Path $BASE 'Projects\Contoso\Acme_Reader_x64_7.1'
$cfg2 = Get-Win32ToolkitAppConfig -ProjectPath $p2
if ($script:patched -eq $false) { Ok 'EXE + SilentArgs => data-driven install' } else { Bad "ManualInstall=$script:patched" }
if ($cfg2.Installer.SilentArgs -eq '/S /norestart') { Ok 'silent args stored as DATA, never spliced into the script' } else { Bad ($cfg2.Installer | Out-String) }

Write-Host '[3] HARD: an EXE with NO silent args is automatically Advanced' -ForegroundColor Cyan
$script:patched = $null; $script:finalized = $false
$exe2 = New-Src 'legacy.exe'
$r3 = New-Win32ToolkitManualApp -Name 'Legacy CAD' -Version '12.0' -Architecture x64 -SourcePath $exe2 -TemplateName 'Contoso' -Force 6>$null 3>$null
if ($script:patched -eq $true) { Ok 'EXE without silent args => the MANUAL install region (you author it)' } else { Bad "ManualInstall=$script:patched" }
if (-not $script:finalized) { Ok 'hard app does NOT finalize — deferred to Complete-Win32ToolkitManualApp' } else { Bad 'finalize ran for an advanced app' }
if ($r3.Mode -eq 'Advanced' -and $r3.ProjectPath) { Ok 'returns { ProjectPath; Mode=Advanced } so the caller can finish later' } else { Bad ($r3 | Out-String) }

Write-Host '[4] -SourcePath accepts a FOLDER (installer + payload beside it)' -ForegroundColor Cyan
$dir = Join-Path $BASE ('pay_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path (Join-Path $dir 'data') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $dir 'setup.msi') 'x'
Set-Content -LiteralPath (Join-Path $dir 'data\payload.bin') 'y'
$null = New-Win32ToolkitManualApp -Name 'Folder App' -Version '1.0' -Architecture x64 -SourcePath $dir -TemplateName 'Contoso' -Force 6>$null 3>$null
$p4 = Join-Path $BASE 'Projects\Contoso\Folder_App_x64_1.0'
if ((Test-Path (Join-Path $p4 'Files\setup.msi')) -and (Test-Path (Join-Path $p4 'Files\data\payload.bin'))) {
    Ok 'the whole folder (including subdirectories) lands in Files\'
} else { Bad 'folder payload not copied' }

Write-Host '[5] REGRESSION: an installer named *setup*.exe must be DETECTED, not discarded' -ForegroundColor Cyan
# Get-InstallerFileInfo used to exclude '*Setup*' from EXE detection — silently discarding the installer for
# any app whose EXE is called setup.exe / acme-setup.exe / VLCSetup.exe, i.e. the commonest installer name
# there is. Such a project failed outright with "No installer (msi/exe/msix/appx) detected".
foreach ($name in 'setup.exe', 'AcmeSetup.exe', 'vlc-setup.exe') {
    $s  = New-Src $name
    $fp = Join-Path $BASE ('fx_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $fp -Force | Out-Null
    Add-Win32ToolkitInstallerFiles -SourcePath $s -FilesPath $fp 6>$null | Out-Null
    $fi = Get-InstallerFileInfo -FilesPath $fp
    if ($fi.Type -eq 'exe' -and $fi.FileName -eq $name) { Ok "'$name' detected as the installer" } else { Bad "'$name' NOT detected (Type='$($fi.Type)')" }
}
# …while PSADT's own binaries are still correctly ignored
$fp2 = Join-Path $BASE ('fy_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $fp2 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fp2 'ServiceUI.exe') 'x'
Set-Content -LiteralPath (Join-Path $fp2 'Invoke-AppDeployToolkit.exe') 'x'
$fi2 = Get-InstallerFileInfo -FilesPath $fp2
if (-not $fi2.Type) { Ok "PSADT's own binaries (ServiceUI / Invoke-AppDeployToolkit) are still ignored" } else { Bad "picked up a PSADT binary: $($fi2.FileName)" }

Write-Host '[6] dependencies work on a manual app exactly as on the winget path' -ForegroundColor Cyan
$msi2 = New-Src 'dep.msi'
$null = New-Win32ToolkitManualApp -Name 'Needs VC' -Version '2.0' -Architecture x64 -SourcePath $msi2 -TemplateName 'Contoso' -Force `
    -DependsOn 'winget:Microsoft.VCRedist.2015+.x64' 6>$null 3>$null
$p5   = Join-Path $BASE 'Projects\Contoso\Needs_VC_x64_2.0'
$deps = @(Get-Win32ToolkitDependencies -ProjectPath $p5)
if ($deps.Count -eq 1 -and $deps[0].Ref -eq 'Microsoft.VCRedist.2015+.x64' -and $deps[0].Source -eq 'winget') {
    Ok 'a custom app can depend on the VC++ redistributable (declared into AppConfig)'
} else { Bad ($deps | Out-String) }

Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'Manual-app integration test PASSED.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail manual-app check(s) FAILED." -ForegroundColor Red; exit 1 }
