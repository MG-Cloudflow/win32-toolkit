<#
    The wrong-tenant guard.

    THE BUG (shipped, live): Connect-Win32ToolkitGraph reused ANY cached Graph context that carried the
    right SCOPE and never looked at the tenant. Connect-MgGraph was called with no -ContextScope, so the
    default (CurrentUser) also persisted that context to disk across sessions. TenantId was read only to
    LOG where a publish went. Nothing refused. For anyone packaging for several customers (this repo's
    own BasePath has Arxus / CLoudFlow / Vloot tiers), connecting to customer A and then publishing a
    customer B project uploaded B's app into A's tenant, printed a green tick, and recorded the wrong
    tenant in the publication cache.

    Graph is fully shadowed; nothing signs in and no tenant is touched.
    Run:  pwsh -File Tests\IntuneTenantGuard.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }

# ── Graph shadows ────────────────────────────────────────────────────────────────────────────────
$script:ctx          = $null
$script:connectCalls = [System.Collections.Generic.List[hashtable]]::new()
$script:disconnects  = 0
function Get-MgContext { $script:ctx }
function Import-Module { param([Parameter(ValueFromRemainingArguments)]$a) }
function Connect-MgGraph {
    param([string[]]$Scopes, [string]$TenantId, [string]$ContextScope, [switch]$UseDeviceAuthentication, [switch]$NoWelcome, $ErrorAction)
    $script:connectCalls.Add(@{ Scopes = $Scopes; TenantId = $TenantId; ContextScope = $ContextScope })
    # a real sign-in lands on the requested tenant
    $script:ctx = [pscustomobject]@{ TenantId = $TenantId; Account = 'mg@cloudflow.be'; Scopes = $Scopes; ContextScope = $ContextScope; AuthType = 'Delegated' }
}
function Disconnect-MgGraph { param($ErrorAction) $script:disconnects++; $script:ctx = $null }
function Get-Module { param([Parameter(ValueFromRemainingArguments)]$a) [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
function Get-Command { param([Parameter(ValueFromRemainingArguments)]$a) [pscustomobject]@{ Parameters = @{} } }
function Get-Win32ToolkitTenantInfo { $null }   # no directory read in tests

$ARXUS = '11111111-1111-1111-1111-111111111111'
$VLOOT = '22222222-2222-2222-2222-222222222222'

Write-Host "`n[1] THE BUG: a cached context for ANOTHER tenant must NOT be reused" -ForegroundColor Cyan
$script:ctx = [pscustomobject]@{ TenantId = $ARXUS; Account = 'mg@cloudflow.be'; Scopes = @('DeviceManagementApps.ReadWrite.All'); ContextScope = 'CurrentUser'; AuthType = 'Delegated' }
$script:connectCalls.Clear(); $script:disconnects = 0
$r = Connect-Win32ToolkitGraph -TenantId $VLOOT 6>$null 3>$null
if ($script:connectCalls.Count -eq 1) { Ok 'a foreign cached context forces a real reconnect (was: silently reused)' }
else { Bad "expected 1 reconnect, got $($script:connectCalls.Count) - THE BUG IS BACK" }
if ($script:disconnects -ge 1) { Ok 'the foreign session is torn down first (cannot silently persist)' } else { Bad 'no disconnect before switching tenants' }
if ($r.TenantId -eq $VLOOT) { Ok 'ends up on the REQUESTED tenant' } else { Bad "landed on [$($r.TenantId)]" }
if ($script:connectCalls[0].TenantId -eq $VLOOT) { Ok 'Connect-MgGraph is pinned with -TenantId' } else { Bad 'connect was not tenant-pinned' }

Write-Host "`n[2] A matching cached context IS reused (no needless re-auth)" -ForegroundColor Cyan
$script:ctx = [pscustomobject]@{ TenantId = $VLOOT; Account = 'mg@cloudflow.be'; Scopes = @('DeviceManagementApps.ReadWrite.All'); ContextScope = 'Process'; AuthType = 'Delegated' }
$script:connectCalls.Clear()
$null = Connect-Win32ToolkitGraph -TenantId $VLOOT 6>$null
if ($script:connectCalls.Count -eq 0) { Ok 'same tenant + same scope -> reused' } else { Bad 'reconnected unnecessarily' }

Write-Host "`n[3] A context missing the scope is not reused even if the tenant matches" -ForegroundColor Cyan
$script:ctx = [pscustomobject]@{ TenantId = $VLOOT; Account = 'x'; Scopes = @('User.Read'); ContextScope = 'Process'; AuthType = 'Delegated' }
$script:connectCalls.Clear()
$null = Connect-Win32ToolkitGraph -TenantId $VLOOT 6>$null
if ($script:connectCalls.Count -eq 1) { Ok 'insufficient scope -> reconnect' } else { Bad 'reused a context lacking the scope' }

Write-Host "`n[4] If the sign-in lands on the WRONG tenant, it throws (never proceeds)" -ForegroundColor Cyan
# simulate an IdP that ignores the pin (existing browser session / home-tenant fallback)
function Connect-MgGraph {
    param([string[]]$Scopes, [string]$TenantId, [string]$ContextScope, [switch]$UseDeviceAuthentication, [switch]$NoWelcome, $ErrorAction)
    $script:ctx = [pscustomobject]@{ TenantId = $ARXUS; Account = 'mg@cloudflow.be'; Scopes = $Scopes; ContextScope = $ContextScope; AuthType = 'Delegated' }
}
$script:ctx = $null; $threw = $false
try { Connect-Win32ToolkitGraph -TenantId $VLOOT 6>$null 3>$null } catch { $threw = $true; $msg = $_.Exception.Message }
if ($threw) { Ok 'a tenant that did not stick is an EXCEPTION, not a warning' } else { Bad 'silently accepted the wrong tenant' }
if ($threw -and $msg -match 'wrong customer') { Ok 'the error says why it matters' } else { Bad "unhelpful error: [$msg]" }
if ($script:disconnects -ge 1) { Ok 'the wrong-tenant session is torn down, not left signed in' } else { Bad 'left the user connected to the wrong tenant' }

# ── Assert-Win32ToolkitTenant ────────────────────────────────────────────────────────────────────
function New-Proj { param([string]$Tenant)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('tg_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    $cfg = [ordered]@{ App = [ordered]@{ Name = 'App'; Version = '1.0' } }
    if ($Tenant) { $cfg['Intune'] = [ordered]@{ TenantId = $Tenant } }
    ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json') -Encoding UTF8
    $p
}

Write-Host "`n[5] Assert: pinned project + WRONG live tenant -> refuses to publish" -ForegroundColor Cyan
$script:ctx = [pscustomobject]@{ TenantId = $ARXUS; Account = 'mg@cloudflow.be'; Scopes = @(); ContextScope = 'Process'; AuthType = 'Delegated' }
$proj = New-Proj -Tenant $VLOOT
$threw = $false
try { Assert-Win32ToolkitTenant -ProjectPath $proj -Operation 'publish' 3>$null } catch { $threw = $true; $m2 = $_.Exception.Message }
if ($threw) { Ok 'publish REFUSED against the wrong customer tenant' } else { Bad 'the guard let a wrong-tenant publish through' }
if ($threw -and $m2 -match "different customer's tenant") { Ok 'the refusal explains the consequence' } else { Bad "weak message: [$m2]" }

Write-Host "`n[6] Assert: pinned project + matching tenant -> proceeds" -ForegroundColor Cyan
$script:ctx = [pscustomobject]@{ TenantId = $VLOOT; Account = 'mg@cloudflow.be'; Scopes = @(); ContextScope = 'Process'; AuthType = 'Delegated' }
$res = Assert-Win32ToolkitTenant -ProjectPath $proj -Operation 'publish' 3>$null
if ($res.Pinned -and $res.TenantId -eq $VLOOT) { Ok 'matching tenant proceeds, reported as pinned' } else { Bad "unexpected: $($res | ConvertTo-Json -Compress)" }

Write-Host "`n[7] Assert: UNPINNED project warns but does not block (honest, not silent)" -ForegroundColor Cyan
$projU = New-Proj -Tenant ''
$script:OrgTemplate = $null
$wv = $null
$resU = Assert-Win32ToolkitTenant -ProjectPath $projU -Operation 'publish' -WarningVariable wv -WarningAction SilentlyContinue
if ($resU -and -not $resU.Pinned) { Ok 'unpinned -> proceeds' } else { Bad 'unpinned project blocked' }
if ($wv) { Ok 'unpinned -> warns that nothing can be verified' } else { Bad 'unpinned passed silently' }

Write-Host "`n[8] Assert: no session at all -> throws" -ForegroundColor Cyan
$script:ctx = $null
$threw = $false
try { Assert-Win32ToolkitTenant -ProjectPath $proj 3>$null } catch { $threw = $true }
if ($threw) { Ok 'no Graph session -> throws' } else { Bad 'passed with no session' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All IntuneTenantGuard tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail IntuneTenantGuard test(s) FAILED." -ForegroundColor Red; exit 1 }
