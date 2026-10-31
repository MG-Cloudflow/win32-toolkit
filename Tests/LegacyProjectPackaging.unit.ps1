<#
    Legacy projects end to end (spec 3.6 task 7; critique C1-M1 / C2-B1; spec 2.11 consequence).

    Every project created by win32-toolkit 1.1.6 or older carries a deploy script patched by the old
    generator (Tests\Fixtures\legacy-1.1.6-*: Psadt41, GeneratorVersion 0, Support 'Legacy'). Such a project
    must stay packageable and publishable from the TUI, which cannot pass -AllowLegacyScript:

      * Show-Win32ToolkitProjectActions.ps1 finish   -> Complete-Win32ToolkitManualApp -ProjectPath <p>
      * Show-Win32ToolkitProjectActions.ps1 package  -> Export-Win32ToolkitIntuneWin -ProjectPath <p> -NoPublishPrompt
      * Show-Win32ToolkitProjectActions.ps1 publish  -> Export-Win32ToolkitIntuneWin -ProjectPath <p> -PublishIntune
                                                       (and -PublishUpdate, and both)

    Real code under test: every Private\*.ps1 is dot-sourced (the real shape detector, the real
    Assert-Win32ToolkitPackageReady, the real Get-Win32ToolkitProjectPsadtVersion) plus the two public
    commands. Only the first helper AFTER each gate is shadowed, to throw an ErrorRecord with
    FullyQualifiedErrorId W32T.TestSentinel (C-2 lets W32T.* through): Get-Win32ToolkitPaths for Export and
    Get-Win32ToolkitTestBackend for Invoke-Win32ToolkitFinalize. Reaching the sentinel proves the gate passed.

    Expected per legacy fixture and call: the sentinel is reached without -AllowLegacyScript, exactly one
    warning contains "older win32-toolkit", no W32T.PackageNotReady; Get-Win32ToolkitProjectPsadtVersion ->
    IsSupported, IsLegacy. Negative: the pristine PSADT 4.2 default golden in the same layout ->
    W32T.PackageNotReady with an 'Unsupported PSADT template shape: ' line and a "no AppConfig loader" line;
    with -AllowLegacyScript the sentinel is reached.

    No PSADT needed; nothing is packaged, uploaded or executed.
    Run:  pwsh -File Tests\LegacyProjectPackaging.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows and fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# C-5: unit suites that dot-source Private files and touch the range set it explicitly.
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
Get-ChildItem -LiteralPath (Join-Path $repo 'Private') -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1')
. (Join-Path $repo 'Public\Complete-Win32ToolkitManualApp.ps1')

# -- shadows: only the first helper after each gate (plus safety nets) --------------------------------
function New-SentinelError([string]$Where) {
    [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("TEST SENTINEL: the gate passed ($Where)"),
        'W32T.TestSentinel', [System.Management.Automation.ErrorCategory]::OperationStopped, $Where)
}
function Get-Win32ToolkitPaths { param([string]$BasePath) throw (New-SentinelError 'Export') }
function Get-Win32ToolkitTestBackend { throw (New-SentinelError 'Finalize') }
# Never reached when the gate works; they make a regression fail loudly instead of touching the machine.
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure) throw 'TEST-BLOCKED: real BasePath resolution' }
function New-TargetedDocumentation { throw 'TEST-BLOCKED: New-TargetedDocumentation (the Finalize gate should have stopped first)' }
function Publish-Win32ToolkitIntuneApp { throw 'TEST-BLOCKED: Publish-Win32ToolkitIntuneApp' }

$ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-lg-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
$projectsDir = Join-Path $ROOT 'Projects\Contoso'
New-Item -ItemType Directory -Path $projectsDir -Force | Out-Null

