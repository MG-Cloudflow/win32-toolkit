<#
    New-InstallAssertionScript — generates Sandbox\InstallAssertions.ps1, the guest assertion script
    that gives the InstallUninstall test a real PASS/FAIL.

    Asserts (the core three):
      1. The file is written with a UTF-8 BOM (first 3 bytes EF BB BF) and PARSES as 5.1-safe
         PowerShell (Parser::ParseFile clean; no ternary / ?? / ?. tokens).
      2. NO app value is spliced into the generated code — the fake project's DisplayName / Version
         literals do NOT appear in the generated text (they must be read from $cfg.App.* at runtime).
      3. Executing the generated logic against a FAKE AppConfig + a STUBBED registry proves:
           PostInstall  -> ASSERT InstallDetected-PostInstall = PASS when the tattoo matches,
                           FAIL when the key is absent;
           PostUninstall-> ASSERT UninstallClean-PostUninstall = PASS when the key is gone,
                           and 'RESULT COMPLETE' is emitted.

    EXECUTION NOTE: rather than a child pwsh, the generated script is invoked IN-PROCESS via '&' with
    'C:\PSADT' text-substituted to a temp layout (so $logDir / $cfgPath resolve under the temp dir) and
    the single registry cmdlet it uses (Get-ItemProperty) shadowed by a function backed by an in-memory
    fake registry ($script:fakeReg). The generated script is 5.1-safe (a subset of PS7), so PS7 runs it
    faithfully; '&' inherits the shadowing function and $script:fakeReg from this test's scope.

    Run:  pwsh -File Tests\InstallAssertionScript.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\New-InstallAssertionScript.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitProductCode.ps1')
# The MSI ProductCode is read host-side from Files\<msi> (WindowsInstaller COM) - shadowed: no real MSI.
$script:msiCode  = '{6F2C1A3B-4D5E-4F60-8A9B-0C1D2E3F4A5B}'
$script:msiReads = @()
function Get-Win32ToolkitMsiProperty { param([string]$Path, [string]$Property) $script:msiReads += "$(Split-Path -Leaf $Path)|$Property"; $script:msiCode }

# ── Distinctive fake app metadata. These literals must NEVER appear in the generated script text. ────
$fakeAuthor  = 'CloudFlowProbe'
$fakeVendor  = 'ZzVendorProbe'
$fakeDisplay = 'Contoso Widget Probe 9000'
$fakeVersion = '7.4.2.1'

function New-TempDir {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ia_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $p
}

$proj = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
$appConfig = [ordered]@{
    SchemaVersion = '1.0'
    App = [ordered]@{
        Vendor = $fakeVendor; Name = 'WidgetProbe'; DisplayName = $fakeDisplay; Version = $fakeVersion
        Arch = 'x64'; ScriptAuthor = $fakeAuthor; ScriptDate = '2026-07-15'; Description = ''; InformationUrl = ''
    }
    Installer = [ordered]@{ Type = 'msi'; FileName = 'w.msi'; SilentArgs = '/qn' }
}
# BOM-less UTF-8 (like Set-Win32ToolkitAppConfig writes).
[System.IO.File]::WriteAllText(
    (Join-Path $proj 'SupportFiles\AppConfig.json'),
    ($appConfig | ConvertTo-Json -Depth 6),
    (New-Object System.Text.UTF8Encoding($false)))

# ══ 1. Generate ══════════════════════════════════════════════════════════════════════════════════
Write-Host '[1] New-InstallAssertionScript writes Sandbox\InstallAssertions.ps1' -ForegroundColor Cyan
$genPath = New-InstallAssertionScript -ProjectPath $proj
if ($genPath -and (Test-Path -LiteralPath $genPath)) { Ok "returned a real path: $genPath" } else { Bad "did not return a path (got: $genPath)" }

# ── BOM ──
$bytes = [System.IO.File]::ReadAllBytes($genPath)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Ok 'file is UTF-8 WITH BOM (EF BB BF) - decodes correctly under WinPS 5.1'
} else {
    Bad "missing UTF-8 BOM (first bytes: $([string]::Join(' ', ($bytes[0..2] | ForEach-Object { $_.ToString('X2') })))"
}

$genText = Get-Content -LiteralPath $genPath -Raw

# ── Parses clean ──
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($genPath, [ref]$null, [ref]$errs) | Out-Null
if (-not ($errs -and $errs.Count)) { Ok 'generated script PARSES (Parser::ParseFile clean)' } else { Bad "parse errors: $($errs[0].Message)" }

