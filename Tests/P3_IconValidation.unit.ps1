<#
    P3 — Get-AppIconFromWinget must validate what it fetches before writing it as the app icon.

      The old code: took IconUrl from the YAML with no scheme check (an http:// URL was fetched),
      Invoke-WebRequest -> [IO.File]::WriteAllBytes with NO size cap and NO content check, and decided
      the image type purely from the URL EXTENSION. So a plaintext (MITM-able) URL, an oversized body,
      or a non-image (e.g. an HTML error page) all got written over the PSADT default icon.

      The fix:
        1. Require HTTPS — an http:// / other-scheme URL is refused and never fetched.
        2. Cap the body at 5 MB (enforced on the real byte count, not just Content-Length).
        3. Validate by MAGIC BYTES (PNG/ICO/JPEG/BMP/GIF); the saved extension comes from the detected
           type, not the URL. A non-image is never written over the default.

    Invoke-WebRequest is shadowed; nothing hits the network or a filesystem we don't own.

    Run:  pwsh -File Tests\P3_IconValidation.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Set-Win32ToolkitIconSource.ps1')   # Get-AppIconFromWinget records icon provenance
. (Join-Path $repo 'Private\Get-AppIconFromWinget.ps1')

# ── Shadow Invoke-WebRequest: record every call and hand back a crafted response ──────────────────
$script:iwrCalled = 0
$script:iwrUri    = $null
$script:iwrBody   = [byte[]]@()      # what the fake server "returns" as .Content
$script:iwrHeaders = @{}             # optional Content-Length etc.
function Invoke-WebRequest {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] $Rest)
    # capture the -Uri value regardless of position
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if ("$($Rest[$i])" -ieq '-Uri' -and ($i + 1) -lt $Rest.Count) { $script:iwrUri = $Rest[$i + 1] }
    }
    $script:iwrCalled++
    [pscustomobject]@{ Content = $script:iwrBody; Headers = $script:iwrHeaders }
}

function New-Dir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ico_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
function New-Proj {
    param([string]$IconUrl)
    $project = New-Dir
    $files   = New-Dir
    Set-Content -LiteralPath (Join-Path $files 'app.installer.yaml') "IconUrl: $IconUrl" -Encoding UTF8
    [pscustomobject]@{ Project = $project; Files = $files; Png = (Join-Path $project 'Assets\AppIcon.png'); Ico = (Join-Path $project 'Assets\AppIcon.ico') }
}
function Reset-Iwr { $script:iwrCalled = 0; $script:iwrUri = $null; $script:iwrHeaders = @{} }

# A minimal but genuine PNG: the 8-byte signature + a little payload.
$realPng = [byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, 0x00,0x00,0x00,0x0D)
# A genuine ICO header.
$realIco = [byte[]]@(0x00,0x00,0x01,0x00, 0x01,0x00,0x10,0x10)
# Not an image at all — an HTML error page.
$notImg  = [System.Text.Encoding]::ASCII.GetBytes('<html><body>404 Not Found</body></html>')

# ── (a) http:// URL: refused, never fetched, nothing written ──────────────────────────────────────
Write-Host '[a] http:// IconUrl is refused — not fetched, no icon written' -ForegroundColor Cyan
Reset-Iwr
$script:iwrBody = $realPng
$t = New-Proj -IconUrl 'http://example.com/icon.png'
$r = Get-AppIconFromWinget -ProjectPath $t.Project -FilesPath $t.Files 3>$null 6>$null
if ($r -eq $false)            { Ok 'returns $false for a non-HTTPS URL' } else { Bad "http:// returned $r" }
if ($script:iwrCalled -eq 0)  { Ok 'Invoke-WebRequest was NOT called (no plaintext fetch)' } else { Bad "http:// was fetched ($($script:iwrCalled)x)" }
if (-not (Test-Path -LiteralPath $t.Png)) { Ok 'no AppIcon.png written' } else { Bad 'wrote an icon for an http:// URL' }

