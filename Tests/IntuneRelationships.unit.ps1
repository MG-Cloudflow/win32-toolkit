<#
    Unit tests for the Intune app-dependency Graph layer. Invoke-MgGraphRequest is shadowed and CAPTURES
    the URI + body, so nothing touches a tenant.

    The two tests that matter most encode real, known failure modes:
      * updateRelationships is a SET operation across dependencies AND supersedence — posting only the new
        dependency silently DESTROYS an admin's supersedence rules.
      * GET /relationships returns inbound rows too; re-posting a targetType='parent' row yields
        "A circular dependency was created" (the open bug in the community IntuneWin32App module, #171).

    Run:  pwsh -File Tests\IntuneRelationships.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Set-Win32ToolkitAppRelationships.ps1')
. (Join-Path $repo 'Private\Find-Win32ToolkitIntuneApp.ps1')

$APP = 'aaaaaaaa-0000-0000-0000-000000000001'
$VC  = 'bbbbbbbb-0000-0000-0000-000000000002'
$OLD = 'cccccccc-0000-0000-0000-000000000003'   # an app THIS one supersedes
$IN  = 'dddddddd-0000-0000-0000-000000000004'   # an app that depends on THIS one (inbound!)

$script:getRows = @()
$script:posted  = $null
$script:postUri = $null
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    if ($Method -eq 'GET')  { return [pscustomobject]@{ value = $script:getRows } }
    if ($Method -eq 'POST') { $script:postUri = $Uri; $script:posted = $Body; return $null }
}
function Parsed { $script:posted | ConvertFrom-Json }

Write-Host '[1] a single dependency serializes as a JSON ARRAY (Graph rejects a bare object)' -ForegroundColor Cyan
$script:getRows = @()
$n = Set-Win32ToolkitAppRelationships -AppId $APP -Dependency @([pscustomobject]@{ TargetId = $VC; DependencyType = 'autoInstall' })
if ($script:posted -match '"relationships"\s*:\s*\[') { Ok 'relationships is an array even with ONE element' } else { Bad "body: $script:posted" }
if ($script:postUri -match 'updateRelationships$') { Ok 'posts to updateRelationships' } else { Bad "uri=$script:postUri" }
$p = Parsed
if ($p.relationships[0].'@odata.type' -eq '#microsoft.graph.mobileAppDependency' -and $p.relationships[0].targetId -eq $VC -and $p.relationships[0].dependencyType -eq 'autoInstall') { Ok 'correct dependency payload' } else { Bad ($p | ConvertTo-Json -Depth 5) }
$keys = ($p.relationships[0].PSObject.Properties.Name | Sort-Object) -join ','
if ($keys -eq '@odata.type,dependencyType,targetId') { Ok 'ONLY the 3 writable properties are sent (read-only fields cause malformed/circular errors)' } else { Bad "keys=$keys" }

Write-Host '[2] EXISTING SUPERSEDENCE SURVIVES (the failure that would wreck a real tenant)' -ForegroundColor Cyan
$script:getRows = @(
    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $OLD; targetType = 'child'; supersedenceType = 'replace' }
)
$n = Set-Win32ToolkitAppRelationships -AppId $APP -Dependency @([pscustomobject]@{ TargetId = $VC; DependencyType = 'autoInstall' })
$p = Parsed
$sup = @($p.relationships | Where-Object { $_.'@odata.type' -match 'Supersedence' })
$dep = @($p.relationships | Where-Object { $_.'@odata.type' -match 'Dependency' })
if ($sup.Count -eq 1 -and $sup[0].targetId -eq $OLD -and $sup[0].supersedenceType -eq 'replace') { Ok 'the admin''s supersedence rule is re-posted intact (NOT wiped)' } else { Bad ($p | ConvertTo-Json -Depth 5) }
if ($dep.Count -eq 1 -and $dep[0].targetId -eq $VC) { Ok 'the new dependency is added alongside it' } else { Bad 'dependency missing' }

