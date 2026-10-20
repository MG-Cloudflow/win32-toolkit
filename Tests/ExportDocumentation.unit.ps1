<#
    Unit tests for Public\Export-Win32ToolkitDocumentation.ps1

    Builds a throwaway project with a realistic AppConfig.json, shadows the private readers
    (Get-Win32DetectionRules, Get-Win32ToolkitDependencies, Get-LatestInstallationCapture) and
    seeds Documentation\TestResults.json + Intune\Publications.json, then asserts the rendered
    Markdown one-pager. Nothing touches the network or the real module state.

    Run:  pwsh -File Tests\ExportDocumentation.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# ── Dot-source the function under test ────────────────────────────────────────────
. (Join-Path $repo 'Public\Export-Win32ToolkitDocumentation.ps1')
# Real readers — safe, read only files we create.
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitPublication.ps1')
# The real command-line source: the doc must print exactly what Publish sends to Intune.
. (Join-Path $repo 'Private\Get-Win32ToolkitIntuneCommandLine.ps1')

# ── A raw sandbox host path we must NEVER see echoed into the doc ──────────────────
$rawSandboxPath = 'C:\Users\WDAGUtilityAccount\AppData\Local\FakeApp\fake.exe'
$seededTenant   = '11111111-2222-3333-4444-555555555555'
$seededAppId    = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

# ── Shadows for the private readers the function calls ────────────────────────────
$script:deps = @()
function Get-Win32DetectionRules {
    param([string]$ProjectPath)
    @([ordered]@{
        '@odata.type'    = '#microsoft.graph.win32LobAppRegistryDetection'
        'keyPath'        = 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso IT\Vendorly\Widget Pro'
        'valueName'      = 'Version'
        'detectionType'  = 'version'
        'operator'       = 'equal'
        'detectionValue' = '3.2.1'
    })
}
function Get-Win32ToolkitDependencies {
    param([string]$ProjectPath)
    return @($script:deps)
}
$script:captureFile = $null
function Get-LatestInstallationCapture {
    param([string]$ProjectPath)
    if ($script:captureFile) { return (Get-Item -LiteralPath $script:captureFile) }
    return $null
}

# ── Build a temp project ──────────────────────────────────────────────────────────
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('w32doc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles')  -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $proj 'Documentation') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $proj 'Intune')        -Force | Out-Null

@{
    SchemaVersion = '1.0'
    App = @{
        Vendor         = 'Vendorly'
        Name           = 'WidgetPro'
        DisplayName    = 'Widget Pro'
        Version        = '3.2.1'
        Arch           = 'x64'
        ScriptAuthor   = 'Contoso IT'
        ScriptDate     = '2026-07-15'
        Description    = 'Widget Pro is the flagship widget management suite.'
        InformationUrl = 'https://example.com/widgetpro'
    }
    Installer = @{ Type = 'exe'; FileName = 'setup.exe'; SilentArgs = '/S' }
    Uninstall = @{ AppName = 'Widget Pro'; ProductCodes = @('{12345678-1111-2222-3333-444455556666}') }
    ProcessesToClose = @('widgetpro')
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $proj 'SupportFiles\AppConfig.json') -Encoding UTF8

