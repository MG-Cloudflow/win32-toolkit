function Enter-Win32ToolkitHyperVLease {
    <#
    .SYNOPSIS
        Takes the machine-wide lease of a Hyper-V test VM (or of a project), waiting while another process holds it.
    .DESCRIPTION
        Hyper-V speed-up PR 3 (D10, A-1, A-2, A-11, A-12, V-5, V-6, V-18). One process at a time may change a test VM:
        every Hyper-V test run, the Intune-parity pre-check (when it restores the VM) and every VM command take this
        lease before their first VM-changing call and keep it until their last one, so a second PowerShell process waits
        for the VM instead of restoring it under the first.

        The lease is a lock file under %ProgramData%\win32-toolkit\locks (created with the folder's inherited ACL; no
        permission is changed): hyperv-<VM Id>.lock for a VM, project-<first 32 hex of the SHA256 of the lower-case full
        project path>.lock for a project (a relative path is resolved against the PowerShell location, not the process's
        working folder). The holder keeps the file open for reading and writing and shares it for reading only (never for
        writing, so a second acquirer is refused), not inheritable by child processes, and the file is never deleted
        (Windows closes the handle when the process ends, so a lease is never left behind by a process that died). The
        file holds a header, an epoch (a GUID, new whenever the file is unreadable) and a generation counter that every
        outermost acquisition increments, then diagnostics for waiting processes (process id and start time, purpose,
        time acquired) that are only ever printed, never trusted.

        The lock folder is not trusted either (the inherited ProgramData ACL lets every user create folders and files in
        it, so a standard user could create %ProgramData%\win32-toolkit first, or make it or a lock file a link, and turn
        an elevated session's write into a write of their choice). Before anything is created or opened, the folder and
        its parent (%ProgramData%\win32-toolkit) must each be a plain folder (no reparse point) owned by
        BUILTIN\Administrators or NT AUTHORITY\SYSTEM; a missing one is created only when this session's new objects
        belong to one of them (an elevated session), and checked again. The lock file must be a plain file (no reparse
        point, not a folder, one name only) with such an owner, inside that folder: it is checked before the open, opened
        without following a link at its own name, and checked again on the open handle (attributes, names, owner, and
        the final path, which must be the folder's own final path plus the file name) before anything is read or
        written. Anything else throws W32T.HyperVLeaseUnsafe and writes nothing (DR-2, an explicit ACL, stays open).

        A clean marker (New-/Remove-Win32ToolkitHyperVSession) is honoured only under the same epoch and while the
        generation shows that no other process held the VM since the teardown stamped it (A-2): the returned lease
        carries Epoch, Generation (after this acquisition) and PreviousGeneration (the file's generation before it).

        The same process taking a lease it already holds (the same file) nests: the count goes up, the file is not
        changed, and the nested lease reports PreviousGeneration = Generation of the outer hold. Exit-Win32ToolkitHyperVLease
        releases; the outermost release closes the file.

        Busy: the file is open in another process (a sharing or lock violation) or cannot be opened (access denied).
        The default open reports a busy file without throwing, so a long wait leaves no error record per attempt in
        $Error or in a caller's -ErrorVariable. The first busy attempt prints one host line naming the holder (read
        without blocking it), then the file is tried every 5 seconds until the wait ends: HyperVLeaseWaitMinutes (HKCU,
        integer 1-240, default 60; any other value is 60 with one verbose line). The holder's diagnostics are printed
        only when they name a running process (with the start time they record, when both can be read): a new holder
        opens the file before it writes them, so a waiter that comes in between reads the previous holder's. Then the
        line waits for the next busy attempt, and leaves the diagnostics out if they are still not the holder's (or
        prints at once, without them, when the wait ends). The wait then throws W32T.HyperVLeaseTimeout
        (W32T.ProjectLeaseTimeout for a project). 12 consecutive access-denied attempts with no sharing violation
        between them end the wait at once (V-6): a lock file that elevated sessions created can be written only by
        administrators, so the session must run elevated.

        Lock order (V-18): a project lease is always taken before the VM lease, never the other way round.
    .PARAMETER VMName
        The test VM to lease.
    .PARAMETER VMId
        The VM's Id when the caller already read it; otherwise it is read with Get-VM (a VM that does not exist fails
        with the cmdlet's error).
    .PARAMETER ProjectPath
        The project to lease (the optional per-project lease, TestProjectLease, and the lane runner).
    .PARAMETER Purpose
        A few words for the diagnostics and the messages (for example 'test run', 'reset').
    .PARAMETER LockRoot
        Hidden: the folder of the lock files (default %ProgramData%\win32-toolkit\locks). Tests only.
    .PARAMETER WaitSeconds
        Hidden: the longest wait in seconds, instead of HyperVLeaseWaitMinutes; 0 makes one attempt only (the lane
        runner's project lease while it already holds the VM, V-18).
    .PARAMETER OpenStream
        Hidden: the scriptblock that opens the lock file (default: the no-follow open above, as a FileStream). It returns
        the stream, or the Win32 error code ([int]) of an open that was refused (the default does: 5 access denied,
        32/33 busy, anything else is thrown as an IOException); it may also throw. Tests only; the stream it returns is
        checked like the default one.
    .PARAMETER TrustedOwnerSid
        Hidden: the owner SIDs the lock folder and file may have, instead of BUILTIN\Administrators (S-1-5-32-544) and
        NT AUTHORITY\SYSTEM (S-1-5-18). Tests only (a test session that is not elevated owns its temp folders); never
        passed by module code.
    .OUTPUTS
        Exactly one lease object: Kind (VM or Project), Path, Name, VMName, VMId, ProjectPath, Purpose, Epoch,
        Generation, PreviousGeneration, Nested, Released. Throws W32T.HyperVLeaseTimeout / W32T.ProjectLeaseTimeout
        (category ResourceBusy) when the wait ends, and W32T.HyperVLeaseUnsafe (SecurityError; PermissionDenied when
        this session would create the folder or the file with another owner) when the lock folder or file fails the
        checks above.
    .EXAMPLE
        $lease = Enter-Win32ToolkitHyperVLease -VMName 'win32tk-golden' -Purpose 'test run'
        try { ... } finally { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
    #>
    [CmdletBinding(DefaultParameterSetName = 'VM')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'VM')]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(ParameterSetName = 'VM')]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$VMId,

        [Parameter(Mandatory, ParameterSetName = 'Project')]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateNotNullOrEmpty()]
        [string]$Purpose = 'test',

        [Parameter(DontShow)]
        [string]$LockRoot,

        [Parameter(DontShow)]
        [ValidateRange(0, 14400)]
        [int]$WaitSeconds,

        [Parameter(DontShow)]
        [scriptblock]$OpenStream,

        [Parameter(DontShow)]
        [string[]]$TrustedOwnerSid
    )

    $isVm = $PSCmdlet.ParameterSetName -eq 'VM'
    $purposeText = ConvertTo-Win32ToolkitSafeText -Text $Purpose -MaxLength 32
    if (-not $LockRoot) { $LockRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'win32-toolkit\locks' }
    $LockRoot = [System.IO.Path]::GetFullPath($LockRoot).TrimEnd('\', '/')
    $trusted = if ($PSBoundParameters.ContainsKey('TrustedOwnerSid')) { @($TrustedOwnerSid) } else { @('S-1-5-32-544', 'S-1-5-18') }

    # The no-follow open and the handle checks (a constant type; no value of this call is compiled). TryOpenLock: read+write,
    # OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT (a link at the file's own name is opened as the link, then refused), no
    # security attributes (not inheritable), never FILE_FLAG_DELETE_ON_CLOSE; a refused open returns null and the Win32
    # error code instead of throwing (a .NET exception per busy attempt would be an error record in $Error and in the
    # caller's -ErrorVariable, live V3). OpenError: the exception for any other code. Describe: attributes, number of
    # names, owner SID and final path of an open handle, or of a path opened without following a link at it ($null:
    # missing). V2 in the name: a process that compiled the earlier type (OpenLock only) keeps it, so this one must differ.
    if (-not ('W32TLeaseFileV2' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition ('using System; using System.ComponentModel; using System.IO; using System.Runtime.InteropServices; ' +
            'using System.Security.Principal; using System.Text; using Microsoft.Win32.SafeHandles; ' +
            'public static class W32TLeaseFileV2 { ' +
            '[StructLayout(LayoutKind.Sequential)] private struct HandleInfo { public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; } ' +
            '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template); ' +
            '[DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out HandleInfo info); ' +
            '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags); ' +
            '[DllImport("advapi32.dll")] private static extern uint GetSecurityInfo(SafeFileHandle handle, int type, uint info, out IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr descriptor); ' +
            '[DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory); ' +
            'private static Exception Fail(int code, string path) { string m = new Win32Exception(code).Message + " (" + path + ")"; ' +
            'if (code == 5) { return new UnauthorizedAccessException(m); } return new IOException(m, unchecked((int)0x80070000) | code); } ' +
            'public static Exception OpenError(int code, string path) { return Fail(code, path); } ' +
            'public static SafeFileHandle TryOpenLock(string path, int share, out int error) { ' +
            'SafeFileHandle h = CreateFileW(path, 0xC0000000, (uint)share, IntPtr.Zero, 4, 0x80 | 0x00200000, IntPtr.Zero); ' +
            'if (h.IsInvalid) { error = Marshal.GetLastWin32Error(); h.Dispose(); return null; } error = 0; return h; } ' +
            'public static object[] Describe(string path) { ' +
            'SafeFileHandle h = CreateFileW(path, 0x00020080, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero); ' +
            'if (h.IsInvalid) { int code = Marshal.GetLastWin32Error(); h.Dispose(); if (code == 2 || code == 3) { return null; } throw Fail(code, path); } ' +
            'using (h) { return Describe(h); } } ' +
            'public static object[] Describe(SafeFileHandle handle) { HandleInfo info; ' +
            'if (!GetFileInformationByHandle(handle, out info)) { throw new Win32Exception(Marshal.GetLastWin32Error()); } ' +
            'IntPtr owner, descriptor; uint rc = GetSecurityInfo(handle, 1, 1, out owner, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out descriptor); ' +
            'if (rc != 0) { throw new Win32Exception((int)rc); } string sid; ' +
            'try { sid = new SecurityIdentifier(owner).Value; } finally { LocalFree(descriptor); } ' +
            'StringBuilder sb = new StringBuilder(1024); uint n = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, 0); ' +
            'if (n >= (uint)sb.Capacity) { sb = new StringBuilder((int)n + 1); n = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, 0); } ' +
            'if (n == 0 || n >= (uint)sb.Capacity) { throw new Win32Exception(Marshal.GetLastWin32Error()); } ' +
            'return new object[] { (int)info.Attributes, (int)info.Links, sid, sb.ToString(0, (int)n) }; } }')
    }
    if (-not $OpenStream) {
        # Read+write for the holder, shared for READING only (V-5): waiters can read the diagnostics, a second acquirer
        # (same open) is refused. Never FileShare.Write/ReadWrite (exclusivity), never Inheritable, never DeleteOnClose.
        # A refused open returns its Win32 error code (no exception, so no error record per busy attempt).
        $OpenStream = {
            param($p)
            $openError = 0
            $h = [W32TLeaseFileV2]::TryOpenLock($p, [int][System.IO.FileShare]::Read, [ref]$openError)
            if ($null -eq $h) { return [int]$openError }
            try { [System.IO.FileStream]::new($h, [System.IO.FileAccess]::ReadWrite) }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $h.Dispose()
                throw
            }
        }
    }

    # The lock file: per VM Id (a renamed VM keeps its lease), or per project path.
    if ($isVm) {
        $nameText = ConvertTo-Win32ToolkitSafeText -Text $VMName -MaxLength 64
        $id = [guid]::Empty
        if ([string]::IsNullOrWhiteSpace($VMId) -or -not [guid]::TryParse($VMId, [ref]$id)) {
            $vms = @(Get-VM -Name $VMName -ErrorAction Stop | Where-Object { $null -ne $_ })
            if ($vms.Count -ne 1 -or -not [guid]::TryParse([string]$vms[0].Id, [ref]$id)) {
                throw "The Id of the test VM '$nameText' could not be read ($($vms.Count) VM(s) with that name), so it cannot be leased."
            }
        }
        $VMId = $id.ToString('D')
        $file = "hyperv-$VMId.lock"
        $what = "the test VM '$nameText'"
    }
    else {
        # Resolved against the PowerShell location (Set-Location), as Test-Path resolved it for the caller: .NET's
        # GetFullPath alone would use the process's working folder, which Set-Location never changes.
        $full = [System.IO.Path]::GetFullPath($PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)).TrimEnd('\', '/')
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') }) }
        finally { $sha.Dispose() }
        $file = 'project-' + $hash.Substring(0, 32) + '.lock'
        $nameText = ConvertTo-Win32ToolkitSafeText -Text (Split-Path -Leaf $full) -MaxLength 64
        $what = "the project '$nameText'"
    }
    $path = Join-Path $LockRoot $file
    if ($null -eq $script:HyperVLeases) { $script:HyperVLeases = @{} }

    $newLease = {
        param([string]$Epoch, [long]$Generation, [long]$PreviousGeneration, [bool]$Nested)
        [pscustomobject]@{
            Kind = $(if ($isVm) { 'VM' } else { 'Project' }); Path = $path; Name = $nameText
            VMName = $(if ($isVm) { $VMName } else { $null }); VMId = $(if ($isVm) { $VMId } else { $null })
            ProjectPath = $(if ($isVm) { $null } else { $ProjectPath }); Purpose = $purposeText
            Epoch = $Epoch; Generation = $Generation; PreviousGeneration = $PreviousGeneration; Nested = $Nested; Released = $false
        }
    }

    # Nested: this process already holds the file.
    $held = $script:HyperVLeases[$path]
    if ($null -ne $held) {
        $held['Count'] = [int]$held['Count'] + 1
        Write-Verbose "Lease of $what is already held by this process ($($held['Purpose'])): nested ($($held['Count']))."
        return (& $newLease $held['Epoch'] $held['Generation'] $held['Generation'] $true)
    }

    # -- The lock folder and file checks (see the help): fail closed with W32T.HyperVLeaseUnsafe, nothing written. ----
    $unsafe = {
        param([string]$Problem, [string]$Category = 'SecurityError')
        throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("The $purposeText was not started: $Problem"),
            'W32T.HyperVLeaseUnsafe', [System.Management.Automation.ErrorCategory]$Category, $nameText)
    }
    $ownerText = {
        param([string]$Sid)
        $account = ''
        try { $account = ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Translate([System.Security.Principal.NTAccount]).Value }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $account = ''
        }
        if ($account) { "$(ConvertTo-Win32ToolkitSafeText -Text $account -MaxLength 80) ($Sid)" } else { $Sid }
    }
    # \\?\C:\x -> C:\x, \\?\UNC\server\share -> \\server\share (GetFinalPathNameByHandle's DOS form).
    $plainPath = { param([string]$Final) if ($Final.StartsWith('\\?\UNC\')) { '\' + $Final.Substring(7) } elseif ($Final.StartsWith('\\?\')) { $Final.Substring(4) } else { $Final } }
    $tokenOwner = [System.Security.Principal.WindowsIdentity]::GetCurrent().Owner.Value
    $removeIt = 'Remove it from an elevated session (it only ever holds win32-toolkit lock files); the toolkit creates it again.'
    $rootFinal = ''
    foreach ($dir in @((Split-Path -Parent $LockRoot), $LockRoot)) {
        if (-not $dir) { continue }
        $info = $null
        try {
            $info = [W32TLeaseFileV2]::Describe($dir)
            if ($null -eq $info) {
                if ($tokenOwner -notin $trusted) {
                    & $unsafe "the lock folder $dir does not exist, and this session would create it owned by $(& $ownerText $tokenOwner), not by Administrators or SYSTEM: run the session elevated." 'PermissionDenied'
                }
                $null = [System.IO.Directory]::CreateDirectory($dir)
                $info = [W32TLeaseFileV2]::Describe($dir)
                if ($null -eq $info) { & $unsafe "the lock folder $dir could not be created." }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $ex = $_.Exception
            while ($ex -is [System.Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
            & $unsafe "the lock folder $dir could not be checked ($(ConvertTo-Win32ToolkitSafeText -Text $ex.Message -MaxLength 200))."
        }
        $attr = [System.IO.FileAttributes][int]$info[0]
        if ($attr.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or -not $attr.HasFlag([System.IO.FileAttributes]::Directory)) {
            & $unsafe "the lock folder $dir is a link (reparse point) or not a folder, so no lock file is written there. $removeIt"
        }
        if ([string]$info[2] -notin $trusted) {
            & $unsafe "the lock folder $dir belongs to $(& $ownerText ([string]$info[2])), not to Administrators or SYSTEM, so another account could redirect its lock files. $removeIt"
        }
        $rootFinal = & $plainPath ([string]$info[3])
    }
    $expectedFinal = $rootFinal.TrimEnd('\') + '\' + $file
    # A lock file (described before the open, or on the open handle) that must not be read or written: the reason, else $null.
    $fileProblem = {
        param([object[]]$Info)
        $a = [System.IO.FileAttributes][int]$Info[0]
        if ($a.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { return 'it is a link (reparse point)' }
        if ($a.HasFlag([System.IO.FileAttributes]::Directory)) { return 'it is a folder' }
        if ([int]$Info[1] -ne 1) { return "it has $([int]$Info[1]) names (hard links)" }
        if ([string]$Info[2] -notin $trusted) { return "it belongs to $(& $ownerText ([string]$Info[2])), not to Administrators or SYSTEM" }
        $final = & $plainPath ([string]$Info[3])
        if (-not [string]::Equals($final, $expectedFinal, [System.StringComparison]::OrdinalIgnoreCase)) { return "it resolves to $(ConvertTo-Win32ToolkitSafeText -Text $final -MaxLength 200), outside the lock folder" }
        $null
    }

    # How long to wait.
    if ($PSBoundParameters.ContainsKey('WaitSeconds')) { $waitSec = $WaitSeconds }
    else {
        $waitSec = 3600
        $raw = ''
        try { $raw = ([string](Get-Win32ToolkitConfigValue -Name 'HyperVLeaseWaitMinutes' -Default '')).Trim() }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $raw = ''
        }
        if ($raw) {
            $n = 0
            if ($raw -match '^\d{1,3}$' -and [int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le 240) { $waitSec = $n * 60 }
            else { Write-Verbose "HyperVLeaseWaitMinutes '$(ConvertTo-Win32ToolkitSafeText -Text $raw -MaxLength 32)' is not an integer from 1 to 240; 60 minutes are used." }
        }
    }
    # The hidden -WaitSeconds may be under a minute (tests): then the text counts seconds.
    $waitText = if ($waitSec -eq 1) { '1 second' } elseif ($waitSec -lt 60) { "$waitSec seconds" } elseif ($waitSec -eq 60) { "1 minute" } elseif ($waitSec % 60 -eq 0) { "$($waitSec / 60) minutes" } else { "$(([math]::Round($waitSec / 60, 1)).ToString([System.Globalization.CultureInfo]::InvariantCulture)) minutes" }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $printed = $false
    $deferred = $false
    $deniedRun = 0
    while ($true) {
        $fs = $null
        $busy = $null
        # Before the open: an existing lock file must pass the checks; a missing one is created only with a trusted owner.
        $pre = $null
        try { $pre = [W32TLeaseFileV2]::Describe($path) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $ex = $_.Exception
            while ($ex -is [System.Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
            & $unsafe "the lease file $path of $what could not be checked ($(ConvertTo-Win32ToolkitSafeText -Text $ex.Message -MaxLength 200))."
        }
        if ($null -ne $pre) {
            $why = & $fileProblem $pre
            if ($why) { & $unsafe "the lease file $path of $what is not written: $why. $removeIt" }
        }
        elseif ($tokenOwner -notin $trusted) {
            & $unsafe "the lease file $path of $what does not exist, and this session would create it owned by $(& $ownerText $tokenOwner), not by Administrators or SYSTEM: run the session elevated." 'PermissionDenied'
        }
        try {
            $fs = & $OpenStream $path
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $ex = $_.Exception
            while ($ex -is [System.Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
            if ($ex -is [System.UnauthorizedAccessException]) { $busy = 'denied' }
            elseif ($ex -is [System.IO.IOException] -and (($ex.HResult -band 0xFFFF) -in 32, 33)) { $busy = 'sharing' }
            else { throw }
        }
        # The default open returns the Win32 error code of a refused open instead of throwing (see the help).
        if ($fs -is [int]) {
            $openCode = [int]$fs
            $fs = $null
            if ($openCode -eq 5) { $busy = 'denied' }
            elseif ($openCode -in 32, 33) { $busy = 'sharing' }
            else { throw [W32TLeaseFileV2]::OpenError($openCode, $path) }
        }

        if ($null -ne $fs) {
            # On the open handle, before anything is read or written: the same checks, and the file the handle really
            # opened must be the lock folder's own file (a link planted between the check and the open is caught here).
            $why = $null
            try { $why = & $fileProblem ([W32TLeaseFileV2]::Describe($fs.SafeFileHandle)) }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $why = "it could not be checked ($(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200))"
            }
            if ($why) {
                $fs.Dispose()
                & $unsafe "the lease file $path of $what is not written: $why. $removeIt"
            }
            try {
                # Read the header: epoch and generation; anything unreadable starts a new epoch (A-2).
                $epoch = $null; $prev = [long]-1
                $len = [int][Math]::Min($fs.Length, 4096)
                $buf = [byte[]]::new($len)
                $read = 0
                while ($read -lt $len) { $n = $fs.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
                $lines = @(([System.Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n") | ForEach-Object { $_.TrimEnd("`r") })
                $g = [guid]::Empty
                if ($lines.Count -ge 3 -and $lines[0] -ceq 'w32t-lease v1' -and $lines[1] -cmatch '^epoch=([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})$' -and
                    [guid]::TryParse($Matches[1], [ref]$g) -and $lines[2] -cmatch '^generation=(\d{1,18})$') {
                    $p = [long]$Matches[1]
                    if ($p -lt 999999999999999999) { $epoch = $g.ToString('D'); $prev = $p }
                }
                if (-not $epoch) {
                    $epoch = [guid]::NewGuid().ToString('D'); $prev = [long]-1
                    if ($read -gt 0) { Write-Verbose "The lease file of $what was not readable: a new epoch starts." }
                }
                $gen = $prev + 1
                $startUtc = ''
                try { $startUtc = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    $startUtc = ''
                }
                $text = "w32t-lease v1`nepoch=$epoch`ngeneration=$gen`npid=$PID`nprocessStartUtc=$startUtc`npurpose=$purposeText`nacquiredUtc=$([datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture))`n"
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
                $fs.SetLength(0)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush($true)
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $fs.Dispose()
                throw
            }
            $script:HyperVLeases[$path] = @{ Stream = $fs; Count = 1; Epoch = $epoch; Generation = $gen; PreviousGeneration = $prev; VMName = $(if ($isVm) { $VMName } else { $null }); Purpose = $purposeText }
            Write-Verbose "Lease of $what taken ($purposeText; generation $gen) after $([math]::Round($clock.Elapsed.TotalSeconds, 1)) s."
            return (& $newLease $epoch $gen $prev $false)
        }

        # Busy.
        if ($busy -eq 'denied') { $deniedRun++ } else { $deniedRun = 0 }
        $deniedEnd = $deniedRun -ge 12
        $ending = $deniedEnd -or $clock.Elapsed.TotalSeconds -ge $waitSec
        if (-not $printed -and $waitSec -gt 0 -and $deniedRun -eq 0) {
            # The holder's diagnostics, read without blocking it (or a later acquirer); never trusted, only printed.
            # Current: complete, and the process they name is running (with the start time they record, when both can
            # be read). A new holder opens the file before it writes them, so a waiter that comes in between reads the
            # previous holder's, which named a process that had exited minutes before (live V3): then the line waits
            # for the next busy attempt and leaves them out if they are still not current.
            $diag = ''
            $current = $false
            try {
                $peek = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $pl = [int][Math]::Min($peek.Length, 4096)
                    $pb = [byte[]]::new($pl); $pr = 0
                    while ($pr -lt $pl) { $n = $peek.Read($pb, $pr, $pl - $pr); if ($n -le 0) { break }; $pr += $n }
                }
                finally { $peek.Dispose() }
                $kv = @{}
                foreach ($line in ([System.Text.Encoding]::UTF8.GetString($pb, 0, $pr) -split "`n")) {
                    if ($line.TrimEnd("`r") -match '^(pid|processStartUtc|purpose|acquiredUtc)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
                }
                $ts = [datetime]::MinValue
                $holderPid = 0
                if ($kv['pid'] -match '^\d{1,10}$' -and [int]::TryParse([string]$kv['pid'], [ref]$holderPid) -and $holderPid -gt 0 -and $kv['purpose'] -and
                    [datetime]::TryParse([string]$kv['acquiredUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$ts)) {
                    $diag = ' ({0} since {1:yyyy-MM-dd HH:mm:ss}Z, process {2})' -f (ConvertTo-Win32ToolkitSafeText -Text ([string]$kv['purpose']) -MaxLength 32), $ts.ToUniversalTime(), $holderPid
                    # -ErrorAction Ignore: a process that is gone leaves no error record.
                    $holderProcess = Get-Process -Id $holderPid -ErrorAction Ignore
                    if ($null -ne $holderProcess) {
                        $current = $true
                        $recordedStart = [datetime]::MinValue
                        if ([datetime]::TryParse([string]$kv['processStartUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$recordedStart)) {
                            $actualStart = $null
                            try { $actualStart = $holderProcess.StartTime.ToUniversalTime() }
                            catch {
                                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                $actualStart = $null
                            }
                            # Another start time: the process id was reused, so the diagnostics are not its own.
                            if ($null -ne $actualStart -and [Math]::Abs(($actualStart - $recordedStart.ToUniversalTime()).TotalSeconds) -gt 1) { $current = $false }
                        }
                    }
                }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $diag = ''
                $current = $false
            }
            if ($current -or $deferred -or $ending) {
                $printed = $true
                if (-not $current) { $diag = '' }
                $doing = if ($isVm) { 'using it' } else { 'testing it' }
                Write-Host "Waiting for ${what}: another process is $doing$diag; up to $waitText..." -ForegroundColor Yellow
            }
            else {
                $deferred = $true
                Write-Verbose "The lease file of $what does not name a running holder yet: the wait line waits for the next attempt."
            }
        }

        if ($ending) {
            $errorId = if ($isVm) { 'W32T.HyperVLeaseTimeout' } else { 'W32T.ProjectLeaseTimeout' }
            $notRestored = if ($isVm) { ' and the VM was not restored' } else { '' }
            $msg = if ($deniedEnd) {
                "The $purposeText was not started: this session could not open the lease file $path of $what (access denied): run the session elevated."
            }
            elseif ($waitSec -eq 0) {
                "Another process holds $what (lease file $path). The $purposeText was not started$notRestored."
            }
            elseif ($isVm) {
                "Another process kept $what for more than $waitText (lease file $path). The $purposeText was not started and the VM was not restored. Wait for it, raise HyperVLeaseWaitMinutes, or pin another VM with W32T_HYPERV_VM."
            }
            else {
                "Another process kept $what for more than $waitText (lease file $path). The $purposeText was not started. Wait for it, or raise HyperVLeaseWaitMinutes."
            }
            throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($msg), $errorId,
                [System.Management.Automation.ErrorCategory]::ResourceBusy, $nameText)
        }
        $remainingMs = [int][Math]::Max(100, [Math]::Min(5000, ($waitSec - $clock.Elapsed.TotalSeconds) * 1000))
        Start-Sleep -Milliseconds $remainingMs
    }
}
