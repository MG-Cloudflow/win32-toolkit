<#
    Installer-identity PR 1 (spec 2.11): the Update-test baseline technology.

      [1] Resolve-Win32ToolkitBaselineFamily (WP-3 helpers shadowed, IdentityDelta.json fixtures): Auto with a
          nullsoft sibling -> one Sibling leg with the packaged fallback; Auto without -> Packaged; a (dormant)
          PriorInstalls Enforce entry -> Entry; a zip-wrapped-only sibling -> Packaged + Note; Both -> packaged + one
          leg per testable family; Both without -> one leg + Note; an appx sibling -> msix; Packaged; an explicit
          type (sibling scope only when explicit); a missing IdentityDelta.json is written once (Auto/Both only,
          never with -NoProbe); a corrupt or newer file never throws; a probe that did not run (Unavailable,
          Skipped, no file) -> the packaged leg of Auto/Both says so in its Note, a stored Unavailable probe is
          retried once; every leg has a Label.
      [2] Download-OldVersionInstaller -FamilyPin (winget shadowed): --installer-type per tried type, no --locale,
          no unpinned retry; the soft scope (user -> no-applicable -> relaxed, cache key '..._any_inno_...');
          one host line per fallback step naming the next attempt (none after the last);
          every type no-applicable -> W32T.InstallerVariantUnavailable naming every attempt; any other code ->
          a plain error; the return fields; the attempts use the staging folder '<OldVersion>.attempt' and
          Sandbox\OldVersion changes only on success (untouched on Unavailable or an error). Without -FamilyPin:
          byte-identical winget arguments, the old unpinned fallback, Family '' and no call to the family helpers
          (their shadows throw).
      [3] Invoke-Win32ToolkitFinalize passes -BaselineInstallerType only when -UpdateBaselineInstallerType is bound.

    No network, no real winget, nothing installed.

    Run:  pwsh -File Tests\BaselineFamily.unit.ps1
#>
# Test shadows keep the real command names (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32bf_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$validTypes = @('Auto', 'Both', 'Packaged', 'msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')

