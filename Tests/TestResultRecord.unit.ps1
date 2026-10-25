<#
    Unit tests for the shared TestResults.json contract:
      Add-Win32ToolkitTestResult  — appends one outcome entry (JSON ARRAY, BOM-less UTF-8, newest-last).
      Get-Win32ToolkitTestResult  — reads it back (@() when absent/empty/corrupt).

    Nothing hits the network or the real filesystem outside a fresh temp project.

    Run:  pwsh -File Tests\TestResultRecord.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Add-Win32ToolkitTestResult.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTestResult.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')   # -Baseline / -OldArpSurvivors strings (installer-identity PR 1)

function New-Proj {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32tr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $p
}

$made = @()

# ── One entry: must still serialise as a JSON ARRAY, and be BOM-less ──────────────────────────────
Write-Host '[1] A single entry serialises as a JSON ARRAY (not a bare object)' -ForegroundColor Cyan
$proj = New-Proj; $made += $proj
$resultsPath = Join-Path $proj 'Documentation\TestResults.json'

$e1 = Add-Win32ToolkitTestResult -ProjectPath $proj -Scenario 'InstallUninstall' -Backend 'Sandbox' `
        -Verdict 'Passed' -Mode 'Unattended' `
        -Assertions @(@{ Name = 'Installed'; Result = 'PASS' }, @{ Name = 'TattooWritten'; Result = 'PASS' }) `
        -Notes 'first run' 3>$null

if (Test-Path -LiteralPath $resultsPath) { Ok 'TestResults.json created' } else { Bad 'file not created' }

# Documentation folder was auto-created
if (Test-Path -LiteralPath (Join-Path $proj 'Documentation')) { Ok 'Documentation folder auto-created' } else { Bad 'no Documentation folder' }

# BOM-less: first three bytes must NOT be EF BB BF
$bytes = [System.IO.File]::ReadAllBytes($resultsPath)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Bad 'file has a UTF-8 BOM (should be BOM-less)'
} else { Ok 'file is BOM-less (no EF BB BF prefix)' }

# Raw text starts with '[' -> array
$raw = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8
if ($raw.TrimStart().StartsWith('[')) { Ok 'raw JSON starts with [ (array form)' } else { Bad "raw JSON is not an array: $($raw.Substring(0,[Math]::Min(20,$raw.Length)))" }

# On-disk array even with ONE entry (PowerShell unwraps a 1-element array on ConvertFrom-Json,
# so the durable check is the raw JSON text above; here we confirm exactly one entry parses out).
$parsed = $raw | ConvertFrom-Json
if (@($parsed).Count -eq 1) {
    Ok 'one-entry file parses back to exactly one entry'
} else { Bad "expected 1 entry, got $(@($parsed).Count)" }

# TimestampUtc is stored ISO-8601 (checked on the returned entry / raw text — ConvertFrom-Json
# would coerce it to a [datetime] and lose the original string form).
$ts = $e1.TimestampUtc
$dt = [datetime]::MinValue
if ($ts -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' -and [datetime]::TryParse($ts, [ref]$dt)) {
    Ok "TimestampUtc is ISO-8601 ($ts)"
} else { Bad "TimestampUtc not ISO-8601: $ts" }
if ($raw -match '"TimestampUtc":\s*"\d{4}-\d{2}-\d{2}T') { Ok 'raw JSON stores TimestampUtc in ISO-8601 form' } else { Bad 'raw JSON TimestampUtc not ISO-8601' }

# Returned entry echoes the write
if ($e1.Scenario -eq 'InstallUninstall' -and $e1.Backend -eq 'Sandbox' -and $e1.Verdict -eq 'Passed') {
    Ok 'the written entry is returned'
} else { Bad 'returned entry mismatch' }

# ── Second entry: appended newest-last, both present in order ──────────────────────────────────────
Write-Host '[2] A second entry appends newest-last; order preserved' -ForegroundColor Cyan
$e2 = Add-Win32ToolkitTestResult -ProjectPath $proj -Scenario 'Update' -Backend 'HyperV' `
        -Verdict 'Failed' -Mode 'Interactive' `
        -Assertions @(@{ Name = 'Updated'; Result = 'FAIL' }) `
        -Notes 'second run' 3>$null

