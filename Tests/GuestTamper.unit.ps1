<#
    Installer-identity PR 3 (L18, SV4): the guest-run tripwire - Get-Win32ToolkitProjectTripwire before the guest
    starts, Assert-Win32ToolkitProjectTripwire once it can no longer write.

      [1] helpers: nothing changed -> no error, no marker; a changed SupportFiles\AppConfig.json, a new file under
          Documentation\ (a forged TestResults.json), a swapped Files\ installer, a deleted file -> W32T.GuestTamper and
          Documentation\GuestTamper.json { On, Scenario, Files, Reason }; a change under Sandbox\ (logs) -> none; more
          than 20 changed files -> 20 listed; -Reason alone (the sandbox could not be confirmed closed) -> marker and
          error without comparing; the marker is BOM-less JSON; both helper files are ASCII-only.
      [2] fail-closed re-read and links: a project file locked when the run is checked -> W32T.GuestTamper ("could not
          be read again"), never a raw I/O error; a junction made under Documentation\ or under Sandbox\Logs\, and a file
          replaced by a symbolic link to an identical copy -> W32T.GuestTamper naming the link; a junction present before
          and unchanged -> recorded as 'LINK:<target>', never entered (its target may change: no error). The marker write
          never follows a link: Documentation\ replaced by a junction, Documentation\GuestTamper.json planted as a
          symbolic link to a host file or as a dangling link -> W32T.GuestTamper, the marker a real file in the project,
          nothing outside it written; a marker that cannot be written -> one warning, W32T.GuestTamper still thrown.
      The scenario part (the Update and InstallUninstall runs on Hyper-V and Windows Sandbox, the watched-Sandbox refusal)
      is in Tests\UpdateProofRun.unit.ps1 [4].

    Fixtures under %TEMP%. Run:  pwsh -File Tests\GuestTamper.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Get-Win32ToolkitProjectTripwire', 'Assert-Win32ToolkitProjectTripwire', 'ConvertTo-Win32ToolkitSafeText') { . (Join-Path $repo "Private\$f.ps1") }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32trip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
function New-TripProject([string]$Name) {
    $p = Join-Path $root $Name
    foreach ($d in 'Files', 'SupportFiles', 'Documentation', 'Sandbox\Logs') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    [IO.File]::WriteAllText((Join-Path $p 'Files\setup.msi'), 'installer', $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), '{"App":{}}', $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), '# script', $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'Sandbox\Logs\UpdateAssertions.log'), 'x', $utf8)
    $p
}
function Get-Thrown([scriptblock]$A) { try { & $A; '' } catch { $_.FullyQualifiedErrorId + '|' + $_.Exception.Message } }

