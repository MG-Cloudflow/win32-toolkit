<#
    Installer-identity PR 3b (spec 2.14.5, L19, L20, SV4): a sibling capture's guest ran an installer nobody vetted, so
    its output comes back into a quarantine through an allow-list, and nothing of the project's sibling work enters
    another guest.

      [1] Copy-Win32ToolkitResultsFromGuest -AllowedEntry / -MaxEntryBytes / -MaxTotalBytes: exact allowed names
          extracted; a name off the list refused (one warning, not extracted); an entry over the size cap refused before
          extraction; the total cap stops the extraction; '..' entries still refused; refusals are not a "torn
          transfer"; -Destination honoured; absolute entry names (C:/, /, //server) refused by the anchored allow-list.
          Without the parameters every entry is extracted as before. A crafted zip whose
          header understates a stored entry's length (declares 10 bytes, holds 1 MB) is refused BEFORE extraction by
          -MaxEntryBytes and stops the extraction under -MaxTotalBytes (the stored length counts); a deflated entry that
          understates its length is never written past its declared length (the runtime behaviour the caps rely on).
          The caps bound the transfer too: a file over -MaxEntryBytes in the guest tree is never zipped nor copied (one
          warning); the guest stops zipping before -MaxTotalBytes (the files left out reported once); a zip the guest
          reports larger than -MaxTotalBytes plus its structure is refused before the copy, one that is larger on the
          host after it, and one with no reported length (fail closed); 25 guest failures -> 20 named, then a count.
      [2] New-Win32ToolkitProjectZip leaves Sandbox\Siblings and Sandbox\SiblingRuns out (and Sandbox\Logs\Runs, as
          before); everything else is in.

    Shadows: Invoke-Command runs the "guest" scriptblock locally against a fixture tree; Copy-Item drops -FromSession.
    Run:  pwsh -File Tests\GuestIsolation.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-Command and Copy-Item are shadowed on purpose: no VM, no session')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Copy-Win32ToolkitResultsFromGuest.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitProjectZip.ps1')

