function Get-Win32ToolkitProjectTripwire {
    <#
    .SYNOPSIS
        Takes the tripwire of a project before a guest run: the SHA-256 of every project file outside Sandbox\.
    .DESCRIPTION
        Installer-identity PR 3 (L18, SV4). A guest run must never change the project it tests: a forged
        TestResults.json, a swapped installer under Files\ or an edited AppConfig.json would turn into a "proof" of a
        prior-install removal that never happened. The test takes this snapshot right before the guest starts (after
        every host write of the run's preparation) and Assert-Win32ToolkitProjectTripwire compares it once the guest
        can no longer write. Sandbox\ (the run's own work area: logs, assertion scripts, staged installers) is not
        hashed.

        Links are recorded, never followed: a symbolic link or junction ANYWHERE in the project (Sandbox\ included) is
        recorded as 'LINK:<target>' and never opened or entered. No toolkit run creates one, and the host keeps writing
        into the project after a run (run logs under Sandbox\Logs\Runs, records under Documentation\), so a link a
        guest left behind - a file or folder replaced by a link, a new junction - is a change like any other. Pure read;
        an unreadable file or folder throws (the run must not start without a complete snapshot).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [hashtable] relative path (as found, case kept) -> 64 upper-case hex characters, or 'LINK:<target>' for a link.
    .EXAMPLE
        $trip = Get-Win32ToolkitProjectTripwire -ProjectPath $p
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $base = (Get-Item -LiteralPath $ProjectPath -ErrorAction Stop).FullName.TrimEnd('\') + '\'
    $map = @{}
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        # Get-ChildItem -Recurse never enters a linked folder (no -FollowSymlink), so nothing behind a link is read.
        foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -Force -ErrorAction Stop)) {
            $rel = $f.FullName.Substring($base.Length)
            $link = [string]$f.LinkTarget
            if ($link) { $map[$rel] = 'LINK:' + $link; continue }
            if ($f.PSIsContainer -or $rel -like 'Sandbox\*') { continue }
            $stream = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { $map[$rel] = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('X2') }) } finally { $stream.Dispose() }
        }
    }
    finally { $sha.Dispose() }
    return $map
}
