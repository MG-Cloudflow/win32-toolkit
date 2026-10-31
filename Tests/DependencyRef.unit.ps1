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
. (Join-Path $repo 'Private\Assert-Win32ToolkitDependencyRef.ps1')   # C-9: Set-Win32ToolkitAppDependency validates through it (B3 r2.1)
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

Write-Host '[6b] project: refs must be <Template>\<ProjectName> under Projects\ (test campaign 2026-10-21, S11-F5)' -ForegroundColor Cyan
# A segment ending in '.' or ' ' (re-verification 2026-10-21, B3 #2): Windows drops it, so these name the project
# itself ('Contoso\Notepad_x64_8.6') and were accepted without even the 'not packaged yet' warning.
# Each refusal shares the prefix and names its own reason (re-verification 2026-10-21, B3 r1.3: a trailing '.'/' '
# was refused as "not a full path or '..'", which none of those refs is).
$fullOrDots = "not a full path or '\.\.'"
$trailing   = "a name ends in '\.' or ' '"
foreach ($case in @(@('project:C:\W32T-Test42\Projects\CLoudFlow\7-Zip_x64_26.04', $fullOrDots), @('project:..\..\W32T-Test42\Projects\CLoudFlow\7-Zip_x64_26.04', $fullOrDots),
                    @('project:Contoso\Sub\Tool', 'exactly two names, neither empty'), @('project:\Tool', $fullOrDots), @('C:\abs\Tool', $fullOrDots), @('project:Contoso\..', $fullOrDots),
                    @('project:Contoso\To:ol', 'a name holds a character that is not allowed in a file name'), @('project:Contoso\To/ol', 'a name holds a character that is not allowed in a file name'),
                    @('project:Contoso\Notepad_x64_8.6.', $trailing), @('project:Contoso.\Notepad_x64_8.6', $trailing), @('project:Contoso \Notepad_x64_8.6', $trailing),
                    @('project:Contoso\Other_x64_1.0.', $trailing))) {
    $badRef = $case[0]
    $e = $null
    try { $null = Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn $badRef -WarningAction SilentlyContinue } catch { $e = $_ }
    if ($e -and "$e" -match "^Dependency '.+' must be '<Template>\\<ProjectName>' under Projects\\ \(") {
        if ("$e" -match "under Projects\\ \($($case[1])\)\.$") { Ok "rejects '$badRef' ($($case[1] -replace '\\', ''))" } else { Bad "'$badRef' rejected with the wrong reason: $e" }
    } else { Bad "accepted '$badRef' ($e)" }
}
if (@(Get-Win32ToolkitDependencies -ProjectPath $proj).Count -eq 0) { Ok 'nothing was written for a rejected reference' } else { Bad 'a rejected reference was stored' }
# Self by another spelling of the same folder (a short 8.3 name) is caught by the normalized full-path compare.
$shortLeaf = $null
try { $shortLeaf = Split-Path -Leaf ((New-Object -ComObject Scripting.FileSystemObject).GetFolder($proj).ShortPath) } catch { $shortLeaf = $null }
if ($shortLeaf -and $shortLeaf -ne (Split-Path -Leaf $proj)) {
    $e = $null
    try { $null = Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn "project:Contoso\$shortLeaf" -WarningAction SilentlyContinue } catch { $e = $_ }
    if ($e -and "$e" -match 'An app cannot depend on itself' -and @(Get-Win32ToolkitDependencies -ProjectPath $proj).Count -eq 0) { Ok "self by its 8.3 name 'Contoso\$shortLeaf' rejected, nothing written" } else { Bad "8.3 self-reference: $e" }
} else { Write-Host '  SKIP: no 8.3 short name on this volume (the full-path self check is still covered by the exact spelling)' -ForegroundColor DarkGray }
$w6 = $null
$set6 = @(Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn 'project:Contoso\NotPackagedYet' -WarningVariable w6 -WarningAction SilentlyContinue)
if ($set6.Count -eq 1 -and @($w6 | Where-Object { "$_" -match "'project:Contoso\\NotPackagedYet' is not packaged yet" }).Count -eq 1) { Ok 'a not-yet-packaged project is declared with one warning (declaring first is legitimate)' } else { Bad "declared=$($set6.Count) warn=$($w6 -join ' | ')" }
$null = Set-Win32ToolkitAppDependency -ProjectPath $proj -Clear