try {
    # == [1] Resolve-Win32ToolkitBaselineFamily ===========================================================
    Write-Host '[1] Resolve-Win32ToolkitBaselineFamily' -ForegroundColor Cyan
    . (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
    . (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
    . (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
    . (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineFamily.ps1')

    # WP-3 contracts, shadowed: the packaged source and the identity-delta writer.
    $script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Scope = 'machine' }
    function Get-Win32ToolkitProjectSource { param($ProjectPath) $script:source }
    $script:deltaWrites = 0
    $script:deltaToWrite = $null
    function Write-Win32ToolkitIdentityDelta {
        param($ProjectPath, $TenantId, [switch]$Quiet)
        $script:deltaWrites++
        if ($script:deltaToWrite) {
            $d = Join-Path $ProjectPath 'Documentation'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 'IdentityDelta.json'), ($script:deltaToWrite | ConvertTo-Json -Depth 8), $utf8)
        }
        $script:deltaToWrite
    }

    function New-Sib([string]$Type, [string]$Family, [int]$Precedence, [string]$Scope = 'machine', [string]$Pin = $Type, [switch]$Zip, [string]$Label = '') {
        [pscustomobject]@{
            EffectiveType = $Type; RegisteredType = ''; Family = $Family; InstallerType = $(if ($Zip) { 'zip' } else { $Type })
            NestedInstallerType = $(if ($Zip) { $Type } else { '' }); Scope = $Scope; ProductCode = 'X'; ZipWrapped = [bool]$Zip
            Registers = $true; Testable = -not $Zip; PinValue = $(if ($Zip) { '' } else { $Pin }); Precedence = $Precedence
            Label = $(if ($Label) { $Label } else { (Get-Win32ToolkitInstallerFamily -Type $(if ($Zip) { 'zip' } else { $Type }) -NestedType $(if ($Zip) { $Type } else { '' })).Label })
        }
    }
    function New-Delta([object[]]$Siblings, [string]$Schema = '1.0') {
        [pscustomobject]@{ SchemaVersion = $Schema; Probe = [pscustomobject]@{ Status = 'Ok' }; Siblings = @($Siblings); Findings = @() }
    }
    function New-BfProj($Delta, $AppConfig) {
        $p = Join-Path $tmpRoot ('bf_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
        if ($null -ne $Delta) {
            New-Item -ItemType Directory -Path (Join-Path $p 'Documentation') -Force | Out-Null
            $json = if ($Delta -is [string]) { $Delta } else { $Delta | ConvertTo-Json -Depth 8 }
            [System.IO.File]::WriteAllText((Join-Path $p 'Documentation\IdentityDelta.json'), $json, $utf8)
        }
        if ($AppConfig) { [System.IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($AppConfig | ConvertTo-Json -Depth 8), $utf8) }
        $p
    }
    $nppDelta = New-Delta @(New-Sib nullsoft exe 7 machine)
    $allLegs = [System.Collections.Generic.List[object]]::new()
    function Get-Leg($Proj, $Mode, [switch]$NoProbe) { $l = @(Resolve-Win32ToolkitBaselineFamily -ProjectPath $Proj -Mode $Mode -NoProbe:$NoProbe); foreach ($x in $l) { $allLegs.Add($x) }; , $l }

    # a. Auto with a nullsoft sibling (Notepad++ 8.9.8.1 x64, packaged wix)
    $l = Get-Leg (New-BfProj $nppDelta) 'Auto'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Sibling' -and $l[0].InstallerType -eq 'nullsoft' -and $l[0].Family -eq 'exe' -and $l[0].Scope -eq 'machine' -and
        $l[0].FallbackInstallerType -eq 'wix' -and $l[0].FallbackScope -eq 'machine') { Ok 'Auto + nullsoft sibling -> one Sibling leg nullsoft (exe), packaged fallback wix/machine (L2)' }
    else { Bad "auto-sibling: $($l | ConvertTo-Json -Compress)" }
    if ($l[0].Label -eq 'nullsoft (vendor EXE, NSIS) (other technology winget ships for this app)') { Ok "Label = '<type label> (<origin>)'" } else { Bad "label: $($l[0].Label)" }

    # b. Auto without a sibling
    $l = Get-Leg (New-BfProj (New-Delta @())) 'Auto'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Packaged' -and $l[0].InstallerType -eq 'wix' -and $l[0].Family -eq 'msi' -and -not $l[0].FallbackInstallerType) { Ok 'Auto without a sibling -> Packaged wix, no fallback' }
    else { Bad "auto-packaged: $($l | ConvertTo-Json -Compress)" }

    # c. Auto with a (dormant) PriorInstalls Enforce entry
    $cfgEntry = [pscustomobject]@{ App = [pscustomobject]@{ Name = 'Git' }; PriorInstalls = [pscustomobject]@{ Entries = @(
                [pscustomobject]@{ Mode = 'Block'; UninstallerType = 'nullsoft' },
                [pscustomobject]@{ Mode = 'Enforce'; UninstallerType = 'msi' },
                [pscustomobject]@{ Mode = 'Enforce'; UninstallerType = 'inno' }) } }
    $l = Get-Leg (New-BfProj $nppDelta $cfgEntry) 'Auto'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Entry' -and $l[0].InstallerType -eq 'inno' -and $l[0].Family -eq 'exe' -and -not $l[0].FallbackInstallerType) { Ok 'Auto + PriorInstalls Enforce entry (inno) -> Entry (Block and non-EXE entries skipped; wins over the sibling)' }
    else { Bad "entry: $($l | ConvertTo-Json -Compress)" }

    # c2. installer-identity PR 3 (L27): the Enforce entries in Id order; -EntryId picks the group of those entries
    $cfgGroups = [pscustomobject]@{ App = [pscustomobject]@{ Name = 'Npp' }; PriorInstalls = [pscustomobject]@{ Entries = @(
                [pscustomobject]@{ Id = 'zz-nsis'; Mode = 'Enforce'; UninstallerType = 'nullsoft' },
                [pscustomobject]@{ Id = 'aa-inno'; Mode = 'Enforce'; UninstallerType = 'inno' }) } }
    $pg = New-BfProj $nppDelta $cfgGroups
    $l = Get-Leg $pg 'Auto'
    if ($l[0].Origin -eq 'Entry' -and $l[0].InstallerType -eq 'inno') { Ok 'Auto: the first Enforce entry in Id ORDER (aa-inno), not in file order' } else { Bad "id order: $($l | ConvertTo-Json -Compress)" }
    $l = @(Resolve-Win32ToolkitBaselineFamily -ProjectPath $pg -Mode Auto -EntryId 'zz-nsis')
    if ($l[0].Origin -eq 'Entry' -and $l[0].InstallerType -eq 'nullsoft') { Ok 'Auto -EntryId zz-nsis -> the second group''s technology (nullsoft), not the first entry''s' } else { Bad "entry id: $($l | ConvertTo-Json -Compress)" }
    $l = @(Resolve-Win32ToolkitBaselineFamily -ProjectPath $pg -Mode Auto -EntryId 'unknown')
    if ($l[0].Origin -eq 'Sibling') { Ok 'Auto -EntryId naming no Enforce entry -> the sibling step as before' } else { Bad "no entry: $($l | ConvertTo-Json -Compress)" }
    # d. a zip-wrapped-only sibling (TeamViewer 15.82.6 x64, packaged nullsoft)
    $script:source = [pscustomobject]@{ InstallerType = 'nullsoft'; Family = 'exe'; Scope = 'machine' }
    $l = Get-Leg (New-BfProj (New-Delta @(New-Sib wix msi 5 '' -Zip))) 'Auto'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Packaged' -and $l[0].InstallerType -eq 'nullsoft' -and $l[0].Note -eq 'wix (MSI), zip-wrapped cannot be used as an Update baseline') { Ok 'zip-wrapped-only sibling -> Packaged nullsoft + Note (cannot be used as an Update baseline)' }
    else { Bad "zip: $($l | ConvertTo-Json -Compress)" }
    $script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Scope = 'machine' }

    # e. Both with two other families (msix via appx, and exe with nullsoft + inno)
    $multi = New-Delta @((New-Sib nullsoft exe 7 machine), (New-Sib appx msix 3 '' msix), (New-Sib inno exe 8 user))
    $l = Get-Leg (New-BfProj $multi) 'Both'
    if ($l.Count -eq 3 -and $l[0].Origin -eq 'Packaged' -and $l[0].InstallerType -eq 'wix' -and
        $l[1].Origin -eq 'Sibling' -and $l[1].InstallerType -eq 'msix' -and $l[1].Family -eq 'msix' -and
        $l[2].Origin -eq 'Sibling' -and $l[2].InstallerType -eq 'nullsoft' -and $l[2].Family -eq 'exe' -and
        -not ($l | Where-Object { $_.FallbackInstallerType })) { Ok 'Both -> Packaged wix + one leg per testable family (msix, exe = its highest-precedence type nullsoft), no fallback' }
    else { Bad "both: $($l | ConvertTo-Json -Compress)" }

    # f. Both without a testable sibling
    $l = Get-Leg (New-BfProj (New-Delta @())) 'Both'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Packaged' -and $l[0].Note -eq 'no other installer technology that can be tested') { Ok 'Both without a testable sibling -> one Packaged leg + Note' }
    else { Bad "both-none: $($l | ConvertTo-Json -Compress)" }

    # g. an appx sibling -> msix
    $script:source = [pscustomobject]@{ InstallerType = 'exe'; Family = 'exe'; Scope = 'machine' }
    $l = Get-Leg (New-BfProj (New-Delta @(New-Sib appx msix 3 '' msix))) 'Auto'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Sibling' -and $l[0].InstallerType -eq 'msix' -and $l[0].FallbackInstallerType -eq 'exe') { Ok 'an appx sibling -> leg InstallerType msix (its pin value), fallback exe' }
    else { Bad "appx: $($l | ConvertTo-Json -Compress)" }
    $script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Scope = 'machine' }

    # h. Packaged
    $l = Get-Leg (New-BfProj $nppDelta) 'Packaged'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Packaged' -and $l[0].InstallerType -eq 'wix' -and $l[0].Scope -eq 'machine' -and -not $l[0].FallbackInstallerType) { Ok 'Packaged -> one leg, packaged scope, no fallback' }
    else { Bad "packaged: $($l | ConvertTo-Json -Compress)" }

    # i. explicit types
    $l = Get-Leg (New-BfProj $nppDelta) 'nullsoft'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Explicit' -and $l[0].InstallerType -eq 'nullsoft' -and $l[0].Family -eq 'exe' -and $l[0].Scope -eq 'machine' -and -not $l[0].FallbackInstallerType) { Ok 'explicit nullsoft -> Explicit, the sibling''s explicit scope, no fallback' }
    else { Bad "explicit: $($l | ConvertTo-Json -Compress)" }
    $l = Get-Leg (New-BfProj (New-Delta @(New-Sib nullsoft exe 7 ''))) 'nullsoft'
    if ($l[0].Scope -eq '') { Ok 'explicit nullsoft, sibling without an explicit scope -> no scope' } else { Bad "scope: $($l[0].Scope)" }
    $l = Get-Leg (New-BfProj $nppDelta) 'inno'
    if ($l[0].Origin -eq 'Explicit' -and $l[0].InstallerType -eq 'inno' -and $l[0].Scope -eq '') { Ok 'explicit inno (no matching sibling) -> no scope' } else { Bad "inno: $($l | ConvertTo-Json -Compress)" }
    $l = Get-Leg (New-BfProj $nppDelta) 'wix'
    if ($l[0].Origin -eq 'Explicit' -and $l[0].Scope -eq 'machine') { Ok 'explicit type = the packaged type -> the packaged scope' } else { Bad "wix: $($l | ConvertTo-Json -Compress)" }

    # j. a missing IdentityDelta.json
    $script:deltaWrites = 0; $script:deltaToWrite = $nppDelta
    $l = Get-Leg (New-BfProj $null) 'Auto'
    if ($script:deltaWrites -eq 1 -and $l[0].Origin -eq 'Sibling') { Ok 'missing IdentityDelta.json + Auto -> Write-Win32ToolkitIdentityDelta called once, its siblings used' } else { Bad "write: $script:deltaWrites $($l | ConvertTo-Json -Compress)" }
    $script:deltaWrites = 0
    $l = Get-Leg (New-BfProj $null) 'Both'
    if ($script:deltaWrites -eq 1 -and $l.Count -eq 2) { Ok 'missing IdentityDelta.json + Both -> written once' } else { Bad "both-write: $script:deltaWrites" }
    $script:deltaWrites = 0
    $l = Get-Leg (New-BfProj $null) 'Auto' -NoProbe
    if ($script:deltaWrites -eq 0 -and $l[0].Origin -eq 'Packaged') { Ok '-NoProbe -> not written, Packaged' } else { Bad "noprobe: $script:deltaWrites" }
    $script:deltaWrites = 0
    $null = Get-Leg (New-BfProj $null) 'Packaged'; $null = Get-Leg (New-BfProj $null) 'nullsoft'
    if ($script:deltaWrites -eq 0) { Ok 'Packaged and an explicit type never write IdentityDelta.json (L6)' } else { Bad "packaged-write: $script:deltaWrites" }
    $script:deltaWrites = 0
    $p = New-BfProj $nppDelta
    $null = Get-Leg $p 'Auto'
    if ($script:deltaWrites -eq 0) { Ok 'an existing IdentityDelta.json is reused (no probe)' } else { Bad 'rewrote an existing file' }
    $script:deltaToWrite = $null

    # l. corrupt and newer files
    $threw = $false
    try { $l = Get-Leg (New-BfProj '{ not json [') 'Auto' -NoProbe } catch { $threw = $true }
    if (-not $threw -and $l[0].Origin -eq 'Packaged') { Ok 'corrupt IdentityDelta.json -> no throw, Packaged' } else { Bad "corrupt: threw=$threw" }
    $newer = New-Delta @(New-Sib nullsoft exe 7 machine) '9.0'
    $newer | Add-Member -NotePropertyName FutureField -NotePropertyValue 'x'
    $l = Get-Leg (New-BfProj $newer) 'Auto'
    if ($l[0].Origin -eq 'Sibling') { Ok 'a newer SchemaVersion with unknown fields is read leniently' } else { Bad "newer: $($l | ConvertTo-Json -Compress)" }
    $sparse = '{"Siblings":[{"EffectiveType":"nullsoft","Testable":true}]}'
    $l = Get-Leg (New-BfProj $sparse) 'Auto'
    if ($l[0].Origin -eq 'Sibling' -and $l[0].InstallerType -eq 'nullsoft' -and $l[0].Family -eq 'exe') { Ok 'a sparse sibling entry (no Family/PinValue/Precedence) falls back to the family table' } else { Bad "sparse: $($l | ConvertTo-Json -Compress)" }

    # n. the sibling probe did not run (offline, HTTP 429, no winget id, no file): the packaged leg says so
    $probeNote = { param([string]$Why) "Other installer technologies could not be checked ($Why), so the packaged technology is used; pass -BaselineInstallerType <type> to choose one." }
    $unavail = [pscustomobject]@{ SchemaVersion = '1.0'; Probe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'Network' }; Siblings = @(); Findings = @() }
    $l = Get-Leg (New-BfProj (New-Delta @())) 'Auto'
    if ($l[0].Origin -eq 'Packaged' -and $l[0].Note -eq '') { Ok 'probe Ok without a sibling -> Packaged, no Note' } else { Bad "ok-note: $($l[0].Note)" }
    $script:deltaWrites = 0; $script:deltaToWrite = $unavail
    $l = Get-Leg (New-BfProj $unavail) 'Auto'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Packaged' -and $l[0].InstallerType -eq 'wix' -and $l[0].Note -eq (& $probeNote 'Network')) { Ok 'stored probe Unavailable (Network) -> Packaged leg with the "could not be checked (Network)" Note' }
    else { Bad "unavail: $($l | ConvertTo-Json -Compress)" }
    if ($script:deltaWrites -eq 1) { Ok 'a stored Unavailable probe is retried once (IdentityDelta.json rewritten once)' } else { Bad "retry writes: $script:deltaWrites" }
    $script:deltaWrites = 0; $script:deltaToWrite = $nppDelta
    $l = Get-Leg (New-BfProj $unavail) 'Auto'
    if ($script:deltaWrites -eq 1 -and $l[0].Origin -eq 'Sibling' -and $l[0].InstallerType -eq 'nullsoft' -and $l[0].Note -eq '') { Ok 'the retry succeeds (probe Ok, nullsoft sibling) -> Sibling leg, no Note' }
    else { Bad "retry ok: $script:deltaWrites $($l | ConvertTo-Json -Compress)" }
    $script:deltaWrites = 0; $script:deltaToWrite = $unavail
    $l = Get-Leg (New-BfProj $unavail) 'Both'
    if ($l.Count -eq 1 -and $l[0].Origin -eq 'Packaged' -and $l[0].Note -eq (& $probeNote 'Network') -and $script:deltaWrites -eq 1) { Ok 'Both + Unavailable -> one Packaged leg whose Note says the check did not run (not "no other installer technology")' }
    else { Bad "both-unavail: $script:deltaWrites $($l | ConvertTo-Json -Compress)" }
    $script:deltaWrites = 0
    $l = Get-Leg (New-BfProj $unavail) 'Auto' -NoProbe
    if ($script:deltaWrites -eq 0 -and $l[0].Origin -eq 'Packaged' -and $l[0].Note -eq (& $probeNote 'Network')) { Ok '-NoProbe + Unavailable -> not retried, same Note' } else { Bad "noprobe-unavail: $script:deltaWrites $($l[0].Note)" }
    $script:deltaWrites = 0; $script:deltaToWrite = $null
    $l = Get-Leg (New-BfProj $null) 'Auto'
    if ($script:deltaWrites -eq 1 -and $l[0].Origin -eq 'Packaged' -and $l[0].Note -eq (& $probeNote 'Documentation\IdentityDelta.json is missing or unreadable')) { Ok 'missing file, the write fails -> one write only (no second retry), Packaged + Note' }
    else { Bad "missing-fail: $script:deltaWrites $($l[0].Note)" }
    $script:deltaWrites = 0
    $l = Get-Leg (New-BfProj '{ not json [') 'Both' -NoProbe
    if ($l.Count -eq 1 -and $l[0].Note -eq (& $probeNote 'Documentation\IdentityDelta.json is missing or unreadable')) { Ok 'corrupt file + Both -> the packaged leg says the check did not run' } else { Bad "corrupt-both: $($l[0].Note)" }
    $skipped = [pscustomobject]@{ SchemaVersion = '1.0'; Probe = [pscustomobject]@{ Status = 'Skipped'; Reason = 'NoWingetId' }; Siblings = @() }
    $l = Get-Leg (New-BfProj $skipped) 'Auto'
    if ($script:deltaWrites -eq 0 -and $l[0].Note -eq (& $probeNote 'NoWingetId')) { Ok 'probe Skipped (NoWingetId) -> Note, not retried (only Unavailable is)' } else { Bad "skipped: $script:deltaWrites $($l[0].Note)" }
    $noProbeField = [pscustomobject]@{ SchemaVersion = '1.0'; Siblings = @() }
    $l = Get-Leg (New-BfProj $noProbeField) 'Auto'
    if ($l[0].Note -eq (& $probeNote 'no lookup result stored')) { Ok 'no Probe in the file -> Note (no lookup result stored)' } else { Bad "noprobe-field: $($l[0].Note)" }
    $esc = [char]27
    $hostile = [pscustomobject]@{ SchemaVersion = '1.0'; Probe = [pscustomobject]@{ Status = 'Unavailable'; Reason = "Net${esc}[31mwork$([char]0x202E)" }; Siblings = @() }
    $l = Get-Leg (New-BfProj $hostile) 'Auto' -NoProbe
    if ($l[0].Note -notmatch "[\x00-\x1f$([char]0x202E)]" -and $l[0].Note -like 'Other installer technologies could not be checked (Net?`[31mwork?)*') { Ok 'a hostile Reason passes ConvertTo-Win32ToolkitSafeText (ESC, U+202E -> ?)' } else { Bad "hostile: $($l[0].Note)" }
    $script:deltaWrites = 0
    $lp = Get-Leg (New-BfProj $unavail) 'Packaged'; $lx = Get-Leg (New-BfProj $unavail) 'nullsoft'
    if ($script:deltaWrites -eq 0 -and $lp[0].Note -eq '' -and $lx[0].Note -eq '') { Ok 'Packaged and an explicit type: no probe Note, no retry (they do not use siblings)' } else { Bad "packaged-unavail: $script:deltaWrites '$($lp[0].Note)' '$($lx[0].Note)'" }
    $entryUnavail = [pscustomobject]@{ App = [pscustomobject]@{ Name = 'Git' }; PriorInstalls = [pscustomobject]@{ Entries = @([pscustomobject]@{ Mode = 'Enforce'; UninstallerType = 'inno' }) } }
    $l = Get-Leg (New-BfProj $unavail $entryUnavail) 'Auto' -NoProbe
    if ($l[0].Origin -eq 'Entry' -and $l[0].Note -eq '') { Ok 'an Entry leg (not the packaged technology) carries no probe Note' } else { Bad "entry-unavail: $($l | ConvertTo-Json -Compress)" }
    $script:deltaToWrite = $null

    # m. an unpinnable packaged type
    $script:source = [pscustomobject]@{ InstallerType = 'portable'; Family = 'portable'; Scope = '' }
    $l = Get-Leg (New-BfProj (New-Delta @())) 'Auto'
    if ($l.Count -eq 1 -and $l[0].InstallerType -eq '' -and $l[0].Note -match "'portable' cannot be pinned") { Ok 'an unpinnable packaged type -> leg without InstallerType + Note (the test then has no verdict)' } else { Bad "unpinnable: $($l | ConvertTo-Json -Compress)" }
    $script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Scope = 'machine' }

    # k. every leg
    $noLabel = @($allLegs | Where-Object { -not $_.Label })
    $badType = @($allLegs | Where-Object { $_.InstallerType -and $_.InstallerType -notin $validTypes })
    $badOrigin = @($allLegs | Where-Object { $_.Origin -notin @('Entry', 'Sibling', 'Packaged', 'Explicit') })
    if ($allLegs.Count -ge 20 -and $noLabel.Count -eq 0 -and $badType.Count -eq 0 -and $badOrigin.Count -eq 0) { Ok "every leg ($($allLegs.Count)) has a Label, a -BaselineInstallerType value and a known Origin" }
    else { Bad "legs: $($allLegs.Count) noLabel $($noLabel.Count) badType $($badType.Count) badOrigin $($badOrigin.Count)" }
    $legProps = @('Family', 'InstallerType', 'Scope', 'Origin', 'FallbackInstallerType', 'FallbackScope', 'Label', 'Note')
    if (@($allLegs | Where-Object { (@($_.PSObject.Properties.Name) -join ',') -ne ($legProps -join ',') }).Count -eq 0) { Ok 'every leg has exactly the contract fields' } else { Bad 'leg shape differs from the contract' }

    # == [2] Download-OldVersionInstaller =================================================================
    Write-Host '[2] Download-OldVersionInstaller -FamilyPin' -ForegroundColor Cyan
    . (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')
    . (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineSilentArgs.ps1')
    . (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
    . (Join-Path $repo 'Private\Get-YAMLInstallerInfo.ps1')
    . (Join-Path $repo 'Private\Test-Win32ToolkitCachedInstaller.ps1')
    . (Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1')   # every winget download runs through it (C-9)
    . (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')

    $script:cacheRoot = $null
    function Get-Win32ToolkitPipelineCacheRoot { $script:cacheRoot }
    $script:calls = [System.Collections.Generic.List[object]]::new()
    # Exit code per call: a scriptblock over the call's argument array. Default: success.
    $script:answer = { param([string[]]$A) 0 }
    function winget {
        $a = [string[]]$args
        $script:calls.Add($a)
        $code = & $script:answer $a
        if ($code -eq 0) {
            $dir = $a[[array]::IndexOf($a, '--download-directory') + 1]
            $ti = [array]::IndexOf($a, '--installer-type')
            $type = if ($ti -ge 0) { $a[$ti + 1] } else { 'nullsoft' }
            $si = [array]::IndexOf($a, '--scope')
            $scope = if ($si -ge 0) { $a[$si + 1] } else { 'machine' }
            $ext = if ($type -in @('msi', 'wix')) { 'msi' } else { 'exe' }
            [System.IO.File]::WriteAllBytes((Join-Path $dir "app.$ext"), [byte[]](5..60))
            $sha = (Get-FileHash -LiteralPath (Join-Path $dir "app.$ext") -Algorithm SHA256).Hash
            Set-Content -LiteralPath (Join-Path $dir 'Acme.App.installer.yaml') -Encoding UTF8 -Value @(
                'PackageIdentifier: Acme.App', 'PackageVersion: 1.2.3', 'Installers:', '- Architecture: x64', "  InstallerType: $type", "  Scope: $scope",
                "  InstallerSha256: $sha", "  ProductCode: 'Acme App'", '  InstallerLocale: en-US', '  InstallerSwitches:', '    Silent: /S')
        }
        $global:LASTEXITCODE = $code
    }
    $NA = -1978335216   # 0x8A150010 no applicable installer
    function Clear-CallLog { $script:calls.Clear() }
    function Has($a, $flag) { [array]::IndexOf([string[]]$a, $flag) -ge 0 }
    function ValueOf($a, $flag) { $i = [array]::IndexOf([string[]]$a, $flag); if ($i -ge 0) { $a[$i + 1] } else { $null } }
    $proj = Join-Path $tmpRoot 'dl'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null

    # --- without -FamilyPin first: the family helpers must not be called (their shadows throw) ---
    function Get-Win32ToolkitInstallerFamily { throw 'Get-Win32ToolkitInstallerFamily must not be called without -FamilyPin' }
    function Test-Win32ToolkitWingetNoApplicableInstaller { throw 'Test-Win32ToolkitWingetNoApplicableInstaller must not be called without -FamilyPin' }
    Clear-CallLog; $script:answer = { param([string[]]$A) 0 }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -Scope machine -InstallerType msi -Locale en-US 6>$null 3>$null
    $dlDir = Join-Path $proj 'Sandbox\OldVersion'
    $expectedArgs = @('download', '--id', 'Acme.App', '--download-directory', $dlDir, '--accept-source-agreements', '--accept-package-agreements',
        '--version', '1.2.3', '--architecture', 'x64', '--scope', 'machine', '--installer-type', 'msi', '--locale', 'en-US')
    if ($script:calls.Count -eq 1 -and ($script:calls[0] -join '|') -eq ($expectedArgs -join '|')) { Ok 'no -FamilyPin: byte-identical winget arguments (scope, installer-type, locale pins as before)' }
    else { Bad "args: $(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ')" }
    if ($r.Family -eq '' -and @($r.TriedTypes).Count -eq 0 -and $r.ScopeRelaxed -eq $false -and $r.UsedFallback -eq $false -and $r.RequestedInstallerType -eq 'msi' -and
        $r.ManifestInstallerType -eq 'msi' -and $r.ManifestProductCode -eq 'Acme App' -and $r.Scope -eq 'machine' -and $r.Locale -eq 'en-US' -and $r.InstallerType -eq 'msi') { Ok 'no -FamilyPin: Family '''', TriedTypes @(), ScopeRelaxed false; manifest type, quote-stripped ProductCode, scope, locale returned' }
    else { Bad "fields: $($r | ConvertTo-Json -Compress)" }
    Clear-CallLog; $script:answer = { param([string[]]$A) if ((Has $A '--installer-type') -or (Has $A '--scope')) { 1 } else { 0 } }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -Scope machine -InstallerType msi 6>$null 3>$null
    if ($script:calls.Count -eq 2 -and -not (Has $script:calls[1] '--installer-type') -and -not (Has $script:calls[1] '--scope') -and $r.UsedFallback -eq $true -and $r.Family -eq '') { Ok 'no -FamilyPin: the old unpinned retry still happens (UsedFallback true)' }
    else { Bad "fallback: calls $($script:calls.Count) used $($r.UsedFallback)" }

    # --- with -FamilyPin: the real family helpers ---
    . (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
    . (Join-Path $repo 'Private\Test-Win32ToolkitWingetNoApplicableInstaller.ps1')

    Clear-CallLog; $script:answer = { param([string[]]$A) 0 }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -InstallerType nullsoft -FamilyPin 6>$null 3>$null
    if ($script:calls.Count -eq 1 -and (ValueOf $script:calls[0] '--installer-type') -eq 'nullsoft' -and -not (Has $script:calls[0] '--scope') -and -not (Has $script:calls[0] '--locale')) { Ok '-FamilyPin: --installer-type nullsoft, no --scope, no --locale' }
    else { Bad "pin: $(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ')" }
    if ($r.Family -eq 'exe' -and (@($r.TriedTypes) -join ',') -eq 'nullsoft' -and $r.ScopeRelaxed -eq $false -and $r.UsedFallback -eq $false -and $r.RequestedInstallerType -eq 'nullsoft' -and $r.ManifestInstallerType -eq 'nullsoft') { Ok '-FamilyPin return fields: Family exe, TriedTypes, ScopeRelaxed false, UsedFallback false' }
    else { Bad "pin fields: $($r | ConvertTo-Json -Compress)" }

    Clear-CallLog; $script:answer = { param([string[]]$A) if ((ValueOf $A '--installer-type') -eq 'nullsoft') { $NA } else { 0 } }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -InstallerType nullsoft -FamilyPin 6>$null 3>$null
    $types = @($script:calls | ForEach-Object { ValueOf $_ '--installer-type' })
    if (($types -join ',') -eq 'nullsoft,burn' -and (@($r.TriedTypes) -join ',') -eq 'nullsoft,burn' -and $r.ManifestInstallerType -eq 'burn' -and $r.Family -eq 'exe') { Ok 'the family order: nullsoft no-applicable -> burn (same family), TriedTypes nullsoft,burn' }
    else { Bad "family order: $($types -join ',')" }
    if (@($script:calls | Where-Object { -not (Has $_ '--installer-type') }).Count -eq 0) { Ok 'no unpinned retry: every call carries --installer-type' } else { Bad 'an unpinned call was made' }

    # The Git worked case: a user-scope inno package, the baseline ships machine scope only.
    $script:cacheRoot = Join-Path $tmpRoot 'cache'
    New-Item -ItemType Directory -Path $script:cacheRoot -Force | Out-Null
    Clear-CallLog; $script:answer = { param([string[]]$A) if ((ValueOf $A '--scope') -eq 'user') { $NA } else { 0 } }
    $warn = @(); $iv = $null
    $r = Download-OldVersionInstaller -AppId 'Git.Git' -Version '2.33.0' -ProjectPath $proj -Architecture x64 -Scope user -InstallerType inno -FamilyPin -WarningVariable warn -InformationVariable iv 6>$null 3>$null
    # The fallback step is announced on the host next to winget's own 'No applicable installer found' line
    # (re-verification 2026-10-21, B1), with the scope of the attempt that found nothing.
    $fb = @($iv | ForEach-Object { "$($_.MessageData)" } | Where-Object { $_ -like 'winget offers no*' })
    if ($fb.Count -eq 1 -and $fb[0] -ceq "winget offers no user-scope 'inno' installer for 'Git.Git' v2.33.0 (the line above is winget's); trying 'inno' without a scope.") { Ok "soft scope: one host line 'no user-scope ''inno'' installer ... trying ''inno'' without a scope'" }
    else { Bad "soft scope host lines: [$($fb -join ' | ')]" }
    if ($script:calls.Count -eq 2 -and (ValueOf $script:calls[0] '--scope') -eq 'user' -and (ValueOf $script:calls[0] '--installer-type') -eq 'inno' -and
        -not (Has $script:calls[1] '--scope') -and (ValueOf $script:calls[1] '--installer-type') -eq 'inno') { Ok 'soft scope: --scope user --installer-type inno -> no-applicable -> --installer-type inno without --scope' }
    else { Bad "soft: $(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ')" }
    if ($r.ScopeRelaxed -eq $true -and $r.Scope -eq 'machine' -and (@($r.TriedTypes) -join ',') -eq 'inno' -and @($warn).Count -eq 1 -and "$($warn[0])" -eq "v2.33.0 has no user-scope inno installer; the baseline uses winget's choice of scope for inno.") { Ok 'soft scope: success with ScopeRelaxed, one warning (spec text)' }
    else { Bad "soft result: relaxed=$($r.ScopeRelaxed) warn=$(@($warn) -join ' | ')" }
    $keys = @(Get-ChildItem -LiteralPath (Join-Path $script:cacheRoot 'Git.Git\2.33.0') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    if ($keys -contains 'x64_any_inno_any' -and -not ($keys | Where-Object { $_ -like '*_user_*' })) { Ok "cache key per tried (type, scope): '...x64_any_inno_any' (never the user key)" } else { Bad "keys: $($keys -join ',')" }
    Clear-CallLog
    $r = Download-OldVersionInstaller -AppId 'Git.Git' -Version '2.33.0' -ProjectPath $proj -Architecture x64 -Scope user -InstallerType inno -FamilyPin 6>$null 3>$null
    if ($script:calls.Count -eq 1 -and (ValueOf $script:calls[0] '--scope') -eq 'user' -and $r.ScopeRelaxed -eq $true) { Ok 'second run: the scoped attempt still asks winget, the relaxed attempt is served from its own cache key' } else { Bad "cache reuse: $($script:calls.Count)" }
    $script:cacheRoot = $null

    # The staging folder (L21, spec 2.12 legacy rule): the attempts never touch Sandbox\OldVersion; only a success replaces it.
    $ovDir = Join-Path $proj 'Sandbox\OldVersion'
    $attemptDir = "$ovDir.attempt"
    $snapshot = { @(Get-ChildItem -LiteralPath $ovDir -Force -File | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ';' }
    $before = & $snapshot
    if ($before -match 'Acme\.App\.installer\.yaml=' -and -not (Test-Path -LiteralPath $attemptDir)) { Ok 'after a successful -FamilyPin download: Sandbox\OldVersion holds it, no staging folder left' } else { Bad "before: '$before' attempt=$(Test-Path -LiteralPath $attemptDir)" }
    if (@($script:calls | Where-Object { (ValueOf $_ '--download-directory') -ne $attemptDir }).Count -eq 0) { Ok "-FamilyPin downloads into the staging folder '<Sandbox\OldVersion>.attempt'" } else { Bad "download dirs: $(@($script:calls | ForEach-Object { ValueOf $_ '--download-directory' }) -join ',')" }

    Clear-CallLog; $script:answer = { param([string[]]$A) $NA }
    $err = $null; $iv = $null
    try { $null = Download-OldVersionInstaller -AppId 'Git.Git' -Version '2.33.0' -ProjectPath $proj -Architecture x64 -Scope user -InstallerType inno -FamilyPin -InformationVariable iv 6>$null 3>$null } catch { $err = $_ }
    $fb = @($iv | ForEach-Object { "$($_.MessageData)" } | Where-Object { $_ -like 'winget offers no*' } | ForEach-Object { ($_ -replace "^winget offers (.+?) for 'Git\.Git' v2\.33\.0 \(the line above is winget's\); (.+)\.$", '$1 -> $2') })
    $fbExp = @("no user-scope 'inno' installer -> trying 'inno' without a scope", "no 'inno' installer -> trying 'burn' (same technology family, user scope)",
               "no user-scope 'burn' installer -> trying 'burn' without a scope", "no 'burn' installer -> trying 'nullsoft' (same technology family, user scope)",
               "no user-scope 'nullsoft' installer -> trying 'nullsoft' without a scope", "no 'nullsoft' installer -> trying 'exe' (same technology family, user scope)",
               "no user-scope 'exe' installer -> trying 'exe' without a scope")
    if (($fb -join ' || ') -ceq ($fbExp -join ' || ')) { Ok 'every attempt no-applicable: one host line per fallback step (7 for 8 attempts), none after the last (the W32T error explains)' }
    else { Bad "fallback host lines: [$($fb -join ' || ')]" }
    $tried = @($script:calls | ForEach-Object { "$(ValueOf $_ '--installer-type')/$(ValueOf $_ '--scope')" })
    if ($err -and $err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable') { Ok 'every type no-applicable (with and without scope) -> W32T.InstallerVariantUnavailable' } else { Bad "fqid: $($err.FullyQualifiedErrorId) $($err.Exception.Message)" }
    if (($tried -join ',') -eq 'inno/user,inno/,burn/user,burn/,nullsoft/user,nullsoft/,exe/user,exe/') { Ok 'each type tried with and then without the scope' } else { Bad "tried: $($tried -join ',')" }
    $expMsg = "winget offers no vendor EXE installer for Git.Git v2.33.0 (x64); tried: inno/user, burn/user, nullsoft/user, exe/user, each scope also relaxed. The Update baseline cannot use that technology at this version: pick a version that ships it (-SpecificVersion) or another technology (-BaselineInstallerType)."
    if ($err -and $err.Exception.Message -eq $expMsg) { Ok 'the message lists inno/user... and says each scope was also relaxed' } else { Bad "msg: $($err.Exception.Message)" }
    if ((& $snapshot) -eq $before -and -not (Test-Path -LiteralPath $attemptDir)) { Ok 'unavailable: Sandbox\OldVersion is left exactly as it was (the previous baseline), the staging folder is gone' }
    else { Bad "unavailable touched OldVersion: '$(& $snapshot)' vs '$before' attempt=$(Test-Path -LiteralPath $attemptDir)" }

    Clear-CallLog; $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.0' -ProjectPath $proj -InstallerType wix -FamilyPin 6>$null 3>$null } catch { $err = $_ }
    if ($err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and $err.Exception.Message -like 'winget offers no MSI installer for Acme.App v1.0 (any architecture); tried: wix, msi. The Update*' -and $err.Exception.Message -notmatch 'relaxed') { Ok 'no scope pinned: tried wix, msi (no /scope, no "relaxed")' }
    else { Bad "noscope msg: $($err.Exception.Message)" }

    Clear-CallLog; $script:answer = { param([string[]]$A) -1978335224 }   # 0x8A150008 download failed
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.0' -ProjectPath $proj -InstallerType nullsoft -FamilyPin 6>$null 3>$null } catch { $err = $_ }
    if ($err -and $err.FullyQualifiedErrorId -notlike 'W32T.*' -and $err.Exception.Message -like 'winget download exited with code -1978335224*' -and $script:calls.Count -eq 1) { Ok 'any other winget code -> a plain error, no further attempt' }
    else { Bad "other: $($err.FullyQualifiedErrorId) calls $($script:calls.Count)" }
    if ((& $snapshot) -eq $before -and -not (Test-Path -LiteralPath $attemptDir)) { Ok 'a plain error leaves Sandbox\OldVersion untouched too; the staging folder is gone' } else { Bad 'plain error touched OldVersion or left the staging folder' }

    # A stale file of an earlier run in the staging folder never reaches the baseline; a success replaces OldVersion whole.
    New-Item -ItemType Directory -Path $attemptDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $attemptDir 'stale-attempt.exe') -Value 'x'
    Set-Content -LiteralPath (Join-Path $ovDir 'stale-baseline.txt') -Value 'x'
    Clear-CallLog; $script:answer = { param([string[]]$A) 0 }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -InstallerType wix -FamilyPin 6>$null 3>$null
    $names = @(Get-ChildItem -LiteralPath $ovDir -Force | ForEach-Object Name | Sort-Object)
    if (($names -join ',') -eq 'Acme.App.installer.yaml,app.msi' -and $r.InstallerName -eq 'app.msi' -and $r.InstallerPath -eq (Join-Path $ovDir 'app.msi') -and -not (Test-Path -LiteralPath $attemptDir)) { Ok 'success: OldVersion holds exactly the new download (old and stale staging files gone), InstallerPath points into OldVersion' }
    else { Bad "swap: $($names -join ',') path=$($r.InstallerPath) attempt=$(Test-Path -LiteralPath $attemptDir)" }

    # A locked file in OldVersion: the swap is a hard error (never a mixed baseline), and the staging folder is removed.
    $lockFile = Join-Path $ovDir 'locked.bin'
    [System.IO.File]::WriteAllBytes($lockFile, [byte[]](1, 2, 3))
    $lock = [System.IO.File]::Open($lockFile, 'Open', 'Read', 'None')
    try {
        Clear-CallLog; $err = $null
        try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -InstallerType wix -FamilyPin 6>$null 3>$null } catch { $err = $_ }
        if ($err -and $err.Exception.Message -like "Could not clear $ovDir (files in use?*" -and $script:calls.Count -eq 1 -and -not (Test-Path -LiteralPath $attemptDir)) { Ok 'OldVersion cannot be cleared after the download -> the old hard error, the staging folder is removed' }
        else { Bad "locked: $($err.Exception.Message) calls $($script:calls.Count) attempt=$(Test-Path -LiteralPath $attemptDir)" }
    }
    finally { $lock.Dispose() }

    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.0' -ProjectPath $proj -FamilyPin 6>$null 3>$null } catch { $err = $_ }
    if ($err -and $err.Exception.Message -like '-FamilyPin requires -InstallerType*') { Ok '-FamilyPin without -InstallerType -> error' } else { Bad 'no error without -InstallerType' }

    # == [3] Invoke-Win32ToolkitFinalize ==================================================================
    Write-Host '[3] Invoke-Win32ToolkitFinalize passes -BaselineInstallerType only when bound' -ForegroundColor Cyan
    . (Join-Path $repo 'Private\Invoke-Win32ToolkitFinalize.ps1')
    # C-9 (speed-up PR 4): Finalize releases a capture pre-warm right after the capture; inert (emits nothing, no pre-warm).
    function Wait-Win32ToolkitHyperVTeardown { param($VMName, $ReleaseOwner, [switch]$Prewarm) }
    function Assert-Win32ToolkitPackageReady { param($ProjectPath, $Stage, [switch]$AllowLegacyScript) [pscustomobject]@{ Ready = $true } }
    function Get-Win32ToolkitTestBackend { 'Sandbox' }
    $script:docCalls = [System.Collections.Generic.List[hashtable]]::new()
    function New-TargetedDocumentation {
        param($ProjectPath, $ProjectName, $AppInfo, $Backend, $BasePath)
        $h = @{}; foreach ($k in $PSBoundParameters.Keys) { $h[$k] = $PSBoundParameters[$k] }
        $script:docCalls.Add($h); $false
    }
    # C-9: the capture run-log helpers Finalize calls (H5-F5/H7-F1).
    function Initialize-Win32ToolkitTestRunLog { param($ProjectPath, $Scenario, $Family) $null }
    function Save-Win32ToolkitTestRunLog { param($Run) $null }
    function Wait-Win32ToolkitCollectedLog { param($ProjectPath, $TimeoutSeconds) $true }
    function Export-Win32ToolkitIntuneWin { param($ProjectPath, [switch]$PublishIntune, [switch]$PublishUpdate, [switch]$AllowLegacyScript, [switch]$NoPublishPrompt, [switch]$PassThru) }
    $script:testCalls = [System.Collections.Generic.List[hashtable]]::new()
    function Test-Win32ToolkitProject {
        param($ProjectPath, $Scenario, $SpecificVersion, $VersionsBack, $BaselineInstallerType, $BasePath)
        $h = @{}; foreach ($k in $PSBoundParameters.Keys) { $h[$k] = $PSBoundParameters[$k] }
        $script:testCalls.Add($h); $true
    }
    Invoke-Win32ToolkitFinalize -ProjectPath $proj -ProjectName 'P' -RunTest Update -UpdateVersionsBack 1 3>$null 6>$null
    if ($script:testCalls.Count -eq 1 -and -not $script:testCalls[0].ContainsKey('BaselineInstallerType') -and $script:testCalls[0]['VersionsBack'] -eq 1) { Ok 'unbound -> Test-Win32ToolkitProject gets no -BaselineInstallerType (its default Auto applies)' }
    else { Bad "unbound: $($script:testCalls | ConvertTo-Json -Compress)" }
    $script:testCalls.Clear()
    Invoke-Win32ToolkitFinalize -ProjectPath $proj -ProjectName 'P' -RunTest InstallUninstall, Update -UpdateSpecificVersion '8.8.9' -UpdateBaselineInstallerType Both 3>$null 6>$null
    $iu = @($script:testCalls | Where-Object { $_['Scenario'] -eq 'InstallUninstall' })
    $up = @($script:testCalls | Where-Object { $_['Scenario'] -eq 'Update' })
    if ($up.Count -eq 1 -and $up[0]['BaselineInstallerType'] -eq 'Both' -and $up[0]['SpecificVersion'] -eq '8.8.9') { Ok 'bound (Both) -> passed to the Update test' } else { Bad "bound: $($script:testCalls | ConvertTo-Json -Compress)" }
    if ($iu.Count -eq 1 -and -not $iu[0].ContainsKey('BaselineInstallerType')) { Ok 'never passed to the InstallUninstall test' } else { Bad 'passed to InstallUninstall' }
    $threw = $false
    try { Invoke-Win32ToolkitFinalize -ProjectPath $proj -ProjectName 'P' -RunTest Update -UpdateBaselineInstallerType 'zip' 3>$null 6>$null } catch { $threw = $true }
    if ($threw) { Ok "-UpdateBaselineInstallerType has the ValidateSet ('zip' rejected)" } else { Bad "'zip' accepted" }

    # The run's -BasePath reaches the capture and every test, where 'project:' dependencies are staged
    # (re-verification 2026-10-21, B3 #4: Finalize had no -BasePath, so both used the registry base folder).
    Write-Host '[3b] Invoke-Win32ToolkitFinalize -BasePath reaches New-TargetedDocumentation and Test-Win32ToolkitProject' -ForegroundColor Cyan
    $script:testCalls.Clear(); $script:docCalls.Clear()
    $baseB = Join-Path $tmpRoot 'BaseB'
    Invoke-Win32ToolkitFinalize -ProjectPath $proj -ProjectName 'P' -RunTest InstallUninstall, Update -UpdateVersionsBack 1 -BasePath $baseB 3>$null 6>$null
    if ($script:docCalls.Count -eq 1 -and $script:docCalls[0]['BasePath'] -eq $baseB) { Ok 'New-TargetedDocumentation gets -BasePath (the capture stages dependencies from it)' } else { Bad "capture args: $($script:docCalls | ConvertTo-Json -Compress)" }
    if ($script:testCalls.Count -eq 2 -and @($script:testCalls | Where-Object { $_['BasePath'] -eq $baseB }).Count -eq 2) { Ok 'both test scenarios get -BasePath' } else { Bad "test args: $($script:testCalls | ConvertTo-Json -Compress)" }
    $script:testCalls.Clear(); $script:docCalls.Clear()
    Invoke-Win32ToolkitFinalize -ProjectPath $proj -ProjectName 'P' -RunTest InstallUninstall 3>$null 6>$null
    if (-not $script:docCalls[0].ContainsKey('BasePath') -and -not $script:testCalls[0].ContainsKey('BasePath')) { Ok 'no -BasePath -> none passed (the callee resolves the configured base folder)' } else { Bad "unbound: $($script:docCalls | ConvertTo-Json -Compress) / $($script:testCalls | ConvertTo-Json -Compress)" }
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All BaselineFamily tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail BaselineFamily test(s) FAILED." -ForegroundColor Red; exit 1 }
