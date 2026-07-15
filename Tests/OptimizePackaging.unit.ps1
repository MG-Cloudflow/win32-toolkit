<#
    Packaging optimize / staging robustness.

      Regression: Export copies the whole project to Staging then Optimize strips the non-shipping folders
      (Sandbox\, Documentation\, Intune\, ...). A freshly-copied PSADT .psm1 is briefly AV-locked, so the
      strip's Remove-Item failed ('being used by another process') yet the run printed success and packaged
      the leftover Sandbox\ into the .intunewin (bloat + shipping the Intune\ secrets was a latent risk).

      The fix:
        - Get-Win32ToolkitNonShippingFolders — one source of truth for the excluded folders.
        - Remove-Win32ToolkitPathWithRetry — retry with back-off to ride out transient locks; returns $false
          if it truly cannot delete (progress silenced so it can't tear the TUI).
        - Optimize uses both; a surviving 'Intune' folder is FATAL (never ship tenant/app ids), the rest warn.
        - (Export excludes them at copy time — covered by DataDriven.integration / adversarial review.)

    Run:  pwsh -File Tests\OptimizePackaging.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitNonShippingFolders.ps1')
. (Join-Path $repo 'Private\Remove-Win32ToolkitPathWithRetry.ps1')
. (Join-Path $repo 'Private\Optimize-Win32ToolkitProject.ps1')

function New-TempDir {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('optpkg_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $p
}

# ── (a) the shared exclusion list ──────────────────────────────────────────────────────────────────
Write-Host '[a] Get-Win32ToolkitNonShippingFolders' -ForegroundColor Cyan
$ex = Get-Win32ToolkitNonShippingFolders
$expected = @('Docs', 'Examples', 'Sandbox', 'Documentation', 'Intune')
if (@($ex).Count -eq $expected.Count -and (@($expected | Where-Object { $_ -in $ex }).Count -eq $expected.Count)) { Ok "returns the expected set: $($ex -join ', ')" }
else { Bad "unexpected set: $($ex -join ', ')" }
if ('Intune' -in $ex -and 'Sandbox' -in $ex) { Ok "includes the secret-bearing 'Intune' and the test 'Sandbox' folder" } else { Bad "missing Intune/Sandbox" }

# ── (b) retry remover ──────────────────────────────────────────────────────────────────────────────
Write-Host '[b] Remove-Win32ToolkitPathWithRetry' -ForegroundColor Cyan

# b1: really removes a populated tree.
$d = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $d 'sub\a.txt') 'x'
if ((Remove-Win32ToolkitPathWithRetry -Path $d) -eq $true -and -not (Test-Path -LiteralPath $d)) { Ok 'removes a populated directory tree' }
else { Bad 'did not remove a real directory' }

# b2: a path that does not exist is a no-op success.
if ((Remove-Win32ToolkitPathWithRetry -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('gone_' + [guid]::NewGuid().ToString('N')))) -eq $true) { Ok 'missing path -> $true (no-op)' }
else { Bad 'missing path did not return $true' }

# b3: a TRANSIENT lock (throws twice, then succeeds) -> $true, and it retried. Shadows are isolated in &{}.
$script:rmN = 0
$dTrans = New-TempDir
$rTrans = & {
    function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }
    function Remove-Item { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) $script:rmN++; if ($script:rmN -lt 3) { throw [System.IO.IOException]::new('locked') } }
    Remove-Win32ToolkitPathWithRetry -Path $dTrans
}
if ($rTrans -eq $true -and $script:rmN -eq 3) { Ok "rides out a transient lock (succeeded on attempt $($script:rmN))" }
else { Bad "transient lock: result=$rTrans, attempts=$($script:rmN)" }
[System.IO.Directory]::Delete($dTrans, $true)