function Invoke-Command {
    [CmdletBinding()]
    param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest)
    $null = $Session, $Rest
    & $ScriptBlock @ArgumentList
}
function Copy-Item {
    [CmdletBinding()]
    param($FromSession, $ToSession, $Path, $Destination, [switch]$Force, [Parameter(ValueFromRemainingArguments)]$Rest)
    $null = $FromSession, $ToSession, $Force, $Rest
    # Every transfer is recorded with the entries of the zip it carried (what crossed from the guest to the host).
    $za = [IO.Compression.ZipFile]::OpenRead($Path)
    try { $script:transfers.Add([pscustomobject]@{ Bytes = (Get-Item -LiteralPath $Path).Length; Entries = @($za.Entries | ForEach-Object FullName) }) } finally { $za.Dispose() }
    Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Force
}
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
$script:transfers = [System.Collections.Generic.List[object]]::new()
$script:tmp = [System.Collections.Generic.List[string]]::new()
function New-TempDir { $p = Join-Path ([IO.Path]::GetTempPath()) ('gi_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $script:tmp.Add($p); $null = New-Item -ItemType Directory -Path $p -Force; $p }
$key = 'nullsoft-8.9.8'
$allow = '^Out/(Sibling(Pre|Install|Capture|Probe|Done)_' + [regex]::Escape($key) + '\.json|SiblingCopy_' + [regex]::Escape($key) + '_(uninstaller|main)\.exe|Logs/[A-Za-z0-9_.-]{1,64}\.log)$'

try {
    # == [1] the quarantine copy-back =======================================================================
    Write-Host '[1] the copy-back allow-list and caps' -ForegroundColor Cyan
    $guest = New-TempDir
    $null = New-Item -ItemType Directory -Path (Join-Path $guest 'Out\Logs') -Force
    foreach ($n in "SiblingPre_$key.json", "SiblingInstall_$key.json", "SiblingCapture_$key.json", "SiblingDone_$key.json", "SiblingCopy_${key}_uninstaller.exe") { Set-Content -LiteralPath (Join-Path $guest "Out\$n") -Value '{}' }
    Set-Content -LiteralPath (Join-Path $guest 'Out\Logs\Install.log') -Value 'log'
    Set-Content -LiteralPath (Join-Path $guest 'Out\evil.ps1') -Value 'Remove-Item C:\ -Recurse'
    Set-Content -LiteralPath (Join-Path $guest 'Out\SiblingPre_other-key.json') -Value '{}'
    [IO.File]::WriteAllBytes((Join-Path $guest "Out\SiblingProbe_$key.json"), [byte[]]::new(5000))
    $q = New-TempDir
    $w = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath (Join-Path $guest 'Out\*') -Destination $q -GuestRoot $guest -AllowedEntry $allow -MaxEntryBytes 4096 -MaxTotalBytes 1MB -WarningVariable w 3>$null
    $got = @(Get-ChildItem -LiteralPath $q -Recurse -File | ForEach-Object { $_.FullName.Substring($q.Length + 1) } | Sort-Object)
    $want = @("Out\Logs\Install.log", "Out\SiblingCapture_$key.json", "Out\SiblingCopy_${key}_uninstaller.exe", "Out\SiblingDone_$key.json", "Out\SiblingInstall_$key.json", "Out\SiblingPre_$key.json") | Sort-Object
    if (($got -join ',') -ceq ($want -join ',')) { Ok 'only the allowed names of this capture key were extracted, into -Destination' } else { Bad "extracted: $($got -join ', ')" }
    $ws = @($w | ForEach-Object { "$_" })
    if (@($ws | Where-Object { $_ -match 'not on the allow-list' -and $_ -match 'evil\.ps1' }).Count -eq 1 -and @($ws | Where-Object { $_ -match 'not on the allow-list' -and $_ -match 'other-key' }).Count -eq 1) { Ok "a name off the list (another file, another capture's key) -> one warning each, not extracted" } else { Bad "warnings: $($ws -join ' | ')" }
    if (@($ws | Where-Object { $_ -match "SiblingProbe_$([regex]::Escape($key))\.json \(5000 bytes, over the 4096-byte cap: not sent\)" }).Count -eq 1 -and
        @($script:transfers[-1].Entries | Where-Object { $_ -like 'Out/SiblingProbe_*' }).Count -eq 0) { Ok 'a file over -MaxEntryBytes is never zipped in the guest (one warning; it never crosses to the host)' } else { Bad "size: $($ws -join ' | ')" }
    if (@($ws | Where-Object { $_ -match 'mismatch' }).Count -eq 0) { Ok 'refusals are not reported as a torn transfer' } else { Bad 'mismatch warning' }

    $q2 = New-TempDir; $w2 = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath (Join-Path $guest 'Out\*') -Destination $q2 -GuestRoot $guest -AllowedEntry '^Out/.*$' -MaxTotalBytes 20 -WarningVariable w2 3>$null
    $got2 = @(Get-ChildItem -LiteralPath $q2 -Recurse -File)
    if (@($w2).Count -eq 1 -and "$($w2[0])" -match 'more file\(s\) \(the results would pass the 20-byte cap: not sent\)' -and $got2.Count -lt 9 -and (($got2 | Measure-Object Length -Sum).Sum -le 20)) { Ok '-MaxTotalBytes stops the zipping in the guest (one warning, nothing over 20 bytes sent or extracted)' } else { Bad "total: $($got2.Count) files, warnings $(@($w2) -join ' | ')" }

    # The transfer itself is bounded (a process an unvetted installer left running can grow an allowed log name to many
    # GB): an oversize file in the guest tree is never zipped nor copied, the zipping stops at the total cap, and the
    # zip is refused before the copy when the guest reports it larger than the caps allow, and after the copy when the
    # host file is.
    $gb = New-TempDir
    $null = New-Item -ItemType Directory -Path (Join-Path $gb 'Out\Logs') -Force
    [IO.File]::WriteAllBytes((Join-Path $gb 'Out\Logs\a.log'), [byte[]]::new(40KB))
    [IO.File]::WriteAllBytes((Join-Path $gb 'Out\Logs\b.log'), [byte[]]::new(40KB))
    [IO.File]::WriteAllBytes((Join-Path $gb 'Out\Logs\c.log'), [byte[]]::new(40KB))
    [IO.File]::WriteAllBytes((Join-Path $gb 'Out\Logs\x.log'), [byte[]]::new(300KB))
    $script:transfers.Clear()
    $qb = New-TempDir; $wb = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath (Join-Path $gb 'Out\*') -Destination $qb -GuestRoot $gb -AllowedEntry $allow -MaxEntryBytes 64KB -MaxTotalBytes 1MB -WarningVariable wb 3>$null
    $sent = if ($script:transfers.Count -eq 1) { @($script:transfers[0].Entries) } else { @('?') }
    if (@($wb).Count -eq 1 -and "$($wb[0])" -match 'Out\\Logs\\x\.log \(307200 bytes, over the 65536-byte cap: not sent\)' -and ($sent -join ',') -ceq 'Out/Logs/a.log,Out/Logs/b.log,Out/Logs/c.log' -and
        -not (Test-Path -LiteralPath (Join-Path $qb 'Out\Logs\x.log')) -and @(Get-ChildItem -LiteralPath $qb -Recurse -File).Count -eq 3) {
        Ok 'a file over -MaxEntryBytes in the guest tree is never zipped nor copied (one warning); the others come back'
    } else { Bad "oversize file: sent $($sent -join ',') / $(@($wb) -join ' | ')" }
    $script:transfers.Clear()
    $qc = New-TempDir; $wc = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath (Join-Path $gb 'Out\*') -Destination $qc -GuestRoot $gb -AllowedEntry $allow -MaxEntryBytes 64KB -MaxTotalBytes 100KB -WarningVariable wc 3>$null
    $sent = if ($script:transfers.Count -eq 1) { @($script:transfers[0].Entries) } else { @('?') }
    if (@($wc).Count -eq 1 -and @($wc | Where-Object { "$_" -match 'Out\\Logs\\c\.log and 1 more file\(s\) \(the results would pass the 102400-byte cap: not sent\)' }).Count -eq 1 -and ($sent -join ',') -ceq 'Out/Logs/a.log,Out/Logs/b.log' -and $script:transfers[0].Bytes -lt 100KB + 64KB) {
        Ok 'the guest stops zipping before -MaxTotalBytes (the files left out reported once); only what fits is copied'
    } else { Bad "total in the guest: sent $($sent -join ',') / $(@($wc) -join ' | ')" }

    # The guest's report is data: 25 failures -> 20 named, then a count.
    $failedMany = @(1..25 | ForEach-Object { "Out\Logs\f$_.log (could not be read: locked)" })
    function Invoke-Command { [CmdletBinding()] param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest) $null = $Session, $ArgumentList, $Rest; if ("$ScriptBlock" -match 'ZipFile') { $script:fakeResult } }
    $script:fakeResult = @{ Zip = $null; Count = 0; Failed = $failedMany; Times = @{}; ZipLength = 0 }
    $wf = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination (New-TempDir) -GuestRoot $gb -WarningVariable wf 3>$null
    if (@($wf).Count -eq 21 -and "$($wf[19])" -match 'f20\.log' -and "$($wf[20])" -match '\.\.\. and 5 more result file\(s\) were NOT copied back') { Ok 'a guest that reports 25 failed files -> 20 named, then one warning with the count' } else { Bad "failed list: $(@($wf).Count) warnings" }

    # A zip the guest reports larger than the caps allow: refused BEFORE the copy (nothing crosses, nothing extracted).
    $bigZip = Join-Path (New-TempDir) 'big.zip'
    $z = [IO.Compression.ZipFile]::Open($bigZip, 'Create')
    try { $e = $z.CreateEntry('Out/Logs/big.log', [IO.Compression.CompressionLevel]::NoCompression); $s = $e.Open(); try { $s.Write([byte[]]::new(2MB), 0, 2MB) } finally { $s.Dispose() } } finally { $z.Dispose() }
    $script:fakeResult = @{ Zip = $bigZip; Count = 1; Failed = @(); Times = @{}; ZipLength = (Get-Item -LiteralPath $bigZip).Length }
    $script:transfers.Clear()
    $qd = New-TempDir; $wd = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $qd -GuestRoot $gb -AllowedEntry $allow -MaxTotalBytes 1MB -WarningVariable wd 3>$null
    if ($script:transfers.Count -eq 0 -and @($wd).Count -eq 1 -and "$($wd[0])" -match 'Refused the guest results: the guest reported a zip of' -and @(Get-ChildItem -LiteralPath $qd -Recurse -File).Count -eq 0) { Ok 'a zip reported larger than -MaxTotalBytes plus its structure -> refused before the copy (one warning, nothing extracted)' } else { Bad "reported zip: transfers=$($script:transfers.Count) / $(@($wd) -join ' | ')" }
    # Live row HOSTILE (2026-10-27): Windows PowerShell 5.1 (.NET Framework) writes a NoCompression entry as deflate stored
    # blocks, so its stored length is the declared length plus about 5 bytes per 32 KB block; a 64 MB file the guest sent
    # (exactly the cap) was refused on the host as 67119109 bytes. A zip built by powershell.exe with an entry of exactly
    # -MaxEntryBytes is extracted; that small block overhead is not counted.
    $ps51z = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps51z) {
        $z51 = Join-Path (New-TempDir) 'ps51.zip'
        & $ps51z -NoProfile -NonInteractive -Command ("Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem; `$z = [IO.Compression.ZipFile]::Open('$z51', 'Create'); try { `$e = `$z.CreateEntry('Out/SiblingCopy_${key}_uninstaller.exe', [IO.Compression.CompressionLevel]::NoCompression); `$s = `$e.Open(); try { `$b = New-Object byte[] 1048576; `$s.Write(`$b, 0, `$b.Length) } finally { `$s.Dispose() } } finally { `$z.Dispose() }") | Out-Null
        $za51 = [IO.Compression.ZipFile]::OpenRead($z51)
        try { $len51 = $za51.Entries[0].Length; $stored51 = $za51.Entries[0].CompressedLength } finally { $za51.Dispose() }
        $script:fakeResult = @{ Zip = $z51; Count = 1; Failed = @(); Times = @{}; ZipLength = (Get-Item -LiteralPath $z51).Length }
        $q51 = New-TempDir; $w51 = $null
        Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $q51 -GuestRoot $gb -AllowedEntry $allow -MaxEntryBytes 1MB -MaxTotalBytes 4MB -WarningVariable w51 3>$null
        $x51 = Join-Path $q51 "Out\SiblingCopy_${key}_uninstaller.exe"
        if ($len51 -eq 1MB -and $stored51 -gt $len51 -and @($w51).Count -eq 0 -and (Test-Path -LiteralPath $x51) -and (Get-Item -LiteralPath $x51).Length -eq 1MB) { Ok "a 5.1-built entry of exactly -MaxEntryBytes (stored $stored51 bytes for $len51) -> extracted, no warning" } else { Bad "5.1 zip at the cap: length=$len51 stored=$stored51 warnings=$(@($w51) -join ' | ')" }
    } else { Bad 'Windows PowerShell 5.1 is not available for the 5.1-built zip case' }
    # The same zip reported small (a guest that lies): copied, then refused by the host file's length.
    $script:fakeResult = @{ Zip = $bigZip; Count = 1; Failed = @(); Times = @{}; ZipLength = 100 }
    $script:transfers.Clear()
    $qe = New-TempDir; $we = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $qe -GuestRoot $gb -AllowedEntry $allow -MaxTotalBytes 1MB -WarningVariable we 3>$null
    if ($script:transfers.Count -eq 1 -and @($we).Count -eq 1 -and "$($we[0])" -match 'Refused the guest results: their zip is \d+ bytes' -and @(Get-ChildItem -LiteralPath $qe -Recurse -File).Count -eq 0) { Ok 'a zip reported small but larger on the host -> refused after the copy (one warning, nothing extracted)' } else { Bad "lying zip length: transfers=$($script:transfers.Count) / $(@($we) -join ' | ')" }
    # No length reported at all (quarantine mode with a total cap): refused, fail closed.
    $script:fakeResult = @{ Zip = $bigZip; Count = 1; Failed = @(); Times = @{} }
    $script:transfers.Clear()
    $wn = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination (New-TempDir) -GuestRoot $gb -AllowedEntry $allow -MaxTotalBytes 1MB -WarningVariable wn 3>$null
    if ($script:transfers.Count -eq 0 -and @($wn).Count -eq 1 -and "$($wn[0])" -match "reported a zip of '' bytes") { Ok 'no zip length reported under -MaxTotalBytes -> refused before the copy (fail closed)' } else { Bad "no length: transfers=$($script:transfers.Count) / $(@($wn) -join ' | ')" }
    # Back to the guest scriptblock run locally.
    function Invoke-Command {
        [CmdletBinding()]
        param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest)
        $null = $Session, $Rest
        & $ScriptBlock @ArgumentList
    }

    $q3 = New-TempDir
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath (Join-Path $guest 'Out\*') -Destination $q3 -GuestRoot $guest 3>$null
    if (@(Get-ChildItem -LiteralPath $q3 -Recurse -File).Count -eq 9) { Ok 'without the new parameters every entry is extracted (as before)' } else { Bad "plain: $(@(Get-ChildItem -LiteralPath $q3 -Recurse -File).Count)" }

    # '..' in an entry name (a crafted zip): still refused by the existing rule, also in quarantine mode.
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $crafted = Join-Path (New-TempDir) 'crafted.zip'
    $z = [IO.Compression.ZipFile]::Open($crafted, 'Create')
    try { $e = $z.CreateEntry('Out/../../escape.txt'); $s = $e.Open(); $s.WriteByte(65); $s.Dispose() } finally { $z.Dispose() }
    function Invoke-Command { [CmdletBinding()] param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest) $null = $Session, $ArgumentList, $Rest; if ("$ScriptBlock" -match 'ZipFile') { @{ Zip = $script:craftedCopy; Count = 1; Failed = @(); Times = @{}; ZipLength = (Get-Item -LiteralPath $script:craftedCopy).Length } } }
    $script:craftedCopy = Join-Path (New-TempDir) 'c.zip'; Microsoft.PowerShell.Management\Copy-Item -LiteralPath $crafted -Destination $script:craftedCopy
    $q4 = New-TempDir; $w4 = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination (Join-Path $q4 'quarantine') -GuestRoot $guest -AllowedEntry '^Out/.*$' -WarningVariable w4 3>$null
    if (-not (Test-Path -LiteralPath (Join-Path $q4 'escape.txt')) -and @($w4 | Where-Object { "$_" -match 'outside the project' }).Count -eq 1) { Ok "a '..' entry that passes the name pattern is still refused (it resolves outside the destination)" } else { Bad "traversal: $(@($w4) -join ' | ')" }

    # Absolute entry names (a drive root, a rooted path, a UNC path) never pass the capture's anchored allow-list.
    $absZip = Join-Path (New-TempDir) 'absolute.zip'
    $z = [IO.Compression.ZipFile]::Open($absZip, 'Create')
    try {
        foreach ($n in 'C:/Windows/Temp/w32t-abs.json', "/Out/SiblingPre_$key.json", '//server/share/x.json', "Out/SiblingPre_$key.json") {
            $e = $z.CreateEntry($n); $s = $e.Open(); $s.WriteByte(65); $s.Dispose()
        }
    }
    finally { $z.Dispose() }
    $script:craftedCopy = $absZip
    $q8 = New-TempDir; $w8 = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $q8 -GuestRoot $guest -AllowedEntry $allow -WarningVariable w8 3>$null
    $got8 = @(Get-ChildItem -LiteralPath $q8 -Recurse -File | ForEach-Object { $_.FullName.Substring($q8.Length + 1) })
    if (($got8 -join ',') -ceq "Out\SiblingPre_$key.json" -and @($w8 | Where-Object { "$_" -match 'not on the allow-list' }).Count -eq 3 -and -not (Test-Path -LiteralPath 'C:\Windows\Temp\w32t-abs.json')) { Ok 'absolute entry names (C:/..., /Out/..., //server/...) -> refused by the allow-list, one warning each; the relative one is extracted' } else { Bad "absolute: $($got8 -join ', ') / $(@($w8) -join ' | ')" }

    # A zip header that understates an entry's length (the zip comes from the guest). The uncompressed-size fields of the
    # first local header (offset 22) and of its central-directory record (offset 24) are patched to 10.
    $newLyingZip = {
        param([string]$Level, [int]$Bytes = 1MB)
        $zp = Join-Path (New-TempDir) "lying_$Level.zip"
        $zz = [IO.Compression.ZipFile]::Open($zp, 'Create')
        try {
            $ee = $zz.CreateEntry("Out/SiblingCapture_$key.json", [IO.Compression.CompressionLevel]::$Level)
            $ss = $ee.Open(); try { $ss.Write([byte[]]::new($Bytes), 0, $Bytes) } finally { $ss.Dispose() }
        }
        finally { $zz.Dispose() }
        $b = [IO.File]::ReadAllBytes($zp)
        $ten = [BitConverter]::GetBytes([uint32]10)
        if ([BitConverter]::ToUInt32($b, 0) -ne 0x04034b50) { throw 'fixture: no local header at 0' }
        [Array]::Copy($ten, 0, $b, 22, 4)
        $cd = -1
        for ($i = 0; $i -le $b.Length - 4; $i++) { if ([BitConverter]::ToUInt32($b, $i) -eq 0x02014b50) { $cd = $i; break } }
        if ($cd -lt 0) { throw 'fixture: no central directory' }
        [Array]::Copy($ten, 0, $b, $cd + 24, 4)
        [IO.File]::WriteAllBytes($zp, $b)
        $ra = [IO.Compression.ZipFile]::OpenRead($zp)
        try { if ($ra.Entries[0].Length -ne 10) { throw 'fixture: the patched length did not read back' } } finally { $ra.Dispose() }
        $zp
    }
    $script:craftedCopy = & $newLyingZip 'NoCompression'
    $q5 = New-TempDir; $w5 = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $q5 -GuestRoot $guest -AllowedEntry $allow -MaxEntryBytes 4096 -WarningVariable w5 3>$null
    if (@(Get-ChildItem -LiteralPath $q5 -Recurse -File).Count -eq 0 -and @($w5 | Where-Object { "$_" -match 'larger than 4096 bytes' -and "$_" -match '1048576 bytes' }).Count -eq 1) { Ok 'a stored entry whose header declares 10 bytes but holds 1 MB -> refused BEFORE extraction by -MaxEntryBytes (nothing written)' } else { Bad "lying stored entry: $(@(Get-ChildItem -LiteralPath $q5 -Recurse -File | ForEach-Object { "$($_.Name)=$($_.Length)" }) -join ', ') / $(@($w5) -join ' | ')" }
    # 32 KB: the zip stays under -MaxTotalBytes plus the zip's structure allowance, so the entry check is what stops it.
    $script:craftedCopy = & $newLyingZip 'NoCompression' 32KB
    $q6 = New-TempDir; $w6 = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $q6 -GuestRoot $guest -AllowedEntry $allow -MaxTotalBytes 4096 -WarningVariable w6 3>$null
    if (@(Get-ChildItem -LiteralPath $q6 -Recurse -File).Count -eq 0 -and @($w6 | Where-Object { "$_" -match 'exceed 4096 bytes: extraction stopped' }).Count -eq 1) { Ok 'a stored entry declaring 10 bytes but holding 32 KB under -MaxTotalBytes only -> the extraction stops before it (nothing written)' } else { Bad "lying stored total: $(@($w6) -join ' | ')" }
    # The 1 MB one under -MaxTotalBytes 4096: its zip is already over the cap plus the structure allowance.
    $script:craftedCopy = & $newLyingZip 'NoCompression'
    $q9 = New-TempDir; $w9 = $null
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $q9 -GuestRoot $guest -AllowedEntry $allow -MaxTotalBytes 4096 -WarningVariable w9 3>$null
    if (@(Get-ChildItem -LiteralPath $q9 -Recurse -File).Count -eq 0 -and @($w9).Count -eq 1 -and "$($w9[0])" -match 'Refused the guest results') { Ok 'the 1 MB stored entry under -MaxTotalBytes 4096 -> the whole zip is refused before the copy (nothing written)' } else { Bad "lying stored total, 1 MB: $(@($w9) -join ' | ')" }
    $script:craftedCopy = & $newLyingZip 'Optimal'
    $q7 = New-TempDir
    Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath 'x' -Destination $q7 -GuestRoot $guest -AllowedEntry $allow -MaxEntryBytes 4096 3>$null
    $f7 = @(Get-ChildItem -LiteralPath $q7 -Recurse -File)
    if ($f7.Count -le 1 -and @($f7 | Where-Object { $_.Length -gt 10 }).Count -eq 0) { Ok 'a deflated entry whose header declares 10 bytes is never written past 10 bytes (what the caps rely on)' } else { Bad "lying deflated entry: $(@($f7 | ForEach-Object { "$($_.Name)=$($_.Length)" }) -join ', ')" }

    # == [2] the project zip ================================================================================
    Write-Host '[2] New-Win32ToolkitProjectZip skips the sibling folders' -ForegroundColor Cyan
    $p = New-TempDir
    foreach ($d in 'Files', 'SupportFiles', 'Sandbox\Logs\Runs\r1', 'Sandbox\Siblings\nullsoft-8.9.8', 'Sandbox\SiblingRuns\nullsoft-8.9.8-20261025\in', 'Sandbox\SiblingsKeep') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    foreach ($f in 'Files\app.msi', 'SupportFiles\AppConfig.json', 'Sandbox\Logs\Install.log', 'Sandbox\Logs\Runs\r1\old.log', 'Sandbox\Siblings\nullsoft-8.9.8\npp.exe', 'Sandbox\SiblingRuns\nullsoft-8.9.8-20261025\in\SiblingCapture.ps1', 'Sandbox\SiblingsKeep\x.txt') { Set-Content -LiteralPath (Join-Path $p $f) -Value 'x' }
    $zip = New-Win32ToolkitProjectZip -ProjectPath $p -ZipPath (Join-Path (New-TempDir) 'p.zip')
    $a = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $names = @($a.Entries | ForEach-Object FullName) } finally { $a.Dispose() }
    $leaked = @($names | Where-Object { $_ -match '^Sandbox/(Siblings|SiblingRuns|Logs/Runs)(/|$)' })
    if ($leaked.Count -eq 0 -and $names -contains 'Files/app.msi' -and $names -contains 'Sandbox/Logs/Install.log' -and $names -contains 'Sandbox/SiblingsKeep/x.txt') { Ok 'Sandbox\Siblings and Sandbox\SiblingRuns never enter a guest (a folder that only starts with the same letters still does)' } else { Bad "zip: leaked $($leaked -join ', ') / $($names -join ', ')" }
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Private\New-Win32ToolkitProjectZip.ps1'))
    $fnAst = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $calls = @($fnAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -like '*-Win32Toolkit*' })
    if ($calls.Count -eq 0) { Ok 'the zip builder stays self-contained (the copy-in job rebuilds it from its text)' } else { Bad "calls: $($calls -join ', ')" }
}
finally { foreach ($t in $script:tmp) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue } }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All GuestIsolation tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail GuestIsolation test(s) FAILED." -ForegroundColor Red; exit 1 }