$all = Get-Win32ToolkitTestResult -ProjectPath $proj
if (@($all).Count -eq 2) { Ok 'two entries present' } else { Bad "expected 2 entries, got $(@($all).Count)" }
if (@($all)[0].Scenario -eq 'InstallUninstall' -and @($all)[1].Scenario -eq 'Update') {
    Ok 'order preserved (oldest first, newest appended)'
} else { Bad 'entry order wrong' }
if (@($all)[1].Backend -eq 'HyperV' -and @($all)[1].Mode -eq 'Interactive' -and @($all)[1].Verdict -eq 'Failed') {
    Ok 'second entry fields round-trip'
} else { Bad 'second entry fields wrong' }

# Assertions round-trip
$a0 = @($all)[0].Assertions
if (@($a0).Count -eq 2 -and @($a0)[0].Name -eq 'Installed' -and @($a0)[0].Result -eq 'PASS' -and @($a0)[1].Name -eq 'TattooWritten') {
    Ok 'assertions round-trip (name + result)'
} else { Bad 'assertions did not round-trip' }

# ── Corrupt existing file: replaced, not thrown on ────────────────────────────────────────────────
Write-Host '[3] A corrupt existing file is replaced (with a warning), not fatal' -ForegroundColor Cyan
$proj2 = New-Proj; $made += $proj2
New-Item -ItemType Directory -Path (Join-Path $proj2 'Documentation') -Force | Out-Null
$corruptPath = Join-Path $proj2 'Documentation\TestResults.json'
Set-Content -LiteralPath $corruptPath -Value '{ this is not : valid json ][' -Encoding UTF8

