<#
    Regression test for the settings -> main-menu crash (issue #67):
        "Cannot process argument transformation on parameter 'BasePath'. Cannot convert value to
         type System.String."

    CAUSE (corrected 2026-09-07): in PwshSpectreConsole 2.6.x the render commands do NOT write to the
    console — Write-AnsiConsole RETURNS the rendered ANSI text, and it only displays when the success
    stream reaches Out-Default. Crucially, Out-SpectreHost is a PASSTHROUGH (it re-renders its input
    and returns the string), NOT a consumer. The first mitigation piped renders to Out-SpectreHost and
    kept capturing the screen ($base = Show-Win32ToolkitSettings ...), so $base still became an array —
    and an earlier version of THIS test modeled Out-SpectreHost as consuming, so it passed while
    production crashed. Capturing (or Out-Null-ing) a TUI screen also blanks its rendering, which is
    why panels inside the '| Out-Null'-ed test-VM subtree were invisible.

    FIX / CONTRACT: TUI screens return NOTHING and render THROUGH their success stream; callers invoke
    them as bare statements and NEVER capture. The base folder travels via the registry: Settings /
    FirstRun persist it (Get-Win32ToolkitBasePath -Set), the caller re-reads (-NonInteractive) and
    adopts a change, keeping a session -BasePath override when the registry did not change.

    The Spectre shadows here are FAITHFUL to 2.6.3 (rules return strings, Out-SpectreHost passes
    through). Scenarios replicate the shipped caller pattern and also regex-pin the shipped source so
    the capturing call shape cannot come back.

    Run:  pwsh -File Tests\TuiReturnValue.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitWrappedText.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitHealth.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitSettings.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitFirstRun.ps1')

# ── FAITHFUL PwshSpectreConsole 2.6.3 shadows: renderers RETURN text, Out-SpectreHost passes through ─
function Write-SpectreRule      { param([Parameter(ValueFromRemainingArguments)]$a) '[rendered:rule]' }
function Format-SpectrePanel    { param([Parameter(ValueFromRemainingArguments)]$a) [pscustomobject]@{ Renderable = 'panel' } }
$script:tableRows = [System.Collections.Generic.List[object]]::new()   # rows handed to tables (asserted in [5])
function Format-SpectreTable    { param([Parameter(ValueFromPipeline)]$InputObject, [Parameter(ValueFromRemainingArguments)]$a) process { $script:tableRows.Add($InputObject) } end { [pscustomobject]@{ Renderable = 'table' } } }
function Out-SpectreHost        { param([Parameter(ValueFromPipeline)]$Data) process { "[rendered:$Data]" } }
function Write-SpectreHost      { param([Parameter(ValueFromRemainingArguments)]$a) }
function Get-SpectreEscapedText { param($Text) $Text }
function Read-SpectreText       { param($Message, $DefaultAnswer) $script:typedPath }
function Read-SpectreSelection  { param([Parameter(ValueFromRemainingArguments)]$a) [pscustomobject]@{ Key = $script:seq.Dequeue() } }

# Leaky subscreen, faithful: the test-VM screen's own rule flows out through Settings' stream.
function Show-Win32ToolkitTestVM { '[rendered:rule]' }

# Toolkit surface used while the screens render.
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Test-Win32ToolkitPrerequisites {
    param([Parameter(ValueFromRemainingArguments)]$a)
    # Rows with AND without the Warn property (older shadows/rows lack it; the health screen must cope).
    @([pscustomobject]@{ Name = 'PowerShell 7.4+'; Ok = $true; Detail = '7.6'; Fixable = $false; Purpose = 'core' }
      [pscustomobject]@{ Name = 'PSAppDeployToolkit (4.1.x and 4.2.x)'; Ok = $true; Detail = 'v4.2.0-rc2 (prerelease - testing only)'; Fixable = $true; Purpose = 'packaging'; Warn = $true }
      [pscustomobject]@{ Name = 'winget'; Ok = $false; Detail = 'not on PATH'; Fixable = $false; Purpose = 'packaging from winget'; Warn = $false }
      # A long Detail (S6-F3, the env-pin Reason) and the widest real labels.
      [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; Ok = $false; Detail = "PreferredPsadtVersion '4.3.0' (from `$env:W32T_PSADT_VERSION) is not installed or not supported (supported: 4.1.x and 4.2.x)."; Fixable = $false; Purpose = 'testing & documentation'; Warn = $false })
}

# Registry simulation with the real resolution order (-Set persists; -BasePath override wins; then
# the stored value; -NonInteractive returns $null when unset).
$script:regBase = $null
function Get-Win32ToolkitBasePath {
    param([string]$BasePath, [switch]$Reconfigure, [switch]$NonInteractive, [string]$Set)
    if ($Set)             { $script:regBase = $Set; return $Set }
    if ($BasePath)        { return $BasePath }
    if ($script:regBase)  { return $script:regBase }
    if ($NonInteractive)  { return $null }
    'C:\Win32Apps'
}
function NewSeq([string[]]$keys) { $script:seq = [System.Collections.Queue]::new([object[]]$keys) }

# The shipped caller pattern from Public\Show-Win32Toolkit.ps1 ('settings' branch), replicated
# verbatim (display suppressed — the point is what happens to $base, not where the text goes).
function Invoke-SettingsBranch([string]$base) {
    $before = Get-Win32ToolkitBasePath -NonInteractive
    Show-Win32ToolkitSettings -BasePath $base | Out-Null
    $after = Get-Win32ToolkitBasePath -NonInteractive
    if ($after -and $after -ne $before) { $base = $after }
    return $base
}
function Take-String { param([string]$BasePath) $BasePath }

# ══ [1] leaky renders (recheck + test-VM subtree) cannot corrupt $base; session override survives ══
Write-Host "`n[1] settings round-trip with leaky renders: `$base stays ONE clean string, override kept" -ForegroundColor Cyan
$script:regBase = 'C:\RegBase'; $script:typedPath = ''
NewSeq @('recheck', 'testvm', 'back')
$base = Invoke-SettingsBranch 'C:\SessionOverride'
if ($base -is [string] -and @($base).Count -eq 1) { Ok 'one clean [string]' } else { Bad "got $(@($base).Count) object(s): $(@($base) | ForEach-Object { $_.GetType().Name })" }
if ($base -eq 'C:\SessionOverride') { Ok 'unchanged registry keeps the session -BasePath override' } else { Bad "base became '$base'" }
$e = $null; try { $bound = Take-String -BasePath $base } catch { $e = $_.Exception.Message }
if (-not $e) { Ok "binds to [string] BasePath -> '$bound' (the exact call that crashed)" } else { Bad "still fails to bind: $e" }

# ══ [2] a base-folder change made in Settings IS adopted via the registry ══════════════════════════
Write-Host '[2] changing the base folder in Settings is adopted by the caller' -ForegroundColor Cyan
$script:regBase = 'C:\RegBase'; $script:typedPath = 'D:\NewBase'
NewSeq @('basepath', 'back')
$base = Invoke-SettingsBranch 'C:\SessionOverride'
if ($base -eq 'D:\NewBase') { Ok "adopted the changed path ('$base')" } else { Bad "base is '$base', expected 'D:\NewBase'" }
if ($script:regBase -eq 'D:\NewBase') { Ok 'change was persisted to the registry (the transport)' } else { Bad "registry holds '$script:regBase'" }

# ══ [3] the screens carry NO data in their stream (only render text) ═══════════════════════════════
Write-Host '[3] Settings/FirstRun emit render text only — the base path never travels in-stream' -ForegroundColor Cyan
$script:regBase = 'C:\RegBase'; $script:typedPath = ''
NewSeq @('recheck', 'testvm', 'back')
$emitted = @(Show-Win32ToolkitSettings -BasePath 'C:\SessionOverride')
if (-not ($emitted -contains 'C:\SessionOverride') -and -not ($emitted -contains 'C:\RegBase')) { Ok "settings stream holds no path data ($($emitted.Count) render item(s))" } else { Bad "path data leaked into the stream: $($emitted -join ' | ')" }

$script:regBase = $null; $script:typedPath = 'E:\Fresh'
$emittedFr = @(Show-Win32ToolkitFirstRun)
if (-not ($emittedFr -contains 'E:\Fresh')) { Ok 'first-run stream holds no path data' } else { Bad "first-run leaked the path: $($emittedFr -join ' | ')" }
if ($script:regBase -eq 'E:\Fresh') { Ok 'first-run persisted the folder to the registry' } else { Bad "registry holds '$script:regBase'" }
if ((Get-Win32ToolkitBasePath -NonInteractive) -eq 'E:\Fresh') { Ok 'caller re-read resolves the saved folder' } else { Bad 're-read did not resolve the folder' }

# ══ [4] the shipped caller can never capture a TUI screen again (source-pinned) ════════════════════
Write-Host '[4] Public\Show-Win32Toolkit.ps1 does not capture Settings/FirstRun and re-reads the registry' -ForegroundColor Cyan
$src = Get-Content -Raw (Join-Path $repo 'Public\Show-Win32Toolkit.ps1')
if ($src -notmatch '\$base\s*=\s*Show-Win32ToolkitSettings') { Ok 'no "$base = Show-Win32ToolkitSettings" capture' } else { Bad 'the settings capture is back' }
if ($src -notmatch '\$base\s*=\s*Show-Win32ToolkitFirstRun') { Ok 'no "$base = Show-Win32ToolkitFirstRun" capture' } else { Bad 'the first-run capture is back' }
if ([regex]::Matches($src, 'Get-Win32ToolkitBasePath\s+-NonInteractive').Count -ge 2) { Ok 'caller re-reads the registry after both screens' } else { Bad 'registry re-read missing from the caller' }
$settingsSrc = Get-Content -Raw (Join-Path $repo 'Private\Show-Win32ToolkitSettings.ps1')
if ($settingsSrc -notmatch 'Show-Win32ToolkitTestVM\s*\|\s*Out-Null') { Ok 'test-VM subtree is no longer Out-Null-ed (its panels render again)' } else { Bad 'test-VM subtree is still Out-Null-ed (invisible panels)' }

# ══ [5] health screen: a Warn row renders a yellow '!', rows without Warn render as before ═════════
Write-Host '[5] Show-Win32ToolkitHealth renders OK / ! (Warn) / X per row' -ForegroundColor Cyan
$script:tableRows.Clear()
$null = @(Show-Win32ToolkitHealth)
$state = @{}; foreach ($row in $script:tableRows) { $state[$row.Component] = $row.' ' }
if ($state['PowerShell 7.4+'] -eq '[green]OK[/]') { Ok 'Ok row without a Warn property -> [green]OK[/]' } else { Bad "row without Warn rendered '$($state['PowerShell 7.4+'])'" }
if ($state['PSAppDeployToolkit (4.1.x and 4.2.x)'] -eq '[yellow]![/]') { Ok 'Ok row with Warn -> [yellow]![/]' } else { Bad "Warn row rendered '$($state['PSAppDeployToolkit (4.1.x and 4.2.x)'])'" }
if ($state['winget'] -eq '[red]X[/]') { Ok 'failed row -> [red]X[/]' } else { Bad "failed row rendered '$($state['winget'])'" }
# The Detail is pre-wrapped to the width its column gets (S6-F3), so Spectre never wraps it a second time.
$bw = 0; try { $bw = [int]$Host.UI.RawUI.BufferSize.Width } catch { $bw = 0 }; if ($bw -le 0) { $bw = 120 }
$colW = [Math]::Min(50, [Math]::Max(24, $bw - 13 - 2 - 'PSAppDeployToolkit (4.1.x and 4.2.x)'.Length - 'testing & documentation'.Length))
$longRow = @($script:tableRows | Where-Object { $_.Component -eq 'Microsoft.Graph.Authentication' })[0]
$dLines = @("$($longRow.Detail)" -split "`r?`n")
if ($dLines.Count -gt 1 -and @($dLines | Where-Object { $_.Length -gt $colW }).Count -eq 0 -and @($dLines | Where-Object { $_.Trim() -eq 'not' }).Count -eq 0) { Ok "long Detail pre-wrapped to the column width ($colW for a $bw-wide host): $($dLines.Count) lines, none wider" }
else { Bad "Detail lines (column $colW): $(@($dLines | ForEach-Object { "[$($_.Length)] $_" }) -join ' | ')" }
Write-Host ''
if ($fail -eq 0) { Write-Host 'All TuiReturnValue tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TuiReturnValue test(s) FAILED." -ForegroundColor Red; exit 1 }
