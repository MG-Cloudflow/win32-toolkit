<#
    Guest capture script — generation + syntax guard.

      New-TargetedDocumentation emits the device script as a single-quoted here-string, so the HOST parser
      treats it as an opaque literal and CANNOT catch syntax errors inside it. The icon extractor adds a
      NESTED here-string (Add-Type -MemberDefinition @"..."@) whose closing "@ must sit at column 0 or the
      guest's Windows PowerShell 5.1 parser breaks at runtime — invisible to normal host-side checks.

      This test generates the guest script and parses it as its own file, so a broken here-string / column-0
      slip fails CI instead of a sandbox run hours later. It also asserts the icon block is present and the
      file carries a UTF-8 BOM (5.1 decodes a BOM-less file as ANSI and mojibakes non-ASCII).

    Run:  pwsh -File Tests\IconGuestScript.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Import-Module (Join-Path $repo 'win32-toolkit.psd1') -Force
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('iconguest_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path (Join-Path $proj 'Files') -Force | Out-Null

try {
    # HyperV backend writes the guest script then returns early (no .wsb, no sandbox feature probe).
    $null = & (Get-Module win32-toolkit) {
        param($p, $n) New-TargetedDocumentation -ProjectPath $p -ProjectName $n -Backend HyperV -SkipLaunch 6>$null 3>$null
    } $proj 'GuestTest_x64_1.0.0'

    $guest = Join-Path $proj 'SupportFiles\TargetedDocumentationScript.ps1'
    if (Test-Path -LiteralPath $guest) { Ok 'guest script generated' } else { Bad 'guest script was not generated'; throw 'no guest script' }

    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($guest, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        Bad "guest script has $($errs.Count) parse error(s):"
        $errs | Select-Object -First 5 | ForEach-Object { Write-Host "        line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor DarkRed }
    }
    else { Ok 'guest script parses cleanly under the PowerShell parser' }

    $raw = Get-Content -LiteralPath $guest -Raw
    if ($raw -match 'PrivateExtractIcons')          { Ok 'icon extractor P/Invoke present' }         else { Bad 'PrivateExtractIcons block missing' }
    if ($raw -match 'AppIcon_Captured\.png')        { Ok 'writes AppIcon_Captured.png' }             else { Bad 'AppIcon_Captured.png output missing' }
    if ($raw -match 'Format32bppArgb')              { Ok 'alpha-safe 32bpp ARGB bitmap used' }       else { Bad 'alpha-safe bitmap path missing' }

    $bom = [System.IO.File]::ReadAllBytes($guest) | Select-Object -First 3
    if ($bom.Count -ge 3 -and $bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF) { Ok 'guest script has a UTF-8 BOM' }
    else { Bad 'guest script is missing the UTF-8 BOM (5.1 would mojibake it)' }
}
finally {
    Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module win32-toolkit -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