function New-FakeProject {
    param([string]$Name, [string]$Fixture, [string]$ModuleVersion, [string]$Prerelease = '')
    $p = Join-Path $projectsDir $Name
    foreach ($d in 'Files', 'SupportFiles', 'PSAppDeployToolkit') { New-Item -ItemType Directory -Path (Join-Path $p $d) -Force | Out-Null }
    # The fixture bytes as they are (BOM, CRLF / mixed line endings): exactly what an old project holds on disk.
    Copy-Item -LiteralPath $Fixture -Destination (Join-Path $p 'Invoke-AppDeployToolkit.ps1') -Force
    [System.IO.File]::WriteAllBytes((Join-Path $p 'Invoke-AppDeployToolkit.exe'), [byte[]]@())
    $pre = if ($Prerelease) { "`r`n    PrivateData = @{ PSData = @{ Prerelease = '$Prerelease' } }" } else { '' }
    Set-Content -LiteralPath (Join-Path $p 'PSAppDeployToolkit\PSAppDeployToolkit.psd1') -Encoding UTF8 -Value "@{`r`n    ModuleVersion = '$ModuleVersion'$pre`r`n}"
    $cfg = [pscustomobject]@{
        App       = [pscustomobject]@{ Vendor = 'Contoso'; Name = $Name; DisplayName = $Name; Version = '1.0.0'; Arch = 'x64'; ScriptAuthor = 'Contoso IT'; ScriptDate = '2026-01-01' }
        Installer = [pscustomobject]@{ Type = 'exe'; FileName = 'setup.exe'; SilentArgs = '/S' }
        ProcessesToClose = @()
    }
    [System.IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -LiteralPath (Join-Path $p 'Files\setup.exe') -Value 'MZ' -Encoding ASCII
    $p
}

# Runs one TUI call shape; returns @{ Error; Warnings[] } (warnings collected from stream 3 as they stream).
function Invoke-TuiCall {
    param([scriptblock]$Call)
    $warnings = [System.Collections.Generic.List[string]]::new()
    $err = $null
    try {
        & $Call 3>&1 6>$null | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings.Add($_.Message) } }
    }
    catch { $err = $_ }
    [pscustomobject]@{ Error = $err; Warnings = @($warnings) }
}

