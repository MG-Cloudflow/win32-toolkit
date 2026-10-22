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
      [5] MSI: MsiProductCode as DATA, MsiProductInstalled / MsiProductRemoved.
      [6] F13 (installer-identity PR 2 follow-ups spec 2.3): the app's own uninstall entries. Host: AppConfig
          Uninstall.PrimaryKeys -> InstallAssertionData.json UninstallKeys, validated (plain key name, view
          Registry64 / Registry32, case-sensitive; a null entry or "PrimaryKeys": null skipped without a
          'not checked' line), only for a deploy script with uninstall revision 2 (B2); value-free. Guest: 'App uninstall entry ... present=[..]' info lines, AppArpGone-PostUninstall
          PASS / FAIL / SKIP, invalid guest data not checked, a forged 'ASSERT x = PASS' key name masked.
          Static: Windows PowerShell 5.1 parses (and runs) the generated script; the three key-name regex
          literals are identical.

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
. (Join-Path $repo 'Private\Get-Win32ToolkitDeployScriptShape.ps1')   # New-InstallAssertionScript -> uninstall revision gate (C-9)
# The support policy does not matter for UninstallRevision (a text fact); the real helper needs the module's range.
function Test-Win32ToolkitPsadtVersionSupported { param($Version) $null = $Version; $false }
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

