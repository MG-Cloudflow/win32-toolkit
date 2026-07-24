<#
    Tests for the in-app update checker (Get-Win32ToolkitUpdateInfo).

    The whole point of this feature is that it NEVER breaks or slows the toolkit, so the tests focus on:
      - opt-out is honoured BEFORE any network call (env vars, CI, config toggle)
      - a newer / same / older latest version compares correctly (semver, 'v' prefix tolerated)
      - the network is hit at most once per TTL (cache), and a live check re-fetches
      - ANY fetch failure fails open (returns $null, never throws)

    The GitHub call (Invoke-RestMethod) and the config reader are shadowed; no network, no registry.
    LOCALAPPDATA is redirected to a temp dir so the cache is isolated.

    Run:  pwsh -File Tests\UpdateCheck.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitUpdateInfo.ps1')

# ── shadows ──────────────────────────────────────────────────────────────────────────────────────
$script:irmCalls = 0
$script:fakeTag  = 'v1.0.1'
$script:throwOnFetch = $false
function Invoke-RestMethod {
    param([Parameter(ValueFromRemainingArguments)]$rest)
    $script:irmCalls++
    if ($script:throwOnFetch) { throw 'simulated network failure' }
    [pscustomobject]@{ tag_name = $script:fakeTag }
}
$script:configUpdate = 'On'
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($Name -eq 'UpdateCheck') { $script:configUpdate } else { $Default } }

# Isolate the cache + neutralise every opt-out that the test host might set (CI sets $env:CI, etc.).
$origLocal = $env:LOCALAPPDATA
$saved = @{}
foreach ($v in 'WIN32TOOLKIT_NO_UPDATE_CHECK', 'DO_NOT_TRACK', 'NO_UPDATE_NOTIFIER', 'CI') {
    $saved[$v] = [Environment]::GetEnvironmentVariable($v); Set-Item "env:$v" -Value '' -ErrorAction SilentlyContinue; Remove-Item "env:$v" -ErrorAction SilentlyContinue
}
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('upd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$env:LOCALAPPDATA = $tmp
$cacheFile = Join-Path $tmp 'CloudFlow\win32-toolkit\update-check.json'
function Reset-Cache { Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue; $script:irmCalls = 0 }

try {
    Write-Host "`n[1] opt-out env vars short-circuit BEFORE any network call" -ForegroundColor Cyan
    foreach ($v in 'WIN32TOOLKIT_NO_UPDATE_CHECK', 'DO_NOT_TRACK', 'NO_UPDATE_NOTIFIER', 'CI') {
        Reset-Cache
        Set-Item "env:$v" -Value '1'
        $r = Get-Win32ToolkitUpdateInfo
        Remove-Item "env:$v" -ErrorAction SilentlyContinue
        if ($null -eq $r -and $script:irmCalls -eq 0) { Ok "$v -> null, zero network calls" }
        else { Bad "$v -> expected null/no-call, got '$r' with $($script:irmCalls) call(s)" }
    }

    Write-Host "`n[2] config toggle Off short-circuits" -ForegroundColor Cyan
    Reset-Cache; $script:configUpdate = 'Off'
    $r = Get-Win32ToolkitUpdateInfo
    if ($null -eq $r -and $script:irmCalls -eq 0) { Ok 'UpdateCheck=Off -> null, no network' } else { Bad "toggle Off not honoured (irm=$($script:irmCalls))" }
    $script:configUpdate = 'On'

    Write-Host "`n[3] a NEWER release => UpdateAvailable" -ForegroundColor Cyan
    Reset-Cache; $script:throwOnFetch = $false; $script:fakeTag = 'v99.0.0'
    $r = Get-Win32ToolkitUpdateInfo
    if ($r -and $r.UpdateAvailable -and $r.Latest -eq '99.0.0') { Ok "newer -> UpdateAvailable, 'v' stripped ($($r.Installed) -> $($r.Latest))" }
    else { Bad "newer not detected: $($r | ConvertTo-Json -Compress)" }

    Write-Host "`n[4] the SAME version => no update" -ForegroundColor Cyan
    Reset-Cache; $installed = $r.Installed; $script:fakeTag = "v$installed"
    $r2 = Get-Win32ToolkitUpdateInfo
    if ($r2 -and -not $r2.UpdateAvailable) { Ok "same version ($installed) -> no update" } else { Bad "same version wrongly flagged: $($r2 | ConvertTo-Json -Compress)" }

    Write-Host "`n[5] an OLDER release => no update" -ForegroundColor Cyan
    Reset-Cache; $script:fakeTag = 'v0.0.1'
    $r3 = Get-Win32ToolkitUpdateInfo
    if ($r3 -and -not $r3.UpdateAvailable) { Ok 'older latest -> no update' } else { Bad "older wrongly flagged: $($r3 | ConvertTo-Json -Compress)" }

    Write-Host "`n[6] cache: within TTL the network is NOT hit again; -Force re-fetches" -ForegroundColor Cyan
    Reset-Cache; $script:fakeTag = 'v99.0.0'
    $null = Get-Win32ToolkitUpdateInfo                       # 1st call: fetches + writes cache
    $callsAfterFirst = $script:irmCalls
    $null = Get-Win32ToolkitUpdateInfo                       # 2nd call: within TTL -> cache
    if ($script:irmCalls -eq $callsAfterFirst) { Ok "second call served from cache (still $($script:irmCalls) network call)" } else { Bad "cache not used: $($script:irmCalls) calls" }
    $null = Get-Win32ToolkitUpdateInfo -Force                # -Force: re-fetch
    if ($script:irmCalls -gt $callsAfterFirst) { Ok '-Force bypasses the cache and re-fetches' } else { Bad '-Force did not re-fetch' }

    Write-Host "`n[7] fetch failure FAILS OPEN (null, no throw) and backs off" -ForegroundColor Cyan
    Reset-Cache; $script:throwOnFetch = $true
    $threw = $false; $r4 = $null
    try { $r4 = Get-Win32ToolkitUpdateInfo } catch { $threw = $true }
    if (-not $threw) { Ok 'network failure did not throw' } else { Bad 'threw on network failure' }
    if ($null -eq $r4) { Ok 'network failure returns null (fails open)' } else { Bad "expected null on failure, got $($r4 | ConvertTo-Json -Compress)" }
    if (Test-Path $cacheFile) { Ok 'lastCheck written even on failure (backs off, no retry-storm)' } else { Bad 'no cache written on failure' }
}
finally {
    $env:LOCALAPPDATA = $origLocal
    foreach ($v in $saved.Keys) { if ($saved[$v]) { Set-Item "env:$v" -Value $saved[$v] } else { Remove-Item "env:$v" -ErrorAction SilentlyContinue } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All UpdateCheck tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail UpdateCheck test(s) FAILED." -ForegroundColor Red; exit 1 }
