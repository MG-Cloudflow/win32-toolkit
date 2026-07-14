<#
    Unit tests for dependency STAGING — making the test/capture guest install declared dependencies
    BEFORE the app, exactly as Intune does on a real device.

    winget download and the project copy are shadowed; nothing hits the network.

    Run:  pwsh -File Tests\DependencyStaging.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitDependencies.ps1')
. (Join-Path $repo 'Public\Set-Win32ToolkitAppDependency.ps1')
. (Join-Path $repo 'Private\Initialize-Win32ToolkitDependencyStaging.ps1')

$VC = 'Microsoft.VCRedist.2015+.x64'

# --- shadows --------------------------------------------------------------------------------------
$script:downloaded = @()
function Download-OldVersionInstaller {
    param($AppId, $Version, $ProjectPath, $Architecture, $Scope, $InstallerType, $Locale, $DestinationDir)
    $script:downloaded += [pscustomobject]@{ AppId = $AppId; Version = $Version; Dest = $DestinationDir }
    Set-Content -LiteralPath (Join-Path $DestinationDir 'vc_redist.x64.exe') -Value 'exe'
    [pscustomobject]@{ InstallerName = 'vc_redist.x64.exe'; InstallerType = 'exe'; SilentArgs = '/install /quiet /norestart' }
}

function New-Proj {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ds_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $p    = Join-Path $root 'Contoso\Notepad_x64_8.6'
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    $p
}

Write-Host '[1] no dependencies declared -> stages nothing (regression contract)' -ForegroundColor Cyan
$p0 = New-Proj
$n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p0
if ($n -eq 0 -and -not (Test-Path (Join-Path $p0 'Sandbox\InstallDependencies.ps1'))) { Ok 'no staging, no guest script' } else { Bad "n=$n" }

Write-Host '[2] winget dep -> installer downloaded + data manifest + value-free guest script' -ForegroundColor Cyan
$p1 = New-Proj
$null = Set-Win32ToolkitAppDependency -ProjectPath $p1 -DependsOn "winget:$VC"
$script:downloaded = @()
$n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p1 6>$null
$script1 = Join-Path $p1 'Sandbox\InstallDependencies.ps1'
$man     = Join-Path $p1 'Sandbox\Dependencies\dependencies.json'

if ($n -eq 1) { Ok 'one dependency staged' } else { Bad "n=$n" }
if ($script:downloaded.Count -eq 1 -and $script:downloaded[0].AppId -eq $VC) { Ok "winget id passed VERBATIM ('+'/'.' intact)" } else { Bad ($script:downloaded | Out-String) }
if (-not $script:downloaded[0].Version) { Ok 'no -Version => latest (any version satisfies a dependency)' } else { Bad "pinned v$($script:downloaded[0].Version)" }
if (Test-Path $man) { Ok 'dependencies.json written' } else { Bad 'no manifest' }

$entries = Get-Content -LiteralPath $man -Raw | ConvertFrom-Json
if ($entries[0].SilentArgs -eq '/install /quiet /norestart' -and $entries[0].Path -like 'C:\PSADT\Sandbox\Dependencies\*') { Ok 'silent args + guest path stored as DATA' } else { Bad ($entries | Out-String) }

$guest = Get-Content -LiteralPath $script1 -Raw
if ($guest -notmatch [regex]::Escape('/install /quiet /norestart') -and $guest -notmatch [regex]::Escape($VC)) {
    Ok 'guest script is VALUE-FREE (no untrusted value spliced into code)'
} else { Bad 'untrusted value spliced into the generated script' }
$b = [System.IO.File]::ReadAllBytes($script1)
if ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { Ok 'guest script written UTF-8 WITH BOM (5.1-safe)' } else { Bad 'no BOM' }
$perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($guest, [ref]$null, [ref]$perr)
if (-not $perr) { Ok 'guest script parses' } else { Bad $perr[0].Message }

Write-Host '[3] project dep -> the packaged project is copied in and installed via its own PSADT' -ForegroundColor Cyan
$p2 = New-Proj
# a fake packaged dependency project under the SAME Projects root the stager resolves from
$projectsRoot = Split-Path -Parent (Split-Path -Parent $p2)
$depProj = Join-Path $projectsRoot 'Contoso\VCRedist_x64_14.38'
New-Item -ItemType Directory -Path $depProj -Force | Out-Null
Set-Content -LiteralPath (Join-Path $depProj 'Invoke-AppDeployToolkit.ps1') -Value '# psadt'
function Get-Win32ToolkitBasePath { param($BasePath) 'IGNORED' }
function Get-Win32ToolkitPaths { param($BasePath) [pscustomobject]@{ Projects = $projectsRoot } }

$null = Set-Win32ToolkitAppDependency -ProjectPath $p2 -DependsOn 'project:Contoso\VCRedist_x64_14.38'
$n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p2 6>$null
$man2 = Join-Path $p2 'Sandbox\Dependencies\dependencies.json'
$e2 = @(Get-Content -LiteralPath $man2 -Raw | ConvertFrom-Json)
if ($n -eq 1 -and $e2[0].Type -eq 'psadt' -and $e2[0].Path -eq 'C:\PSADT\Sandbox\Dependencies\VCRedist_x64_14.38\Invoke-AppDeployToolkit.ps1') {
    Ok 'project dep staged; installs via its own PSADT silently'
} else { Bad ($e2 | Out-String) }
if (Test-Path (Join-Path $p2 'Sandbox\Dependencies\VCRedist_x64_14.38\Invoke-AppDeployToolkit.ps1')) { Ok 'dependency package copied into the project' } else { Bad 'not copied' }

Write-Host '[4] re-staging is clean (a removed dependency does not linger in the guest)' -ForegroundColor Cyan
$null = Set-Win32ToolkitAppDependency -ProjectPath $p2 -Clear
$n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p2
if ($n -eq 0 -and -not (Test-Path (Join-Path $p2 'Sandbox\Dependencies'))) { Ok 'stale staging removed' } else { Bad 'stale dependency left staged' }

Write-Host '[5] intune: dep cannot be staged -> warns, stages nothing (relationship still made at publish)' -ForegroundColor Cyan
$p3 = New-Proj
$null = Set-Win32ToolkitAppDependency -ProjectPath $p3 -DependsOn 'intune:8d0a1f2c-1111-2222-3333-444455556666'
$n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p3 -WarningAction SilentlyContinue
if ($n -eq 0) { Ok 'intune-only dep is not stageable (warned)' } else { Bad "n=$n" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All DependencyStaging tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail DependencyStaging test(s) FAILED." -ForegroundColor Red; exit 1 }
