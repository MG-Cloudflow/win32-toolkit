# SparseConfig.unit.ps1 — F1: New-Win32ToolkitSparseConfig emits a SPARSE, valid, correctly-typed
# PSADT config.psd1 from an org template. Guards the superimpose contract: omit-unset-keys, bare-hex
# FluentAccentColor, quote-escaped strings, $env tokens preserved, DialogStyle/LanguageOverride,
# explicit Assets paths on every config (ORG-03 / TST-05), 0x RRGGBB gets an opaque alpha (ORG-12).

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'Private\ConvertTo-PSSingleQuoted.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitAccentLiteral.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitSparseConfig.ps1')

$fail = 0
function Ok  { param($m) Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad { param($m) Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

function Import-Sparse { param([string]$text)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sparse_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.psd1')
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($true)))
    try { Import-PowerShellDataFile -LiteralPath $tmp } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n[1] Full template — all keys, correct typing" -ForegroundColor Cyan
$t1 = [pscustomobject]@{
    CompanyName='Acme IT'; LogPath='$envWinDir\Logs\Software'
    DialogStyle='Classic'; FluentAccentColor='0xFF0078D7'; LanguageOverride='nl'
}
$c1 = New-Win32ToolkitSparseConfig -Template $t1
$p1 = Import-Sparse $c1
if ($p1.Toolkit.CompanyName -eq 'Acme IT') { Ok 'CompanyName' } else { Bad "CompanyName=[$($p1.Toolkit.CompanyName)]" }
if ($p1.Toolkit.LogPath -eq '$envWinDir\Logs\Software') { Ok 'LogPath preserves $env token verbatim' } else { Bad "LogPath=[$($p1.Toolkit.LogPath)]" }
if ($p1.UI.DialogStyle -eq 'Classic') { Ok 'DialogStyle=Classic' } else { Bad "DialogStyle=[$($p1.UI.DialogStyle)]" }
# Bare hex must parse as an integer, exactly as PSADT's own 0xFF0078D7 default does.
if ($p1.UI.FluentAccentColor -is [int] -and $p1.UI.FluentAccentColor -eq 0xFF0078D7) { Ok 'FluentAccentColor bare hex -> Int32' } else { Bad "accent=[$($p1.UI.FluentAccentColor)] type=[$($p1.UI.FluentAccentColor.GetType().Name)]" }
if ($p1.UI.LanguageOverride -eq 'nl') { Ok 'LanguageOverride' } else { Bad "lang=[$($p1.UI.LanguageOverride)]" }

Write-Host "`n[2] Sparse — unset keys are OMITTED (cannot blank a default)" -ForegroundColor Cyan
$t2 = [pscustomobject]@{ CompanyName='Bare Co'; LogPath=''; DialogStyle='Fluent'; FluentAccentColor=''; LanguageOverride='' }
$c2 = New-Win32ToolkitSparseConfig -Template $t2
$p2 = Import-Sparse $c2
if (-not $p2.Toolkit.ContainsKey('LogPath')) { Ok 'empty LogPath omitted' } else { Bad 'empty LogPath emitted' }
if (-not $p2.UI.ContainsKey('FluentAccentColor')) { Ok 'empty accent omitted' } else { Bad 'empty accent emitted' }
if (-not $p2.UI.ContainsKey('LanguageOverride')) { Ok 'empty language omitted' } else { Bad 'empty language emitted' }
if ($c2 -notmatch "''" ) { Ok 'no empty-string literals in output' } else { Bad 'output contains empty-string literals' }

Write-Host "`n[3] Old-schema template (missing new fields) degrades cleanly" -ForegroundColor Cyan
$t3 = [pscustomobject]@{ CompanyName='Legacy Co'; LogPath='C:\Logs' }  # no DialogStyle/accent/language
$c3 = New-Win32ToolkitSparseConfig -Template $t3
$p3 = Import-Sparse $c3
if ($p3.UI.DialogStyle -eq 'Fluent') { Ok 'missing DialogStyle -> defaults to Fluent' } else { Bad "DialogStyle=[$($p3.UI.DialogStyle)]" }
if ($p3.Toolkit.CompanyName -eq 'Legacy Co') { Ok 'CompanyName present' } else { Bad 'CompanyName missing' }

Write-Host "`n[4] Injection safety — apostrophes doubled, output still parses" -ForegroundColor Cyan
$t4 = [pscustomobject]@{ CompanyName="O'Brien's IT"; LogPath="C:\Logs\O'Neil"; DialogStyle='Fluent' }
$c4 = New-Win32ToolkitSparseConfig -Template $t4
$p4 = Import-Sparse $c4
if ($p4.Toolkit.CompanyName -eq "O'Brien's IT") { Ok "CompanyName apostrophes round-trip" } else { Bad "company=[$($p4.Toolkit.CompanyName)]" }
if ($p4.Toolkit.LogPath -eq "C:\Logs\O'Neil") { Ok 'LogPath apostrophes round-trip' } else { Bad "logpath=[$($p4.Toolkit.LogPath)]" }

Write-Host "`n[5] Invalid DialogStyle falls back to Fluent (never emits garbage)" -ForegroundColor Cyan
$t5 = [pscustomobject]@{ CompanyName='X'; DialogStyle='Neon' }
$p5 = Import-Sparse (New-Win32ToolkitSparseConfig -Template $t5)
if ($p5.UI.DialogStyle -eq 'Fluent') { Ok "invalid style -> Fluent" } else { Bad "style=[$($p5.UI.DialogStyle)]" }

Write-Host "`n[6] FluentAccentColor — every hex form normalizes to a PARSEABLE 0x literal (review fix)" -ForegroundColor Cyan
# The bug: a bare/#-prefixed hex was emitted verbatim, producing a config.psd1 that THROWS on load
# (aborting the on-device SYSTEM deploy). Each accepted form must now round-trip through Import.
foreach ($case in @(
    @{ In='0xFF0078D7'; Expect=0xFF0078D7 }
    @{ In='#0078D7';    Expect=0xFF0078D7 }   # 6-digit RGB -> FF alpha
    @{ In='0078D7';     Expect=0xFF0078D7 }   # bare 6-digit
    @{ In='FF0078D7';   Expect=0xFF0078D7 }   # bare 8-digit ARGB
)) {
    $tc = [pscustomobject]@{ CompanyName='X'; DialogStyle='Fluent'; FluentAccentColor=$case.In }
    $pc = Import-Sparse (New-Win32ToolkitSparseConfig -Template $tc)
    if ($pc.UI.ContainsKey('FluentAccentColor') -and $pc.UI.FluentAccentColor -eq $case.Expect) {
        Ok "accent '$($case.In)' -> parseable 0x literal ($($pc.UI.FluentAccentColor))"
    } else { Bad "accent '$($case.In)' -> [$($pc.UI.FluentAccentColor)] (expected $($case.Expect))" }
}

Write-Host "`n[7] Garbage accent is OMITTED + warns (degrades to PSADT default, never breaks the config)" -ForegroundColor Cyan
$tg = [pscustomobject]@{ CompanyName='X'; DialogStyle='Fluent'; FluentAccentColor='blue' }
$cg = New-Win32ToolkitSparseConfig -Template $tg -WarningVariable wa -WarningAction SilentlyContinue
$pg = Import-Sparse $cg   # must still parse
if (-not $pg.UI.ContainsKey('FluentAccentColor')) { Ok 'invalid accent omitted' } else { Bad 'invalid accent emitted' }
if ($wa) { Ok 'invalid accent warned' } else { Bad 'no warning for invalid accent' }

Write-Host "`n[8] Assets ALWAYS emitted first, explicit project paths, never Base64 (ORG-03 / TST-05)" -ForegroundColor Cyan
# PSADT 4.2's module defaults for Logo/Banner are embedded Base64 images that are never resolved against
# the project, so a sparse config without Assets showed the PSADT logo instead of the app/org icon.
foreach ($case in @(
    @{ Label = 'full template';                 T = $t1 }
    @{ Label = 'old-schema template';           T = $t3 }
    @{ Label = 'template with no fields at all'; T = [pscustomobject]@{} }
)) {
    $txt = New-Win32ToolkitSparseConfig -Template $case.T
    $pa  = Import-Sparse $txt
    if ($pa.ContainsKey('Assets') -and $pa.Assets.Logo -eq '..\Assets\AppIcon.png' -and $pa.Assets.Banner -eq '..\Assets\Banner.Classic.png') {
        Ok "$($case.Label): Assets.Logo / Assets.Banner point at the project's Assets\ files"
    } else { Bad "$($case.Label): Assets=[$(($pa.Assets | Out-String).Trim())]" }
    if (@($pa.Assets.Keys).Count -eq 2 -and -not $pa.Assets.ContainsKey('LogoDark') -and -not $pa.Assets.ContainsKey('TaskbarIcon')) {
        Ok "$($case.Label): only Logo + Banner (no LogoDark / TaskbarIcon)"
    } else { Bad "$($case.Label): Assets keys = $(@($pa.Assets.Keys) -join ', ')" }
    # First section of the hashtable (the ordered text the generator writes).
    $firstKey = ([regex]::Match($txt, '(?m)^    (\w+) = @\{')).Groups[1].Value
    if ($firstKey -eq 'Assets') { Ok "$($case.Label): Assets is the first section" } else { Bad "$($case.Label): first section is '$firstKey'" }
    if ($txt -notmatch '[A-Za-z0-9+/]{80,}={0,2}') { Ok "$($case.Label): no Base64 payload in the config" } else { Bad "$($case.Label): config contains a Base64-looking value" }
}

Write-Host "`n[9] 0x + 6 hex is RRGGBB -> opaque alpha; other 0x lengths are rejected (ORG-12)" -ForegroundColor Cyan
# 0x0078D7 used to pass through unchanged = alpha 0 = a fully transparent accent on the dialog.
foreach ($case in @(
    @{ In = '0x0078D7';   Expect = 0xFF0078D7 }
    @{ In = '0x0078d7';   Expect = 0xFF0078D7 }
    @{ In = '0X0078D7';   Expect = 0xFF0078D7 }
    @{ In = '0x800078D7'; Expect = 0x800078D7 }   # explicit AARRGGBB kept as is (semi-transparent on purpose)
)) {
    $pc = Import-Sparse (New-Win32ToolkitSparseConfig -Template ([pscustomobject]@{ FluentAccentColor = $case.In }))
    if ($pc.UI.FluentAccentColor -eq $case.Expect) { Ok "accent '$($case.In)' -> $('0x{0:X8}' -f $pc.UI.FluentAccentColor)" }
    else { Bad "accent '$($case.In)' -> [$($pc.UI.FluentAccentColor)] (expected $('0x{0:X8}' -f $case.Expect))" }
}
if ((ConvertTo-Win32ToolkitAccentLiteral -Value '0x0078D7') -ceq '0xFF0078D7') { Ok "ConvertTo-Win32ToolkitAccentLiteral '0x0078D7' -> '0xFF0078D7'" } else { Bad "literal = [$(ConvertTo-Win32ToolkitAccentLiteral -Value '0x0078D7')]" }
foreach ($badAccent in @('0x123', '0x12345', '0x1234567', '0x123456789', '0x')) {
    $lit = ConvertTo-Win32ToolkitAccentLiteral -Value $badAccent
    $cb  = New-Win32ToolkitSparseConfig -Template ([pscustomobject]@{ FluentAccentColor = $badAccent }) -WarningVariable wb -WarningAction SilentlyContinue
    $pb  = Import-Sparse $cb
    if ($null -eq $lit -and -not $pb.UI.ContainsKey('FluentAccentColor') -and $wb) { Ok "accent '$badAccent' -> rejected, omitted, warned" }
    else { Bad "accent '$badAccent' -> literal=[$lit] emitted=[$($pb.UI.FluentAccentColor)] warned=[$([bool]$wb)]" }
}

Write-Host "`n[10] Typographic single quotes round-trip (security-02: U+2018/U+2019/U+201A/U+201B end a '...' literal)" -ForegroundColor Cyan
# Escaping only the ASCII apostrophe left e.g. a French CompanyName with U+2019 breaking config.psd1 (3 parse
# errors under 5.1 and 7), so EVERY deployment of the template failed. Source stays ASCII: [char] builds them.
$company10 = 'L' + [char]0x2019 + 'Atelier IT'
$log10     = 'C:\Logs\' + [char]0x2018 + 'a' + [char]0x201A + 'b' + [char]0x201B + "c'd"
$c10 = New-Win32ToolkitSparseConfig -Template ([pscustomobject]@{ CompanyName = $company10; LogPath = $log10; DialogStyle = 'Fluent' })
$e10 = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($c10, [ref]$null, [ref]$e10)
if (@($e10).Count -eq 0) { Ok 'config.psd1 with typographic quotes parses (0 errors)' } else { Bad "parse errors: $($e10[0].Message)" }
$p10 = Import-Sparse $c10
if ($p10.Toolkit.CompanyName -ceq $company10) { Ok 'CompanyName with U+2019 round-trips exactly (Import-PowerShellDataFile)' } else { Bad "company=[$($p10.Toolkit.CompanyName)]" }
if ($p10.Toolkit.LogPath -ceq $log10) { Ok "LogPath with U+2018/U+201A/U+201B and ' round-trips exactly" } else { Bad "logpath=[$($p10.Toolkit.LogPath)]" }
$ps51 = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $ps51) {
    # The device reads the file with Windows PowerShell 5.1: import it there (UTF-8 with BOM, as written by
    # Apply-OrgTemplate) and compare the value as UTF-8 base64 (ASCII-safe across the console).
    $tmp10 = Join-Path ([System.IO.Path]::GetTempPath()) ('sparse51_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
    [System.IO.File]::WriteAllText($tmp10, $c10, (New-Object System.Text.UTF8Encoding($true)))
    $prev10 = $env:W32T_SPARSECHECK
    try {
        $env:W32T_SPARSECHECK = $tmp10
        $b64 = & $ps51 -NoProfile -NonInteractive -Command '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Import-PowerShellDataFile -LiteralPath $env:W32T_SPARSECHECK).Toolkit.CompanyName))'
    }
    finally { $env:W32T_SPARSECHECK = $prev10; Remove-Item -LiteralPath $tmp10 -Force -ErrorAction SilentlyContinue }
    $got51 = try { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(("$b64").Trim())) } catch { "<$b64>" }
    if ($got51 -ceq $company10) { Ok 'Windows PowerShell 5.1 imports the same CompanyName' } else { Bad "5.1 CompanyName=[$got51]" }
}
else { Write-Host '  SKIP: Windows PowerShell 5.1 not found' -ForegroundColor DarkGray }

Write-Host ""
if ($fail -eq 0) { Write-Host "SparseConfig unit test PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILURE(S)" -ForegroundColor Red; exit 1 }