# Capture JSON — includes the raw sandbox path in NewFiles, which must be summarised away.
$cap = Join-Path $proj 'Documentation\InstallationChanges_20260715.json'
@{
    InstallationInfo = @{ ProjectName = 'Widget Pro'; Timestamp = '2026-07-15T10:00:00Z' }
    NewFiles        = @(@{ Path = $rawSandboxPath; Size = 1024 }, @{ Path = 'C:\Program Files\Widget Pro\app.dll'; Size = 2048 })
    ModifiedFiles   = @()
    NewRegistryKeys = @(@{ Path = 'HKLM\SOFTWARE\Vendorly\Widget Pro' })
    NewServices     = @(@{ Name = 'WidgetSvc'; DisplayName = 'Widget Service' })
    NewPrograms     = @(@{ Name = 'WidgetPro'; DisplayName = 'Widget Pro'; DisplayVersion = '3.2.1'; Publisher = 'Vendorly' })
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cap -Encoding UTF8
$script:captureFile = $cap

# TestResults.json — one Passed + one Failed entry.
@(
    @{ Scenario = 'InstallUninstall'; Backend = 'Sandbox'; Mode = 'Unattended'; TimestampUtc = '2026-07-14T09:00:00Z'
       Verdict = 'Passed'; Assertions = @(@{ Name = 'Installed'; Result = 'PASS' }, @{ Name = 'Detected'; Result = 'PASS' }); Notes = '' }
    @{ Scenario = 'Update'; Backend = 'HyperV'; Mode = 'Interactive'; TimestampUtc = '2026-07-15T09:00:00Z'
       Verdict = 'Failed'; Assertions = @(@{ Name = 'Installed'; Result = 'PASS' }, @{ Name = 'VersionBumped'; Result = 'FAIL' }); Notes = 'version did not change' }
) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $proj 'Documentation\TestResults.json') -Encoding UTF8

# Publications.json — seeded tenant + app id (must stay hidden without the switch).
@(
    @{ TenantId = $seededTenant; AppId = $seededAppId; DisplayName = 'Widget Pro'; DisplayVersion = '3.2.1'; WingetId = 'Vendorly.WidgetPro'; PublishedUtc = '2026-07-15T11:00:00Z' }
) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $proj 'Intune\Publications.json') -Encoding UTF8

# ══ Test 1: default render (no Intune ids) ════════════════════════════════════════
Write-Host '[1] Default render — no dependencies, no Intune ids' -ForegroundColor Cyan
$script:deps = @()
$outPath = Export-Win32ToolkitDocumentation -ProjectPath $proj 3>$null
if ($outPath -eq (Join-Path $proj 'Documentation.md')) { Ok 'returns the default output path' } else { Bad "unexpected path: $outPath" }
if (Test-Path -LiteralPath $outPath) { Ok 'the .md file exists' } else { Bad 'no .md written' }

$md = Get-Content -LiteralPath $outPath -Raw

if ($md -match '# Widget Pro 3\.2\.1') { Ok 'title has DisplayName + Version' } else { Bad 'title missing' }

# Expected lines come from the SAME helper Publish uses (TST-06/DOC-06: the doc printed a command line
# Intune never ran once the launcher changed).
$cl = Get-Win32ToolkitIntuneCommandLine
$mdLines = @($md -split "\r?\n")
if ($mdLines -ccontains "  $($cl.Install)") { Ok "exact install command line present ($($cl.Install))" } else { Bad 'install command line missing/wrong' }
if ($mdLines -ccontains "  $($cl.Uninstall)") { Ok "exact uninstall command line present ($($cl.Uninstall))" } else { Bad 'uninstall command line missing/wrong' }
if ($md -notmatch 'powershell\.exe') { Ok 'no powershell.exe command line (the 32-bit IME launch, PKG-01)' } else { Bad 'powershell.exe still documented' }

