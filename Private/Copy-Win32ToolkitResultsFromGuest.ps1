function Copy-Win32ToolkitResultsFromGuest {
    <#
    .SYNOPSIS
        Copies result files the guest produced back to the host project, preserving structure.
    .DESCRIPTION
        The Hyper-V equivalent of the mapped folder's live write-back: after the guest phases run, the
        outputs (e.g. Documentation\InstallationChanges_*.json, Sandbox\Logs\*) live only on the guest
        VHDX, so copy them back UNDER the host project at the same relative path. This is what lets the
        existing host-side consumers (Wait-ForDocumentationAndProcess, Wait-Win32ToolkitUpdateAssertion,
        New-IntuneRequirementScript, ...) work unchanged — by the time they read, the files are on disk.

        The transfer is ONE zip, not a Copy-Item -FromSession round trip per file: N sessions round trips
        (0.5-2 s each) collapse to 3, and -FromSession's per-file attribute replay is sidestepped (the
        same failure mode the copy-IN zip already avoids). Entries are added PER FILE with try/catch so
        one locked/unreadable guest file loses only itself — and, unlike the old per-file
        -ErrorAction SilentlyContinue loop, every skipped file is now REPORTED instead of vanishing.
        A guest-vs-host entry-count check makes a torn transfer loud. Each extracted file gets the guest's exact
        UTC LastWriteTime back (the zip only stores local DOS time, which shifted copied-back files by the UTC
        offset between guest and host).

        Sandbox\Logs\Runs\ is never brought back: it is the host's own copy of earlier runs' logs (test campaign
        F2), never copied in (New-Win32ToolkitProjectZip), so a guest file there is not a result. The guest skips
        it, and the host refuses such an entry (with a warning) so a guest can never overwrite that evidence.

        Quarantine mode (installer-identity PR 3b, spec 2.14.5, L19-L20; a sibling capture, whose guest just ran an
        installer nobody vetted): with -AllowedEntry, every entry name ('/' separators) must match that regex (anchored by
        the caller, case-insensitive) or it is refused with one warning and not extracted; with -MaxEntryBytes an entry
        whose size is larger is refused BEFORE it is extracted; with -MaxTotalBytes extraction stops (one warning) at the
        first entry that would pass the total. Refused entries are not counted as a torn transfer. The size checked is
        the LARGER of the entry's declared length and its stored (compressed) length: the zip comes from the guest, and
        a stored entry is extracted by its stored length whatever length its header declares (a deflated one stops at
        its declared length), so a header that understates the size cannot slip past the caps; a stored length above
        the declared one by at most the deflate stored-block overhead (64 bytes + 8 per 16 KB: how Windows PowerShell 5.1
        writes the guest's NoCompression entries) counts as the declared length. The caps also bound
        the transfer: the guest never zips a file over -MaxEntryBytes and stops zipping before -MaxTotalBytes (each
        file's length is taken once it is open and exactly that many bytes are sent; the files left out are reported),
        and a zip larger than -MaxTotalBytes plus its own structure (64 KB, 2 KB per declared entry, at most 4096) is
        refused before the copy (the length the guest reports) and after it (the host file): one warning, nothing
        extracted. Without these parameters nothing changes.

        Every guest-supplied name or message shown in a warning (or a verbose line) is reduced to printable ASCII (at
        most 200 characters): a file name the guest chose can never carry terminal control sequences into the console
        or the TUI. At most 20 of the files the guest could not send are named, then a count. An entry the host cannot
        write (a name NTFS refuses, such as one with a control character) loses only itself, with one warning.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER GuestPath
        One or more guest paths/globs under C:\PSADT to pull back (e.g. 'C:\PSADT\Documentation\*').
    .PARAMETER Destination
        Host project root that mirrors C:\PSADT.
    .PARAMETER GuestRoot
        The guest root that maps to Destination (default 'C:\PSADT'); used to compute relative paths.
    .PARAMETER AllowedEntry
        Quarantine mode: a regex every entry name must match (else refused, never extracted).
    .PARAMETER MaxEntryBytes
        Quarantine mode: the largest uncompressed entry accepted (0 = no limit).
    .PARAMETER MaxTotalBytes
        Quarantine mode: the most uncompressed bytes extracted in all (0 = no limit).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string[]]$GuestPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Destination,
        [string]$GuestRoot = 'C:\PSADT',
        [string]$AllowedEntry,
        [long]$MaxEntryBytes = 0,
        [long]$MaxTotalBytes = 0
    )

    # In-guest: resolve the globs and zip every match (relative to GuestRoot) into one archive.
    # 5.1-safe; untrusted values are arguments only. Returns @{ Zip; Count; Failed; Times; ZipLength }.
    $guestResult = Invoke-Command -Session $Session -ScriptBlock {
        param($globs, $rootPrefix)
        # PS Direct doesn't inherit the host's $ProgressPreference (separate runspace); keep this remote
        # work from relaying any progress onto the host's Spectre TUI. (5.1-safe assignment.)
        $ProgressPreference = 'SilentlyContinue'
        # The quarantine caps (0 = none) follow the two named arguments.
        $maxEntry = [long]0
        $maxTotal = [long]0
        if ($args.Count -ge 2) { $maxEntry = [long]$args[0]; $maxTotal = [long]$args[1] }

        $files = @()
        foreach ($g in $globs) {
            $files += @(Get-ChildItem -Path $g -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
        # The host's earlier run logs (Sandbox\Logs\Runs\) are never a guest result: never sent back.
        $files = @($files | Sort-Object -Unique | Where-Object {
                $r = if ($_.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $_.Substring($rootPrefix.Length) } else { '' }
                -not $r.StartsWith('Sandbox\Logs\Runs\', [System.StringComparison]::OrdinalIgnoreCase)
            })
        if ($files.Count -eq 0) { return @{ Zip = $null; Count = 0; Failed = @(); Times = @{}; ZipLength = 0 } }

        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
        $zipPath = 'C:\Windows\Temp\w32results_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip'
        $failed  = @()
        $added   = 0
        # Quarantine mode (caps given): the caps hold here too, before anything is zipped or sent.
        $capped  = (($maxEntry -gt 0) -or ($maxTotal -gt 0))
        $sent    = [long]0
        # Exact UTC write time per entry: a zip entry stores local DOS time (2 s resolution), so the host's
        # extract would shift every file by the guest-vs-host UTC offset.
        $times   = @{}
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
        try {
            for ($i = 0; $i -lt $files.Count; $i++) {
                $f = $files[$i]
                # Entry name = path relative to the guest root ('/' separators per the zip spec).
                $rel = if ($f.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $f.Substring($rootPrefix.Length)
                } else { Split-Path -Leaf $f }
                $entryName = $rel -replace '\\', '/'
                try {
                    if (-not $capped) {
                        $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                            $archive, $f, $entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
                    }
                    else {
                        # A file over the entry cap is not sent, and nothing more is sent once the total would pass
                        # the total cap. The length is taken once the file is open and exactly that many bytes are
                        # sent, so a file that keeps growing (a process the installer left running) cannot pass.
                        $src = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                        try {
                            $len = [long]$src.Length
                            if ($maxEntry -gt 0 -and $len -gt $maxEntry) {
                                $failed += ($rel + ' (' + $len + ' bytes, over the ' + $maxEntry + '-byte cap: not sent)')
                                continue
                            }
                            if ($maxTotal -gt 0 -and ($sent + $len) -gt $maxTotal) {
                                $failed += ($rel + ' and ' + ($files.Count - $i - 1) + ' more file(s) (the results would pass the ' + $maxTotal + '-byte cap: not sent)')
                                break
                            }
                            $e = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
                            $lw = [System.IO.File]::GetLastWriteTime($f)
                            if ($lw.Year -ge 1980 -and $lw.Year -le 2107) { $e.LastWriteTime = $lw }
                            $dst = $e.Open()
                            $left = $len
                            try {
                                $buf = New-Object byte[] 81920
                                while ($left -gt 0) {
                                    $n = $src.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $left))
                                    if ($n -le 0) { break }
                                    $dst.Write($buf, 0, $n)
                                    $left -= $n
                                }
                            }
                            finally { $dst.Dispose() }
                            $sent += ($len - $left)
                        }
                        finally { $src.Dispose() }
                    }
                    $added++
                    # Best effort: with no recorded time the host keeps the zip's own stamp for this entry.
                    try { $times[$entryName] = [System.IO.File]::GetLastWriteTimeUtc($f).Ticks } catch { $times.Remove($entryName) }
                }
                catch {
                    # One locked file must lose only itself (parity with the old per-file loop) — but
                    # visibly, so the host can warn about exactly what is missing.
                    $failed += ($rel + ' (could not be read: ' + $_.Exception.Message + ')')
                }
            }
        }
        finally { $archive.Dispose() }

        if ($added -eq 0) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            return @{ Zip = $null; Count = 0; Failed = $failed; Times = @{}; ZipLength = 0 }
        }
        return @{ Zip = $zipPath; Count = $added; Failed = $failed; Times = $times; ZipLength = (New-Object System.IO.FileInfo $zipPath).Length }
    } -ArgumentList (, $GuestPath), ($GuestRoot.TrimEnd('\') + '\'), $MaxEntryBytes, $MaxTotalBytes

    # Names and messages from the guest are data: printable ASCII only in a warning (no ESC/CSI, no bidi controls).
    $show = {
        param($Text)
        $s = ([string]$Text) -replace '[^\x20-\x7E]', '?'
        if ($s.Length -gt 200) { $s.Substring(0, 200) + '...' } else { $s }
    }
    # At most 20 named, then a count: the list comes from the guest.
    $missed = @($guestResult.Failed)
    foreach ($miss in @($missed | Select-Object -First 20)) {
        Write-Warning "Result file was NOT copied back from the guest: $(& $show $miss)"
    }
    if ($missed.Count -gt 20) { Write-Warning "... and $($missed.Count - 20) more result file(s) were NOT copied back from the guest (not listed)." }
    if (-not $guestResult.Zip) {
        Write-Verbose 'No result files matched in the guest — nothing to copy back.'
        return
    }
    $declared = 0L
    if (-not [long]::TryParse("$($guestResult.Count)", [ref]$declared) -or $declared -lt 0) { $declared = 0L }

    # One transfer + host-side extract, then verify the count so a torn transfer cannot pass silently.
    $hostZip = Join-Path ([System.IO.Path]::GetTempPath()) ('w32results_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
    try {
        # Quarantine mode with a total cap: the zip may hold at most MaxTotalBytes of results plus its own structure
        # (64 KB, and 2 KB for each entry it declares, at most 4096). A larger zip is refused before it is copied
        # (the length the guest reports) and after (the host file's length): one warning, nothing extracted.
        $zipCap = 0L
        if ($MaxTotalBytes -gt 0) {
            $zipCap = $MaxTotalBytes + 64KB + 2KB * [Math]::Min($declared, 4096L)
            $reported = -1L
            if (-not [long]::TryParse("$($guestResult.ZipLength)", [ref]$reported) -or $reported -lt 0 -or $reported -gt $zipCap) {
                Write-Warning "Refused the guest results: the guest reported a zip of '$(& $show $guestResult.ZipLength)' bytes, more than the $MaxTotalBytes-byte cap allows ($zipCap bytes with the zip's own structure). Nothing was copied back."
                return
            }
        }
        Copy-Item -FromSession $Session -Path $guestResult.Zip -Destination $hostZip -Force -ErrorAction Stop
        if ($zipCap -gt 0) {
            $copied = (Get-Item -LiteralPath $hostZip -Force).Length
            if ($copied -gt $zipCap) {
                Write-Warning "Refused the guest results: their zip is $copied bytes, more than the $MaxTotalBytes-byte cap allows ($zipCap bytes with the zip's own structure). Nothing was extracted."
                return
            }
        }

        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
        $destRoot  = [System.IO.Path]::GetFullPath(($Destination.TrimEnd('\') + '\'))
        $runsRoot  = $destRoot + 'Sandbox\Logs\Runs\'
        $extracted = 0
        $refused   = 0
        $total     = 0L
        $archive   = [System.IO.Compression.ZipFile]::OpenRead($hostZip)
        try {
            foreach ($entry in $archive.Entries) {
                $name = & $show $entry.FullName
                # Quarantine mode: the name and the size are checked before anything is written. The size is the larger
                # of the declared and the stored length: a stored entry is extracted by its stored length, so a guest
                # that understates the declared length in the zip header cannot pass the caps (a deflated entry stops
                # at its declared length).
                # Windows PowerShell 5.1 (.NET Framework) writes the guest's NoCompression entries as deflate stored blocks,
                # about 5 bytes per 32 KB above the data (live row HOSTILE: a 64 MB file read as 67119109 bytes and was
                # refused at its own cap). A stored length within that block overhead counts as the declared length (a
                # stored entry could at most pass the cap by that overhead); anything above it counts in full.
                $declaredLen = [long]$entry.Length
                $storedLen = [long]$entry.CompressedLength
                $blockSlack = 64L + 8L * [long][Math]::Ceiling($declaredLen / 16384.0)
                $size = if ($storedLen -gt $declaredLen -and $storedLen -le $declaredLen + $blockSlack) { $declaredLen } else { [Math]::Max($declaredLen, $storedLen) }
                if ($AllowedEntry -and $entry.FullName -notmatch ('(?i)' + $AllowedEntry)) {
                    Write-Warning "Refused a guest result that is not on the allow-list ('$name'): not extracted."
                    $refused++
                    continue
                }
                if ($MaxEntryBytes -gt 0 -and $size -gt $MaxEntryBytes) {
                    Write-Warning "Refused a guest result larger than $MaxEntryBytes bytes ('$name', $size bytes): not extracted."
                    $refused++
                    continue
                }
                if ($MaxTotalBytes -gt 0 -and ($total + $size) -gt $MaxTotalBytes) {
                    Write-Warning "The guest results exceed $MaxTotalBytes bytes: extraction stopped at '$name' (the rest is not extracted)."
                    $refused += (@($archive.Entries).Count - $extracted - $refused)
                    break
                }
                $total += $size
                $target = [System.IO.Path]::GetFullPath((Join-Path $Destination ($entry.FullName -replace '/', '\')))
                # The guest just ran an untrusted installer: never let an entry escape the project root.
                if (-not $target.StartsWith($destRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Warning "Skipped a result entry that resolves outside the project ('$name')."
                    continue
                }
                # ...nor overwrite the host's own run logs (the guest skips them; this holds against any guest).
                if ($target.StartsWith($runsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Warning "Skipped a result entry inside Sandbox\Logs\Runs ('$name'): the run logs there are kept on the host."
                    continue
                }
                # An entry the host cannot write (a name NTFS refuses: a control character, a reserved name) loses
                # only itself, with one warning; the I/O message carries the guest's name, so it is shown made safe.
                try {
                    $targetDir = Split-Path -Parent $target
                    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) { $null = [System.IO.Directory]::CreateDirectory($targetDir) }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    Write-Warning "Could not extract a guest result ('$name'): $(& $show $_.Exception.Message) Not copied back."
                    $refused++
                    continue
                }
                $extracted++
                # Restore the guest's exact UTC write time (test campaign 2026-10-21, H7-F4; TODO F-15): the zip's
                # local DOS time shifted every file by the host's UTC offset (the guest runs UTC). The value is
                # guest data, but only a bounded timestamp on a file the guest wrote anyway; best effort.
                $guestTicks = $null
                if ($guestResult.Times -is [System.Collections.IDictionary]) { $guestTicks = $guestResult.Times[$entry.FullName] }
                $ticks = 0L
                if ($null -ne $guestTicks -and [long]::TryParse("$guestTicks", [ref]$ticks) -and
                    $ticks -ge [datetime]::MinValue.Ticks -and $ticks -le [datetime]::MaxValue.Ticks) {
                    try { [System.IO.File]::SetLastWriteTimeUtc($target, [datetime]::new($ticks, [System.DateTimeKind]::Utc)) }
                    catch {
                        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                        Write-Verbose "Could not set the write time of '$name': $(& $show $_.Exception.Message)"
                    }
                }
            }
        }
        finally { $archive.Dispose() }

        if (($extracted + $refused) -ne $declared) {
            Write-Warning "Result copy-back mismatch: the guest zipped $declared file(s) but $extracted were extracted - review the warnings above and the guest logs."
        }
    }
    finally {
        if (Test-Path -LiteralPath $hostZip) { Remove-Item -LiteralPath $hostZip -Force -ErrorAction SilentlyContinue }
        Invoke-Command -Session $Session -ScriptBlock {
            param($zip)
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        } -ArgumentList $guestResult.Zip -ErrorAction SilentlyContinue
    }
}
