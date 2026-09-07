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
function Format-SpectreTable    { param([Parameter(ValueFromPipeline)]$InputObject, [Parameter(ValueFromRemainingArguments)]$a) end { [pscustomobject]@{ Renderable = 'table' } } }
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
    @([pscustomobject]@{ Name = 'PowerShell 7.2+'; Ok = $true; Detail = '7.6'; Fixable = $false; Purpose = 'core' })
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

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TuiReturnValue tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TuiReturnValue test(s) FAILED." -ForegroundColor Red; exit 1 }