Write-Host '[3] INBOUND rows are dropped (targetType=parent => "circular dependency" error)' -ForegroundColor Cyan
$script:getRows = @(
    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = $IN; targetType = 'parent'; dependencyType = 'autoInstall' }
)
$n = Set-Win32ToolkitAppRelationships -AppId $APP -Dependency @([pscustomobject]@{ TargetId = $VC; DependencyType = 'autoInstall' })
$p = Parsed
if (@($p.relationships).Count -eq 1 -and $p.relationships[0].targetId -eq $VC) { Ok 'the inbound parent row is NOT re-posted' } else { Bad ($p | ConvertTo-Json -Depth 5) }

Write-Host '[4] an existing dependency is not duplicated; ours wins on type' -ForegroundColor Cyan
$script:getRows = @(
    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = $VC; targetType = 'child'; dependencyType = 'detect' }
)
$n = Set-Win32ToolkitAppRelationships -AppId $APP -Dependency @([pscustomobject]@{ TargetId = $VC; DependencyType = 'autoInstall' })
$p = Parsed
if (@($p.relationships).Count -eq 1 -and $p.relationships[0].dependencyType -eq 'autoInstall') { Ok 'deduped by targetId; declared type wins' } else { Bad ($p | ConvertTo-Json -Depth 5) }

Write-Host '[5] clearing dependencies still preserves supersedence' -ForegroundColor Cyan
$script:getRows = @(
    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $OLD; targetType = 'child'; supersedenceType = 'replace' }
    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency';   targetId = $VC;  targetType = 'child'; dependencyType = 'autoInstall' }
)
$n = Set-Win32ToolkitAppRelationships -AppId $APP -Dependency @()
$p = Parsed
if (@($p.relationships).Count -eq 1 -and $p.relationships[0].'@odata.type' -match 'Supersedence') { Ok 'dependencies cleared, supersedence kept' } else { Bad ($p | ConvertTo-Json -Depth 5) }

Write-Host '[6] an app cannot depend on itself' -ForegroundColor Cyan
$threw = $false
try { Set-Win32ToolkitAppRelationships -AppId $APP -Dependency @([pscustomobject]@{ TargetId = $APP; DependencyType = 'autoInstall' }) | Out-Null } catch { $threw = $true }
if ($threw) { Ok 'self-dependency rejected before any Graph write' } else { Bad 'self-dependency accepted' }

Write-Host '[7] tenant search: OData apostrophes are DOUBLED, and the (Update) twin is excluded' -ForegroundColor Cyan
$script:seenUri = $null
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    $script:seenUri = $Uri
    [pscustomobject]@{ value = @(
        [pscustomobject]@{ id = $VC;  displayName = "O'Reilly Toolkit";          displayVersion = '1.0'; publisher = 'X'; notes = 'win32-toolkit; Microsoft.VCRedist.2015+.x64' }
        [pscustomobject]@{ id = $OLD; displayName = "O'Reilly Toolkit (Update)"; displayVersion = '1.0'; publisher = 'X'; notes = 'win32-toolkit; update; Microsoft.VCRedist.2015+.x64' }
    ) }
}
$hits = @(Find-Win32ToolkitIntuneApp -DisplayName "O'Reilly Toolkit")
if ($script:seenUri -match "displayName eq 'O''Reilly Toolkit'") { Ok "apostrophe doubled in the OData filter (O''Reilly)" } else { Bad "uri=$script:seenUri" }
if ($hits.Count -eq 1 -and $hits[0].Id -eq $VC) { Ok 'the "(Update)" twin is excluded (it could never be satisfied as a dependency)' } else { Bad "hits=$($hits.Count)" }

$byId = @(Find-Win32ToolkitIntuneApp -WingetId 'Microsoft.VCRedist.2015+.x64')
if ($byId.Count -eq 1 -and $byId[0].Id -eq $VC) { Ok 'winget id resolved via the notes stamp' } else { Bad "byId=$($byId.Count)" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All IntuneRelationships tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail IntuneRelationships test(s) FAILED." -ForegroundColor Red; exit 1 }