try {
    $fixtures = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Tests\Fixtures') -Directory -Filter 'legacy-1.1.6-*' | Sort-Object Name)
    if ($fixtures.Count -ne 3) { Bad "expected 3 legacy-1.1.6-* fixtures, found $($fixtures.Count)" }

    foreach ($fx in $fixtures) {
        $name = 'Legacy_' + ($fx.Name -replace '^legacy-1\.1\.6-', '') + '_x64_1.0.0'
        Write-Host "[$($fx.Name)] fake project $name (bundled PSAppDeployToolkit 4.1.8)" -ForegroundColor Cyan
        $proj = New-FakeProject -Name $name -Fixture (Join-Path $fx.FullName 'Invoke-AppDeployToolkit.ps1') -ModuleVersion '4.1.8'
        $scriptBefore = [System.IO.File]::ReadAllBytes((Join-Path $proj 'Invoke-AppDeployToolkit.ps1'))

        $pv = Get-Win32ToolkitProjectPsadtVersion -ProjectPath $proj
        if ($pv.IsSupported -and $pv.IsLegacy -and $pv.Shape -eq 'Psadt41' -and $pv.Support -eq 'Legacy' -and $pv.VersionText -eq '4.1.8') {
            Ok 'Get-Win32ToolkitProjectPsadtVersion: Psadt41, 4.1.8, IsSupported, IsLegacy'
        } else { Bad "project version: $($pv | ConvertTo-Json -Compress)" }
        if ($pv.Warning -match 'older win32-toolkit') { Ok 'project version carries the legacy warning text' } else { Bad "project version warning: [$($pv.Warning)]" }

        $calls = [ordered]@{
            'Export -NoPublishPrompt (TUI package)'                 = @{ Sentinel = 'Export'; Call = { Export-Win32ToolkitIntuneWin -ProjectPath $proj -NoPublishPrompt } }
            'Export -PublishIntune (TUI publish install)'           = @{ Sentinel = 'Export'; Call = { Export-Win32ToolkitIntuneWin -ProjectPath $proj -PublishIntune } }
            'Export -PublishUpdate (TUI publish update)'            = @{ Sentinel = 'Export'; Call = { Export-Win32ToolkitIntuneWin -ProjectPath $proj -PublishUpdate } }
            'Export -PublishIntune -PublishUpdate (TUI publish both)' = @{ Sentinel = 'Export'; Call = { Export-Win32ToolkitIntuneWin -ProjectPath $proj -PublishIntune -PublishUpdate } }
            'Complete-Win32ToolkitManualApp (TUI finish)'           = @{ Sentinel = 'Finalize'; Call = { Complete-Win32ToolkitManualApp -ProjectPath $proj } }
        }
        foreach ($label in $calls.Keys) {
            $r = Invoke-TuiCall -Call $calls[$label].Call
            $fq = if ($r.Error) { [string]$r.Error.FullyQualifiedErrorId } else { '' }
            if ($fq -like 'W32T.TestSentinel*' -and $r.Error.Exception.Message -match [regex]::Escape("($($calls[$label].Sentinel))")) {
                Ok "${label}: gate passed WITHOUT -AllowLegacyScript (sentinel reached)"
            }
            elseif ($fq -like 'W32T.PackageNotReady*') { Bad "${label}: W32T.PackageNotReady: $($r.Error.Exception.Message)" }
            else { Bad "${label}: sentinel not reached ($(if ($r.Error) { "$fq - $($r.Error.Exception.Message)" } else { 'no error' }))" }
            $legacyW = @($r.Warnings | Where-Object { $_ -match 'older win32-toolkit' })
            if ($legacyW.Count -eq 1) { Ok "${label}: exactly one 'older win32-toolkit' warning" }
            else { Bad "${label}: $($legacyW.Count) legacy warnings [$($r.Warnings -join ' | ')]" }
        }
        if ((Compare-Object $scriptBefore ([System.IO.File]::ReadAllBytes((Join-Path $proj 'Invoke-AppDeployToolkit.ps1'))) -SyncWindow 0).Count -eq 0) {
            Ok 'the legacy deploy script is untouched (packaged as-is)'
        } else { Bad 'the legacy deploy script was modified' }
    }

    Write-Host '[negative] pristine PSADT 4.2 default template (no loader, Psadt42Default) in the same layout' -ForegroundColor Cyan
    $neg = New-FakeProject -Name 'Pristine420_x64_1.0.0' -Fixture (Join-Path $repo 'Tests\Fixtures\psadt-4.2.0\Invoke-AppDeployToolkit.ps1') -ModuleVersion '4.2.0' -Prerelease 'rc2'
    $negCalls = [ordered]@{
        'Export -NoPublishPrompt' = @{ Plain = { Export-Win32ToolkitIntuneWin -ProjectPath $neg -NoPublishPrompt }; Allow = { Export-Win32ToolkitIntuneWin -ProjectPath $neg -NoPublishPrompt -AllowLegacyScript }; Sentinel = 'Export' }
        'Export -PublishIntune'   = @{ Plain = { Export-Win32ToolkitIntuneWin -ProjectPath $neg -PublishIntune }; Allow = { Export-Win32ToolkitIntuneWin -ProjectPath $neg -PublishIntune -AllowLegacyScript }; Sentinel = 'Export' }
        'Complete-Win32ToolkitManualApp' = @{ Plain = { Complete-Win32ToolkitManualApp -ProjectPath $neg }; Allow = { Complete-Win32ToolkitManualApp -ProjectPath $neg -AllowLegacyScript }; Sentinel = 'Finalize' }
    }
    foreach ($label in $negCalls.Keys) {
        $r = Invoke-TuiCall -Call $negCalls[$label].Plain
        $fq = if ($r.Error) { [string]$r.Error.FullyQualifiedErrorId } else { '' }
        $lines = if ($r.Error) { @($r.Error.Exception.Message -split '\r?\n') } else { @() }
        if ($fq -like 'W32T.PackageNotReady*') { Ok "${label}: W32T.PackageNotReady (the gate stops it)" }
        else { Bad "${label}: expected W32T.PackageNotReady, got [$fq] $(if ($r.Error) { $r.Error.Exception.Message })" }
        if (@($lines | Where-Object { $_.StartsWith('Unsupported PSADT template shape: ') }).Count -ge 1) { Ok "${label}: a line starts with 'Unsupported PSADT template shape: '" }
        else { Bad "${label}: no 'Unsupported PSADT template shape: ' line" }
        if (@($lines | Where-Object { $_ -match 'no AppConfig loader' }).Count -ge 1) { Ok "${label}: a line names the missing AppConfig loader" }
        else { Bad "${label}: no 'no AppConfig loader' line" }

        $ra = Invoke-TuiCall -Call $negCalls[$label].Allow
        $fqa = if ($ra.Error) { [string]$ra.Error.FullyQualifiedErrorId } else { '' }
        if ($fqa -like 'W32T.TestSentinel*' -and $ra.Error.Exception.Message -match [regex]::Escape("($($negCalls[$label].Sentinel))")) { Ok "${label} -AllowLegacyScript: gate downgraded to warnings (sentinel reached)" }
        else { Bad "${label} -AllowLegacyScript: sentinel not reached ([$fqa] $(if ($ra.Error) { $ra.Error.Exception.Message }))" }
    }
}
catch {
    Bad "unexpected error: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
}
finally {
    Remove-Item -LiteralPath $ROOT -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All LegacyProjectPackaging tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail check(s) FAILED" -ForegroundColor Red
exit 1
