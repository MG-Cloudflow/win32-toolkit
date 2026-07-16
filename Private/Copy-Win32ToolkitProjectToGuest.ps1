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
        Copy-Item -ToSession $Session -Path $hostZip -Destination $guestZip -Force -ErrorAction Stop

        Invoke-Command -Session $Session -ScriptBlock {
            param($zip, $dest)
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
        } -ArgumentList $guestZip, $GuestPath -ErrorAction Stop
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
