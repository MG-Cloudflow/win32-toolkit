<#
    ConvertFrom-Win32ToolkitRgb565Image — the RGB565 framebuffer → PNG conversion factored out of
    Get-Win32ToolkitVMScreenshot so it is testable without a Hyper-V host.

      Covers both copy paths: even width (stride == width*2, whole-buffer Marshal.Copy) and odd width
      (stride padded to a 4-byte boundary, row-by-row), plus the short-buffer guard. Colors are checked by
      re-loading the saved PNG and reading pixels — RGB565 red 0xF800, green 0x07E0, blue 0x001F.

    Run:  pwsh -File Tests\VMScreenshotConvert.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m) { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertFrom-Win32ToolkitRgb565Image.ps1')
Add-Type -AssemblyName System.Drawing.Common -ErrorAction SilentlyContinue

function New-TempDir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('vmsc_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
# Solid W×H image in little-endian RGB565 (lo byte first).
function New-Solid565 { param([int]$W, [int]$H, [uint16]$Rgb565)
    $lo = [byte]($Rgb565 -band 0xFF); $hi = [byte](($Rgb565 -shr 8) -band 0xFF)
    $b = New-Object byte[] ($W * $H * 2)
    for ($i = 0; $i -lt $b.Length; $i += 2) { $b[$i] = $lo; $b[$i + 1] = $hi }
    return , $b
}
function Get-Corner { param([string]$Path, [int]$X, [int]$Y)
    $bmp = [System.Drawing.Bitmap]::new($Path); try { return $bmp.GetPixel($X, $Y) } finally { $bmp.Dispose() }
}

$dir = New-TempDir

# ── (a) even width — whole-buffer path — red ───────────────────────────────────────────────────────
Write-Host '[a] 2x2 solid red (even width: whole-buffer Marshal.Copy)' -ForegroundColor Cyan
$p = Join-Path $dir 'red.png'
ConvertFrom-Win32ToolkitRgb565Image -Bytes (New-Solid565 2 2 ([uint16]0xF800)) -Width 2 -Height 2 -Path $p | Out-Null
if (Test-Path $p) { Ok 'PNG written' } else { Bad 'no PNG' }
$px = Get-Corner $p 1 1
if ($px.R -ge 200 -and $px.G -le 40 -and $px.B -le 40) { Ok "bottom-right pixel is red (R=$($px.R) G=$($px.G) B=$($px.B))" } else { Bad "not red: R=$($px.R) G=$($px.G) B=$($px.B)" }

# ── (b) odd width — row-by-row path — blue ─────────────────────────────────────────────────────────
Write-Host '[b] 3x2 solid blue (odd width: stride padded, row-by-row copy)' -ForegroundColor Cyan
$p = Join-Path $dir 'blue.png'
ConvertFrom-Win32ToolkitRgb565Image -Bytes (New-Solid565 3 2 ([uint16]0x001F)) -Width 3 -Height 2 -Path $p | Out-Null
$px = Get-Corner $p 2 1
if ($px.B -ge 200 -and $px.R -le 40 -and $px.G -le 40) { Ok "far pixel is blue (R=$($px.R) G=$($px.G) B=$($px.B))" } else { Bad "not blue: R=$($px.R) G=$($px.G) B=$($px.B)" }

# ── (c) green, and dimensions preserved ────────────────────────────────────────────────────────────
Write-Host '[c] 4x3 solid green — dimensions preserved' -ForegroundColor Cyan
$p = Join-Path $dir 'green.png'
ConvertFrom-Win32ToolkitRgb565Image -Bytes (New-Solid565 4 3 ([uint16]0x07E0)) -Width 4 -Height 3 -Path $p | Out-Null
$bmp = [System.Drawing.Bitmap]::new($p)
try {
    if ($bmp.Width -eq 4 -and $bmp.Height -eq 3) { Ok 'PNG is 4x3' } else { Bad "wrong size $($bmp.Width)x$($bmp.Height)" }
    $g = $bmp.GetPixel(0, 0)
    if ($g.G -ge 200 -and $g.R -le 40 -and $g.B -le 40) { Ok "pixel is green (R=$($g.R) G=$($g.G) B=$($g.B))" } else { Bad "not green: R=$($g.R) G=$($g.G) B=$($g.B)" }
}
finally { $bmp.Dispose() }

# ── (d) short buffer is rejected ───────────────────────────────────────────────────────────────────
Write-Host '[d] a too-short byte buffer throws (no half-written PNG)' -ForegroundColor Cyan
$threw = $false
try { ConvertFrom-Win32ToolkitRgb565Image -Bytes (New-Object byte[] 4) -Width 10 -Height 10 -Path (Join-Path $dir 'short.png') | Out-Null }
catch { $threw = $true }
if ($threw) { Ok 'short buffer rejected' } else { Bad 'short buffer was NOT rejected' }

# ── (e) parent directory is created ────────────────────────────────────────────────────────────────
Write-Host '[e] a missing parent directory is created' -ForegroundColor Cyan
$nested = Join-Path $dir 'a\b\c\shot.png'
ConvertFrom-Win32ToolkitRgb565Image -Bytes (New-Solid565 2 2 ([uint16]0xF800)) -Width 2 -Height 2 -Path $nested | Out-Null
if (Test-Path $nested) { Ok 'nested path created and written' } else { Bad 'nested path not created' }

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
