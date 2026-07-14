<#
    P1 — unguarded [int] casts on Read-Host input crashed the run instead of re-prompting.

      Select-Architecture      did `if ([int]$selection -ge 1 ...)` on RAW Read-Host input. Typing 'x',
                               or just pressing Enter, threw an InvalidArgument cast exception straight
                               out of the do/while loop and killed the whole pipeline.

      Show-ScenarioSelection   guarded with `-match '^\d+$'` before the cast, so 'x' and '' were handled —
      Show-VersionSelection    but '99999999999999999999' IS all digits and still overflows Int32, so the
                               cast threw out of the loop just the same.

    All three now use [int]::TryParse + re-prompt (the pattern already used by Show-ProjectSelection).

    Read-Host is shadowed with a scripted QUEUE; if a function asks for more input than was scripted the
    shadow throws, so a broken loop surfaces as a failure instead of hanging the suite forever.

    Run:  pwsh -File Tests\P1_MenuInputGuards.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Select-Architecture.ps1')
. (Join-Path $repo 'Private\Show-ScenarioSelection.ps1')
. (Join-Path $repo 'Private\Show-VersionSelection.ps1')

# ── the scripted-input harness ───────────────────────────────────────────────────────────────────
$script:queue     = [System.Collections.Generic.Queue[string]]::new()
$script:readCount = 0

# Shadows the Read-Host cmdlet for every function dot-sourced above.
function Read-Host {
    param([string]$Prompt)
    if ($script:queue.Count -eq 0) {
        throw "Read-Host was called more times than scripted — the menu is looping without consuming input."
    }
    $script:readCount++
    return $script:queue.Dequeue()
}

function Set-Inputs {
    param([string[]]$Inputs)
    $script:queue.Clear()
    $script:readCount = 0
    foreach ($i in $Inputs) { $script:queue.Enqueue($i) }
}

# Runs a menu with the queued input and reports what happened, without ever throwing at the caller.
function Invoke-Menu {
    param([scriptblock]$Menu)

    $result = [ordered]@{ Threw = $false; Error = ''; Value = $null; Reads = 0; Rejections = 0; Leftover = 0 }
    try {
        # 6>&1 folds the menu's Write-Host output into the pipeline so we can see the re-prompt messages.
        $out  = @(& $Menu 6>&1)
        $msgs = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        $vals = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })

        $result.Value      = $vals | Select-Object -Last 1
        $result.Rejections = @($msgs | Where-Object { $_ -match 'Invalid selection|Please enter a number' }).Count
    }
    catch {
        $result.Threw = $true
        $result.Error = $_.Exception.Message
    }
    $result.Reads    = $script:readCount
    $result.Leftover = $script:queue.Count
    [pscustomobject]$result
}

# ══ Select-Architecture ══════════════════════════════════════════════════════════════════════════
# Architectures = @('x64') -> the menu always offers  1. x64  2. x86  3. arm64  4. All detected
Write-Host '[P1] Select-Architecture: garbage input must re-prompt, not crash the run' -ForegroundColor Cyan

# THE BUG: 'x' hit `[int]$selection` and threw InvalidArgument out of the do/while.
Set-Inputs 'x', '', '99', '2'
$r = Invoke-Menu { Select-Architecture -Architectures @('x64') -AppName 'Test' }
if (-not $r.Threw) { Ok "non-numeric 'x' does not throw (was: InvalidArgument cast exception)" }
else               { Bad "threw: $($r.Error)" }
if ($r.Reads -eq 4 -and $r.Leftover -eq 0) { Ok "consumed all 4 scripted inputs — 'x', '', '99' each re-prompted" }
else                                       { Bad "reads=$($r.Reads) leftover=$($r.Leftover) (expected 4 / 0)" }
if ($r.Rejections -eq 3) { Ok 'printed an invalid-choice message for each of the 3 bad inputs' }
else                     { Bad "rejection messages=$($r.Rejections) (expected 3)" }
if ($r.Value -eq 'x86')  { Ok "ultimately returned the value for '2' -> x86" }
else                     { Bad "returned '$($r.Value)' (expected x86)" }

# Out-of-range must be REJECTED, not indexed with. '0' and '5' are both outside 1..4.
Set-Inputs '0', '5', '1'
$r = Invoke-Menu { Select-Architecture -Architectures @('x64') -AppName 'Test' }
if (-not $r.Threw -and $r.Reads -eq 3 -and $r.Value -eq 'x64' -and $r.Rejections -eq 2) {
    Ok "out-of-range '0' and '5' re-prompt rather than being accepted -> '1' returns x64"
} else { Bad "threw=$($r.Threw) reads=$($r.Reads) value=$($r.Value) rejections=$($r.Rejections)" }

# A digit string that overflows Int32 is still not a valid choice — and must not throw.
Set-Inputs '99999999999999999999', '1'
$r = Invoke-Menu { Select-Architecture -Architectures @('x64') -AppName 'Test' }
if (-not $r.Threw -and $r.Value -eq 'x64') { Ok 'an Int32-overflowing number re-prompts instead of throwing' }
else                                       { Bad "threw=$($r.Threw) error=$($r.Error) value=$($r.Value)" }