# b4: a PERMANENT lock -> $false after exactly -Retries attempts (never an infinite loop, no throw).
$script:rmN = 0
$dPerm = New-TempDir
$rPerm = & {
    function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }
    function Remove-Item { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) $script:rmN++; throw [System.IO.IOException]::new('locked') }
    Remove-Win32ToolkitPathWithRetry -Path $dPerm -Retries 4 3>$null
}
if ($rPerm -eq $false -and $script:rmN -eq 4) { Ok "gives up after exactly -Retries attempts -> `$false (tried $($script:rmN))" }
else { Bad "permanent lock: result=$rPerm, attempts=$($script:rmN)" }
[System.IO.Directory]::Delete($dPerm, $true)

# ── (c) Optimize strips non-shipping folders, keeps the package payload ────────────────────────────
Write-Host '[c] Optimize-Win32ToolkitProject' -ForegroundColor Cyan
$proj = New-TempDir
foreach ($sub in 'Files', 'Assets', 'Sandbox\Dependencies\dep', 'Documentation', 'Intune', 'Docs', 'Examples', 'SupportFiles') {
    New-Item -ItemType Directory -Path (Join-Path $proj $sub) -Force | Out-Null
}
Set-Content -LiteralPath (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') '# stub'
Set-Content -LiteralPath (Join-Path $proj 'Files\installer.exe') 'x'
Set-Content -LiteralPath (Join-Path $proj 'Intune\Publications.json') '{"secret":"tenant"}'
Set-Content -LiteralPath (Join-Path $proj 'README.md') '# readme'
Set-Content -LiteralPath (Join-Path $proj 'app.wsb') '<Configuration/>'
Set-Content -LiteralPath (Join-Path $proj 'SupportFiles\TargetedDocumentationScript.ps1') '# doc'
Set-Content -LiteralPath (Join-Path $proj 'SupportFiles\RequirementScript.ps1') '# keep me'

Optimize-Win32ToolkitProject -ProjectPath $proj 6>$null 3>$null

$gone = @('Sandbox', 'Documentation', 'Intune', 'Docs', 'Examples', 'README.md', 'app.wsb', 'SupportFiles\TargetedDocumentationScript.ps1')
$kept = @('Invoke-AppDeployToolkit.ps1', 'Files\installer.exe', 'SupportFiles\RequirementScript.ps1')
$badGone = @($gone | Where-Object { Test-Path -LiteralPath (Join-Path $proj $_) })
$badKept = @($kept | Where-Object { -not (Test-Path -LiteralPath (Join-Path $proj $_)) })
if ($badGone.Count -eq 0) { Ok 'strips Sandbox/Documentation/Intune/Docs/Examples + root .md/.wsb + doc script' } else { Bad "did not remove: $($badGone -join ', ')" }
if ($badKept.Count -eq 0) { Ok 'keeps the payload (Invoke-AppDeployToolkit.ps1, Files\, RequirementScript.ps1)' } else { Bad "wrongly removed: $($badKept -join ', ')" }
[System.IO.Directory]::Delete($proj, $true)

# c2: a 'Intune' folder that cannot be stripped is FATAL (never ship tenant/app ids).
Write-Host '[c2] a locked Intune\ folder is fatal (secret must never ship)' -ForegroundColor Cyan
$proj2 = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $proj2 'Intune') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $proj2 'Intune\Publications.json') '{"secret":"x"}'
Set-Content -LiteralPath (Join-Path $proj2 'Invoke-AppDeployToolkit.ps1') '# stub'
$threw = $null
& {
    # Simulate Intune\ being un-removable (locked); everything else removes fine.
    function Remove-Win32ToolkitPathWithRetry { param([string]$Path, [int]$Retries, [int]$InitialDelayMs) return ($Path -notmatch '[\\/]Intune$') }
    try { Optimize-Win32ToolkitProject -ProjectPath $proj2 6>$null 3>$null } catch { $script:threw = $_.Exception.Message }
}
if ($script:threw -and $script:threw -match 'Intune' -and $script:threw -match 'Publications') { Ok 'throws, refusing to package with an un-strippable Intune\ folder' }
else { Bad "did not fail correctly on a locked Intune\ folder (msg: $($script:threw))" }
[System.IO.Directory]::Delete($proj2, $true)

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
