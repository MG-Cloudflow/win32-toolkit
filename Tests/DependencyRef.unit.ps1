<#
    Unit tests for the Intune app-dependency DECLARATION model (parser + AppConfig round-trip).
    Fully offline — no Graph, no tenant, no winget.

    Run:  pwsh -File Tests\DependencyRef.unit.ps1
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

$VC = 'Microsoft.VCRedist.2015+.x64'

Write-Host '[1] parser: explicit schemes' -ForegroundColor Cyan
$w = ConvertTo-Win32ToolkitDependencyRef -Reference "winget:$VC"
if ($w.Source -eq 'winget' -and $w.Ref -eq $VC) { Ok "winget id preserved VERBATIM ('+' and '.' intact)" } else { Bad "$($w.Source)/$($w.Ref)" }
$p = ConvertTo-Win32ToolkitDependencyRef -Reference 'project:Contoso\VCRedist_x64_14.38'
if ($p.Source -eq 'project' -and $p.Ref -eq 'Contoso\VCRedist_x64_14.38') { Ok 'project ref parsed' } else { Bad "$($p.Source)/$($p.Ref)" }
$i = ConvertTo-Win32ToolkitDependencyRef -Reference 'intune:8d0a1f2c-1111-2222-3333-444455556666'
if ($i.Source -eq 'intune') { Ok 'intune guid parsed' } else { Bad "$($i.Source)" }
if ($w.DependencyType -eq 'autoInstall') { Ok 'defaults to autoInstall' } else { Bad "type=$($w.DependencyType)" }

Write-Host '[2] parser: bare-string disambiguation' -ForegroundColor Cyan
if ((ConvertTo-Win32ToolkitDependencyRef -Reference $VC).Source -eq 'winget') { Ok 'bare Publisher.Package -> winget' } else { Bad 'bare -> not winget' }
if ((ConvertTo-Win32ToolkitDependencyRef -Reference 'Contoso\App_x64_1.0').Source -eq 'project') { Ok 'bare with backslash -> project' } else { Bad 'bare backslash -> not project' }
if ((ConvertTo-Win32ToolkitDependencyRef -Reference '8d0a1f2c-1111-2222-3333-444455556666').Source -eq 'intune') { Ok 'bare GUID -> intune' } else { Bad 'bare guid -> not intune' }

Write-Host '[3] parser: rejects malformed refs' -ForegroundColor Cyan
foreach ($bad in @('intune:not-a-guid', 'project:NoBackslash')) {
    $threw = $false
    try { ConvertTo-Win32ToolkitDependencyRef -Reference $bad | Out-Null } catch { $threw = $true }
    if ($threw) { Ok "rejects '$bad'" } else { Bad "accepted '$bad'" }
}

Write-Host '[4] AppConfig round-trip (data, never code)' -ForegroundColor Cyan
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('w32dep_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proj = Join-Path $proj 'Contoso\Notepad_x64_8.6'   # <Template>\<Name>, so self-reference can be derived
New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null

if ((Get-Win32ToolkitDependencies -ProjectPath $proj).Count -eq 0) { Ok 'no Dependencies section -> empty array (regression contract)' } else { Bad 'expected empty' }

$set = Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn "winget:$VC"
$rt  = @(Get-Win32ToolkitDependencies -ProjectPath $proj)
if ($rt.Count -eq 1 -and $rt[0].Ref -eq $VC -and $rt[0].Source -eq 'winget') { Ok "round-trips through JSON with '+'/'.' intact" } else { Bad ($rt | Out-String) }
$json = Get-Content -LiteralPath (Join-Path $proj 'SupportFiles\AppConfig.json') -Raw
if ($json -match '"Dependencies"') { Ok 'stored as a Dependencies DATA section in AppConfig.json' } else { Bad 'no Dependencies in AppConfig' }

Write-Host '[5] add a second dep; dedupe; clear' -ForegroundColor Cyan
$null = Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn 'project:Contoso\VCRedist_x64_14.38'
if ((Get-Win32ToolkitDependencies -ProjectPath $proj).Count -eq 2) { Ok 'second dependency appended (existing preserved)' } else { Bad 'append failed' }
$null = Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn "winget:$VC"
if ((Get-Win32ToolkitDependencies -ProjectPath $proj).Count -eq 2) { Ok 're-adding the same dep dedupes (no duplicate relationship)' } else { Bad 'duplicate added' }
$null = Set-Win32ToolkitAppDependency -ProjectPath $proj -Clear
if ((Get-Win32ToolkitDependencies -ProjectPath $proj).Count -eq 0) { Ok '-Clear removes all' } else { Bad 'clear failed' }

Write-Host '[6] an app cannot depend on itself' -ForegroundColor Cyan
$threw = $false
try { Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn 'project:Contoso\Notepad_x64_8.6' | Out-Null } catch { $threw = $true }
if ($threw) { Ok 'self-reference rejected (Intune rejects it too)' } else { Bad 'self-reference accepted' }

Write-Host '[7] both entry points expose the same declaration surface (winget + custom/manual apps)' -ForegroundColor Cyan
$surface = @{}
foreach ($f in @('Public\Invoke-Win32Toolkit.ps1', 'Public\New-Win32ToolkitManualApp.ps1')) {
    $raw = Get-Content -LiteralPath (Join-Path $repo $f) -Raw
    $surface[$f] = ($raw -match '\[string\[\]\]\$DependsOn') -and ($raw -match '\$DependencyType') -and ($raw -match 'Set-Win32ToolkitAppDependency')
}
if ($surface['Public\Invoke-Win32Toolkit.ps1'])        { Ok 'winget flow: -DependsOn declares into AppConfig' }        else { Bad 'winget flow missing -DependsOn' }
if ($surface['Public\New-Win32ToolkitManualApp.ps1'])  { Ok 'custom/manual flow: -DependsOn declares into AppConfig' } else { Bad 'manual flow missing -DependsOn' }

Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $proj)) -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All DependencyRef tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail DependencyRef test(s) FAILED." -ForegroundColor Red; exit 1 }