$threw = $false
$warn = @()
try {
    $e3 = Add-Win32ToolkitTestResult -ProjectPath $proj2 -Scenario 'InstallUninstall' -Backend 'Sandbox' `
            -Verdict 'Inconclusive' -WarningVariable warn 3>$null
} catch { $threw = $true }
if (-not $threw) { Ok 'append over a corrupt file did not throw' } else { Bad 'threw on corrupt file' }

$after = Get-Win32ToolkitTestResult -ProjectPath $proj2
if (@($after).Count -eq 1 -and @($after)[0].Verdict -eq 'Inconclusive') {
    Ok 'corrupt file replaced with a fresh 1-entry array'
} else { Bad "expected fresh 1-entry array, got $(@($after).Count)" }

# ── Reader on a missing file ──────────────────────────────────────────────────────────────────────
Write-Host '[4] Get-Win32ToolkitTestResult returns @() for a missing file' -ForegroundColor Cyan
$proj3 = New-Proj; $made += $proj3
$none = Get-Win32ToolkitTestResult -ProjectPath $proj3
if ($null -ne $none -and @($none).Count -eq 0) { Ok 'missing file -> @()' } else { Bad "missing file did not return @() (count=$(@($none).Count))" }

# Reader on an empty file
Write-Host '[5] Get-Win32ToolkitTestResult returns @() for an empty file' -ForegroundColor Cyan
$proj4 = New-Proj; $made += $proj4
New-Item -ItemType Directory -Path (Join-Path $proj4 'Documentation') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $proj4 'Documentation\TestResults.json') -Value '' -Encoding UTF8
$empty = Get-Win32ToolkitTestResult -ProjectPath $proj4
if ($null -ne $empty -and @($empty).Count -eq 0) { Ok 'empty file -> @()' } else { Bad 'empty file did not return @()' }

# ── Update baseline facts (installer-identity PR 1): written only when supplied ──────────────────────
Write-Host '[6] -Baseline / -OldArpSurvivors are written only when supplied; older entries keep their shape' -ForegroundColor Cyan
$proj5 = New-Proj; $made += $proj5
$p5 = Join-Path $proj5 'Documentation\TestResults.json'
$null = Add-Win32ToolkitTestResult -ProjectPath $proj5 -Scenario 'Update' -Backend 'HyperV' -Verdict 'Failed' -Assertions @(@{ Name = 'OldArpGone-PostUpdate'; Result = 'FAIL' })
$raw5a = Get-Content -LiteralPath $p5 -Raw -Encoding UTF8
if ($raw5a -notmatch '"Baseline"' -and $raw5a -notmatch '"OldArpSurvivors"') { Ok 'without -Baseline / -OldArpSurvivors: no such property (the pre-PR-1 shape)' } else { Bad 'unsupplied properties written' }
$firstBefore = (@($raw5a | ConvertFrom-Json)[0] | ConvertTo-Json -Compress -Depth 6)

$esc = [char]27
$bl = @{ ProjectName = ''; Source = 'winget'; Version = '8.8.9'; Mode = 'Auto'; Origin = 'Sibling'; RequestedInstallerType = 'nullsoft'; InstallerType = "null${esc}soft"
         Family = 'exe'; UsedFallback = $false; FallbackReason = ''; RequestedScope = 'machine'; Scope = 'machine'; ScopeRelaxed = $true; Unavailable = $false
         Locale = 'en-US'; Extra = 'x' }
$surv = @(
    [pscustomobject]@{ DisplayName = 'Notepad++ (64-bit x64)'; Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'; KeyLeaf = 'Notepad++'; View = 'Native' },
    @{ DisplayName = 'Two'; Key = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Two'; KeyLeaf = 'Two'; View = 'User' })
$e5 = Add-Win32ToolkitTestResult -ProjectPath $proj5 -Scenario 'Update' -Backend 'HyperV' -Verdict 'Failed' -Assertions @(@{ Name = 'OldArpGone-PostUpdate'; Result = 'FAIL' }) -Baseline $bl -OldArpSurvivors $surv
$all5 = Get-Win32ToolkitTestResult -ProjectPath $proj5   # the reader returns the array itself (unary comma)
$b5 = $all5[1].Baseline
if (@($all5).Count -eq 2 -and $b5.Family -eq 'exe' -and $b5.Version -eq '8.8.9' -and $b5.Origin -eq 'Sibling' -and $b5.Source -eq 'winget') { Ok 'Baseline read back' } else { Bad "baseline: $($b5 | ConvertTo-Json -Compress)" }
if ($b5.UsedFallback -is [bool] -and $b5.UsedFallback -eq $false -and $b5.ScopeRelaxed -eq $true -and $b5.Unavailable -eq $false) { Ok 'booleans stay JSON booleans' } else { Bad "bools: $($b5 | ConvertTo-Json -Compress)" }
if ($b5.InstallerType -eq 'null?soft') { Ok 'string values pass ConvertTo-Win32ToolkitSafeText (ESC -> ?)' } else { Bad "unsafe: $($b5.InstallerType)" }
$names = @($b5.PSObject.Properties.Name)
if (($names -join ',') -eq 'Version,Mode,Origin,RequestedInstallerType,InstallerType,Family,UsedFallback,FallbackReason,RequestedScope,Scope,ScopeRelaxed,Unavailable,Locale,Source,ProjectName,Extra') { Ok 'Baseline keys in the contract order, extra keys after them' } else { Bad "order: $($names -join ',')" }
$s5 = @($all5[1].OldArpSurvivors)
if ($s5.Count -eq 2 -and $s5[0].KeyLeaf -eq 'Notepad++' -and $s5[0].View -eq 'Native' -and $s5[1].DisplayName -eq 'Two' -and $s5[1].View -eq 'User') { Ok 'OldArpSurvivors read back (objects and hashtables)' } else { Bad "survivors: $($s5 | ConvertTo-Json -Compress)" }
if ((@($all5)[0] | ConvertTo-Json -Compress -Depth 6) -eq $firstBefore) { Ok 'the older entry is unchanged by the append' } else { Bad 'older entry changed' }
if ($e5.PSObject.Properties['Baseline'] -and $e5.PSObject.Properties['OldArpSurvivors']) { Ok 'the returned entry carries both' } else { Bad 'returned entry lacks them' }
$many = @(1..12 | ForEach-Object { @{ DisplayName = "A$_"; Key = "HKLM\X\A$_"; KeyLeaf = "A$_"; View = 'Native' } })
$null = Add-Win32ToolkitTestResult -ProjectPath $proj5 -Scenario 'Update' -Backend 'Sandbox' -Verdict 'Failed' -OldArpSurvivors $many
$last5 = (Get-Win32ToolkitTestResult -ProjectPath $proj5)[-1]
if (@($last5.OldArpSurvivors).Count -eq 10 -and -not $last5.PSObject.Properties['Baseline']) { Ok 'at most 10 survivors; -OldArpSurvivors alone writes no Baseline' } else { Bad "cap: $(@($last5.OldArpSurvivors).Count)" }
$null = Add-Win32ToolkitTestResult -ProjectPath $proj5 -Scenario 'Update' -Backend 'Sandbox' -Verdict 'Inconclusive' -Baseline @{ Version = '1.0'; Unavailable = $true; InstallerType = ''; Family = 'msi' }
$last6 = (Get-Win32ToolkitTestResult -ProjectPath $proj5)[-1]
if ($last6.Baseline.Unavailable -eq $true -and $last6.Baseline.InstallerType -eq '' -and -not $last6.PSObject.Properties['OldArpSurvivors']) { Ok 'an Unavailable record: Baseline only, empty InstallerType kept' } else { Bad "unavailable: $($last6 | ConvertTo-Json -Compress -Depth 5)" }

# ── A test the Intune-parity pre-check did not start (installer-identity PR 2): NotRun ─────────────────
Write-Host '[7] -NotRun is written only when supplied: key order, safe text, integers and booleans kept' -ForegroundColor Cyan
$proj7 = New-Proj; $made += $proj7
$p7 = Join-Path $proj7 'Documentation\TestResults.json'
$null = Add-Win32ToolkitTestResult -ProjectPath $proj7 -Scenario 'InstallUninstall' -Backend 'HyperV' -Verdict 'Passed' -LogFolder 'Sandbox\Logs\Runs\x'
$raw7a = Get-Content -LiteralPath $p7 -Raw -Encoding UTF8
if ($raw7a -notmatch '"NotRun"') { Ok 'without -NotRun: no NotRun property (the older shape)' } else { Bad 'NotRun written without -NotRun' }
$nr = @{ SignedInSessions = 2; Welcome = "Org${esc}Ui"; Zeta = $true; ProcessesToClose = 0; Shape = 'Psadt41'; Code = 'PARITY-DIALOG-WAIT'; Alpha = ('x' * 100) }
$e7 = Add-Win32ToolkitTestResult -ProjectPath $proj7 -Scenario 'InstallUninstall' -Backend 'HyperV' -Mode 'Unattended' -Verdict 'Inconclusive' -Assertions @() `
    -Notes 'Not run (Intune-parity pre-check): reason' -LogFolder 'Sandbox\Logs\Runs\y' -NotRun $nr
$last7 = (Get-Win32ToolkitTestResult -ProjectPath $proj7)[-1]
$n7 = $last7.NotRun
$keys7 = @($n7.PSObject.Properties.Name)
if (($keys7 -join ',') -eq 'Code,Shape,ProcessesToClose,Welcome,SignedInSessions,Alpha,Zeta') { Ok 'NotRun keys: Code, Shape, ProcessesToClose, Welcome, SignedInSessions, then the others alphabetically' } else { Bad "NotRun keys: $($keys7 -join ',')" }
if ($n7.ProcessesToClose -is [long] -or $n7.ProcessesToClose -is [int]) { $intsKept = $n7.ProcessesToClose -eq 0 -and $n7.SignedInSessions -eq 2 } else { $intsKept = $false }
if ($intsKept -and $n7.Zeta -is [bool] -and $n7.Zeta) { Ok 'integers and booleans stay JSON numbers and booleans' } else { Bad "types: $($n7 | ConvertTo-Json -Compress)" }
if ($n7.Welcome -eq 'Org?Ui' -and $n7.Alpha.Length -eq 64 -and $n7.Alpha.EndsWith('...') -and $n7.Code -eq 'PARITY-DIALOG-WAIT') { Ok 'strings pass ConvertTo-Win32ToolkitSafeText (ESC -> ?, at most 64 characters)' } else { Bad "strings: $($n7 | ConvertTo-Json -Compress)" }
$props7 = @($last7.PSObject.Properties.Name)
if (($props7 -join ',') -eq 'Scenario,Backend,Mode,TimestampUtc,Verdict,Assertions,Notes,LogFolder,NotRun' -and $last7.Verdict -eq 'Inconclusive' -and @($last7.Assertions).Count -eq 0) { Ok 'NotRun is written after LogFolder; Verdict Inconclusive, no assertions' } else { Bad "entry: $($props7 -join ',')" }
if ($e7.PSObject.Properties['NotRun'] -and (Get-Content -LiteralPath $p7 -Raw -Encoding UTF8) -match '"ProcessesToClose":\s*0') { Ok 'the returned entry carries NotRun; the raw JSON keeps ProcessesToClose a number' } else { Bad 'NotRun missing from the returned entry or written as a string' }

# ── A Hyper-V run's Timing and Lane (Hyper-V speed-up PR 1, D12, A-7): an allow-list ──────────────────────────────────
Write-Host '[8] -Timing / -Lane: allow-listed keys in the contract order, wrong types -> null, safe text; absent -> no property' -ForegroundColor Cyan
$proj8 = New-Proj; $made += $proj8
$p8 = Join-Path $proj8 'Documentation\TestResults.json'
$null = Add-Win32ToolkitTestResult -ProjectPath $proj8 -Scenario 'InstallUninstall' -Backend 'HyperV' -Verdict 'Passed'
$raw8a = Get-Content -LiteralPath $p8 -Raw -Encoding UTF8
if ($raw8a -notmatch '"Timing"' -and $raw8a -notmatch '"Lane"') { Ok 'without -Timing / -Lane: no such property (the older shape)' } else { Bad 'Timing/Lane written without the parameters' }
$hash8 = 'AB' * 32
$phases8 = [System.Collections.Generic.List[object]]::new()
foreach ($i in 1..22) { $phases8.Add(@{ Label = "Phase $i"; Seconds = $i + 0.04 }) }
$phases8[0] = @{ Label = "Install${esc}x (Intune parity)"; Seconds = 12.345 }
$timing8 = @{
    PrecheckFromCache = $true; Unknown = 'dropped'; TotalSeconds = 123.456; OpenSeconds = 31; OpenRevertSkipped = $false; SecondsSinceTeardown = $null
    CopyInSeconds = '7.5'; CopyInSha256 = $hash8; Phases = $phases8; TeardownSeconds = [double]::NaN; RevertMode = 'Legacy'; PrecheckSeconds = 1.25
}
$lane8 = @{
    Attestation = [pscustomobject]@{ SignedIn = $true; DefenderRealTime = $true; DefenderExclusionCount = 0; SignatureAgeDays = $null; FromCache = $false; Extra = 'x' }
    VMName = ('v' * 200); VMId = '0E5F9E66-1111-2222-3333-444455556666'; CheckpointName = "clean${esc}base"; CheckpointId = 'not-a-guid'
    CheckpointCreatedUtc = '2026-10-23T15:29:00.0000000Z'; CheckpointAgeDays = 0; ProcessorCount = 4; MemoryGB = 7.996; ConcurrentLanes = 1
    CheckpointCreationTicks = 638653893400000000; CheckpointObjectId = 'internal'
}
$e8 = Add-Win32ToolkitTestResult -ProjectPath $proj8 -Scenario 'InstallUninstall' -Backend 'HyperV' -Mode 'Unattended' -Verdict 'Passed' -Timing $timing8 -Lane $lane8
$last8 = (Get-Win32ToolkitTestResult -ProjectPath $proj8)[-1]
$t8 = $last8.Timing; $l8 = $last8.Lane
if ((@($t8.PSObject.Properties.Name) -join ',') -eq 'TotalSeconds,OpenSeconds,OpenRevertSkipped,SecondsSinceTeardown,CopyInSeconds,CopyInSha256,Phases,TeardownSeconds,RevertMode,PrecheckSeconds,PrecheckFromCache') {
    Ok 'Timing keys in the contract order; the unknown key is dropped'
} else { Bad "Timing keys: $(@($t8.PSObject.Properties.Name) -join ',')" }
if ($t8.TotalSeconds -eq 123.5 -and $t8.OpenSeconds -eq 31 -and $t8.OpenRevertSkipped -eq $false -and $null -eq $t8.SecondsSinceTeardown -and $null -eq $t8.CopyInSeconds -and
    $t8.CopyInSha256 -ceq $hash8 -and $null -eq $t8.TeardownSeconds -and $t8.RevertMode -ceq 'Legacy' -and $t8.PrecheckSeconds -eq 1.2 -and $t8.PrecheckFromCache -eq $true) {
    Ok 'numbers rounded to one decimal; a string number and NaN -> null; booleans, the hash and RevertMode kept'
} else { Bad "Timing values: $($t8 | ConvertTo-Json -Compress -Depth 4)" }
$ph8 = @($t8.Phases)
if ($ph8.Count -eq 20 -and $ph8[0].Label -ceq 'Install?x (Intune parity)' -and $ph8[0].Seconds -eq 12.3 -and $ph8[19].Label -eq 'Phase 20' -and (@($ph8[0].PSObject.Properties.Name) -join ',') -eq 'Label,Seconds') {
    Ok 'Phases: at most 20, { Label (safe text), Seconds (one decimal) }'
} else { Bad "Phases: $($ph8 | ConvertTo-Json -Compress)" }
if ((@($l8.PSObject.Properties.Name) -join ',') -eq 'VMName,VMId,CheckpointName,CheckpointId,CheckpointCreatedUtc,CheckpointAgeDays,ProcessorCount,MemoryGB,ConcurrentLanes,Attestation') {
    Ok 'Lane keys in the contract order; the internal cache keys (CheckpointCreationTicks, CheckpointObjectId) are dropped'
} else { Bad "Lane keys: $(@($l8.PSObject.Properties.Name) -join ',')" }
$raw8 = Get-Content -LiteralPath $p8 -Raw -Encoding UTF8
if ($l8.VMName.Length -eq 64 -and $l8.VMName.EndsWith('...') -and $l8.CheckpointName -ceq 'clean?base' -and $l8.VMId -eq '0E5F9E66-1111-2222-3333-444455556666' -and $l8.CheckpointId -eq '' -and
    $raw8 -match '"CheckpointCreatedUtc":\s*"2026-10-23T15:29:00\.0000000Z"' -and $l8.CheckpointAgeDays -eq 0 -and $l8.ProcessorCount -eq 4 -and $l8.MemoryGB -eq 8 -and $l8.ConcurrentLanes -eq 1) {
    Ok 'Lane: a 200-character VM name cut to 64, safe text, a bad GUID -> '''', the creation time kept as written, numbers kept'
} else { Bad "Lane values: $($l8 | ConvertTo-Json -Compress -Depth 4)" }
$a8 = $l8.Attestation
if ((@($a8.PSObject.Properties.Name) -join ',') -eq 'SignedIn,DefenderRealTime,DefenderExclusionCount,SignatureAgeDays,FromCache' -and $a8.SignedIn -eq $true -and $a8.DefenderExclusionCount -eq 0 -and $null -eq $a8.SignatureAgeDays -and $a8.FromCache -eq $false) {
    Ok 'Lane.Attestation: the five keys only, SignatureAgeDays $null kept as null'
} else { Bad "Attestation: $($a8 | ConvertTo-Json -Compress)" }
if ($e8.PSObject.Properties['Timing'] -and $e8.PSObject.Properties['Lane'] -and (@($last8.PSObject.Properties.Name) -join ',') -eq 'Scenario,Backend,Mode,TimestampUtc,Verdict,Assertions,Notes,Timing,Lane') { Ok 'the returned entry carries both; Timing then Lane, after the older properties' } else { Bad "entry: $(@($last8.PSObject.Properties.Name) -join ',')" }
# Wrong types for whole objects or members.
$null = Add-Win32ToolkitTestResult -ProjectPath $proj8 -Scenario 'Update' -Backend 'HyperV' -Verdict 'Failed' -Timing @{ TotalSeconds = 'x'; CopyInSha256 = ('ab' * 32); RevertMode = 'Fast'; Phases = 'Install'; OpenRevertSkipped = 'false' } `
    -Lane @{ VMName = 42; VMId = 7; CheckpointCreatedUtc = '23/10/2026'; CheckpointAgeDays = '3'; MemoryGB = 'big'; Attestation = 'yes'; ConcurrentLanes = 1.5 }
$last8b = (Get-Win32ToolkitTestResult -ProjectPath $proj8)[-1]
$t8b = $last8b.Timing; $l8b = $last8b.Lane
if ($null -eq $t8b.TotalSeconds -and $null -eq $t8b.CopyInSha256 -and $null -eq $t8b.RevertMode -and $null -eq $t8b.Phases -and $null -eq $t8b.OpenRevertSkipped -and $null -eq $t8b.OpenSeconds) {
    Ok 'Timing: a string number, a lower-case hash, an unknown RevertMode, a string Phases, a string boolean and an absent key -> null'
} else { Bad "Timing wrong types: $($t8b | ConvertTo-Json -Compress -Depth 4)" }
if ($null -eq $l8b.VMName -and $l8b.VMId -eq '' -and $l8b.CheckpointName -eq '' -and $l8b.CheckpointCreatedUtc -eq '' -and $null -eq $l8b.CheckpointAgeDays -and $null -eq $l8b.MemoryGB -and $null -eq $l8b.Attestation -and $null -eq $l8b.ConcurrentLanes) {
    Ok 'Lane: a number as a name -> null, a number as an Id -> '''', a non round-trip time -> '''', wrong numbers and attestation -> null, an absent name -> '''''
} else { Bad "Lane wrong types: $($l8b | ConvertTo-Json -Compress -Depth 4)" }
$null = Add-Win32ToolkitTestResult -ProjectPath $proj8 -Scenario 'InstallUninstall' -Backend 'HyperV' -Verdict 'Inconclusive' -Timing $null -Lane $null
$last8c = (Get-Win32ToolkitTestResult -ProjectPath $proj8)[-1]
if (-not $last8c.PSObject.Properties['Timing'] -and -not $last8c.PSObject.Properties['Lane']) { Ok '-Timing $null / -Lane $null: no property' } else { Bad 'a $null Timing/Lane was written' }
$null = Add-Win32ToolkitTestResult -ProjectPath $proj8 -Scenario 'InstallUninstall' -Backend 'HyperV' -Verdict 'Passed' -Timing @{ Phases = [System.Collections.Generic.List[object]]::new() }
if (@((Get-Win32ToolkitTestResult -ProjectPath $proj8)[-1].Timing.Phases).Count -eq 0 -and (Get-Content -LiteralPath $p8 -Raw -Encoding UTF8) -match '"Phases":\s*\[\s*\]') { Ok 'no phase ran: Phases is an empty array' } else { Bad 'an empty phase list was not written as []' }
$all8 = Get-Win32ToolkitTestResult -ProjectPath $proj8   # the reader returns the array itself (unary comma)
if ($all8.Count -eq 5) { Ok 'round trip: every record reads back' } else { Bad "records: $($all8.Count)" }
# ── [9] Proof: the prior-install proof allow-list (installer-identity PR 3, spec 2.10) ─────────────────────
Write-Host '[9] -Proof is written through an allow-list; without it the record keeps its older shape' -ForegroundColor Cyan
$proj9 = New-Proj; $made += $proj9
$h64 = 'AB' * 32
$null = Add-Win32ToolkitTestResult -ProjectPath $proj9 -Scenario 'Update' -Backend 'HyperV' -Verdict 'Passed' -Proof @{
    PriorInstallsHash = $h64; ScriptSha256 = $h64; FilesSha256 = $h64; SupportFilesSha256 = $h64; BaselineInstallerSha256 = ''; CatalogVersion = '1a2cadc16dec5c3b'
    EntryIds = @('nsis-x64', 'NSIS', ('x' * 41)); CaptureIds = @('3f9c0a7d51e2b846', 'XYZ'); RequirementChecked = $true
    ObservedVersions = @{ 'nsis-x64' = "8.9.5`e[31m"; 'Bad Id' = '1' }; DataLoss = @('nsis-x64'); Unknown = 'dropped' }
$r9 = (Get-Win32ToolkitTestResult -ProjectPath $proj9)[-1]
$pr = $r9.Proof
if ((@($pr.PSObject.Properties.Name) -join ',') -eq 'SchemaVersion,PriorInstallsHash,ScriptSha256,FilesSha256,SupportFilesSha256,BaselineInstallerSha256,CatalogVersion,EntryIds,CaptureIds,RequirementChecked,ObservedVersions,DataLoss') { Ok 'the Proof keys in the frozen order; an unknown key dropped' } else { Bad "proof keys: $(@($pr.PSObject.Properties.Name) -join ',')" }
if ($pr.PriorInstallsHash -ceq $h64 -and $pr.BaselineInstallerSha256 -eq '' -and $pr.CatalogVersion -ceq '1a2cadc16dec5c3b' -and $pr.RequirementChecked -eq $true -and (@($pr.EntryIds) -join ',') -eq 'nsis-x64' -and (@($pr.CaptureIds) -join ',') -eq '3f9c0a7d51e2b846' -and (@($pr.DataLoss) -join ',') -eq 'nsis-x64') {
    Ok 'hashes, catalog version, ids (bad ids dropped), RequirementChecked and DataLoss kept'
} else { Bad "proof values: $($pr | ConvertTo-Json -Compress)" }
if ($pr.ObservedVersions.'nsis-x64' -eq '8.9.5?[31m' -and -not $pr.ObservedVersions.PSObject.Properties['Bad Id']) { Ok 'ObservedVersions: neutralised text, bad ids dropped' } else { Bad "observed: $($pr.ObservedVersions | ConvertTo-Json -Compress)" }
$null = Add-Win32ToolkitTestResult -ProjectPath $proj9 -Scenario 'Update' -Backend 'HyperV' -Verdict 'Passed' -Proof @{ PriorInstallsHash = $h64.ToLowerInvariant(); CatalogVersion = 'XYZ'; EntryIds = 'nsis-x64'; RequirementChecked = 'true'; ObservedVersions = 'x'; DataLoss = @{ a = 1 } }
$pw = (Get-Win32ToolkitTestResult -ProjectPath $proj9)[-1].Proof
if ($pw.PriorInstallsHash -eq '' -and $pw.CatalogVersion -eq '' -and $null -eq $pw.EntryIds -and $null -eq $pw.RequirementChecked -and $null -eq $pw.ObservedVersions -and $null -eq $pw.DataLoss -and @($pw.CaptureIds).Count -eq 0) {
    Ok 'wrong types: a lower-case hash and a bad catalog version -> '''', a string id list, a string boolean, a string map and a map list -> null, an absent list -> []'
} else { Bad "proof wrong types: $($pw | ConvertTo-Json -Compress)" }
$null = Add-Win32ToolkitTestResult -ProjectPath $proj9 -Scenario 'Update' -Backend 'HyperV' -Verdict 'Passed'
if (-not (Get-Win32ToolkitTestResult -ProjectPath $proj9)[-1].PSObject.Properties['Proof']) { Ok 'without -Proof: no Proof property (older shape)' } else { Bad 'a Proof property without -Proof' }
# ── cleanup ───────────────────────────────────────────────────────────────────────────────────────
foreach ($m in $made) { Remove-Item -LiteralPath $m -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestResultRecord tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestResultRecord test(s) FAILED." -ForegroundColor Red; exit 1 }
