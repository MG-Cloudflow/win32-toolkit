function Copy-Win32ToolkitProjectToGuest {
    <#
    .SYNOPSIS
        Copies a PSADT project into the guest at a fixed path over a PowerShell Direct session.
    .DESCRIPTION
        The Hyper-V equivalent of the Windows Sandbox mapped folder: the guest scripts all assume the
        project lives at C:\PSADT (and the update baseline at C:\PSADTOld), so this puts the project
        CONTENTS there. The target is cleared first so no stale files from a previous run linger (the
        warm checkpoint is clean, but this is belt-and-braces). Running on the guest's local VHDX — not
        a VSMB mapped folder — is the performance win over Sandbox.

        The transfer is a SINGLE ZIP, not a file-by-file Copy-Item -ToSession. That is not an
        optimisation, it is a correctness fix: -ToSession replays every source file's attributes onto the
        guest, so one file carrying an attribute outside .NET's FileAttributes enum aborts the whole run.
        A file synced/touched by OneDrive carries FILE_ATTRIBUTE_PINNED (0x80000), which produces
        'Cannot convert value "524320" to type "System.IO.FileAttributes"'. Zipping sidesteps attribute
        replay entirely, is faster (one transfer instead of hundreds), and leaves the raw Projects\ copy
        untouched — we never mutate the source to work around it.

        Each extracted file gets the host file's exact UTC LastWriteTime (a Times map read on the host from the
        zip's entries): a zip entry stores local DOS time (2 s, no time zone), so the guest, which runs UTC, would
        date every file by the host's UTC offset - and the copy-back (which keeps the guest's exact time) would then
        carry that shift back to the host, one offset per run, for every file the guest did not rewrite
        (re-verification 2026-10-21, A1/A2/A3 hv#1).
    .PARAMETER Session
        An open PowerShell Direct PSSession (from New-Win32ToolkitHyperVSession).
    .PARAMETER ProjectPath
        Host path of the project to copy.
    .PARAMETER GuestPath
        Guest destination (default 'C:\PSADT').
    .PARAMETER ReadOnly
        Lock the copied folder read+execute (icacls) after copying, reproducing the Sandbox mapped folder's
        <ReadOnly>true</ReadOnly> semantics. Used for the update baseline at C:\PSADTOld: without it the
        baseline's own PSADT run could WRITE into it on Hyper-V while the identical run FAILS on Sandbox —
        a silent backend divergence. The VM reverts after every run, so the ACL never persists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$ProjectPath,
        [string]$GuestPath = 'C:\PSADT',
        [switch]$ReadOnly,

        # A zip already built for this project (Invoke-Win32ToolkitHyperVRun pre-builds it CONCURRENTLY
        # with the checkpoint revert — the build needs no session). Consumed: deleted in finally either
        # way. Omitted/missing => built here, exactly as before.
        [string]$PrebuiltZip
    )

    # Transfer as ONE zip rather than file-by-file. Copy-Item -ToSession REPLAYS each source file's
    # attributes onto the guest, so a single file carrying an attribute outside .NET's FileAttributes enum
    # kills the whole run: a file touched by OneDrive gets FILE_ATTRIBUTE_PINNED (0x80000) and the copy
    # throws
    #     Cannot convert value "524320" to type "System.IO.FileAttributes"      (0x80020 = PINNED|Archive)
    # A zip carries no such attributes. It is also markedly faster (one transfer, not hundreds), and it
    # leaves the raw Projects\ copy untouched — we never mutate the source to work around this.
    $hostZip = if ($PrebuiltZip -and (Test-Path -LiteralPath $PrebuiltZip)) { $PrebuiltZip }
               else { New-Win32ToolkitProjectZip -ProjectPath $ProjectPath }
    $guestZip = 'C:\Windows\Temp\' + (Split-Path -Leaf $hostZip)

    try {
        # Exact UTC write time per FILE entry of the zip that goes in (prebuilt or built here): entry name
        # ('/' separators) -> the host file's LastWriteTimeUtc ticks. Read from the zip itself, so the map always
        # matches what is extracted (the thread-job builder is unchanged). Best effort: an entry whose host file
        # cannot be read keeps the zip's own stamp in the guest.
        $times = @{}
        try {
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
            $projRoot = [System.IO.Path]::GetFullPath($ProjectPath)
            $za = [System.IO.Compression.ZipFile]::OpenRead($hostZip)
            try {
                foreach ($entry in $za.Entries) {
                    if (-not $entry.Name) { continue }   # a folder entry
                    $hostFile = Join-Path $projRoot ($entry.FullName -replace '/', '\')
                    if ([System.IO.File]::Exists($hostFile)) { $times[$entry.FullName] = [System.IO.File]::GetLastWriteTimeUtc($hostFile).Ticks }
                }
            }
            finally { $za.Dispose() }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $times = @{}
            Write-Verbose "Could not read the copy-in write times ($($_.Exception.Message)): the guest keeps the zip's stamps."
        }

        Copy-Item -ToSession $Session -Path $hostZip -Destination $guestZip -Force -ErrorAction Stop

        $unset = Invoke-Command -Session $Session -ScriptBlock {
            param($zip, $dest, $times)
            # PS Direct does NOT inherit the host's $ProgressPreference — each Invoke-Command is its own
            # runspace. Silence at the source so the guest 'Removed N of M files' bar from Remove-Item
            # -Recurse isn't relayed back and painted over the host's Spectre TUI. (5.1-safe assignment.)
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path -LiteralPath $dest) {
                # A previous -ReadOnly copy of this path grants only RX (no DELETE) — and a deps
                # checkpoint could have frozen such a folder into the image. Reset the ACL first so the
                # cleanup always succeeds (self-heal); harmless when the ACL is normal.
                & icacls.exe $dest /reset /t /c /q 2>$null | Out-Null
                Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            # The host file's exact UTC write time (the zip holds local DOS time and this guest runs UTC). Set
            # here, before any -ReadOnly ACL. Only a tick count inside DateTime's range, only inside $dest.
            $unset = 0
            if ($times -is [System.Collections.IDictionary]) {
                $root = [System.IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'
                foreach ($k in @($times.Keys)) {
                    $t = [long]0
                    if (-not [long]::TryParse([string]$times[$k], [ref]$t)) { $unset++; continue }
                    if ($t -lt [datetime]::MinValue.Ticks -or $t -gt [datetime]::MaxValue.Ticks) { $unset++; continue }
                    $p = [System.IO.Path]::GetFullPath((Join-Path $dest ([string]$k -replace '/', '\')))
                    if (-not $p.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { $unset++; continue }
                    try { [System.IO.File]::SetLastWriteTimeUtc($p, (New-Object System.DateTime -ArgumentList $t, ([System.DateTimeKind]::Utc))) }
                    catch { $unset++ }
                }
            }
            $unset
        } -ArgumentList $guestZip, $GuestPath, $times -ErrorAction Stop
        if ("$unset" -match '^[1-9]\d*$') { Write-Verbose "Copy-in: $unset file(s) in '$GuestPath' keep the zip's local time stamp." }
    }
    finally {
        if (Test-Path -LiteralPath $hostZip) { Remove-Item -LiteralPath $hostZip -Force -ErrorAction SilentlyContinue }
    }

    if ($ReadOnly) {
        # Grant read+execute only (no deny ACE — SYSTEM must still READ and EXECUTE the baseline's PSADT).
        Invoke-Command -Session $Session -ScriptBlock {
            param($p)
            & icacls.exe $p /inheritance:r /grant 'SYSTEM:(OI)(CI)(RX)' 'Administrators:(OI)(CI)(RX)' 'Users:(OI)(CI)(RX)' | Out-Null
        } -ArgumentList $GuestPath
    }
}