# ── 5.1-safe: no PS7-only tokens ──
$ps7Tokens = @('??', '?.', '?[')
$badToken = $null
foreach ($t in $ps7Tokens) { if ($genText.Contains($t)) { $badToken = $t; break } }
# ternary: a bare ' ? ' operator (our script uses none). Guard against it too.
if (-not $badToken -and ($genText -match '\S\s+\?\s+\S.*\s+:\s+\S')) { $badToken = 'ternary' }
if (-not $badToken) { Ok 'no PS7-only syntax (?? / ?. / ?[ / ternary) - 5.1-safe' } else { Bad "found PS7-only token: $badToken" }

# ══ 2. No app value spliced ══════════════════════════════════════════════════════════════════════
Write-Host '[2] no app value is spliced into the generated script (read as DATA at runtime)' -ForegroundColor Cyan
$leaked = @()
foreach ($v in @($fakeAuthor, $fakeVendor, $fakeDisplay, $fakeVersion)) {
    if ($genText.Contains($v)) { $leaked += $v }
}
if ($leaked.Count -eq 0) { Ok 'DisplayName / Vendor / Version / ScriptAuthor literals are absent from the script text' } else { Bad "spliced literal(s) leaked into the script: $($leaked -join ', ')" }
if ($genText -match '\$cfg\.App|\.App\b|ConvertFrom-Json') { Ok 'the script reads AppConfig.json / $cfg.App at runtime' } else { Bad 'no runtime AppConfig read found' }
# Log times are UTC with a 'Z', like PsadtExitCodes.log (test campaign 2026-10-21).
if ($genText.Contains("[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'") -and $genText -notmatch "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'") { Ok 'assertion lines are stamped in UTC with a Z' } else { Bad 'assertion log times are not UTC' }
$updText = Get-Content -LiteralPath (Join-Path $repo 'Private\New-UpdateAssertionScript.ps1') -Raw
if ($updText.Contains("[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'") -and $updText -notmatch "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'") { Ok 'Update assertion lines are stamped in UTC with a Z too' } else { Bad 'Update assertion log times are not UTC' }

# ══ 3. Execute the generated logic against a fake config + stubbed registry ═══════════════════════
Write-Host '[3] execute: PostInstall PASS/FAIL and PostUninstall RESULT COMPLETE' -ForegroundColor Cyan

# The single registry cmdlet the tattoo path uses is Get-ItemProperty. Shadow it with an in-memory
# fake registry; '&'-invoking the copied script resolves this function via the scope chain.
# NOTE: use $global: (not $script:) — a non-module function's $script: scope is DYNAMIC to the
# script file currently on the call stack. When the '&'-invoked copy calls this shadow, $script:
# would resolve to the COPY's scope (undefined), so the fake store must live in $global:.
$global:fakeReg = @{}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Path)
    $key = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($global:fakeReg.ContainsKey($key)) { return [pscustomobject]$global:fakeReg[$key] }
    throw "fake-registry: key not found: $key"
}
# Match a result/marker line despite the leading '[timestamp] ' prefix Write-AssertLine adds.
function Test-LogHas([string[]]$Lines, [string]$Suffix) { @($Lines | Where-Object { $_ -like "*$Suffix" }).Count -ge 1 }

# Build a temp C:\PSADT layout and a path-substituted COPY of the generated script.
$guestRoot = New-TempDir                                  # stands in for C:\PSADT
New-Item -ItemType Directory -Path (Join-Path $guestRoot 'SupportFiles') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Sandbox\Logs')   -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $proj 'SupportFiles\AppConfig.json') -Destination (Join-Path $guestRoot 'SupportFiles\AppConfig.json') -Force

$copyPath = Join-Path $guestRoot 'Sandbox\InstallAssertions.copy.ps1'
$copyText = $genText.Replace('C:\PSADT', $guestRoot)
Set-Content -LiteralPath $copyPath -Value $copyText -Encoding UTF8

$logPath = Join-Path $guestRoot 'Sandbox\Logs\InstallAssertions.log'
function Read-AssertLines { if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath } else { @() } }
function Clear-AssertLog  { if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force } }

$tattooKey = 'HKLM:\SOFTWARE\' + $fakeAuthor + '\' + $fakeVendor + '\' + $fakeDisplay

