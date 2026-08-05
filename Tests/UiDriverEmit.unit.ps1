<#
    New-Win32ToolkitUiDriverScript — the generated guest UI driver must be a device-safe artifact.

      The driver runs on the DEVICE under Windows PowerShell 5.1 (interactive session), so it must: be
      saved UTF-8 WITH BOM, parse under 5.1 (Test-Win32ToolkitPS51Syntax), anchor on the Fluent dialog's
      AutomationId, and be a LITERAL here-string — nothing interpolated at emit time (proven by the literal
      `$DeploymentType` param surviving into the file, and by ProjectPath never being spliced in).

    Run:  pwsh -File Tests\UiDriverEmit.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m) { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\New-Win32ToolkitUiDriverScript.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitPS51Syntax.ps1')

function New-TempDir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('uide_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }

# A ProjectPath containing a '$' and a single quote would corrupt the driver IF it were ever spliced in —
# it must not be. (Single quotes are illegal in Windows paths, so use just the '$' hazard.)
$proj = Join-Path (New-TempDir) 'App_$x_1.0'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
$path = New-Win32ToolkitUiDriverScript -ProjectPath $proj

# ── (a) written where expected ─────────────────────────────────────────────────────────────────────
Write-Host '[a] driver is written to <project>\Sandbox\DrivePsadtUi.ps1' -ForegroundColor Cyan
$expected = Join-Path $proj 'Sandbox\DrivePsadtUi.ps1'
if ($path -eq $expected -and (Test-Path -LiteralPath $path)) { Ok 'emitted at the expected path' } else { Bad "unexpected path: $path" }

# ── (b) UTF-8 BOM ──────────────────────────────────────────────────────────────────────────────────
Write-Host '[b] saved UTF-8 WITH BOM (Intune runs it via powershell.exe)' -ForegroundColor Cyan
$bytes = [System.IO.File]::ReadAllBytes($path)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Ok 'BOM present' } else { Bad 'no UTF-8 BOM' }

# ── (c) parses under Windows PowerShell 5.1 ────────────────────────────────────────────────────────
Write-Host '[c] passes the Windows PowerShell 5.1 syntax gate' -ForegroundColor Cyan
$ps51 = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
if (Test-Path $ps51) {
    $errs = @(Test-Win32ToolkitPS51Syntax -Path $path)
    if ($errs.Count -eq 0) { Ok '5.1 parse clean' } else { Bad "5.1 syntax errors: $($errs -join ' | ')" }
}
else { Write-Host '  SKIP: Windows PowerShell 5.1 not present (gate fails open)' -ForegroundColor DarkYellow }

$text = Get-Content -LiteralPath $path -Raw

# ── (d) anchors on the Fluent dialog AutomationId ──────────────────────────────────────────────────
Write-Host '[d] anchors on AutomationId PSAppDeployToolkitDialog and emits structured output' -ForegroundColor Cyan
$need = @('PSAppDeployToolkitDialog', 'SESSION_START', 'RESULT ', 'Invoke-AppDeployToolkit.ps1', 'GetCurrentPattern')
$miss = @($need | Where-Object { $text -notmatch [regex]::Escape($_) })
if ($miss.Count -eq 0) { Ok 'all expected anchors/markers present' } else { Bad "missing: $($miss -join ', ')" }

# ── (e) literal here-string: nothing interpolated at emit time ─────────────────────────────────────
Write-Host '[e] the driver is a LITERAL here-string (no interpolation / no ProjectPath splice)' -ForegroundColor Cyan
if ($text -match '\$DeploymentType' -and $text -match '\$OverallTimeoutSec') { Ok 'param variables survived verbatim (single-quoted here-string)' } else { Bad 'param variables were interpolated away — here-string is not literal' }
if ($text -notmatch [regex]::Escape($proj)) { Ok 'ProjectPath was never spliced into the driver body' } else { Bad 'ProjectPath leaked into the driver body' }

# ── (f) no PS7-only operators slipped in (belt-and-suspenders over the 5.1 gate) ───────────────────
Write-Host '[f] no PS7-only null-coalescing / pipeline-chain operators' -ForegroundColor Cyan
if ($text -notmatch '\?\?' -and $text -notmatch '&&' -and $text -notmatch '\|\|') { Ok 'no ?? / && / || present' } else { Bad 'a PS7-only operator is present' }

Remove-Item (Split-Path $proj -Parent) -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
