function Get-Win32ToolkitHyperVLeaseState {
    <#
    .SYNOPSIS
        Tells whether another process holds a test VM's lease, without taking it (read-only; never throws).
    .DESCRIPTION
        Menu selectors design section 4.3, D6 (knowledge-base/designs/menu-selectors.md). The menu's test VM screen shows
        which VMs another PowerShell process is using. This probe never takes the lease (that would bump the generation
        and void the other process's clean marker, A-2), never creates, never writes:
          1. This process holds the lock file ($script:HyperVLeases): State 'ThisWindow'.
          2. The lease's own checks, through W32TLeaseFileV2.Describe (Initialize-Win32ToolkitLeaseFileType: no data
             access, never follows a link, blocks nobody): the lock folder and its parent must be plain folders owned by
             Administrators or SYSTEM, the lock file a plain file with one name, such an owner and a final path inside the
             folder. Anything else: 'Unknown'. A missing folder or file: 'Free'.
          3. One open for reading, shared for reading only: a sharing violation means a holder has the file open for
             writing ('InUse'); success means nobody does ('Free', the handle is closed at once); anything else 'Unknown'.
             While that handle is open (microseconds), a process that starts its own acquisition gets a sharing violation
             and takes the lease on its next try, 5 s later.
        For 'InUse' the holder's diagnostics are read the way a waiting process reads them (shared for reading and
        writing, the first 4 KB) and returned only when they name a running process with the start time they record;
        they are display data, sanitized, never trusted. The error records of the probe's own caught exceptions are
        removed from $Error (the lease avoids leaving them, too).
    .PARAMETER VMId
        The VM's Id (Get-VM .Id).
    .PARAMETER LockRoot
        Hidden: the folder of the lock files (default %ProgramData%\win32-toolkit\locks). Tests only.
    .PARAMETER TrustedOwnerSid
        Hidden: the owner SIDs the lock folder and file may have, instead of BUILTIN\Administrators and SYSTEM. Tests only.
    .OUTPUTS
        [pscustomobject] State ('ThisWindow', 'InUse', 'Free' or 'Unknown'), Purpose, SinceUtc ([datetime] or $null),
        ProcessId ([int] or $null), Why (a short reason for 'Unknown', else '').
    .EXAMPLE
        (Get-Win32ToolkitHyperVLeaseState -VMId $vm.Id).State
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$VMId,

        [Parameter(DontShow)]
        [string]$LockRoot,

        [Parameter(DontShow)]
        [string[]]$TrustedOwnerSid
    )

    $result = {
        param([string]$State, [string]$Why = '', [string]$Purpose = '', $SinceUtc = $null, $ProcessId = $null)
        [pscustomobject]@{ State = $State; Purpose = $Purpose; SinceUtc = $SinceUtc; ProcessId = $ProcessId; Why = $Why }
    }
    $errorsBefore = $Error.Count
    try {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($VMId, [ref]$id)) { return (& $result 'Unknown' 'the VM Id is not a GUID') }
        if (-not $LockRoot) { $LockRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'win32-toolkit\locks' }
        $LockRoot = [System.IO.Path]::GetFullPath($LockRoot).TrimEnd('\', '/')
        $file = "hyperv-$($id.ToString('D')).lock"
        $path = Join-Path $LockRoot $file
        $trusted = if ($PSBoundParameters.ContainsKey('TrustedOwnerSid')) { @($TrustedOwnerSid) } else { @('S-1-5-32-544', 'S-1-5-18') }

        # 1. This process.
        if ($null -ne $script:HyperVLeases -and $script:HyperVLeases.ContainsKey($path)) { return (& $result 'ThisWindow') }

        # 2. The lease's own folder and file checks, without opening anything for data.
        Initialize-Win32ToolkitLeaseFileType
        $plainPath = { param([string]$Final) if ($Final.StartsWith('\\?\UNC\')) { '\' + $Final.Substring(7) } elseif ($Final.StartsWith('\\?\')) { $Final.Substring(4) } else { $Final } }
        $rootFinal = ''
        foreach ($dir in @((Split-Path -Parent $LockRoot), $LockRoot)) {
            if (-not $dir) { continue }
            $info = [W32TLeaseFileV2]::Describe($dir)
            if ($null -eq $info) { return (& $result 'Free') }
            $attr = [System.IO.FileAttributes][int]$info[0]
            if ($attr.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or -not $attr.HasFlag([System.IO.FileAttributes]::Directory)) { return (& $result 'Unknown' 'the lock folder is a link or not a folder') }
            if ([string]$info[2] -notin $trusted) { return (& $result 'Unknown' 'the lock folder has another owner') }
            $rootFinal = & $plainPath ([string]$info[3])
        }
        $info = [W32TLeaseFileV2]::Describe($path)
        if ($null -eq $info) { return (& $result 'Free') }
        $attr = [System.IO.FileAttributes][int]$info[0]
        $final = & $plainPath ([string]$info[3])
        if ($attr.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or $attr.HasFlag([System.IO.FileAttributes]::Directory) -or [int]$info[1] -ne 1 -or
            [string]$info[2] -notin $trusted -or -not [string]::Equals($final, ($rootFinal.TrimEnd('\') + '\' + $file), [System.StringComparison]::OrdinalIgnoreCase)) {
            return (& $result 'Unknown' 'the lock file is not one the toolkit made')
        }

        # 3. One open for reading, shared for reading only: refused while a holder has it open for writing.
        $state = 'Unknown'
        $why = ''
        $fs = $null
        try {
            $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $state = 'Free'
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $ex = $_.Exception
            while ($ex -is [System.Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
            if ($ex -is [System.IO.FileNotFoundException]) { $state = 'Free' }
            elseif ($ex -is [System.IO.IOException] -and (($ex.HResult -band 0xFFFF) -in 32, 33)) { $state = 'InUse' }
            else { $why = 'the lock file could not be read' }
        }
        finally {
            if ($null -ne $fs) { $fs.Dispose() }
        }
        if ($state -ne 'InUse') { return (& $result $state $why) }

        # The holder's diagnostics, read like a waiting process reads them (never blocks the holder); display only.
        $kv = @{}
        try {
            $peek = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $len = [int][Math]::Min($peek.Length, 4096)
                $buf = [byte[]]::new($len); $read = 0
                while ($read -lt $len) { $n = $peek.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
            }
            finally { $peek.Dispose() }
            foreach ($line in ([System.Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n")) {
                if ($line.TrimEnd("`r") -match '^(pid|processStartUtc|purpose|acquiredUtc)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $kv = @{}
        }
        $holderPid = 0
        $since = [datetime]::MinValue
        if ($kv['pid'] -match '^\d{1,10}$' -and [int]::TryParse([string]$kv['pid'], [ref]$holderPid) -and $holderPid -gt 0 -and $kv['purpose'] -and
            [datetime]::TryParse([string]$kv['acquiredUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$since)) {
            # -ErrorAction Ignore: a process that is gone leaves no error record.
            $holder = Get-Process -Id $holderPid -ErrorAction Ignore
            $current = $null -ne $holder
            $recorded = [datetime]::MinValue
            if ($current -and [datetime]::TryParse([string]$kv['processStartUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$recorded)) {
                $actual = $null
                try { $actual = $holder.StartTime.ToUniversalTime() }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    $actual = $null
                }
                if ($null -ne $actual -and [Math]::Abs(($actual - $recorded.ToUniversalTime()).TotalSeconds) -gt 1) { $current = $false }
            }
            if ($current) {
                return (& $result 'InUse' '' (ConvertTo-Win32ToolkitSafeText -Text ([string]$kv['purpose']) -MaxLength 32) $since.ToUniversalTime() $holderPid)
            }
        }
        return (& $result 'InUse')
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        return (& $result 'Unknown' 'the lock folder could not be checked')
    }
    finally {
        # The probe's own caught exceptions leave no record in $Error.
        while ($Error.Count -gt $errorsBefore) { $Error.RemoveAt(0) }
    }
}