try {
    Write-Host '[1] the tripwire helpers' -ForegroundColor Cyan
    $p = New-TripProject 'clean'
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $p
    if ($t.Count -eq 3 -and -not $t.ContainsKey('Sandbox\Logs\UpdateAssertions.log') -and $t['Files\setup.msi'] -cmatch '^[0-9A-F]{64}$') { Ok 'every file outside Sandbox\ hashed (Sandbox\ excluded)' } else { Bad "snapshot: $($t.Keys -join ',')" }
    [IO.File]::AppendAllText((Join-Path $p 'Sandbox\Logs\UpdateAssertions.log'), 'more')
    [IO.File]::WriteAllText((Join-Path $p 'Sandbox\Logs\new.log'), 'x', $utf8)
    $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $p -Before $t -Scenario Update }
    if (-not $r -and -not (Test-Path -LiteralPath (Join-Path $p 'Documentation\GuestTamper.json'))) { Ok 'changes under Sandbox\ (the run''s logs) -> no error, no marker' } else { Bad "sandbox change: $r" }

    foreach ($c in @(
            @{ L = 'a changed SupportFiles\AppConfig.json'; A = { param($q) [IO.File]::WriteAllText((Join-Path $q 'SupportFiles\AppConfig.json'), '{"App":{"x":1}}', $utf8) }; F = 'SupportFiles\AppConfig.json' }
            @{ L = 'a forged Documentation\TestResults.json'; A = { param($q) [IO.File]::WriteAllText((Join-Path $q 'Documentation\TestResults.json'), '[]', $utf8) }; F = 'Documentation\TestResults.json' }
            @{ L = 'a swapped Files\ installer'; A = { param($q) [IO.File]::WriteAllText((Join-Path $q 'Files\setup.msi'), 'evil', $utf8) }; F = 'Files\setup.msi' }
            @{ L = 'a deleted deploy script'; A = { param($q) Remove-Item -LiteralPath (Join-Path $q 'Invoke-AppDeployToolkit.ps1') }; F = 'Invoke-AppDeployToolkit.ps1' }
        )) {
        $q = New-TripProject ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
        & $c.A $q
        $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update }
        $mf = Join-Path $q 'Documentation\GuestTamper.json'
        $m = if (Test-Path -LiteralPath $mf) { Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json } else { $null }
        if ($r -like 'W32T.GuestTamper|*' -and $r -match 'No test result was recorded' -and $m -and @($m.Files) -contains $c.F -and $m.Scenario -eq 'Update' -and $m.Reason -match 'changed 1 project file') {
            Ok "$($c.L) -> W32T.GuestTamper and the marker names $($c.F)"
        } else { Bad "$($c.L): $r / $($m | ConvertTo-Json -Compress)" }
        $bytes = [IO.File]::ReadAllBytes($mf)
        if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) { Ok "$($c.L): the marker is BOM-less" } else { Bad 'marker has a BOM' }
    }
    $q = New-TripProject 'many'
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
    1..25 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $q ('Documentation\f{0:D2}.txt' -f $_)), 'x', $utf8) }
    $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario SiblingCapture }
    $m = Get-Content -LiteralPath (Join-Path $q 'Documentation\GuestTamper.json') -Raw | ConvertFrom-Json
    if ($r -like 'W32T.GuestTamper|*' -and @($m.Files).Count -eq 20 -and $r -match '25 in all' -and $m.Scenario -eq 'SiblingCapture') { Ok '25 new files -> 20 listed in the marker, the message says 25' } else { Bad "many: $(@($m.Files).Count) $r" }
    $q = New-TripProject 'reason'
    $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Scenario Update -Reason 'the sandbox could not be confirmed closed' }
    $m = Get-Content -LiteralPath (Join-Path $q 'Documentation\GuestTamper.json') -Raw | ConvertFrom-Json
    if ($r -like 'W32T.GuestTamper|*the sandbox could not be confirmed closed*' -and @($m.Files).Count -eq 0 -and $m.Reason -eq 'the sandbox could not be confirmed closed') { Ok '-Reason alone: marker + W32T.GuestTamper without comparing' } else { Bad "reason: $r" }
    $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Scenario Update }
    if ($r -like '*ArgumentException*' -or $r -match 'needs -Before or -Reason') { Ok 'neither -Before nor -Reason -> an argument error (a programming error)' } else { Bad "no args: $r" }
    foreach ($f in 'Get-Win32ToolkitProjectTripwire', 'Assert-Win32ToolkitProjectTripwire') {
        if (@([IO.File]::ReadAllBytes((Join-Path $repo "Private\$f.ps1")) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok "$f.ps1 is ASCII-only" } else { Bad "$f.ps1 has non-ASCII bytes" }
    }

    Write-Host '[2] fail-closed re-read and links' -ForegroundColor Cyan
    # A file the host cannot read again when the run is checked: the project cannot be shown unchanged -> tamper.
    $q = New-TripProject 'locked'
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
    $lock = [IO.File]::Open((Join-Path $q 'SupportFiles\AppConfig.json'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update } } finally { $lock.Dispose() }
    $mf = Join-Path $q 'Documentation\GuestTamper.json'
    $m = if (Test-Path -LiteralPath $mf) { Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json } else { $null }
    if ($r -like 'W32T.GuestTamper|*could not be read again*' -and $m -and $m.Reason -match '^the project could not be read again after the guest run' -and @($m.Files).Count -eq 0) { Ok 'a project file locked at the check -> W32T.GuestTamper (fail closed), never a raw I/O error' } else { Bad "locked: $r" }

    # Links: recorded by their target, never followed; a new link anywhere (Sandbox\ included) is a change.
    $outside = Join-Path $root 'outside'
    $null = New-Item -ItemType Directory -Path $outside -Force
    [IO.File]::WriteAllText((Join-Path $outside 'x.txt'), 'outside', $utf8)
    foreach ($c in @(
            @{ L = 'a junction made under Documentation\'; Rel = 'Documentation\linked' }
            @{ L = 'a junction made under Sandbox\Logs\ (the host writes there after the run)'; Rel = 'Sandbox\Logs\linked' }
        )) {
        $q = New-TripProject ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
        $null = New-Item -ItemType Junction -Path (Join-Path $q $c.Rel) -Target $outside
        $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update }
        $mf = Join-Path $q 'Documentation\GuestTamper.json'
        $m = if (Test-Path -LiteralPath $mf) { Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json } else { $null }
        if ($r -like 'W32T.GuestTamper|*' -and $m -and @($m.Files) -contains $c.Rel) { Ok "$($c.L) -> W32T.GuestTamper naming the link" } else { Bad "$($c.L): $r" }
    }
    $q = New-TripProject 'symlink'
    [IO.File]::WriteAllText((Join-Path $root 'same.msi'), 'installer', $utf8)
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
    Remove-Item -LiteralPath (Join-Path $q 'Files\setup.msi')
    $made = $true
    try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $q 'Files\setup.msi') -Target (Join-Path $root 'same.msi') -ErrorAction Stop } catch { $made = $false }
    if ($made) {
        $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update }
        $m = Get-Content -LiteralPath (Join-Path $q 'Documentation\GuestTamper.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($r -like 'W32T.GuestTamper|*' -and @($m.Files) -contains 'Files\setup.msi') { Ok 'a file replaced by a symbolic link to an identical copy -> W32T.GuestTamper (the link is not followed)' } else { Bad "symlink: $r" }
    }
    else { Write-Host '  SKIP: symbolic links cannot be created here (needs an elevated session or Developer Mode)' -ForegroundColor Yellow }
    # The marker write after a detection never follows a link the guest left (the session is elevated: a followed
    # link is a write anywhere on the host). Each case fails on a helper that writes through the link.
    $markerOut = Join-Path $root 'marker-outside'
    $null = New-Item -ItemType Directory -Path $markerOut -Force
    [IO.File]::WriteAllText((Join-Path $markerOut 'keep.txt'), 'keep', $utf8)
    $q = New-TripProject 'docjunction'
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
    Remove-Item -LiteralPath (Join-Path $q 'Documentation') -Recurse -Force
    $null = New-Item -ItemType Junction -Path (Join-Path $q 'Documentation') -Target $markerOut
    $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update }
    $docItem = Get-Item -LiteralPath (Join-Path $q 'Documentation') -Force -ErrorAction SilentlyContinue
    $m = Get-Content -LiteralPath (Join-Path $q 'Documentation\GuestTamper.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    $outNames = @(Get-ChildItem -LiteralPath $markerOut -Force -Name)
    if ($r -like 'W32T.GuestTamper|*' -and $docItem -and -not $docItem.LinkTarget -and $m -and @($m.Files) -contains 'Documentation' -and
        $outNames.Count -eq 1 -and $outNames[0] -eq 'keep.txt' -and [IO.File]::ReadAllText((Join-Path $markerOut 'keep.txt')) -eq 'keep') {
        Ok 'Documentation\ replaced by a junction -> W32T.GuestTamper, the marker in a real Documentation\ folder, the junction target unchanged'
    } else { Bad "doc junction: '$r' link '$($docItem.LinkTarget)' outside: $($outNames -join ',')" }
    $q = New-TripProject 'markerlink'
    $victim = Join-Path $root 'host-victim.txt'
    [IO.File]::WriteAllText($victim, 'host data', $utf8)
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
    $made = $true
    try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $q 'Documentation\GuestTamper.json') -Target $victim -ErrorAction Stop } catch { $made = $false }
    if ($made) {
        $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update }
        $mItem = Get-Item -LiteralPath (Join-Path $q 'Documentation\GuestTamper.json') -Force -ErrorAction SilentlyContinue
        $m = if ($mItem -and -not $mItem.LinkTarget) { Get-Content -LiteralPath $mItem.FullName -Raw | ConvertFrom-Json } else { $null }
        if ($r -like 'W32T.GuestTamper|*' -and $m -and @($m.Files) -contains 'Documentation\GuestTamper.json' -and [IO.File]::ReadAllText($victim) -ceq 'host data') {
            Ok 'Documentation\GuestTamper.json planted as a symbolic link to a host file -> W32T.GuestTamper, the marker a real file in the project, the host file unchanged'
        } else { Bad "marker link: '$r' link '$($mItem.LinkTarget)' victim '$([IO.File]::ReadAllText($victim))'" }
        # A dangling link: a followed write would create a file wherever the guest pointed it.
        $q = New-TripProject 'markerdangling'
        $nowhere = Join-Path $root 'created-by-marker.txt'
        $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $q 'Documentation\GuestTamper.json') -Target $nowhere -Force
        $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update }
        $mItem = Get-Item -LiteralPath (Join-Path $q 'Documentation\GuestTamper.json') -Force -ErrorAction SilentlyContinue
        if ($r -like 'W32T.GuestTamper|*' -and $mItem -and -not $mItem.LinkTarget -and -not (Test-Path -LiteralPath $nowhere)) {
            Ok 'Documentation\GuestTamper.json planted as a dangling symbolic link -> W32T.GuestTamper, nothing created outside the project'
        } else { Bad "dangling marker link: '$r' created outside: $(Test-Path -LiteralPath $nowhere)" }
    }
    else { Write-Host '  SKIP: symbolic links cannot be created here (needs an elevated session or Developer Mode)' -ForegroundColor Yellow }
    # A marker that cannot be written (Documentation is a file now) is a warning; W32T.GuestTamper is still thrown.
    $q = New-TripProject 'docfile'
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
    Remove-Item -LiteralPath (Join-Path $q 'Documentation') -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $q 'Documentation'), 'not a folder', $utf8)
    $warned = $null
    $r = ''
    try { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update -WarningVariable warned -WarningAction SilentlyContinue }
    catch { $r = $_.FullyQualifiedErrorId + '|' + $_.Exception.Message }
    if ($r -like 'W32T.GuestTamper|*' -and @($warned).Count -eq 1 -and "$($warned[0])" -match 'could not be written' -and [IO.File]::ReadAllText((Join-Path $q 'Documentation')) -eq 'not a folder') {
        Ok 'a marker that cannot be written (Documentation is a file) -> one warning, W32T.GuestTamper still thrown'
    } else { Bad "doc file: '$r' warnings $(@($warned).Count)" }
    $q = New-TripProject 'prelink'
    $null = New-Item -ItemType Junction -Path (Join-Path $q 'Documentation\pre') -Target $outside
    $t = Get-Win32ToolkitProjectTripwire -ProjectPath $q
    [IO.File]::WriteAllText((Join-Path $outside 'x.txt'), 'changed outside the project', $utf8)
    [IO.File]::WriteAllText((Join-Path $outside 'y.txt'), 'new outside the project', $utf8)
    $r = Get-Thrown { Assert-Win32ToolkitProjectTripwire -ProjectPath $q -Before $t -Scenario Update }
    $behind = @($t.Keys | Where-Object { $_ -like 'Documentation\pre\*' })
    if (-not $r -and [string]$t['Documentation\pre'] -like 'LINK:*outside' -and $behind.Count -eq 0) { Ok "a link present before and unchanged -> recorded as 'LINK:<target>', never entered (no error when its target changes)" } else { Bad "prelink: '$r' value '$($t['Documentation\pre'])' behind $($behind -join ',')" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All GuestTamper tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail GuestTamper test(s) FAILED." -ForegroundColor Red; exit 1 }