# ---- PostInstall, tattoo PRESENT + matching version -> PASS ----
Clear-AssertLog
$global:fakeReg = @{ $tattooKey = @{ Version = $fakeVersion } }
& $copyPath -Phase PostInstall
$lines = Read-AssertLines
if (Test-LogHas $lines 'ASSERT InstallDetected-PostInstall = PASS') { Ok 'PostInstall + matching tattoo -> InstallDetected-PostInstall = PASS' }
else { Bad "expected PASS; log:`n    $($lines -join "`n    ")" }
if (Test-LogHas $lines '=== Phase: PostInstall ===') { Ok 'phase marker written' } else { Bad 'no phase marker' }

# ---- PostInstall, tattoo ABSENT -> FAIL ----
Clear-AssertLog
$global:fakeReg = @{}
& $copyPath -Phase PostInstall
$lines = Read-AssertLines
if (Test-LogHas $lines 'ASSERT InstallDetected-PostInstall = FAIL*') { Ok 'PostInstall + absent tattoo -> InstallDetected-PostInstall = FAIL' }
else { Bad "expected FAIL; log:`n    $($lines -join "`n    ")" }

# ---- PostInstall, tattoo present but WRONG version -> FAIL ----
Clear-AssertLog
$global:fakeReg = @{ $tattooKey = @{ Version = '0.0.0.1' } }
& $copyPath -Phase PostInstall
$lines = Read-AssertLines
if (Test-LogHas $lines 'ASSERT InstallDetected-PostInstall = FAIL*') { Ok 'PostInstall + version mismatch -> FAIL' }
else { Bad "expected FAIL on version mismatch; log:`n    $($lines -join "`n    ")" }

# ---- PostUninstall, tattoo GONE -> PASS + RESULT COMPLETE ----
Clear-AssertLog
$global:fakeReg = @{}
& $copyPath -Phase PostUninstall
$lines = Read-AssertLines
if (Test-LogHas $lines 'ASSERT UninstallClean-PostUninstall = PASS') { Ok 'PostUninstall + key gone -> UninstallClean-PostUninstall = PASS' }
else { Bad "expected uninstall PASS; log:`n    $($lines -join "`n    ")" }
if (Test-LogHas $lines 'RESULT COMPLETE') { Ok "'RESULT COMPLETE' emitted at end of PostUninstall" } else { Bad "no 'RESULT COMPLETE' marker" }

# ---- PostUninstall, tattoo STILL PRESENT -> FAIL (leftover install) ----
Clear-AssertLog
$global:fakeReg = @{ $tattooKey = @{ Version = $fakeVersion } }
& $copyPath -Phase PostUninstall
$lines = Read-AssertLines
if (Test-LogHas $lines 'ASSERT UninstallClean-PostUninstall = FAIL*') { Ok 'PostUninstall + key still present -> FAIL' }
else { Bad "expected uninstall FAIL; log:`n    $($lines -join "`n    ")" }

# ---- SKIP path: no tattoo fields and no DisplayName -> SKIP ----
Write-Host '[4] no tattoo fields AND no DisplayName -> SKIP' -ForegroundColor Cyan
$proj2 = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $proj2 'SupportFiles') -Force | Out-Null
$cfg2 = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Vendor = ''; Name = ''; DisplayName = ''; Version = ''; ScriptAuthor = '' } }
[System.IO.File]::WriteAllText((Join-Path $proj2 'SupportFiles\AppConfig.json'), ($cfg2 | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$gen2 = New-InstallAssertionScript -ProjectPath $proj2
$guestRoot2 = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $guestRoot2 'SupportFiles') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $guestRoot2 'Sandbox\Logs') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $proj2 'SupportFiles\AppConfig.json') -Destination (Join-Path $guestRoot2 'SupportFiles\AppConfig.json') -Force
$copy2 = Join-Path $guestRoot2 'Sandbox\InstallAssertions.copy.ps1'
Set-Content -LiteralPath $copy2 -Value ((Get-Content -LiteralPath $gen2 -Raw).Replace('C:\PSADT', $guestRoot2)) -Encoding UTF8
& $copy2 -Phase PostInstall
$log2 = Join-Path $guestRoot2 'Sandbox\Logs\InstallAssertions.log'
$lines2 = if (Test-Path -LiteralPath $log2) { Get-Content -LiteralPath $log2 } else { @() }
if (Test-LogHas $lines2 'ASSERT InstallDetected-PostInstall = SKIP*') { Ok 'nothing checkable -> SKIP with a reason note' }
else { Bad "expected SKIP; log:`n    $($lines2 -join "`n    ")" }

# ══ 5. MSI: Windows Installer's own record (SWP-02) ═══════════════════════════════════════════════
Write-Host '[5] MSI project: ProductCode as DATA + MsiProductInstalled/MsiProductRemoved assertions' -ForegroundColor Cyan
$projM = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $projM 'SupportFiles'), (Join-Path $projM 'Files') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $projM 'Files\w.msi') -Value 'not a real msi'
Set-Content -LiteralPath (Join-Path $projM 'Files\other.msi') -Value 'not a real msi'
[System.IO.File]::WriteAllText((Join-Path $projM 'SupportFiles\AppConfig.json'), ($appConfig | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$script:msiReads = @()
$genM = New-InstallAssertionScript -ProjectPath $projM
$dataM = Join-Path $projM 'Sandbox\InstallAssertionData.json'
if (Test-Path -LiteralPath $dataM) { Ok 'Sandbox\InstallAssertionData.json written for an MSI project' } else { Bad 'no MSI data file' }
if ($script:msiReads -contains 'w.msi|ProductCode') { Ok 'ProductCode read from the configured installer (Installer.FileName = w.msi)' } else { Bad "reads: $($script:msiReads -join ',')" }
$dm = Get-Content -LiteralPath $dataM -Raw | ConvertFrom-Json
if ($dm.MsiProductCode -eq $script:msiCode) { Ok 'data = { MsiProductCode: <validated GUID> }' } else { Bad "data: $($dm | ConvertTo-Json -Compress)" }
$bm = [System.IO.File]::ReadAllBytes($dataM)
if (-not ($bm[0] -eq 0xEF -and $bm[1] -eq 0xBB)) { Ok 'data JSON is BOM-less' } else { Bad 'data JSON has a BOM' }
$genMText = Get-Content -LiteralPath $genM -Raw
if (-not $genMText.Contains($script:msiCode)) { Ok 'the ProductCode is NOT spliced into the script (read at runtime)' } else { Bad 'ProductCode spliced into the script' }
if ($genMText -ceq $genText) { Ok 'the generated script is identical for MSI and non-MSI projects (value-free)' } else { Bad 'script text depends on the project' }
foreach ($nm in 'MsiProductInstalled-PostInstall', 'MsiProductRemoved-PostUninstall') {
    if (([regex]::Matches($genMText, [regex]::Escape("ASSERT $nm ="))).Count -eq 2 -and ([regex]::Matches($genMText, 'ASSERT ' + [regex]::Escape($nm) + ' =')).Count -eq 2) { Ok "assertion name '$nm' is unique (PASS + FAIL branch only)" } else { Bad "name $nm" }
}

# The guest probes the MSI Uninstall key (either view) with Get-ItemProperty -LiteralPath - the in-memory
# registry shadow above answers it. SetFakeReg replaces that store (the same global the earlier sections use).
function SetFakeReg([hashtable]$Keys) { Set-Variable -Name fakeReg -Scope Global -Value $Keys }
$guestM = New-TempDir
New-Item -ItemType Directory -Path (Join-Path $guestM 'SupportFiles'), (Join-Path $guestM 'Sandbox\Logs') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projM 'SupportFiles\AppConfig.json') -Destination (Join-Path $guestM 'SupportFiles\AppConfig.json') -Force
Copy-Item -LiteralPath $dataM -Destination (Join-Path $guestM 'Sandbox\InstallAssertionData.json') -Force
$copyM = Join-Path $guestM 'Sandbox\InstallAssertions.copy.ps1'
Set-Content -LiteralPath $copyM -Value ($genMText.Replace('C:\PSADT', $guestM)) -Encoding UTF8
$logM = Join-Path $guestM 'Sandbox\Logs\InstallAssertions.log'
function Read-M { if (Test-Path -LiteralPath $logM) { Get-Content -LiteralPath $logM } else { @() } }
function Clear-M { if (Test-Path -LiteralPath $logM) { Remove-Item -LiteralPath $logM -Force } }
$k64 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $script:msiCode
$k32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\' + $script:msiCode

Clear-M; SetFakeReg @{ $tattooKey = @{ Version = $fakeVersion }; $k64 = @{ DisplayName = 'x' } }
& $copyM -Phase PostInstall
$lm = Read-M
if ((Test-LogHas $lm 'ASSERT MsiProductInstalled-PostInstall = PASS') -and (Test-LogHas $lm 'ASSERT InstallDetected-PostInstall = PASS')) { Ok 'PostInstall: ProductCode registered (64-bit view) -> MsiProductInstalled PASS (tattoo assert still runs)' } else { Bad "log:`n    $($lm -join "`n    ")" }
Clear-M; SetFakeReg @{ $tattooKey = @{ Version = $fakeVersion }; $k32 = @{ DisplayName = 'x' } }
& $copyM -Phase PostInstall
if (Test-LogHas (Read-M) 'ASSERT MsiProductInstalled-PostInstall = PASS') { Ok 'PostInstall: registered in the WOW6432Node view also counts' } else { Bad "log: $((Read-M) -join ' / ')" }
Clear-M; SetFakeReg @{ $tattooKey = @{ Version = $fakeVersion } }
& $copyM -Phase PostInstall
$lm = Read-M
if (Test-LogHas $lm 'ASSERT MsiProductInstalled-PostInstall = FAIL*') { Ok 'PostInstall: tattoo written but the MSI never registered -> FAIL (a false tattoo is caught)' } else { Bad "log:`n    $($lm -join "`n    ")" }
Clear-M; SetFakeReg @{}
& $copyM -Phase PostUninstall
$lm = Read-M
if ((Test-LogHas $lm 'ASSERT MsiProductRemoved-PostUninstall = PASS') -and (Test-LogHas $lm 'RESULT COMPLETE')) { Ok 'PostUninstall: ProductCode gone -> MsiProductRemoved PASS, RESULT COMPLETE still last' } else { Bad "log:`n    $($lm -join "`n    ")" }
if ($lm[-1] -like '*RESULT COMPLETE') { Ok 'RESULT COMPLETE stays the final line' } else { Bad "last line: $($lm[-1])" }
Clear-M; SetFakeReg @{ $k32 = @{ DisplayName = 'x' } }
& $copyM -Phase PostUninstall
if (Test-LogHas (Read-M) 'ASSERT MsiProductRemoved-PostUninstall = FAIL*') { Ok 'PostUninstall: still registered (either view) -> FAIL' } else { Bad "log: $((Read-M) -join ' / ')" }

# Tampered / non-GUID data in the guest -> the MSI assertion is skipped, never spliced into a path.
[System.IO.File]::WriteAllText((Join-Path $guestM 'Sandbox\InstallAssertionData.json'), '{"MsiProductCode":"x\\..\\..\\Run"}', (New-Object System.Text.UTF8Encoding($false)))
Clear-M; SetFakeReg @{ $tattooKey = @{ Version = $fakeVersion } }
& $copyM -Phase PostInstall
$lm = Read-M
if (-not (Test-LogHas $lm 'ASSERT MsiProductInstalled-PostInstall*') -and ($lm -match 'not a GUID')) { Ok 'non-GUID data in the guest -> MSI assertion skipped (no FAIL, no path built from it)' } else { Bad "log:`n    $($lm -join "`n    ")" }

# Host side: invalid ProductCode -> no data file; a non-MSI project removes a stale one.
$script:msiCode = 'not-a-guid'
$null = New-InstallAssertionScript -ProjectPath $projM
if (-not (Test-Path -LiteralPath $dataM)) { Ok 'an unreadable / invalid ProductCode writes no data file (no MSI assertion)' } else { Bad 'invalid ProductCode written' }
$script:msiCode = '{6F2C1A3B-4D5E-4F60-8A9B-0C1D2E3F4A5B}'
$null = New-InstallAssertionScript -ProjectPath $projM
$exeCfg = [ordered]@{}; foreach ($ck in $appConfig.Keys) { $exeCfg[$ck] = $appConfig[$ck] }; $exeCfg['Installer'] = [ordered]@{ Type = 'exe'; FileName = 'setup.exe'; SilentArgs = '/S' }
[System.IO.File]::WriteAllText((Join-Path $projM 'SupportFiles\AppConfig.json'), ($exeCfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$script:msiReads = @()
$null = New-InstallAssertionScript -ProjectPath $projM
if (-not (Test-Path -LiteralPath $dataM) -and $script:msiReads.Count -eq 0) { Ok 'non-MSI project: stale data file removed, no MSI read' } else { Bad "data present=$(Test-Path -LiteralPath $dataM) reads=$($script:msiReads -join ',')" }
$mCfg = [ordered]@{}; foreach ($ck in $appConfig.Keys) { $mCfg[$ck] = $appConfig[$ck] }; $mCfg['Installer'] = [ordered]@{ Type = 'msi'; FileName = 'missing.msi'; SilentArgs = '/qn' }
[System.IO.File]::WriteAllText((Join-Path $projM 'SupportFiles\AppConfig.json'), ($mCfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$script:msiReads = @()
$null = New-InstallAssertionScript -ProjectPath $projM
if ((Test-Path -LiteralPath $dataM) -and $script:msiReads.Count -eq 1 -and $script:msiReads[0] -like '*.msi|ProductCode') { Ok 'FileName not found -> falls back to the MSI in Files\' } else { Bad "reads=$($script:msiReads -join ',')" }

# cleanup
Remove-Item -LiteralPath $proj, $proj2, $guestRoot, $guestRoot2, $projM, $guestM -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All InstallAssertionScript tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail InstallAssertionScript test(s) FAILED." -ForegroundColor Red; exit 1 }