Write-Host '[6c] every refusal is W32T.InvalidDependencyReference (InvalidArgument); Assert-Win32ToolkitDependencyRef is pure (re-verification 2026-10-21, B3 r2.1)' -ForegroundColor Cyan
function Get-RefusalOf([scriptblock]$Action) { try { $null = & $Action; $null } catch { $_ } }
$refusals = [ordered]@{
    "ConvertTo 'intune:not-a-guid'"         = { ConvertTo-Win32ToolkitDependencyRef -Reference 'intune:not-a-guid' }
    "ConvertTo 'project:NoBackslash'"       = { ConvertTo-Win32ToolkitDependencyRef -Reference 'project:NoBackslash' }
    "Assert 'C:\abs\Tool' (bare, rooted)"   = { Assert-Win32ToolkitDependencyRef -Reference 'C:\abs\Tool' }
    "Assert 'project:..\X'"                 = { Assert-Win32ToolkitDependencyRef -Reference 'project:..\X' }
    "Assert 'project:Contoso\App.'"         = { Assert-Win32ToolkitDependencyRef -Reference 'project:Contoso\App.' }
    "Assert self (folder not created yet)"  = { Assert-Win32ToolkitDependencyRef -Reference 'project:Contoso\NotYet_x64_1.0' -ProjectPath (Join-Path (Split-Path -Parent $proj) 'NotYet_x64_1.0') }
    "Set without -DependsOn or -Clear"      = { Set-Win32ToolkitAppDependency -ProjectPath $proj }
    "Set 'project:..\X'"                    = { Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn 'project:..\X' -WarningAction SilentlyContinue }
    "Set self"                              = { Set-Win32ToolkitAppDependency -ProjectPath $proj -DependsOn 'project:Contoso\Notepad_x64_8.6' }
}
foreach ($k in $refusals.Keys) {
    $e = Get-RefusalOf $refusals[$k]
    if ($e -and $e.FullyQualifiedErrorId -eq 'W32T.InvalidDependencyReference' -and $e.CategoryInfo.Category -eq 'InvalidArgument' -and $e.Exception -is [System.ArgumentException]) {
        Ok "$k -> W32T.InvalidDependencyReference / InvalidArgument ($($e.Exception.Message))"
    } else { Bad "$k -> fqid='$(if ($e) { $e.FullyQualifiedErrorId })' category='$(if ($e) { $e.CategoryInfo.Category })' $e" }
}
if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $proj) 'NotYet_x64_1.0'))) { Ok 'the self check of a project that does not exist yet created nothing' } else { Bad 'the self check created the project folder' }
$ok6c = @(Assert-Win32ToolkitDependencyRef -Reference "winget:$VC", '', ' ', 'project:Contoso\Other_x64_1.0', 'intune:8d0a1f2c-1111-2222-3333-444455556666' -DependencyType detect -ProjectPath $proj)
if ($ok6c.Count -eq 3 -and ($ok6c.Source -join ',') -eq 'winget,project,intune' -and @($ok6c | Where-Object DependencyType -ne 'detect').Count -eq 0) { Ok 'valid references come back parsed, in order, blanks skipped, DependencyType stamped' } else { Bad "parsed: $($ok6c | ConvertTo-Json -Compress)" }
$noSelf = @(Assert-Win32ToolkitDependencyRef -Reference 'project:Contoso\Notepad_x64_8.6')
if ($noSelf.Count -eq 1) { Ok 'without -ProjectPath only the form is checked (the pipelines run the self check once the project name is known)' } else { Bad 'shape-only check refused a well-formed reference' }
if (@(Get-Win32ToolkitDependencies -ProjectPath $proj).Count -eq 0) { Ok 'nothing was written by any refusal' } else { Bad 'a refused reference was stored' }

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