# ══ 6. F13: the app's own uninstall entries (AppArpGone-PostUninstall) ════════════════════════════
Write-Host '[6] F13: Uninstall.PrimaryKeys -> UninstallKeys (data, revision-2 gate) + AppArpGone-PostUninstall in the guest' -ForegroundColor Cyan
$script:msiCode = '{6F2C1A3B-4D5E-4F60-8A9B-0C1D2E3F4A5B}'
$k6Dirs = [System.Collections.Generic.List[string]]::new()
$uninstallBegin = '## win32-toolkit:Uninstall:uninstall (begin)'
$uninstallEnd   = '## win32-toolkit:Uninstall:uninstall (end)'
$deployTexts = @{
    rev2   = "$uninstallBegin`r`n## Uninstall revision 2 (win32-toolkit)`r`n$uninstallEnd`r`n"
    rev1   = "$uninstallBegin`r`n    Write-ADTLogEntry -Message 'uninstall'`r`n$uninstallEnd`r`n"
    legacy = "`$appConfig = Get-Content -LiteralPath 'AppConfig.json' -Raw | ConvertFrom-Json`r`n"
}
# A host project: the [1] App section, an exe or msi Installer, an Uninstall section with -PrimaryKeys (omitted
# with -NoPrimaryKeys; no Uninstall section with -NoUninstall) and a deploy script (rev2 / rev1 / legacy / none).
function Build-ArpProject {
    param([string]$Installer = 'exe', [object[]]$PrimaryKeys = @(), [switch]$NoPrimaryKeys, [switch]$NoUninstall, [string]$Script = 'rev2')
    $p = New-TempDir
    $k6Dirs.Add($p)
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles'), (Join-Path $p 'Files') -Force | Out-Null
    $c = [ordered]@{}; foreach ($ck in $appConfig.Keys) { $c[$ck] = $appConfig[$ck] }
    if ($Installer -eq 'msi') {
        $c['Installer'] = [ordered]@{ Type = 'msi'; FileName = 'w.msi'; SilentArgs = '/qn' }
        Set-Content -LiteralPath (Join-Path $p 'Files\w.msi') -Value 'not a real msi'
    }
    else { $c['Installer'] = [ordered]@{ Type = 'exe'; FileName = 'setup.exe'; SilentArgs = '/S' } }
    if (-not $NoUninstall) {
        $un = [ordered]@{ AppName = 'x'; ProductCodes = @(); Uninstallers = @(); CleanupPaths = @(); InstallRoots = @() }
        if (-not $NoPrimaryKeys) { $un['PrimaryKeys'] = @($PrimaryKeys) }
        $c['Uninstall'] = $un
    }
    [System.IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($c | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    if ($deployTexts.ContainsKey($Script)) {
        [System.IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), $deployTexts[$Script], (New-Object System.Text.UTF8Encoding($true)))
    }
    $p
}
# Generates for a host project: the data file (parsed, $null when absent), its raw bytes, the verbose lines, the script text.
function Invoke-ArpGen([string]$Project) {
    $verbose = @(New-InstallAssertionScript -ProjectPath $Project -Verbose 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
    $dataFile = Join-Path $Project 'Sandbox\InstallAssertionData.json'
    $has = Test-Path -LiteralPath $dataFile
    [pscustomobject]@{
        Data    = if ($has) { Get-Content -LiteralPath $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        Raw     = if ($has) { [System.IO.File]::ReadAllText($dataFile) } else { '' }
        Bytes   = if ($has) { [System.IO.File]::ReadAllBytes($dataFile) } else { [byte[]]@() }
        Verbose = $verbose
        Script  = Get-Content -LiteralPath (Join-Path $Project 'Sandbox\InstallAssertions.ps1') -Raw
    }
}
function Show-KeyList($Data) {
    if (-not $Data -or $Data.PSObject.Properties.Name -notcontains 'UninstallKeys') { return '<none>' }
    @(@($Data.UninstallKeys) | ForEach-Object { "$($_.Name)|$($_.View)" }) -join ';'
}
$twoKeys = @([ordered]@{ Name = 'Notepad++'; View = 'Registry64' }, [ordered]@{ Name = 'Acme Tool'; View = 'Registry32' })

# ---- host: EXE project, revision 2 ----
$projK = Build-ArpProject -PrimaryKeys $twoKeys
$rK = Invoke-ArpGen $projK
if ((Show-KeyList $rK.Data) -ceq 'Notepad++|Registry64;Acme Tool|Registry32' -and $rK.Data.PSObject.Properties.Name -notcontains 'MsiProductCode') { Ok 'EXE project, revision 2: data = { UninstallKeys: [Notepad++ Registry64, Acme Tool Registry32] }, no MsiProductCode' } else { Bad "EXE rev2: $(Show-KeyList $rK.Data) raw=$($rK.Raw)" }
if ($rK.Bytes.Length -gt 3 -and -not ($rK.Bytes[0] -eq 0xEF -and $rK.Bytes[1] -eq 0xBB)) { Ok 'the data JSON is BOM-less' } else { Bad 'data JSON has a BOM (or is missing)' }
if ($rK.Raw -match '"UninstallKeys":\s*\[') { Ok 'UninstallKeys is a JSON array' } else { Bad "raw: $($rK.Raw)" }
if ($rK.Script -ceq $genText) { Ok 'the generated script is identical to the [1] project''s (value-free)' } else { Bad 'the script text depends on the project' }
$one = Build-ArpProject -PrimaryKeys @([ordered]@{ Name = 'Notepad++'; View = 'Registry64' })
$rOne = Invoke-ArpGen $one
if ((Show-KeyList $rOne.Data) -ceq 'Notepad++|Registry64' -and $rOne.Raw -match '"UninstallKeys":\s*\[') { Ok 'a single key is still written as a JSON array' } else { Bad "single: $($rOne.Raw)" }

# ---- host: MSI project with both, revision 2 ----
$rM6 = Invoke-ArpGen (Build-ArpProject -Installer 'msi' -PrimaryKeys $twoKeys)
if ($rM6.Data.MsiProductCode -eq $script:msiCode -and (Show-KeyList $rM6.Data) -ceq 'Notepad++|Registry64;Acme Tool|Registry32') { Ok 'MSI project with PrimaryKeys (revision 2): both MsiProductCode and UninstallKeys' } else { Bad "MSI both: $($rM6.Raw)" }

# ---- host: invalid entries are dropped ----
$badEntries = @(
    [ordered]@{ Name = '..'; View = 'Registry64' }
    [ordered]@{ Name = 'a\b'; View = 'Registry64' }
    [ordered]@{ Name = 'x/y'; View = 'Registry64' }
    [ordered]@{ Name = "Acme`tTool"; View = 'Registry64' }
    [ordered]@{ Name = "Acme Tool`n"; View = 'Registry32' }
    [ordered]@{ Name = ('k' * 256); View = 'Registry64' }
    [ordered]@{ Name = 'Good'; View = 'HKCU' }
    [ordered]@{ Name = 'Notepad++'; View = 'registry64' }
)
$rBad = Invoke-ArpGen (Build-ArpProject -PrimaryKeys ($badEntries + @([ordered]@{ Name = ('k' * 255); View = 'Registry32' })))
$notChecked = @($rBad.Verbose | Where-Object { $_ -ceq 'Install assertion: an Uninstall.PrimaryKeys entry is not a plain key name in Registry64 or Registry32 - not checked.' })
if ((Show-KeyList $rBad.Data) -ceq "$('k' * 255)|Registry32" -and $notChecked.Count -eq 8) { Ok "'..', 'a\b', 'x/y', a TAB, a trailing line feed (B3), 256 chars, View 'HKCU', View 'registry64' (B10) -> dropped (8 verbose lines); 255 chars kept" } else { Bad "invalid: $(Show-KeyList $rBad.Data) verbose $($notChecked.Count): $($rBad.Verbose -join ' | ')" }
if (-not ($rBad.Verbose -join ' ').Contains('Notepad++') -and -not ($rBad.Verbose -join ' ').Contains('Good')) { Ok 'no key name is printed host-side' } else { Bad "a key name in the verbose text: $($rBad.Verbose -join ' | ')" }
$rOnlyBad = Invoke-ArpGen (Build-ArpProject -PrimaryKeys $badEntries)
if ($null -eq $rOnlyBad.Data) { Ok 'EXE project whose PrimaryKeys are all invalid -> no data file' } else { Bad "only invalid: $($rOnlyBad.Raw)" }

# ---- host: the revision gate (B2) ----
$predates = "Install assertion: the project's uninstall predates uninstall revision 2, so the app's own Add/Remove Programs entries are not checked (re-create the project to get the check)."
foreach ($case in @(
        @{ Script = 'rev1'; Label = 'a revision-1 block (begin/end without the revision marker)' }
        @{ Script = 'none'; Label = 'no deploy script' }
        @{ Script = 'legacy'; Label = 'a Legacy deploy script ($appConfig = without the loader block)' }
    )) {
    $r = Invoke-ArpGen (Build-ArpProject -PrimaryKeys $twoKeys -Script $case.Script)
    $lines = @($r.Verbose | Where-Object { $_ -ceq $predates })
    if ($null -eq $r.Data -and $lines.Count -eq 1) { Ok "EXE project, $($case.Label) -> no UninstallKeys, no data file, one 'predates uninstall revision 2' verbose line" } else { Bad "$($case.Label): data $($r.Raw) verbose $($r.Verbose -join ' | ')" }
}
$r = Invoke-ArpGen (Build-ArpProject -Installer 'msi' -PrimaryKeys $twoKeys -Script 'rev1')
if ($r.Data.MsiProductCode -eq $script:msiCode -and (Show-KeyList $r.Data) -ceq '<none>') { Ok 'MSI project, revision 1 -> MsiProductCode only' } else { Bad "MSI rev1: $($r.Raw)" }

# ---- host: no PrimaryKeys (a project captured before this version) -> today's behaviour ----
foreach ($case in @(@{ NoPrimaryKeys = $true; NoUninstall = $false; Label = 'an Uninstall section without PrimaryKeys' }, @{ NoPrimaryKeys = $true; NoUninstall = $true; Label = 'no Uninstall section' })) {
    $r = Invoke-ArpGen (Build-ArpProject -NoPrimaryKeys:$case.NoPrimaryKeys -NoUninstall:$case.NoUninstall)
    if ($null -eq $r.Data -and @($r.Verbose | Where-Object { $_ -ceq $predates }).Count -eq 0) { Ok "non-MSI project, $($case.Label) -> no data file (today), the deploy script is not read" } else { Bad "$($case.Label): $($r.Raw) verbose $($r.Verbose -join ' | ')" }
}
$r = Invoke-ArpGen (Build-ArpProject -PrimaryKeys @())
if ($null -eq $r.Data) { Ok 'PrimaryKeys [] -> no data file' } else { Bad "empty PrimaryKeys: $($r.Raw)" }

# ---- host: null entries (B10) are skipped without a 'not checked' line: a null next to a valid key, [null], "PrimaryKeys": null ----
$notCheckedLine = 'Install assertion: an Uninstall.PrimaryKeys entry is not a plain key name in Registry64 or Registry32 - not checked.'
$pNullMix = Build-ArpProject -PrimaryKeys @($null, [ordered]@{ Name = 'Notepad++'; View = 'Registry64' })
$cfgNullMix = [System.IO.File]::ReadAllText((Join-Path $pNullMix 'SupportFiles\AppConfig.json'))
$rNullMix = Invoke-ArpGen $pNullMix
$ncNullMix = @($rNullMix.Verbose | Where-Object { $_ -ceq $notCheckedLine })
if ($cfgNullMix -match '"PrimaryKeys":\s*\[\s*null\s*,' -and (Show-KeyList $rNullMix.Data) -ceq 'Notepad++|Registry64' -and $ncNullMix.Count -eq 0) { Ok "EXE project, revision 2, PrimaryKeys [null, Notepad++ Registry64] -> UninstallKeys = Notepad++ Registry64 only, no 'not checked' line" } else { Bad "null + valid: config $cfgNullMix data $(Show-KeyList $rNullMix.Data) verbose $($rNullMix.Verbose -join ' | ')" }
$pNullArray = Build-ArpProject -PrimaryKeys @($null)
$pNullProp  = Build-ArpProject
$cfgNullPropPath = Join-Path $pNullProp 'SupportFiles\AppConfig.json'
$cfgNullPropObj = Get-Content -LiteralPath $cfgNullPropPath -Raw | ConvertFrom-Json
$cfgNullPropObj.Uninstall.PrimaryKeys = $null
[System.IO.File]::WriteAllText($cfgNullPropPath, ($cfgNullPropObj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
foreach ($case in @(
        @{ Project = $pNullArray; Pattern = '"PrimaryKeys":\s*\[\s*null\s*\]'; Label = 'PrimaryKeys [null]' }
        @{ Project = $pNullProp;  Pattern = '"PrimaryKeys":\s*null'; Label = '"PrimaryKeys": null' }
    )) {
    $cfgText = [System.IO.File]::ReadAllText((Join-Path $case.Project 'SupportFiles\AppConfig.json'))
    $r = Invoke-ArpGen $case.Project
    $nc = @($r.Verbose | Where-Object { $_ -ceq $notCheckedLine })
    if ($cfgText -match $case.Pattern -and $null -eq $r.Data -and $nc.Count -eq 0) { Ok "EXE project, revision 2, $($case.Label) -> no data file, no 'not checked' line" } else { Bad "$($case.Label): config $cfgText data $($r.Raw) verbose $($r.Verbose -join ' | ')" }
}

# ---- host: value-free ----
$rCanary = Invoke-ArpGen (Build-ArpProject -PrimaryKeys @([ordered]@{ Name = 'W32T-SPLICE-CANARY'; View = 'Registry64' }))
if ($rCanary.Raw.Contains('W32T-SPLICE-CANARY') -and -not $rCanary.Script.Contains('W32T-SPLICE-CANARY') -and $rCanary.Script -ceq $genText) { Ok 'value-free: the key name is in the data file, not in InstallAssertions.ps1 (the script is unchanged)' } else { Bad 'the canary key name reached the script (or not the data)' }

# ---- guest ----
$u64 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'
$u32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\'
$guestK = New-TempDir
$k6Dirs.Add($guestK)
New-Item -ItemType Directory -Path (Join-Path $guestK 'SupportFiles'), (Join-Path $guestK 'Sandbox\Logs') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $proj 'SupportFiles\AppConfig.json') -Destination (Join-Path $guestK 'SupportFiles\AppConfig.json') -Force
$guestData = Join-Path $guestK 'Sandbox\InstallAssertionData.json'
# The guest data = what the host wrote for $projK above (written here as well, so the guest cases do not depend on it).
[System.IO.File]::WriteAllText($guestData, (ConvertTo-Json -InputObject ([ordered]@{ UninstallKeys = $twoKeys }) -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
$copyK = Join-Path $guestK 'Sandbox\InstallAssertions.copy.ps1'
Set-Content -LiteralPath $copyK -Value ($rK.Script.Replace('C:\PSADT', $guestK)) -Encoding UTF8
$logK = Join-Path $guestK 'Sandbox\Logs\InstallAssertions.log'
function Read-K { if (Test-Path -LiteralPath $logK) { @(Get-Content -LiteralPath $logK -Encoding UTF8) } else { @() } }
function Clear-K { if (Test-Path -LiteralPath $logK) { Remove-Item -LiteralPath $logK -Force } }
function Write-GuestData([string]$Json) { [System.IO.File]::WriteAllText($guestData, $Json, (New-Object System.Text.UTF8Encoding($false))) }
function Get-ArpLine([string[]]$Lines) { @($Lines | Where-Object { $_ -match 'AppArpGone' }) }
$tattooOnly = @{ $tattooKey = @{ Version = $fakeVersion } }

Clear-K; SetFakeReg @{ $tattooKey = @{ Version = $fakeVersion }; ($u64 + 'Notepad++') = @{ DisplayName = 'Notepad++' }; ($u32 + 'Acme Tool') = @{ DisplayName = 'Acme Tool' } }
& $copyK -Phase PostInstall
$lk = Read-K
if ((Test-LogHas $lk 'App uninstall entry [[]Registry64] Notepad++ present=[[]True]') -and (Test-LogHas $lk 'App uninstall entry [[]Registry32] Acme Tool present=[[]True]') -and (Get-ArpLine $lk).Count -eq 0 -and (Test-LogHas $lk 'ASSERT InstallDetected-PostInstall = PASS')) { Ok 'PostInstall, both keys present -> two "App uninstall entry ... present=[True]" lines, no AppArpGone line (Fd9)' } else { Bad "PostInstall:`n    $($lk -join "`n    ")" }
Clear-K; SetFakeReg $tattooOnly.Clone()
& $copyK -Phase PostInstall
$lk = Read-K
if ((Test-LogHas $lk 'App uninstall entry [[]Registry64] Notepad++ present=[[]False]') -and (Get-ArpLine $lk).Count -eq 0) { Ok 'PostInstall, a recorded key not there -> present=[False] (the evidence of a vacuous PASS), still no assertion' } else { Bad "PostInstall absent:`n    $($lk -join "`n    ")" }

Clear-K; SetFakeReg @{}
& $copyK -Phase PostUninstall
$lk = Read-K
if ((Test-LogHas $lk 'ASSERT AppArpGone-PostUninstall = PASS') -and (Test-LogHas $lk 'ASSERT UninstallClean-PostUninstall = PASS') -and $lk[-1] -like '*RESULT COMPLETE' -and (Test-LogHas $lk 'App uninstall entry [[]Registry32] Acme Tool present=[[]False]')) { Ok 'PostUninstall, both keys gone -> AppArpGone-PostUninstall = PASS; RESULT COMPLETE stays last' } else { Bad "PostUninstall gone:`n    $($lk -join "`n    ")" }

Clear-K; SetFakeReg @{ ($u32 + 'Acme Tool') = @{ DisplayName = 'Acme Tool' } }
& $copyK -Phase PostUninstall
$lk = Read-K
$arp = @(Get-ArpLine $lk)
if ($arp.Count -eq 1 -and $arp[0] -like "*ASSERT AppArpGone-PostUninstall = FAIL (the app's own uninstall entry is still present after uninstall: [[]Registry32] Acme Tool)" -and (Test-LogHas $lk 'ASSERT UninstallClean-PostUninstall = PASS')) { Ok 'PostUninstall, the Registry32 key left (tattoo gone: the H5-F1 blind spot) -> AppArpGone-PostUninstall = FAIL naming [Registry32] Acme Tool' } else { Bad "PostUninstall left:`n    $($lk -join "`n    ")" }

Clear-K; SetFakeReg @{ ($u64 + 'Acme Tool') = @{ DisplayName = 'x' }; ($u32 + 'Notepad++') = @{ DisplayName = 'x' } }
& $copyK -Phase PostUninstall
if (Test-LogHas (Read-K) 'ASSERT AppArpGone-PostUninstall = PASS') { Ok 'each view probes its own path: Registry32 -> WOW6432Node, Registry64 -> the native key (the other view''s same-named key does not count)' } else { Bad "views:`n    $((Read-K) -join "`n    ")" }

Clear-K; SetFakeReg @{ ($u64 + 'MozillaMaintenanceService') = @{ DisplayName = 'Mozilla Maintenance Service' }; ($u32 + 'AcmeUpdater') = @{ DisplayName = 'Acme Updater' } }
& $copyK -Phase PostUninstall
if (Test-LogHas (Read-K) 'ASSERT AppArpGone-PostUninstall = PASS') { Ok 'a co-installed key still present (not in the data) -> PASS (never asserted)' } else { Bad "co-installed:`n    $((Read-K) -join "`n    ")" }

# Tampered guest data: every entry is validated again; the valid one is still asserted.
Write-GuestData ('{"UninstallKeys":[{"Name":"..","View":"Registry64"},{"Name":"Acme Tool\n","View":"Registry32"},{"Name":"Notepad++","View":"registry64"},"just a string",{"View":"Registry64"},{"Name":"Notepad++","View":"Registry64"}]}')
Clear-K; SetFakeReg @{ ($u64 + 'Notepad++') = @{ DisplayName = 'x' }; ($u32 + "Acme Tool`n") = @{ DisplayName = 'x' }; ($u32 + 'Acme Tool') = @{ DisplayName = 'x' } }
& $copyK -Phase PostUninstall
$lk = Read-K
$nc = @($lk | Where-Object { $_ -like '*InstallAssertionData.json UninstallKeys has an entry that is not a plain key name in Registry64 or Registry32 - not checked' })
$arp = @(Get-ArpLine $lk)
if ($nc.Count -eq 5 -and $arp.Count -eq 1 -and $arp[0] -like "*= FAIL (the app's own uninstall entry is still present after uninstall: [[]Registry64] Notepad++)") { Ok "guest data with '..', a trailing line feed, View 'registry64', a string and no Name -> 5 'not checked' lines; the valid key is still asserted (FAIL: [Registry64] Notepad++ only)" } else { Bad "tampered ($($nc.Count) not checked):`n    $($lk -join "`n    ")" }
Write-GuestData '{"UninstallKeys":[{"Name":"..","View":"Registry64"}]}'
Clear-K; SetFakeReg @{}
& $copyK -Phase PostUninstall
$arp = @(Get-ArpLine (Read-K))
if ($arp.Count -eq 1 -and $arp[0] -like '*ASSERT AppArpGone-PostUninstall = SKIP (InstallAssertionData.json UninstallKeys holds no valid key)') { Ok 'only invalid entries -> AppArpGone-PostUninstall = SKIP (...)' } else { Bad "only invalid:`n    $((Read-K) -join "`n    ")" }
Remove-Item -LiteralPath $guestData -Force
Clear-K; SetFakeReg @{ ($u64 + 'Notepad++') = @{ DisplayName = 'x' } }
& $copyK -Phase PostUninstall
$lk = Read-K
if ((Get-ArpLine $lk).Count -eq 0 -and @($lk | Where-Object { $_ -match 'App uninstall entry' }).Count -eq 0 -and $lk[-1] -like '*RESULT COMPLETE') { Ok 'no data file (a project captured before this version) -> no AppArpGone line, today''s checks only' } else { Bad "no data:`n    $($lk -join "`n    ")" }
Write-GuestData '{"MsiProductCode":"{6F2C1A3B-4D5E-4F60-8A9B-0C1D2E3F4A5B}"}'
Clear-K; SetFakeReg @{}
& $copyK -Phase PostUninstall
$lk = Read-K
if ((Get-ArpLine $lk).Count -eq 0 -and (Test-LogHas $lk 'ASSERT MsiProductRemoved-PostUninstall = PASS')) { Ok 'MSI-only data (no UninstallKeys) -> no AppArpGone line; the MSI assertion unchanged' } else { Bad "msi only:`n    $($lk -join "`n    ")" }

# A key name that tries to forge an assertion line, and a non-ASCII one: '=' and non-ASCII print as '?'.
$rigged = 'x ASSERT Rigged = PASS'
$accent = "Acm$([char]0x00E9) Tool"
Write-GuestData (ConvertTo-Json -InputObject ([ordered]@{ UninstallKeys = @([ordered]@{ Name = $rigged; View = 'Registry64' }, [ordered]@{ Name = $accent; View = 'Registry32' }) }) -Depth 4)
Clear-K; SetFakeReg @{ $tattooKey = @{ Version = $fakeVersion }; ($u64 + $rigged) = @{ DisplayName = 'x' }; ($u32 + $accent) = @{ DisplayName = 'x' } }
& $copyK -Phase PostInstall
SetFakeReg @{ ($u64 + $rigged) = @{ DisplayName = 'x' }; ($u32 + $accent) = @{ DisplayName = 'x' } }
& $copyK -Phase PostUninstall
$lk = Read-K
$arp = @(Get-ArpLine $lk)
if ((Test-LogHas $lk 'App uninstall entry [[]Registry64] x ASSERT Rigged ? PASS present=[[]True]') -and (Test-LogHas $lk 'App uninstall entry [[]Registry32] Acm? Tool present=[[]True]') -and $arp.Count -eq 1 -and $arp[0] -like '*= FAIL (*: [[]Registry64] x ASSERT Rigged ? PASS; [[]Registry32] Acm? Tool)' -and -not @($lk | Where-Object { $_.Contains($rigged) -or $_.Contains($accent) }).Count) { Ok "'=' and non-ASCII characters in a key name print as '?' (the probe still uses the real name)" } else { Bad "masked:`n    $($lk -join "`n    ")" }
. (Join-Path $repo 'Private\Write-Win32ToolkitTestOutcome.ps1')
$script:recorded = $null
function Add-Win32ToolkitTestResult { param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $Assertions, $Notes) $null = $ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $Notes; $script:recorded = @($Assertions) }
Write-Win32ToolkitTestOutcome -ProjectPath $guestK -Scenario InstallUninstall -Backend Sandbox -Verdict $false -LogFileName 'InstallAssertions.log'
$names = @($script:recorded | ForEach-Object { "$($_.Name)=$($_.Result)" })
if ($names -contains 'AppArpGone-PostUninstall=FAIL' -and -not @($names | Where-Object { $_ -like 'Rigged*' }).Count) { Ok "Write-Win32ToolkitTestOutcome records AppArpGone-PostUninstall = FAIL and no forged 'Rigged' assertion" } else { Bad "recorded: $($names -join ', ')" }

# ---- static: one assertion name, the three key-name rule literals, the C-2 catch, Windows PowerShell 5.1 ----
foreach ($nm in 'AppArpGone-PostUninstall') {
    if (([regex]::Matches($genText, [regex]::Escape("ASSERT $nm ="))).Count -eq 3) { Ok "assertion name '$nm' occurs only in its SKIP / PASS / FAIL lines" } else { Bad "name $nm count" }
}
$ruleSpec = '^[^\\/:*?"<>|\p{Cc}\p{Cf}\p{Zl}\p{Zp}]{1,255}\z'
$updSrc = Get-Content -LiteralPath (Join-Path $repo 'Private\Update-PSADTUninstallLogic.ps1') -Raw
$iasSrc = Get-Content -LiteralPath (Join-Path $repo 'Private\New-InstallAssertionScript.ps1') -Raw
$lits = @(
    @([regex]::Matches($updSrc, "\`$uninstallKeyNameRule = '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    @([regex]::Matches($iasSrc, "\`$uninstallKeyNameRule = '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    @([regex]::Matches($genText, "\`$ukName -match '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
)
if ($lits.Count -eq 3 -and @($lits | Where-Object { $_ -cne $ruleSpec }).Count -eq 0) { Ok 'the key-name rule literal is identical in Update-PSADTUninstallLogic, New-InstallAssertionScript and the generated script (ends in \z)' } else { Bad "rule literals ($($lits.Count)): $($lits -join ' | ')" }
$iasAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private\New-InstallAssertionScript.ps1'), [ref]$null, [ref]$null)
$dataCatch = @($iasAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text.Contains('Install-assertion data skipped') }, $true))
if ($dataCatch.Count -eq 1 -and $dataCatch[0].Body.Statements[0].Extent.Text -ceq "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }") { Ok 'the data writer''s catch starts with the C-2 re-throw' } else { Bad "data catch: $($dataCatch.Count)" }
$ps51 = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51 -PathType Leaf)) { Write-Host '  SKIP: Windows PowerShell 5.1 (powershell.exe) not present' -ForegroundColor DarkYellow }
else {
    $parse51 = & $ps51 -NoProfile -NonInteractive -Command { param($p) $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); "PARSE=$(@($e).Count)" } -args $genPath
    if (($parse51 -join '') -ceq 'PARSE=0') { Ok 'Windows PowerShell 5.1 parses the generated script (0 errors)' } else { Bad "5.1 parse: $parse51" }
    # Run it under 5.1 against the REAL registry (read-only probes; the log goes to a temp guest root): a key that
    # cannot exist -> PASS; one that exists in this machine's 64-bit Uninstall view (when any does) -> FAIL.
    $g51 = New-TempDir
    $k6Dirs.Add($g51)
    New-Item -ItemType Directory -Path (Join-Path $g51 'SupportFiles'), (Join-Path $g51 'Sandbox\Logs') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $proj 'SupportFiles\AppConfig.json') -Destination (Join-Path $g51 'SupportFiles\AppConfig.json') -Force
    $real = @(Get-ChildItem -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.PSChildName } | Where-Object { $_ -cmatch $ruleSpec -and $_ -notmatch '[^\x20-\x7E]|=' } | Select-Object -First 1)
    $entries = @([ordered]@{ Name = 'W32T-NoSuchKey-' + [guid]::NewGuid().ToString('N'); View = 'Registry64' }, [ordered]@{ Name = "Acme Tool`n"; View = 'Registry32' })
    if ($real.Count) { $entries += [ordered]@{ Name = $real[0]; View = 'Registry64' } }
    [System.IO.File]::WriteAllText((Join-Path $g51 'Sandbox\InstallAssertionData.json'), (ConvertTo-Json -InputObject ([ordered]@{ UninstallKeys = $entries }) -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $copy51 = Join-Path $g51 'Sandbox\InstallAssertions.ps1'
    [System.IO.File]::WriteAllText($copy51, $genText.Replace('C:\PSADT', $g51), (New-Object System.Text.UTF8Encoding($true)))
    $null = & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copy51 -Phase PostUninstall
    $l51 = @(Get-Content -LiteralPath (Join-Path $g51 'Sandbox\Logs\InstallAssertions.log') -Encoding UTF8 -ErrorAction SilentlyContinue)
    $a51 = @(Get-ArpLine $l51)
    $nc51 = @($l51 | Where-Object { $_ -like '*UninstallKeys has an entry that is not a plain key name*' })
    $want51 = if ($real.Count) { "*ASSERT AppArpGone-PostUninstall = FAIL (*: [[]Registry64] $($real[0]))" } else { '*ASSERT AppArpGone-PostUninstall = PASS' }
    if ($a51.Count -eq 1 -and $a51[0] -like $want51 -and $nc51.Count -eq 1 -and $l51[-1] -like '*RESULT COMPLETE') { Ok "Windows PowerShell 5.1 runs it against the real registry: the trailing-LF entry not checked, a missing key gone$(if ($real.Count) { ', an existing 64-bit key -> FAIL' } else { ' -> PASS (no 64-bit Uninstall key to probe)' })" } else { Bad "5.1 run:`n    $($l51 -join "`n    ")" }
}

# cleanup
Remove-Item -LiteralPath $proj, $proj2, $guestRoot, $guestRoot2, $projM, $guestM -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in $k6Dirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All InstallAssertionScript tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail InstallAssertionScript test(s) FAILED." -ForegroundColor Red; exit 1 }
