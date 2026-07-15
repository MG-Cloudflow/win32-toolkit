<#
    P3 — Get-Win32DetectionRules must produce a detection rule for apps installed OUTSIDE
    C:\Program Files.

    THE BUG: the file-system fallback hard-filtered captured NewFiles with
    `-match '^C:\Program Files'` then took the first. An app whose captured files live under a
    MACHINE-WIDE non-Program-Files location (C:\Tools, C:\ProgramData, D:\Apps) matched nothing, so
    the function returned @() and Intune got NO detection rule.

    THE FIX: choose the best single machine-wide absolute-path file candidate, preferring Program
    Files, then any other machine-wide absolute path, dropping temp/installer scratch. Still returns
    EXACTLY ONE rule.

    IMPORTANT (caught by adversarial review): PER-USER profile paths (C:\Users\<name>\AppData\...) are
    deliberately EXCLUDED. Intune evaluates detection as SYSTEM on the device, which cannot see another
    user's profile, and the capture host's account name is baked into the literal path — so a per-user
    file rule can NEVER match and would loop-reinstall the app. For a per-user-only capture we return @()
    (no auto rule), exactly as before this broadening.

    Get-Win32ToolkitAppConfig and Get-LatestInstallationCapture are shadowed; nothing hits the
    real filesystem beyond the temp capture JSON this test writes.

    Run:  pwsh -File Tests\P3_DetectionLocation.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32DetectionRules.ps1')

# ── Shadows ────────────────────────────────────────────────────────────────────────────────────
# App config WITHOUT tattoo fields (no App section) so the tattoo/registry-version branch is skipped
# and execution reaches the capture-based fallback.
$script:appConfig = [pscustomobject]@{ SchemaVersion = '1.0' }
function Get-Win32ToolkitAppConfig { param($ProjectPath) $script:appConfig }

# Return a FileInfo for the temp capture JSON this test writes (the function reads .FullName/.Name).
$script:captureFile = $null
function Get-LatestInstallationCapture { param($ProjectPath) $script:captureFile }

function New-Capture($obj) {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32cap_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $p -Encoding UTF8
    $script:captureFile = Get-Item -LiteralPath $p
}

# ══ Case 1a ═════════════════════════════════════════════════════════════════════════════════════
Write-Host '[1a] NewFiles under a MACHINE-WIDE non-Program-Files path -> a file rule is produced (was: @())' -ForegroundColor Cyan

$toolsApp = 'C:\Tools\Widget\widget.exe'
New-Capture ([pscustomobject]@{
    NewRegistryKeys = @()
    NewFiles        = @(
        'C:\Windows\Temp\setup12345.tmp',   # noise — must be dropped
        $toolsApp
    )
})

$rules = @(Get-Win32DetectionRules -ProjectPath 'X' -WarningAction SilentlyContinue)
if ($rules.Count -eq 1) { Ok 'exactly one rule returned' } else { Bad "expected 1 rule, got $($rules.Count) (old code returned 0)" }
if ($rules.Count -eq 1) {
    $r = $rules[0]
    if ($r['@odata.type'] -eq '#microsoft.graph.win32LobAppFileSystemDetection') { Ok 'rule is a file-system detection' } else { Bad "wrong @odata.type: $($r['@odata.type'])" }
    if ($r['path'] -eq (Split-Path $toolsApp -Parent) -and $r['fileOrFolderName'] -eq (Split-Path $toolsApp -Leaf)) {
        Ok 'rule points at the C:\Tools file (temp noise ignored)'
    } else {
        Bad "rule points at path=$($r['path']) file=$($r['fileOrFolderName'])"
    }
}

# ══ Case 1b ═════════════════════════════════════════════════════════════════════════════════════
Write-Host '[1b] NewFiles ONLY under a per-user profile path -> @() (a SYSTEM-context file rule could never match)' -ForegroundColor Cyan

New-Capture ([pscustomobject]@{
    NewRegistryKeys = @()
    NewFiles        = @(
        'C:\Users\WDAGUtilityAccount\AppData\Local\Programs\Widget\widget.exe',
        'C:\Users\jdoe\AppData\Roaming\Widget\widget.exe'
    )
})

$rules = @(Get-Win32DetectionRules -ProjectPath 'X' -WarningAction SilentlyContinue)
if ($rules.Count -eq 0) { Ok 'no rule emitted for a per-user-only capture (avoids the perpetual-reinstall footgun)' }
else { Bad "expected @() for per-user paths, got a rule pointing at $($rules[0]['path']) (SYSTEM can't see it)" }

# ══ Case 2 ══════════════════════════════════════════════════════════════════════════════════════
Write-Host '[2] Program Files present alongside C:\Tools -> Program Files is preferred' -ForegroundColor Cyan

$pf    = 'C:\Program Files\Contoso\App\app.exe'
$tools = 'C:\Tools\contoso\app.exe'
New-Capture ([pscustomobject]@{
    NewRegistryKeys = @()
    NewFiles        = @($tools, $pf)   # order deliberately puts the non-PF path first
})

$rules = @(Get-Win32DetectionRules -ProjectPath 'X' -WarningAction SilentlyContinue)
if ($rules.Count -eq 1 -and $rules[0]['path'] -eq (Split-Path $pf -Parent) -and $rules[0]['fileOrFolderName'] -eq (Split-Path $pf -Leaf)) {
    Ok 'Program Files path chosen over C:\Tools'
} else {
    Bad "expected Program Files, got path=$($rules[0]['path']) file=$($rules[0]['fileOrFolderName'])"
}

# ══ Case 3 (regression) ═════════════════════════════════════════════════════════════════════════
Write-Host '[3] Registry candidate present -> still returns the registry rule (unchanged branch)' -ForegroundColor Cyan

New-Capture ([pscustomobject]@{
    NewRegistryKeys = @(
        [pscustomobject]@{ Path = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{ABC-123}'; Values = @() }
    )
    NewFiles        = @('C:\Tools\contoso\app.exe')  # would also match the file fallback, but registry wins
})

$rules = @(Get-Win32DetectionRules -ProjectPath 'X' -WarningAction SilentlyContinue)
if ($rules.Count -eq 1 -and $rules[0]['@odata.type'] -eq '#microsoft.graph.win32LobAppRegistryDetection') {
    Ok 'registry detection returned (file fallback not reached)'
} else {
    Bad "expected registry rule, got count=$($rules.Count) type=$($rules[0]['@odata.type'])"
}

# ── Summary ──────────────────────────────────────────────────────────────────────────────────────
Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASSED' -ForegroundColor Green; exit 0 }
else             { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
