<#
    Icon-from-install feature — unit tests.

      Covers the host-side, testable surface of "source the app icon from the first install run":
        (a) ConvertFrom-Win32ToolkitDisplayIcon — parse ARP DisplayIcon (quoted/unquoted/index/negative/env).
        (b) ConvertTo-Win32ToolkitPngBytes      — PNG passthrough, JPEG->PNG conversion, garbage->null.
        (c) Set/Get-Win32ToolkitIconSource      — provenance marker round-trip.
        (d) Import-Win32ToolkitCapturedIcon     — precedence (winget/manual win) + promotion + validation.
        (e) Get-Win32ToolkitLargeIconBytes      — project icon -> genuine PNG bytes for Intune largeIcon.

      The guest-side extractor (PrivateExtractIcons P/Invoke inside New-TargetedDocumentation) needs a real
      installed app + GUI session, so it is validated by generating and parse-checking the guest script, not
      here. This file mirrors ConvertFrom-DisplayIcon's logic via the host copy it is derived from.

    Run:  pwsh -File Tests\IconFromInstall.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in @(
    'ConvertFrom-Win32ToolkitDisplayIcon',
    'ConvertTo-Win32ToolkitPngBytes',
    'Set-Win32ToolkitIconSource',
    'Get-Win32ToolkitIconSource',
    'Get-Win32ToolkitLargeIconBytes',
    'Import-Win32ToolkitCapturedIcon')) {
    . (Join-Path $repo (Join-Path 'Private' ($f + '.ps1')))
}

Add-Type -AssemblyName System.Drawing