# ── (b) https + real PNG magic bytes: accepted, AppIcon.png written ────────────────────────────────
Write-Host '[b] https + PNG magic bytes -> $true and AppIcon.png written' -ForegroundColor Cyan
Reset-Iwr
$script:iwrBody = $realPng
$t = New-Proj -IconUrl 'https://example.com/icon.png'
$r = Get-AppIconFromWinget -ProjectPath $t.Project -FilesPath $t.Files 3>$null 6>$null
if ($r -eq $true)                       { Ok 'returns $true for a valid PNG over HTTPS' } else { Bad "valid PNG returned $r" }
if ($script:iwrCalled -eq 1)            { Ok 'Invoke-WebRequest was called once' } else { Bad "fetch count = $($script:iwrCalled)" }
if (Test-Path -LiteralPath $t.Png)      { Ok 'AppIcon.png was written' } else { Bad 'no AppIcon.png written for a valid PNG' }
if (Test-Path -LiteralPath $t.Png) {
    $written = [System.IO.File]::ReadAllBytes($t.Png)
    if ($written.Length -eq $realPng.Length -and $written[0] -eq 0x89) { Ok 'the exact PNG bytes were written' } else { Bad 'written bytes do not match the PNG body' }
}

# ── (b2) https + real ICO magic bytes: also writes AppIcon.ico ─────────────────────────────────────
Write-Host '[b2] https + ICO magic bytes -> AppIcon.ico written alongside AppIcon.png' -ForegroundColor Cyan
Reset-Iwr
$script:iwrBody = $realIco
$t = New-Proj -IconUrl 'https://example.com/whatever.png'   # URL ext lies (.png) but bytes are ICO
$r = Get-AppIconFromWinget -ProjectPath $t.Project -FilesPath $t.Files 3>$null 6>$null
if ($r -eq $true)                  { Ok 'returns $true for a valid ICO over HTTPS' } else { Bad "valid ICO returned $r" }
if (Test-Path -LiteralPath $t.Ico) { Ok 'AppIcon.ico written from the detected type (not the URL extension)' } else { Bad 'no AppIcon.ico for genuine ICO bytes' }

# ── (c) https + non-image body: refused, no icon written over the default ─────────────────────────
Write-Host '[c] https + non-image body (<html>) -> $false, default icon preserved' -ForegroundColor Cyan
Reset-Iwr
$script:iwrBody = $notImg
$t = New-Proj -IconUrl 'https://example.com/icon.png'
$r = Get-AppIconFromWinget -ProjectPath $t.Project -FilesPath $t.Files 3>$null 6>$null
if ($r -eq $false)                        { Ok 'returns $false when the body is not an image' } else { Bad "non-image returned $r" }
if (-not (Test-Path -LiteralPath $t.Png)) { Ok 'no AppIcon.png written over the PSADT default' } else { Bad 'wrote a non-image as the icon' }

# ── (d) https + body over 5 MB: refused ───────────────────────────────────────────────────────────
Write-Host '[d] https + body > 5 MB -> $false (size cap enforced on the real byte count)' -ForegroundColor Cyan
Reset-Iwr
$big = [byte[]]::new((5MB) + 1)          # PNG magic + oversized => must fail on SIZE, not content
$big[0] = 0x89; $big[1] = 0x50; $big[2] = 0x4E; $big[3] = 0x47
$script:iwrBody = $big
$t = New-Proj -IconUrl 'https://example.com/huge.png'
$r = Get-AppIconFromWinget -ProjectPath $t.Project -FilesPath $t.Files 3>$null 6>$null
if ($r -eq $false)                        { Ok 'returns $false when the body exceeds 5 MB' } else { Bad "oversized body returned $r" }
if (-not (Test-Path -LiteralPath $t.Png)) { Ok 'no oversized file written' } else { Bad 'wrote a >5 MB icon' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P3_IconValidation tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P3_IconValidation test(s) FAILED." -ForegroundColor Red; exit 1 }