# REGRESSION GUARD: every pre-existing valid choice still works, including the last entry ('All detected').
Write-Host '[P1] Select-Architecture: existing valid choices are preserved' -ForegroundColor Cyan
$expected = @{ '1' = 'x64'; '2' = 'x86'; '3' = 'arm64'; '4' = 'all' }
$allGood  = $true
foreach ($key in '1', '2', '3', '4') {
    Set-Inputs $key
    $r = Invoke-Menu { Select-Architecture -Architectures @('x64') -AppName 'Test' }
    if ($r.Threw -or $r.Value -ne $expected[$key] -or $r.Rejections -ne 0) {
        $allGood = $false
        Bad "choice '$key' returned '$($r.Value)' (expected '$($expected[$key])')"
    }
}
if ($allGood) { Ok "1/2/3 return x64/x86/arm64 and 4 still returns 'all' (escape hatch intact)" }

# The -Architecture parameter path must still short-circuit the menu entirely (no Read-Host at all).
Set-Inputs   # empty queue: any Read-Host call would throw
$r = Invoke-Menu { Select-Architecture -Architectures @('x64') -AppName 'Test' -PreSelected 'arm64' }
if (-not $r.Threw -and $r.Value -eq 'arm64' -and $r.Reads -eq 0) { Ok '-PreSelected still bypasses the prompt loop' }
else { Bad "threw=$($r.Threw) value=$($r.Value) reads=$($r.Reads)" }

# ══ Show-ScenarioSelection ═══════════════════════════════════════════════════════════════════════
# Menu:  1. InstallUninstall   2. Update
Write-Host '[P1] Show-ScenarioSelection: garbage input must re-prompt, not crash the run' -ForegroundColor Cyan

Set-Inputs 'x', '', '99', '2'
$r = Invoke-Menu { Show-ScenarioSelection }
if (-not $r.Threw -and $r.Reads -eq 4 -and $r.Leftover -eq 0 -and $r.Rejections -eq 3 -and $r.Value -eq 'Update') {
    Ok "'x', '' and out-of-range '99' each re-prompt; '2' returns Update"
} else { Bad "threw=$($r.Threw) reads=$($r.Reads) rejections=$($r.Rejections) value=$($r.Value)" }

# THE BUG here: '^\d+$' matched, then [int] overflowed Int32 and threw out of the loop.
Set-Inputs '99999999999999999999', '1'
$r = Invoke-Menu { Show-ScenarioSelection }
if (-not $r.Threw -and $r.Reads -eq 2 -and $r.Value -eq 'InstallUninstall') {
    Ok 'an all-digits number too large for Int32 re-prompts (was: overflow cast exception)'
} else { Bad "threw=$($r.Threw) error=$($r.Error) reads=$($r.Reads) value=$($r.Value)" }

Set-Inputs '1'
$r = Invoke-Menu { Show-ScenarioSelection }
if (-not $r.Threw -and $r.Value -eq 'InstallUninstall' -and $r.Rejections -eq 0) { Ok "valid choice '1' -> InstallUninstall (unchanged)" }
else { Bad "value=$($r.Value) rejections=$($r.Rejections)" }

# ══ Show-VersionSelection ════════════════════════════════════════════════════════════════════════
# Menu:  1. 3.0   2. 2.0   3. 1.0
Write-Host '[P1] Show-VersionSelection: garbage input must re-prompt, not crash the run' -ForegroundColor Cyan
$versions = @('3.0', '2.0', '1.0')

Set-Inputs 'x', '', '99', '2'
$r = Invoke-Menu { Show-VersionSelection -Versions $versions }
if (-not $r.Threw -and $r.Reads -eq 4 -and $r.Leftover -eq 0 -and $r.Rejections -eq 3 -and $r.Value -eq '2.0') {
    Ok "'x', '' and out-of-range '99' each re-prompt; '2' returns 2.0"
} else { Bad "threw=$($r.Threw) reads=$($r.Reads) rejections=$($r.Rejections) value=$($r.Value)" }

Set-Inputs '99999999999999999999', '3'
$r = Invoke-Menu { Show-VersionSelection -Versions $versions }
if (-not $r.Threw -and $r.Reads -eq 2 -and $r.Value -eq '1.0') {
    Ok 'an all-digits number too large for Int32 re-prompts (was: overflow cast exception)'
} else { Bad "threw=$($r.Threw) error=$($r.Error) reads=$($r.Reads) value=$($r.Value)" }

Set-Inputs '0', '1'
$r = Invoke-Menu { Show-VersionSelection -Versions $versions }
if (-not $r.Threw -and $r.Reads -eq 2 -and $r.Value -eq '3.0' -and $r.Rejections -eq 1) {
    Ok "out-of-range '0' re-prompts rather than indexing off the end -> '1' returns 3.0"
} else { Bad "threw=$($r.Threw) reads=$($r.Reads) value=$($r.Value) rejections=$($r.Rejections)" }

# ══ no raw casts left ════════════════════════════════════════════════════════════════════════════
Write-Host '[P1] no unguarded [int] cast of Read-Host input remains' -ForegroundColor Cyan
foreach ($f in 'Select-Architecture', 'Show-ScenarioSelection', 'Show-VersionSelection') {
    $src = Get-Content -LiteralPath (Join-Path $repo "Private\$f.ps1") -Raw
    if ($src -match '\[int\]::TryParse' -and $src -notmatch '\[int\]\$') { Ok "$f parses with [int]::TryParse" }
    else { Bad "$f still contains a raw [int] cast" }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_MenuInputGuards tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_MenuInputGuards test(s) FAILED." -ForegroundColor Red; exit 1 }
