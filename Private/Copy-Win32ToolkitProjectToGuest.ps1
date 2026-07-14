function Copy-Win32ToolkitProjectToGuest {
    <#
    .SYNOPSIS
        Copies a PSADT project into the guest at a fixed path over a PowerShell Direct session.
    .DESCRIPTION
        The Hyper-V equivalent of the Windows Sandbox mapped folder: the guest scripts all assume the
        project lives at C:\PSADT (and the update baseline at C:\PSADTOld), so this copies the project
        CONTENTS there. The target is cleared first so no stale files from a previous run linger (the
        warm checkpoint is clean, but this is belt-and-braces). Running on the guest's local VHDX — not
        a VSMB mapped folder — is the performance win over Sandbox.
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
        [switch]$ReadOnly
    )

    Invoke-Command -Session $Session -ScriptBlock {
        param($p)
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    } -ArgumentList $GuestPath

    # Copy the project CONTENTS (not the folder itself) so files land directly under $GuestPath.
    Copy-Item -ToSession $Session -Path (Join-Path $ProjectPath '*') -Destination $GuestPath -Recurse -Force -ErrorAction Stop

    if ($ReadOnly) {
        # Grant read+execute only (no deny ACE — SYSTEM must still READ and EXECUTE the baseline's PSADT).
        Invoke-Command -Session $Session -ScriptBlock {
            param($p)
            & icacls.exe $p /inheritance:r /grant 'SYSTEM:(OI)(CI)(RX)' 'Administrators:(OI)(CI)(RX)' 'Users:(OI)(CI)(RX)' | Out-Null
        } -ArgumentList $GuestPath
    }
}
