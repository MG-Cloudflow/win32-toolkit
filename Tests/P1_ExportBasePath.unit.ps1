<#
    P1 — Export-Win32ToolkitIntuneWin silently ignored -BasePath whenever -ProjectPath was supplied.

    The old code ALWAYS derived the base by walking two parents up from the project path and fed that
    to Get-Win32ToolkitPaths. Consequences:
      * an explicit -BasePath was thrown away (a parameter the caller passed did nothing);
      * a project stored anywhere other than <Base>\Projects\<Template>\<App> caused Staging\ and
        IntuneWin\ to be created in a surprising directory, silently.

    How this test observes the decision WITHOUT running anything heavy: Get-Win32ToolkitPaths is the
    single choke point — Export calls it with the base it settled on, BEFORE the IntuneWinAppUtil
    download, the Staging copy, the optimizer and any publish. We shadow it to record that base and
    then throw a sentinel, which aborts the run before a single byte is downloaded, copied or executed.

    Run:  pwsh -File Tests\P1_ExportBasePath.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1')

# ── Shadows: nothing real may run ────────────────────────────────────────────────────────────────
$SENTINEL = 'W32TK_SENTINEL_STOP'
$script:seenBase = $null

# The choke point. Record the base Export decided on, then abort the run.
function Get-Win32ToolkitPaths { param([string]$BasePath) $script:seenBase = $BasePath; throw $SENTINEL }

# Belt and braces: if any of these were ever reached, the test would rather fail loudly than act.
function Assert-Win32ToolkitTrustedBinary { throw 'Assert-Win32ToolkitTrustedBinary must not be reached' }
function Optimize-Win32ToolkitProject     { throw 'Optimize-Win32ToolkitProject must not be reached' }
function Publish-Win32ToolkitIntuneApp    { throw 'Publish-Win32ToolkitIntuneApp must not be reached' }
function Start-Process                    { throw 'Start-Process must not be reached' }
function Invoke-WebRequest                { throw 'Invoke-WebRequest must not be reached' }
function Invoke-RestMethod                { throw 'Invoke-RestMethod must not be reached' }
function Get-Win32ToolkitBasePath         { throw 'Get-Win32ToolkitBasePath must not be reached (a ProjectPath is always supplied)' }
function Get-PSADTProjects                { throw 'Get-PSADTProjects must not be reached' }
function Show-ProjectSelection            { throw 'Show-ProjectSelection must not be reached' }

# ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32base_' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function New-Project([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'Invoke-AppDeployToolkit.ps1') '# PSADT v4 stub'
    $Path
}

# conforming:      <Base>\Projects\<Template>\<App>
$conformBase = Join-Path $tmp 'Base'
$conforming  = New-Project (Join-Path $conformBase 'Projects\CloudFlow\Git_x64_2.53.0')
# NON-conforming:  a project someone keeps on their desktop / in a repo checkout
$nonConform  = New-Project (Join-Path $tmp 'Loose\Git_x64_2.53.0')

# What Export must never invent on its own.
$explicitBase = Join-Path $tmp 'ExplicitBase'

# Runs Export and returns the base it chose (or $null) plus the error it raised (or $null).
function Invoke-Export {
    param([string]$ProjectPath, [string]$Base)

    $script:seenBase = $null
    $err = $null
    try {
        if ($PSBoundParameters.ContainsKey('Base')) {
            Export-Win32ToolkitIntuneWin -ProjectPath $ProjectPath -BasePath $Base -NoPublishPrompt 6>$null
        }
        else {
            Export-Win32ToolkitIntuneWin -ProjectPath $ProjectPath -NoPublishPrompt 6>$null
        }
    }
    catch { $err = $_.Exception.Message }

    [pscustomobject]@{ Base = $script:seenBase; Error = $err }
}

# ══ (a) An explicit -BasePath must be HONOURED ═══════════════════════════════════════════════════
Write-Host '[a] -BasePath is used verbatim when -ProjectPath is also supplied' -ForegroundColor Cyan

$r = Invoke-Export -ProjectPath $conforming -Base $explicitBase
if ($r.Base -eq $explicitBase) {
    Ok "explicit -BasePath honoured ($($r.Base))"
}
else {
    Bad "explicit -BasePath IGNORED — Export used '$($r.Base)' instead of '$explicitBase'"
}

# The nastiest form of the bug: a project that lives elsewhere, with the caller TELLING Export where
# the tiers are. The old code still walked two parents up and wrote outside the base it was handed.
$r = Invoke-Export -ProjectPath $nonConform -Base $explicitBase
if ($r.Base -eq $explicitBase) {
    Ok 'explicit -BasePath honoured even for a project outside the tier layout (no throw)'
}
else {
    Bad "explicit -BasePath not honoured for an out-of-tier project — used '$($r.Base)', error='$($r.Error)'"
}

# ══ (b) No -BasePath + conforming layout: derivation is unchanged (no regression) ════════════════
Write-Host '[b] No -BasePath, conforming layout -> the derived base is unchanged' -ForegroundColor Cyan

$r = Invoke-Export -ProjectPath $conforming
if ($r.Base -eq $conformBase) {
    Ok "derived <Base> from <Base>\Projects\<Template>\<App> ($($r.Base))"
}
else {
    Bad "derivation regressed — expected '$conformBase', got '$($r.Base)' (error='$($r.Error)')"
}

# Trailing separator / unnormalised input must not change the answer.
$r = Invoke-Export -ProjectPath ($conforming + '\')
if ($r.Base -eq $conformBase) { Ok 'a trailing separator on -ProjectPath derives the same base' }
else { Bad "trailing separator derived '$($r.Base)'" }

# ══ (c) No -BasePath + NON-conforming layout: fail loudly, do not guess ══════════════════════════
Write-Host '[c] No -BasePath, project outside Projects\<Template>\ -> clear error, no silent output' -ForegroundColor Cyan

$r = Invoke-Export -ProjectPath $nonConform
$surprise = Split-Path $tmp -Parent   # what the OLD code would have used: two parents up from the project

if ($null -ne $r.Base) {
    Bad "silently chose a base ('$($r.Base)') for a non-conforming project instead of failing"
}
elseif ($r.Error -match 'BasePath') {
    Ok "throws a clear error naming -BasePath (was: silently used '$surprise')"
}
else {
    Bad "did not fail with a BasePath error — error='$($r.Error)'"
}

if ($r.Error -match 'Projects') {
    Ok 'the error states the expected <BasePath>\Projects\<Template>\<ProjectName> layout'
}
else {
    Bad "the error does not explain the expected layout — error='$($r.Error)'"
}

# Nothing was created next to the loose project or at the surprise location.
$strayStaging = @(
    (Join-Path $tmp 'Staging'),
    (Join-Path $tmp 'IntuneWin'),
    (Join-Path (Join-Path $tmp 'Loose') 'Staging')
) | Where-Object { Test-Path -LiteralPath $_ }

if ($strayStaging.Count -eq 0) { Ok 'no Staging\ / IntuneWin\ folders were created in a surprising place' }
else { Bad "stray output folders created: $($strayStaging -join ', ')" }

# ══ Guard: the help must no longer claim the parameter is ignored ════════════════════════════════
Write-Host '[d] The parameter help no longer advertises the bug' -ForegroundColor Cyan
$src = Get-Content -LiteralPath (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1') -Raw
if ($src -notmatch 'Ignored when ProjectPath is supplied') { Ok 'help no longer says -BasePath is ignored' }
else { Bad 'help still documents -BasePath as ignored' }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_ExportBasePath tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_ExportBasePath test(s) FAILED." -ForegroundColor Red; exit 1 }