function New-TestImageBytes {
    param([ValidateSet('Png', 'Jpeg')][string]$Format = 'Png', [int]$W = 64, [int]$H = 64)
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try { $g.Clear([System.Drawing.Color]::FromArgb(200, 20, 130, 210)) } finally { $g.Dispose() }
        $ms = New-Object System.IO.MemoryStream
        try {
            $bmp.Save($ms, ([System.Drawing.Imaging.ImageFormat]::$Format))
            return $ms.ToArray()
        }
        finally { $ms.Dispose() }
    }
    finally { $bmp.Dispose() }
}
function BytesEqual($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return $false }
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}
function IsPng($b) {
    return ($b -and $b.Length -ge 4 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47)
}
function New-TempProject {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('iconft_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Path (Join-Path $p 'Assets') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $p 'Sandbox\Logs') -Force | Out-Null
    return $p
}

# ── (a) DisplayIcon parser ─────────────────────────────────────────────────────────────────────────
Write-Host '[a] ConvertFrom-Win32ToolkitDisplayIcon' -ForegroundColor Cyan
$cases = @(
    @{ In = '"C:\Program Files\App\app.exe",0'; Path = 'C:\Program Files\App\app.exe'; Index = 0 },
    @{ In = 'C:\App\app.exe,-3';                Path = 'C:\App\app.exe';                Index = -3 },
    @{ In = '"C:\A B\x.exe"';                   Path = 'C:\A B\x.exe';                  Index = 0 },
    @{ In = 'C:\A\x.ico';                       Path = 'C:\A\x.ico';                    Index = 0 },
    @{ In = 'C:\A\x.exe,7';                     Path = 'C:\A\x.exe';                    Index = 7 }
)
foreach ($c in $cases) {
    $r = ConvertFrom-Win32ToolkitDisplayIcon -Value $c.In
    if ($r -and $r.Path -eq $c.Path -and $r.Index -eq $c.Index) { Ok "parsed '$($c.In)' -> ($($r.Path) | $($r.Index))" }
    else { Bad "parse '$($c.In)' -> got ($($r.Path) | $($r.Index)), expected ($($c.Path) | $($c.Index))" }
}
foreach ($empty in @('', '   ', $null)) {
    if ($null -eq (ConvertFrom-Win32ToolkitDisplayIcon -Value $empty)) { Ok "empty/blank -> null" } else { Bad "blank value did not return null" }
}
$env1 = ConvertFrom-Win32ToolkitDisplayIcon -Value '%SystemRoot%\system32\shell32.dll,10'
if ($env1 -and $env1.Index -eq 10 -and $env1.Path -notmatch '%' -and $env1.Path -match 'system32') { Ok "env vars expanded ($($env1.Path))" }
else { Bad "env var expansion failed: $($env1.Path)" }

# ── (b) PNG normalization ──────────────────────────────────────────────────────────────────────────
Write-Host '[b] ConvertTo-Win32ToolkitPngBytes' -ForegroundColor Cyan
$png  = New-TestImageBytes -Format Png
$jpg  = New-TestImageBytes -Format Jpeg
$pass = ConvertTo-Win32ToolkitPngBytes -Bytes $png
if (BytesEqual $pass $png) { Ok 'already-PNG passes through unchanged' } else { Bad 'PNG passthrough altered the bytes' }
$conv = ConvertTo-Win32ToolkitPngBytes -Bytes $jpg
if ((IsPng $conv) -and -not (BytesEqual $conv $jpg)) { Ok 'JPEG re-encoded to real PNG' } else { Bad 'JPEG was not converted to PNG' }
if ($null -eq (ConvertTo-Win32ToolkitPngBytes -Bytes ([byte[]]@(0, 1, 2, 3, 4, 5)))) { Ok 'garbage bytes -> null' } else { Bad 'garbage bytes did not return null' }
if ($null -eq (ConvertTo-Win32ToolkitPngBytes -Bytes ([byte[]]@()))) { Ok 'empty -> null' } else { Bad 'empty did not return null' }
if ($null -eq (ConvertTo-Win32ToolkitPngBytes -Bytes $null)) { Ok 'null -> null' } else { Bad 'null did not return null' }

# ── (c) provenance marker round-trip ───────────────────────────────────────────────────────────────
Write-Host '[c] Set/Get-Win32ToolkitIconSource' -ForegroundColor Cyan
$pc = New-TempProject
try {
    if ($null -eq (Get-Win32ToolkitIconSource -ProjectPath $pc)) { Ok 'no marker -> null' } else { Bad 'expected null before any marker' }
    Set-Win32ToolkitIconSource -ProjectPath $pc -Source 'winget'
    if ((Get-Win32ToolkitIconSource -ProjectPath $pc) -eq 'winget') { Ok "round-trips 'winget'" } else { Bad 'marker did not round-trip' }
    Set-Win32ToolkitIconSource -ProjectPath $pc -Source 'captured'
    if ((Get-Win32ToolkitIconSource -ProjectPath $pc) -eq 'captured') { Ok "overwrite to 'captured'" } else { Bad 'marker overwrite failed' }
}
finally { Remove-Item $pc -Recurse -Force -ErrorAction SilentlyContinue }

# ── (d) capture reconcile / precedence ─────────────────────────────────────────────────────────────
Write-Host '[d] Import-Win32ToolkitCapturedIcon' -ForegroundColor Cyan
$pngA = New-TestImageBytes -Format Png -W 48 -H 48
$pngB = New-TestImageBytes -Format Png -W 200 -H 200

# d1: winget marker present -> captured icon is IGNORED, existing icon untouched.
$p1 = New-TempProject
try {
    [System.IO.File]::WriteAllBytes((Join-Path $p1 'Assets\AppIcon.png'), $pngA)
    [System.IO.File]::WriteAllBytes((Join-Path $p1 'Sandbox\Logs\AppIcon_Captured.png'), $pngB)
    Set-Win32ToolkitIconSource -ProjectPath $p1 -Source 'winget'
    $r = Import-Win32ToolkitCapturedIcon -ProjectPath $p1 6>$null
    $after = [System.IO.File]::ReadAllBytes((Join-Path $p1 'Assets\AppIcon.png'))
    if ($r -eq $false -and (BytesEqual $after $pngA)) { Ok 'winget marker -> captured ignored, winget icon kept' }
    else { Bad "winget precedence violated (returned $r)" }
}
finally { Remove-Item $p1 -Recurse -Force -ErrorAction SilentlyContinue }

# d2: manual marker present -> also wins.
$p2 = New-TempProject
try {
    [System.IO.File]::WriteAllBytes((Join-Path $p2 'Assets\AppIcon.png'), $pngA)
    [System.IO.File]::WriteAllBytes((Join-Path $p2 'Sandbox\Logs\AppIcon_Captured.png'), $pngB)
    Set-Win32ToolkitIconSource -ProjectPath $p2 -Source 'manual'
    $r = Import-Win32ToolkitCapturedIcon -ProjectPath $p2 6>$null
    if ($r -eq $false -and (BytesEqual ([System.IO.File]::ReadAllBytes((Join-Path $p2 'Assets\AppIcon.png'))) $pngA)) { Ok 'manual marker -> captured ignored' }
    else { Bad "manual precedence violated (returned $r)" }
}
finally { Remove-Item $p2 -Recurse -Force -ErrorAction SilentlyContinue }

# d3: no marker -> captured icon is promoted, and the marker becomes 'captured'.
$p3 = New-TempProject
try {
    [System.IO.File]::WriteAllBytes((Join-Path $p3 'Assets\AppIcon.png'), $pngA)  # PSADT default stand-in
    [System.IO.File]::WriteAllBytes((Join-Path $p3 'Sandbox\Logs\AppIcon_Captured.png'), $pngB)
    $r = Import-Win32ToolkitCapturedIcon -ProjectPath $p3 6>$null
    $after = [System.IO.File]::ReadAllBytes((Join-Path $p3 'Assets\AppIcon.png'))
    if ($r -eq $true -and (BytesEqual $after $pngB) -and (Get-Win32ToolkitIconSource -ProjectPath $p3) -eq 'captured') { Ok 'no marker -> captured promoted + marker set' }
    else { Bad "captured promotion failed (returned $r)" }
}
finally { Remove-Item $p3 -Recurse -Force -ErrorAction SilentlyContinue }

# d4: captured file is garbage -> not promoted, existing icon untouched.
$p4 = New-TempProject
try {
    [System.IO.File]::WriteAllBytes((Join-Path $p4 'Assets\AppIcon.png'), $pngA)
    [System.IO.File]::WriteAllBytes((Join-Path $p4 'Sandbox\Logs\AppIcon_Captured.png'), ([byte[]]@(1, 2, 3, 4, 5, 6, 7, 8)))
    $r = Import-Win32ToolkitCapturedIcon -ProjectPath $p4 6>$null 3>$null
    if ($r -eq $false -and (BytesEqual ([System.IO.File]::ReadAllBytes((Join-Path $p4 'Assets\AppIcon.png'))) $pngA)) { Ok 'garbage capture -> rejected, icon kept' }
    else { Bad "garbage capture was not rejected (returned $r)" }
}
finally { Remove-Item $p4 -Recurse -Force -ErrorAction SilentlyContinue }

# d5: no captured file at all -> false.
$p5 = New-TempProject
try {
    if ((Import-Win32ToolkitCapturedIcon -ProjectPath $p5 6>$null) -eq $false) { Ok 'no capture file -> false' } else { Bad 'expected false with no capture file' }
}
finally { Remove-Item $p5 -Recurse -Force -ErrorAction SilentlyContinue }

# ── (e) largeIcon bytes for publish ────────────────────────────────────────────────────────────────
Write-Host '[e] Get-Win32ToolkitLargeIconBytes' -ForegroundColor Cyan
$p6 = New-TempProject
try {
    if ($null -eq (Get-Win32ToolkitLargeIconBytes -ProjectPath $p6)) { Ok 'no icon -> null' } else { Bad 'expected null with no icon' }
    [System.IO.File]::WriteAllBytes((Join-Path $p6 'Assets\AppIcon.png'), $png)
    $lb = Get-Win32ToolkitLargeIconBytes -ProjectPath $p6
    if ((IsPng $lb) -and (BytesEqual $lb $png)) { Ok 'PNG icon -> same PNG bytes' } else { Bad 'PNG icon bytes mismatch' }
    [System.IO.File]::WriteAllBytes((Join-Path $p6 'Assets\AppIcon.png'), $jpg)  # a JPEG mislabeled as .png
    $lb2 = Get-Win32ToolkitLargeIconBytes -ProjectPath $p6
    if (IsPng $lb2) { Ok 'JPEG-in-.png -> normalized to real PNG for largeIcon' } else { Bad 'JPEG-in-.png was not normalized' }
}
finally { Remove-Item $p6 -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