# Interaction wording: true on PSADT 4.1 and 4.2 (no more "silently ... no user interaction required").
$runsLine = '- Runs **as SYSTEM** via `Invoke-AppDeployToolkit.exe` (64-bit PowerShell). Whether the signed-in user sees dialogs (close the app, defer, progress) depends on the organisation template and on whether the app is running at install time.'
if ($mdLines -ccontains $runsLine) { Ok 'interaction line: as SYSTEM via the launcher; dialogs depend on the template and running apps' } else { Bad 'interaction line missing/wrong' }
if ($md -notmatch 'silently, as SYSTEM' -and $md -notmatch 'no user interaction required') { Ok 'the "silent, no user interaction" claim is gone' } else { Bad 'still claims a silent install' }
$runsBytes = [System.Text.Encoding]::UTF8.GetBytes((@($mdLines | Where-Object { $_ -match 'Runs \*\*as SYSTEM' }) -join ''))
if (@($runsBytes | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'interaction line is ASCII' } else { Bad 'interaction line has non-ASCII characters' }

if ($md -match 'version marker in the registry \(HKLM\\SOFTWARE\\Contoso IT\\Vendorly\\Widget Pro\\Version = 3\.2\.1\)') {
    Ok 'plain-English registry-version detection sentence'
} else { Bad 'detection sentence missing/wrong' }

# Capture: COUNTS + ARP name, but NEVER the raw sandbox path.
if ($md -match 'Registers 2 files, 1 registry keys, 1 service') { Ok 'capture summarised to counts' } else { Bad 'capture counts missing' }
if ($md -match 'Add/Remove Programs as \*\*Widget Pro 3\.2\.1\*\*') { Ok 'ARP name + version present' } else { Bad 'ARP line missing' }
if ($md -notmatch 'WDAGUtilityAccount') { Ok 'no WDAGUtilityAccount sandbox account leaked' } else { Bad 'raw sandbox account leaked!' }
if ($md -notmatch [regex]::Escape($rawSandboxPath)) { Ok 'no raw sandbox file path leaked' } else { Bad 'raw sandbox path leaked!' }

# Testing table — both rows.
if ($md -match '\| Scenario \| Backend \| Date \| Result \|') { Ok 'Testing table header present' } else { Bad 'table header missing' }
if ($md -match '\| InstallUninstall \| Sandbox \|.*\| Passed \|') { Ok 'passed row present' } else { Bad 'passed row missing' }
if ($md -match '\| Update \| HyperV \|.*\| Failed \|') { Ok 'failed row present' } else { Bad 'failed row missing' }
if ($md -match 'VersionBumped \(FAIL\)') { Ok 'failed assertion is listed' } else { Bad 'failed assertion not listed' }

# Uninstall section mentions product codes.
if ($md -match '## Uninstall' -and $md -match 'product code') { Ok 'Uninstall section notes product codes' } else { Bad 'Uninstall section wrong' }

# NO Intune ids without the switch.
if ($md -notmatch [regex]::Escape($seededTenant)) { Ok 'seeded tenant id NOT present by default' } else { Bad 'tenant id leaked without switch!' }
if ($md -notmatch [regex]::Escape($seededAppId)) { Ok 'seeded app id NOT present by default' } else { Bad 'app id leaked without switch!' }

# ══ Test 2: with -IncludeIntuneIds ════════════════════════════════════════════════
Write-Host '[2] With -IncludeIntuneIds — the Intune section appears' -ForegroundColor Cyan
$out2 = Join-Path $proj 'Documentation_internal.md'
$null = Export-Win32ToolkitDocumentation -ProjectPath $proj -OutputPath $out2 -IncludeIntuneIds 3>$null
$md2 = Get-Content -LiteralPath $out2 -Raw
if ($md2 -match [regex]::Escape($seededAppId)) { Ok 'app id present WITH the switch' } else { Bad 'app id missing with switch' }
if ($md2 -match 'intune\.microsoft\.com') { Ok 'portal link present' } else { Bad 'portal link missing' }
if ($md2 -match [regex]::Escape("appId/$seededAppId")) { Ok 'portal link targets the app id' } else { Bad 'portal link malformed' }

# ══ Test 3: one-dependency case ═══════════════════════════════════════════════════
Write-Host '[3] Dependency rendering' -ForegroundColor Cyan
$script:deps = @([pscustomobject]@{ Source = 'winget'; Ref = 'Microsoft.VCRedist.2015+.x64'; DependencyType = 'autoInstall' })
$out3 = Join-Path $proj 'Documentation_dep.md'
$null = Export-Win32ToolkitDocumentation -ProjectPath $proj -OutputPath $out3 3>$null
$md3 = Get-Content -LiteralPath $out3 -Raw
if ($md3 -match 'winget:Microsoft\.VCRedist\.2015\+\.x64') { Ok 'dependency listed as Source:Ref' } else { Bad 'dependency not listed' }

# ══ Test 4: graceful degradation — empty project, no capture, no results ══════════
Write-Host '[4] Graceful degradation on a bare project' -ForegroundColor Cyan
$bare = Join-Path ([System.IO.Path]::GetTempPath()) ('w32doc_bare_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $bare -Force | Out-Null
$script:captureFile = $null
function Get-Win32DetectionRules { param([string]$ProjectPath) return @() }
$threw = $false
try { $outBare = Export-Win32ToolkitDocumentation -ProjectPath $bare 3>$null } catch { $threw = $true }
if (-not $threw) { Ok 'does not throw on a bare project' } else { Bad 'threw on a bare project' }
if (-not $threw) {
    $mdBare = Get-Content -LiteralPath $outBare -Raw
    if ($mdBare -match 'No automated tests recorded yet') { Ok 'no-tests fallback line' } else { Bad 'no-tests fallback missing' }
    if ($mdBare -match 'not captured' -or $mdBare -match 'were not captured') { Ok 'no-capture fallback line' } else { Bad 'no-capture fallback missing' }
    # No description -> the fallback Overview sentence must not claim a silent install either (DOC-06).
    if (@($mdBare -split "\r?\n") -ccontains 'Application packaged for deployment via Microsoft Intune.') { Ok 'no-description fallback is version-neutral' } else { Bad 'no-description fallback sentence missing/wrong' }
    if ($mdBare -notmatch '(?i)\bsilent') { Ok 'no "silent" wording anywhere in the fallback doc' } else { Bad 'the fallback doc still says silent' }
}
if ($md -notmatch '(?i)\bsilent') { Ok 'no "silent" wording anywhere in the default doc' } else { Bad 'the default doc still says silent' }

# ══ Manifest ══════════════════════════════════════════════════════════════════════
Write-Host '[5] Manifest export' -ForegroundColor Cyan
$psd1 = Get-Content -LiteralPath (Join-Path $repo 'win32-toolkit.psd1') -Raw
if ($psd1 -match "'Export-Win32ToolkitDocumentation'") { Ok 'Export-Win32ToolkitDocumentation is in FunctionsToExport' } else { Bad 'not exported in the manifest' }

# ══ Test 6: Update rows name their baseline technology (installer-identity PR 1, spec 2.13) ═══════
# A 'Both' run records one Update entry per technology (spec 2.11 Baseline); the customer doc must tell them
# apart and name the failing one. An Unavailable baseline is listed as such; a pre-PR-1 record keeps 'Update'.
Write-Host '[6] Update rows: baseline technology + version; Both legs told apart; unavailable baseline' -ForegroundColor Cyan
function Get-BaselineFixture([string]$Type, [string]$Family, [string]$Requested, [switch]$Unavailable) {
    [ordered]@{ Version = '8.8.9'; Mode = 'Both'; Origin = $(if ($Family -eq 'msi') { 'Packaged' } else { 'Sibling' }); RequestedInstallerType = $Requested; InstallerType = $Type
                Family = $Family; UsedFallback = $false; FallbackReason = ''; RequestedScope = 'machine'; Scope = 'machine'; ScopeRelaxed = $false
                Unavailable = [bool]$Unavailable; Locale = 'en-US'; Source = 'winget'; ProjectName = '' }
}
@(
    [ordered]@{ Scenario = 'Update'; Backend = 'HyperV'; Mode = 'Unattended'; TimestampUtc = '2026-10-20T09:00:00Z'; Verdict = 'Failed'
                Assertions = @(@{ Name = 'Tattoo-PostUpdate'; Result = 'PASS' }, @{ Name = 'OldArpGone-PostUpdate'; Result = 'FAIL' }); Notes = ''
                Baseline = (Get-BaselineFixture 'nullsoft' 'exe' 'nullsoft') }
    [ordered]@{ Scenario = 'Update'; Backend = 'HyperV'; Mode = 'Unattended'; TimestampUtc = '2026-10-20T09:30:00Z'; Verdict = 'Passed'
                Assertions = @(@{ Name = 'OldArpGone-PostUpdate'; Result = 'PASS' }); Notes = ''; Baseline = (Get-BaselineFixture 'wix' 'msi' 'wix') }
    [ordered]@{ Scenario = 'Update'; Backend = 'Sandbox'; Mode = 'Unattended'; TimestampUtc = '2026-10-20T10:00:00Z'; Verdict = 'Inconclusive'
                Assertions = @(); Notes = 'Baseline unavailable: winget offers no vendor EXE installer'; Baseline = (Get-BaselineFixture '' 'exe' 'nullsoft' -Unavailable) }
    [ordered]@{ Scenario = 'Update'; Backend = 'HyperV'; Mode = 'Interactive'; TimestampUtc = '2026-10-19T09:00:00Z'; Verdict = 'Failed'
                Assertions = @(@{ Name = 'VersionBumped'; Result = 'FAIL' }); Notes = '' }
) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $proj 'Documentation\TestResults.json') -Encoding UTF8
$out6 = Join-Path $proj 'Documentation_both.md'
$null = Export-Win32ToolkitDocumentation -ProjectPath $proj -OutputPath $out6 3>$null
$md6 = Get-Content -LiteralPath $out6 -Raw
$rows6 = @($md6 -split "\r?\n" | Where-Object { $_ -like '| Update*' })
if (@($rows6 | Where-Object { $_ -match '^\| Update \(baseline: nullsoft exe, v8\.8\.9\) \| HyperV \|.*\| Failed \|$' }).Count -eq 1) { Ok 'the nullsoft leg: | Update (baseline: nullsoft exe, v8.8.9) | HyperV | ... | Failed |' } else { Bad "nullsoft row missing: $($rows6 -join ' / ')" }
if (@($rows6 | Where-Object { $_ -match '^\| Update \(baseline: wix msi, v8\.8\.9\) \| HyperV \|.*\| Passed \|$' }).Count -eq 1) { Ok 'the wix leg: | Update (baseline: wix msi, v8.8.9) | HyperV | ... | Passed |' } else { Bad "wix row missing: $($rows6 -join ' / ')" }
if (@($rows6 | Where-Object { $_ -match '^\| Update \(baseline unavailable: nullsoft\) \| Sandbox \|.*\| Inconclusive \|$' }).Count -eq 1) { Ok 'an unavailable baseline: | Update (baseline unavailable: nullsoft) | ... | Inconclusive |' } else { Bad "unavailable row missing: $($rows6 -join ' / ')" }
if (@($rows6 | Where-Object { $_ -match '^\| Update \| HyperV \|.*\| Failed \|$' }).Count -eq 1) { Ok 'a record without Baseline keeps the plain | Update | row' } else { Bad "legacy row missing: $($rows6 -join ' / ')" }
$notes6 = @($md6 -split "\r?\n" | Where-Object { $_ -like '- **Update*' })
if ($notes6 -ccontains '- **Update (baseline: nullsoft exe, v8.8.9) / HyperV** - issues: OldArpGone-PostUpdate (FAIL)' -and @($notes6 | Where-Object { $_ -match 'wix msi' }).Count -eq 0 -and
    @($notes6 | Where-Object { $_ -match 'unavailable' }).Count -eq 0) {
    Ok 'the fail note names the nullsoft leg (not the passing wix leg, not the unavailable one)'
} else { Bad "fail notes: $($notes6 -join ' / ')" }
if (@(($rows6 + $notes6) -join '' | ForEach-Object { $_.ToCharArray() } | Where-Object { [int]$_ -gt 127 }).Count -eq 0) { Ok 'the Update rows and notes are ASCII' } else { Bad 'non-ASCII characters in the Update rows' }

# ── Cleanup ───────────────────────────────────────────────────────────────────────
Remove-Item -LiteralPath $proj, $bare -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All ExportDocumentation tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail ExportDocumentation test(s) FAILED." -ForegroundColor Red; exit 1 }
