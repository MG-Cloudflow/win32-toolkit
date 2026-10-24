<#
    Hyper-V speed-up PR 3 (D10, A-1, A-2, A-11, V-5, V-6, V-15, V-18): the machine-wide lease of a test VM or a project,
    Enter-/Exit-Win32ToolkitHyperVLease, and the module's OnRemove that closes held leases.

      [a] The first acquisition: exactly one lease object; the lock file hyperv-<VM Id lower-case>.lock holds the header,
          a new epoch, generation 0 and the diagnostics (pid, process start, purpose, acquired); PreviousGeneration -1.
      [b] Share modes (V-5): while the lease is held the diagnostics are readable with (Open, Read, FileShare.ReadWrite);
          a second (ReadWrite, FileShare.Read) open fails with HResult 0x80070020, and so does a (ReadWrite,
          FileShare.ReadWrite) writer; a reader that keeps its peek handle open never blocks the next acquirer.
      [c] Exclusive: another holder (a stream the test opens, as another process would) makes Enter wait, print ONE host
          line with the holder's purpose, acquired time and pid, then throw W32T.HyperVLeaseTimeout (ResourceBusy,
          target the VM name) naming the lease file; the wait honours -WaitSeconds.
     [c2] Stale diagnostics (live V3): a lock file that still names the previous holder (a process that has exited, or a
          reused process id with another start time) is not printed. The line waits for the next busy attempt and names
          the new holder once it has written its diagnostics; still stale -> the line without them; a wait that ends on
          the first attempt prints at once, without them.
      [q] No error record per attempt (live V3): a wait on a held file with the default open leaves nothing in $Error
          or in the caller's -ErrorVariable (a timeout: only the W32T error); another refused open is thrown as an
          IOException naming the file.
      [d] Release and generations: Exit closes the file (re-acquirable, generation +1, the same epoch, PreviousGeneration
          the old generation); an abandoned file (holder gone) is acquirable and its generation advances; the file
          stays after Exit (no DeleteOnClose).
      [e] Re-entrancy: a nested Enter writes nothing, counts 2, PreviousGeneration = Generation; the nested Exit keeps the
          file held; a second Exit of the same lease does nothing; the outer Exit releases.
      [f] A corrupt file (wrong header, bad epoch, letters in the generation, an empty file) starts a new epoch with
          PreviousGeneration -1.
      [g] Access denied only (V-6): the wait ends after 12 consecutive attempts, not after -WaitSeconds, with the
          "run the session elevated" wording; a sharing violation in between restarts the count; no wait line.
      [h] -WaitSeconds 0: exactly one attempt, no sleep, no wait line, the "holds" wording.
      [i] HyperVLeaseWaitMinutes: a valid value (1-240) is the wait the line names; blank/invalid -> 60 (one verbose line
          for a non-blank invalid value).
      [j] The VM Id: read with Get-VM when not given (or not a GUID); a given Id is used lower-case without Get-VM; a VM
          that does not exist fails with the cmdlet's error (not a W32T error).
      [k] Per-project: project-<first 32 hex of SHA256(lower-case full path)>.lock; W32T.ProjectLeaseTimeout names the
          project; a relative path is resolved against the PowerShell location (Set-Location), not the process's
          working folder.
      [l] C-12: Enter emits exactly one object, Exit nothing (also for $null and a released lease).
      [m] The holder's handle is not inherited by a child process (FileShare.Inheritable off).
      [n] OnRemove: a lease taken through the real module in a child process is closed by Remove-Module.
      [o] File hygiene: ASCII, one function each, every catch starts with the C-2 line; the native open never follows a
          link at the file's name, is not inheritable, never delete-on-close; no module file passes -TrustedOwnerSid.
      [p] The lock folder and file are not trusted (W32T.HyperVLeaseUnsafe, nothing written anywhere): a lock folder
          whose parent is a junction, a lock folder that is a junction, a folder owned by a non-admin SID (the parent,
          and the lock folder itself), a missing folder or lock file this session would create with an untrusted owner
          (PermissionDenied, nothing created), a junction or a hard link at the lock file's name, a lock file owned by
          another account, and a stream that opened another file (the open handle's final path).

    Lock files go to a temp folder (the hidden -LockRoot, <temp>\w32lease_*\locks); %ProgramData% is never touched; HKCU
    is shadowed. Elevated, the suite uses the default owners (Administrators, SYSTEM); not elevated, it trusts its own
    token owner (-TrustedOwnerSid) and the cases that need an elevated token print SKIP lines.

    Run:  pwsh -File Tests\HyperVLease.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: no PSScriptAnalyzer warning in the suites).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Enter-Win32ToolkitHyperVLease.ps1')
. (Join-Path $repo 'Private\Exit-Win32ToolkitHyperVLease.ps1')
# C-9 (speed-up PR 4): Enter joins this process's background restore first; with none pending the real join does nothing.
. (Join-Path $repo 'Private\Wait-Win32ToolkitHyperVTeardown.ps1')

# -- shadows: HKCU in memory, Get-VM counted --------------------------------------------------------------------------
$script:cfg = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
$vmId = '0e5f9e66-1111-2222-3333-444455556666'
$script:getVm = 0; $script:vmMissing = $false
function Get-VM { param($Name, $ErrorAction)
    $script:getVm++
    if ($script:vmMissing) { throw "Hyper-V was unable to find a virtual machine with name '$Name'." }
    # $script: (the caller's own $VMId parameter would shadow a plain $vmId here: dynamic scoping)
    [pscustomobject]@{ Name = $Name; Id = [guid]$script:vmId }
}

$BASE = Join-Path ([System.IO.Path]::GetTempPath()) ('w32lease_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $BASE -Force
$ROOT = Join-Path $BASE 'locks'
$lockFile = Join-Path $ROOT "hyperv-$vmId.lock"
$utf8 = [System.Text.UTF8Encoding]::new($false)
# Elevated: this session's new objects belong to Administrators and the default owners are used; not elevated: the
# suite trusts its own token owner (the hidden -TrustedOwnerSid), and the cases that need an elevated token are skipped.
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Owner.Value
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$elevatedOwner = $me -in 'S-1-5-32-544', 'S-1-5-18'
$trust = if ($elevatedOwner) { @{} } else { @{ TrustedOwnerSid = @($me) } }
function Skip($m) { Write-Host "  SKIP (this session's new objects do not belong to Administrators): $m" -ForegroundColor Yellow }
function Set-TestOwner { param([string]$Path, [string]$Sid)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        $sd = [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]$item, [System.Security.AccessControl.AccessControlSections]::Owner)
        $sd.SetOwner([System.Security.Principal.SecurityIdentifier]::new($Sid)); [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]$item, $sd)
    }
    else {
        $sd = [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]$item, [System.Security.AccessControl.AccessControlSections]::Owner)
        $sd.SetOwner([System.Security.Principal.SecurityIdentifier]::new($Sid)); [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]$item, $sd)
    }
}
# Another holder, as another process would hold the file: the same open as the real holder, optionally with content.
function Open-Foreign { param([string]$Path, [string]$Content)
    $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    if ($PSBoundParameters.ContainsKey('Content')) { $b = $utf8.GetBytes($Content); $fs.SetLength(0); $fs.Write($b, 0, $b.Length); $fs.Flush($true) }
    $fs
}
# Reads the lock file while it may be held (the waiters' peek).
function Read-Lock { param([string]$Path = $lockFile)
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $r = [System.IO.StreamReader]::new($fs, $utf8); $r.ReadToEnd() } finally { $fs.Dispose() }
}
# Tries an open, returns $null on success or the HResult of the failure.
function Test-Open { param([string]$Path = $lockFile, [System.IO.FileAccess]$Access = 'ReadWrite', [System.IO.FileShare]$Share = 'Read')
    try { $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, $Access, $Share); $fs.Dispose(); $null }
    catch { $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }; $ex.HResult }
}
# One Enter call: its output, host lines, verbose lines and error.
function Invoke-Enter {
    param([hashtable]$Splat, [switch]$DefaultOwners)
    $a = @{ VMName = 'vm-test'; VMId = $vmId; LockRoot = $ROOT }
    if (-not $DefaultOwners) { foreach ($k in $trust.Keys) { $a[$k] = $trust[$k] } }
    foreach ($k in $Splat.Keys) { $a[$k] = $Splat[$k] }
    if ($a.ContainsKey('ProjectPath')) { $a.Remove('VMName'); $a.Remove('VMId') }
    $out = @(); $threw = $null; $iv = $null
    try { $out = @(Enter-Win32ToolkitHyperVLease @a -InformationVariable iv -Verbose 4>$null 6>$null) } catch { $threw = $_ }
    [pscustomobject]@{ Out = $out; L = $(if ($out.Count -ge 1) { $out[0] } else { $null }); Threw = $threw; Host = @($iv | ForEach-Object { "$_" }) }
}
function Get-Verbose { param([hashtable]$Splat)
    $a = @{ VMName = 'vm-test'; VMId = $vmId; LockRoot = $ROOT } + $trust
    foreach ($k in $Splat.Keys) { $a[$k] = $Splat[$k] }
    $all = @(Enter-Win32ToolkitHyperVLease @a -Verbose 4>&1 6>$null)
    [pscustomobject]@{ L = @($all | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })[0]; Verbose = @($all | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }) }
}
# A foreign holder's diagnostics are printed only while they name a running process (with its start time): the test
# process itself plays the holder.
$myStart = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
$shape = 'Kind,Path,Name,VMName,VMId,ProjectPath,Purpose,Epoch,Generation,PreviousGeneration,Nested,Released'
$guidRx = '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$'

try {
    # ============================== [a] first acquisition ==============================
    Write-Host '[a] the first acquisition: one lease object; header, epoch, generation 0 and the diagnostics in the file' -ForegroundColor Cyan
    $script:HyperVLeases = $null
    $x = Invoke-Enter @{ Purpose = 'test run' }
    $l = $x.L
    if (-not $x.Threw -and $x.Out.Count -eq 1 -and (@($l.PSObject.Properties.Name) -join ',') -eq $shape -and $l.Kind -eq 'VM' -and $l.Path -eq $lockFile -and $l.VMId -eq $vmId -and
        $l.Generation -eq 0 -and $l.PreviousGeneration -eq -1 -and $l.Epoch -match $guidRx -and -not $l.Nested -and -not $l.Released -and $l.Purpose -eq 'test run' -and $l.Name -eq 'vm-test') {
        Ok 'exactly one object (Kind, Path, Name, VMName, VMId, ProjectPath, Purpose, Epoch, Generation 0, PreviousGeneration -1, Nested, Released)'
    } else { Bad "first: threw=$($x.Threw) count=$($x.Out.Count) $($l | ConvertTo-Json -Compress)" }
    $text = Read-Lock
    $lines = $text -split "`n"
    if ($lines[0] -ceq 'w32t-lease v1' -and $lines[1] -ceq "epoch=$($l.Epoch)" -and $lines[2] -ceq 'generation=0' -and $lines[3] -ceq "pid=$PID" -and $lines[4] -match '^processStartUtc=\d{4}-\d\d-\d\dT.*Z$' -and
        $lines[5] -ceq 'purpose=test run' -and $lines[6] -match '^acquiredUtc=\d{4}-\d\d-\d\dT.*Z$' -and $text.EndsWith("`n") -and -not $text.Contains("`r")) {
        Ok 'the file: w32t-lease v1, epoch, generation=0, pid, processStartUtc, purpose, acquiredUtc (LF, UTF-8, readable while held)'
    } else { Bad "file: $text" }
    $pk = [System.IO.FileStream]::new($lockFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $b0 = $pk.ReadByte() } finally { $pk.Dispose() }
    if ($b0 -eq [int][char]'w') { Ok 'no BOM' } else { Bad "the lock file starts with byte $b0" }
    if ($script:getVm -eq 0) { Ok 'a given VM Id: no Get-VM' } else { Bad "Get-VM calls: $($script:getVm)" }

    # ============================== [b] share modes ==============================
    Write-Host '[b] share modes (V-5): readable while held; a second acquirer and a writer are refused (0x80070020)' -ForegroundColor Cyan
    $hrSecond = Test-Open -Access ReadWrite -Share Read
    $hrWriter = Test-Open -Access ReadWrite -Share ReadWrite
    $hrRead = Test-Open -Access Read -Share ReadWrite
    if ($hrSecond -eq [int]0x80070020) { Ok 'a second (ReadWrite, FileShare.Read) open fails with 0x80070020 (sharing violation)' } else { Bad "second acquirer: $hrSecond" }
    if ($hrWriter -eq [int]0x80070020) { Ok 'a (ReadWrite, FileShare.ReadWrite) writer fails too: the holder never shares write access' } else { Bad "writer: $hrWriter" }
    if ($null -eq $hrRead) { Ok 'a reader (Read, FileShare.ReadWrite) opens it while it is held' } else { Bad "reader: $hrRead" }
    $null = Exit-Win32ToolkitHyperVLease -Lease $l
    $peek = [System.IO.FileStream]::new($lockFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 0 }
        if (-not $x.Threw -and $x.L -and $x.L.Generation -eq 1) { Ok 'a reader holding its peek handle open does not block the next acquirer' } else { Bad "peek blocks: $($x.Threw)" }
    }
    finally { $peek.Dispose() }
    $null = Exit-Win32ToolkitHyperVLease -Lease $x.L

    # ============================== [c] exclusive: wait, one line, timeout ==============================
    Write-Host '[c] another holder: one wait line with its diagnostics, then W32T.HyperVLeaseTimeout' -ForegroundColor Cyan
    $foreign = Open-Foreign -Path $lockFile -Content "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=7`npid=$PID`nprocessStartUtc=$myStart`npurpose=lane`nacquiredUtc=2026-10-24T09:15:30.1234567Z`n"
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 2 }
        $sw.Stop()
    }
    finally { $foreign.Dispose() }
    $e = $x.Threw
    if ($e -and $e.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and $e.CategoryInfo.Category -eq 'ResourceBusy' -and $e.TargetObject -eq 'vm-test' -and $x.Out.Count -eq 0) {
        Ok 'W32T.HyperVLeaseTimeout, category ResourceBusy, target the VM name; no lease returned'
    } else { Bad "timeout: $($e.FullyQualifiedErrorId) $($e.CategoryInfo.Category) target=$($e.TargetObject)" }
    if ("$e" -ceq "Another process kept the test VM 'vm-test' for more than 2 seconds (lease file $lockFile). The test run was not started and the VM was not restored. Wait for it, raise HyperVLeaseWaitMinutes, or pin another VM with W32T_HYPERV_VM.") {
        Ok 'the message names the VM, the wait, the lease file, what was not done and the three ways out'
    } else { Bad "message: $e" }
    if ($x.Host.Count -eq 1 -and $x.Host[0] -ceq "Waiting for the test VM 'vm-test': another process is using it (lane since 2026-10-24 09:15:30Z, process $PID); up to 2 seconds...") {
        Ok 'one host line with the holder''s purpose, acquired time (UTC) and pid, read from the held file'
    } else { Bad "host lines: $($x.Host -join ' | ')" }
    if ($sw.Elapsed.TotalSeconds -ge 1.9 -and $sw.Elapsed.TotalSeconds -lt 15) { Ok "the wait lasted -WaitSeconds ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)" } else { Bad "waited $($sw.Elapsed.TotalSeconds) s" }
    # Diagnostics that cannot be read (a holder that wrote nothing yet): the line without the parenthesis.
    $foreign = Open-Foreign -Path $lockFile -Content ''
    try { $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 1 } } finally { $foreign.Dispose() }
    if ($x.Host.Count -eq 1 -and $x.Host[0] -ceq "Waiting for the test VM 'vm-test': another process is using it; up to 1 second..." -and $x.Threw) { Ok 'no readable diagnostics: the wait line without the parenthesis' } else { Bad "no diag: $($x.Host -join ' | ')" }
    # Untrusted diagnostics are printed as safe text.
    $foreign = Open-Foreign -Path $lockFile -Content "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=7`npid=$PID`npurpose=x$([char]27)[31mred`nacquiredUtc=2026-10-24T09:15:30Z`n"
    try { $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 1 } } finally { $foreign.Dispose() }
    if ($x.Host.Count -eq 1 -and -not $x.Host[0].Contains([string][char]27) -and $x.Host[0].Contains('x?[31mred')) { Ok 'a control character in the holder''s purpose is printed as ?' } else { Bad "unsafe diag: $($x.Host -join ' | ')" }

    # ============================== [c2] stale diagnostics ==============================
    Write-Host '[c2] stale diagnostics (a holder that exited, a reused pid) are never printed; the line waits one attempt' -ForegroundColor Cyan
    # A process that has exited: its id and start time, as the previous holder wrote them.
    $gonePsi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), '/c exit 0')
    $gonePsi.UseShellExecute = $false; $gonePsi.CreateNoWindow = $true
    $gone = [System.Diagnostics.Process]::Start($gonePsi)
    $gone.WaitForExit()
    $gonePid = $gone.Id
    $goneStart = $gone.StartTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $gone.Dispose()
    $staleText = "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=7`npid=$gonePid`nprocessStartUtc=$goneStart`npurpose=turn off`nacquiredUtc=2026-10-24T05:16:42Z`n"
    $script:newText = "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=8`npid=$PID`nprocessStartUtc=$myStart`npurpose=P1 test run`nacquiredUtc=2026-10-24T05:19:11Z`n"
    $script:sleeps = 0
    function Start-Sleep { param($Seconds, $Milliseconds) $script:sleeps++ }
    # Attempt 1: busy, the file still holds the previous holder's diagnostics (the new holder opened it, wrote nothing
    # yet). Attempt 2: busy, the new holder has written its own (or, -Rewrite off, still nothing). Attempt 3: free.
    $script:rewrite = $true
    $race = { param($p)
        $script:opens++
        if ($script:opens -eq 2 -and $script:rewrite) { [System.IO.File]::WriteAllText($p, $script:newText, [System.Text.UTF8Encoding]::new($false)) }
        if ($script:opens -le 2) { throw [System.IO.IOException]::new('being used by another process', [int]0x80070020) }
        [System.IO.FileStream]::new($p, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read) }
    [System.IO.File]::WriteAllText($lockFile, $staleText, $utf8)
    $script:opens = 0
    $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 600; OpenStream = $race }
    if (-not $x.Threw -and $x.Out.Count -eq 1 -and $script:opens -eq 3 -and $x.Host.Count -eq 1 -and
        $x.Host[0] -ceq "Waiting for the test VM 'vm-test': another process is using it (P1 test run since 2026-10-24 05:19:11Z, process $PID); up to 10 minutes...") {
        Ok "a lock file naming a holder that has exited (process $gonePid): no line yet; the next attempt names the new holder"
    } else { Bad "stale then new: threw=$($x.Threw) opens=$($script:opens) host=$($x.Host -join ' | ')" }
    foreach ($le in $x.Out) { $null = Exit-Win32ToolkitHyperVLease -Lease $le }
    # Still stale on the second attempt (the holder is not a toolkit process, or wrote nothing): the line without them.
    $script:rewrite = $false
    foreach ($case in @(
            @{ Tag = 'a holder that has exited'; Text = $staleText }
            @{ Tag = 'a reused process id (another start time)'; Text = "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=7`npid=$PID`nprocessStartUtc=2001-01-01T00:00:00.0000000Z`npurpose=old`nacquiredUtc=2026-10-24T05:16:42Z`n" })) {
        [System.IO.File]::WriteAllText($lockFile, $case.Text, $utf8)
        $script:opens = 0
        $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 600; OpenStream = $race }
        if (-not $x.Threw -and $x.Out.Count -eq 1 -and $x.Host.Count -eq 1 -and $x.Host[0] -ceq "Waiting for the test VM 'vm-test': another process is using it; up to 10 minutes...") {
            Ok "$($case.Tag), still on the second attempt: one line without the diagnostics"
        } else { Bad "$($case.Tag): threw=$($x.Threw) host=$($x.Host -join ' | ')" }
        foreach ($le in $x.Out) { $null = Exit-Win32ToolkitHyperVLease -Lease $le }
    }
    Remove-Item Function:\Start-Sleep
    # A wait that ends on the first attempt prints at once, without the stale diagnostics.
    [System.IO.File]::WriteAllText($lockFile, $staleText, $utf8)
    $slowBusy = { param($p) [System.Threading.Thread]::Sleep(1100); throw [System.IO.IOException]::new('being used by another process', [int]0x80070020) }
    $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 1; OpenStream = $slowBusy }
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and $x.Host.Count -eq 1 -and $x.Host[0] -ceq "Waiting for the test VM 'vm-test': another process is using it; up to 1 second...") {
        Ok 'a wait that ends on the first attempt: the line at once, without the stale diagnostics'
    } else { Bad "ending: $($x.Threw.FullyQualifiedErrorId) host=$($x.Host -join ' | ')" }

    # ============================== [d] release, generations, abandoned file ==============================
    Write-Host '[d] release: re-acquirable, generation +1, same epoch; an abandoned file advances; the file stays' -ForegroundColor Cyan
    $foreign = Open-Foreign -Path $lockFile -Content "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=7`npid=4242`n"
    $foreign.Dispose()   # the holder died: Windows closed its handle
    $x = Invoke-Enter @{ Purpose = 'test run' }
    if (-not $x.Threw -and $x.L.Epoch -eq '11111111-2222-3333-4444-555555555555' -and $x.L.PreviousGeneration -eq 7 -and $x.L.Generation -eq 8) { Ok 'an abandoned file: acquired at once, same epoch, PreviousGeneration 7, Generation 8' } else { Bad "abandoned: $($x.Threw) $($x.L | ConvertTo-Json -Compress)" }
    $out = @(Exit-Win32ToolkitHyperVLease -Lease $x.L)
    if ($null -eq (Test-Open -Access ReadWrite -Share None)) { Ok 'Exit closes the file (an exclusive open succeeds)' } else { Bad 'still held after Exit' }
    if (Test-Path -LiteralPath $lockFile) { Ok 'the file stays after Exit (no DeleteOnClose)' } else { Bad 'the lock file was deleted' }
    $y = Invoke-Enter @{ Purpose = 'reset' }
    if ($y.L.Epoch -eq $x.L.Epoch -and $y.L.PreviousGeneration -eq 8 -and $y.L.Generation -eq 9) { Ok 're-acquired: generation 9 (PreviousGeneration 8), the same epoch' } else { Bad "again: $($y.L | ConvertTo-Json -Compress)" }
    if ((Read-Lock) -match "(?m)^purpose=reset$") { Ok 'the diagnostics are rewritten by each holder' } else { Bad 'purpose not rewritten' }

    # ============================== [e] re-entrancy ==============================
    Write-Host '[e] nested in the same process: no write, count 2, PreviousGeneration = Generation; release order' -ForegroundColor Cyan
    $before = Read-Lock
    $stampBefore = (Get-Item -LiteralPath $lockFile).LastWriteTimeUtc
    $n = Invoke-Enter @{ Purpose = 'lane' }
    $held = $script:HyperVLeases[$lockFile]
    if (-not $n.Threw -and $n.L.Nested -and $n.L.Generation -eq 9 -and $n.L.PreviousGeneration -eq 9 -and $n.L.Epoch -eq $y.L.Epoch -and $held['Count'] -eq 2 -and (Read-Lock) -ceq $before) {
        Ok 'nested: Nested $true, Generation 9 = PreviousGeneration, count 2, the file unchanged'
    } else { Bad "nested: $($n.L | ConvertTo-Json -Compress) count=$($held['Count'])" }
    if ((Get-Item -LiteralPath $lockFile).LastWriteTimeUtc -eq $stampBefore) { Ok 'nested: no write at all' } else { Bad 'nested wrote the file' }
    $null = Exit-Win32ToolkitHyperVLease -Lease $n.L
    $null = Exit-Win32ToolkitHyperVLease -Lease $n.L   # twice: idempotent
    if ($held['Count'] -eq 1 -and (Test-Open -Access ReadWrite -Share Read) -eq [int]0x80070020 -and $n.L.Released) { Ok 'the nested Exit (twice) leaves the outer hold: count 1, still refused to others' } else { Bad "after nested exit: count=$($held['Count'])" }
    $null = Exit-Win32ToolkitHyperVLease -Lease $y.L
    if ($null -eq $script:HyperVLeases[$lockFile] -and $null -eq (Test-Open -Access ReadWrite -Share None)) { Ok 'the outer Exit releases the file' } else { Bad 'outer exit did not release' }

    # ============================== [f] a corrupt file ==============================
    Write-Host '[f] an unreadable file starts a new epoch (PreviousGeneration -1)' -ForegroundColor Cyan
    foreach ($case in @(
            @{ Tag = 'another header'; Text = "w32t-lease v2`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=3`n" }
            @{ Tag = 'a bad epoch'; Text = "w32t-lease v1`nepoch=not-a-guid`ngeneration=3`n" }
            @{ Tag = 'letters in the generation'; Text = "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=3a`n" }
            @{ Tag = 'a 19-digit generation'; Text = "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=1000000000000000000`n" }
            @{ Tag = 'the last generation (no overflow)'; Text = "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=999999999999999999`n" }
            @{ Tag = 'an empty file'; Text = '' })) {
        [System.IO.File]::WriteAllText($lockFile, $case.Text, $utf8)
        $v = Get-Verbose @{ Purpose = 'test run' }
        $newEpoch = $v.L.Epoch -match $guidRx -and $v.L.Epoch -ne '11111111-2222-3333-4444-555555555555'
        $line = @($v.Verbose | Where-Object { $_ -like '*was not readable: a new epoch starts*' }).Count
        if ($newEpoch -and $v.L.PreviousGeneration -eq -1 -and $v.L.Generation -eq 0 -and $line -eq $(if ($case.Text) { 1 } else { 0 })) { Ok "$($case.Tag): a new epoch, PreviousGeneration -1, Generation 0" } else { Bad "$($case.Tag): $($v.L | ConvertTo-Json -Compress) lines=$line" }
        $null = Exit-Win32ToolkitHyperVLease -Lease $v.L
    }

    # ============================== [g] access denied only ==============================
    Write-Host '[g] access denied only (V-6): 12 attempts end the wait at once, "run the session elevated"' -ForegroundColor Cyan
    $script:sleeps = 0
    function Start-Sleep { param($Seconds, $Milliseconds) $script:sleeps++ }
    $script:opens = 0
    $denied = { param($p) $script:opens++; throw [System.UnauthorizedAccessException]::new("Access to the path '$p' is denied.") }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 600; OpenStream = $denied }
    $sw.Stop()
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and "$($x.Threw)" -ceq "The test run was not started: this session could not open the lease file $lockFile of the test VM 'vm-test' (access denied): run the session elevated." -and
        $script:opens -eq 12 -and $script:sleeps -eq 11 -and $sw.Elapsed.TotalSeconds -lt 30 -and $x.Host.Count -eq 0) {
        Ok "12 denied attempts (11 sleeps) end the wait at once ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s of a 600 s wait), the elevated wording, no wait line"
    } else { Bad "denied: id=$($x.Threw.FullyQualifiedErrorId) opens=$($script:opens) sleeps=$($script:sleeps) host=$($x.Host.Count) msg=$($x.Threw)" }
    # a sharing violation in between restarts the count: 6 denied, 1 busy, then 12 denied
    $script:opens = 0; $script:sleeps = 0
    $mixed = { param($p) $script:opens++; if ($script:opens -eq 7) { throw [System.IO.IOException]::new('being used by another process', [int]0x80070020) }; throw [System.UnauthorizedAccessException]::new('denied') }
    $x = Invoke-Enter @{ Purpose = 'test run'; WaitSeconds = 600; OpenStream = $mixed }
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and "$($x.Threw)" -like '*(access denied): run the session elevated.' -and $script:opens -eq 19 -and $x.Host.Count -eq 1) {
        Ok 'a sharing violation between denials restarts the count (19 attempts), and prints the one wait line'
    } else { Bad "mixed: opens=$($script:opens) host=$($x.Host.Count) msg=$($x.Threw)" }

    # ============================== [h] -WaitSeconds 0 ==============================
    Write-Host '[h] -WaitSeconds 0: one attempt, no sleep, no wait line' -ForegroundColor Cyan
    $script:opens = 0; $script:sleeps = 0
    $busy = { param($p) $script:opens++; throw [System.IO.IOException]::new('being used by another process', [int]0x80070020) }
    $x = Invoke-Enter @{ Purpose = 'lane'; WaitSeconds = 0; OpenStream = $busy }
    if ($script:opens -eq 1 -and $script:sleeps -eq 0 -and $x.Host.Count -eq 0 -and "$($x.Threw)" -ceq "Another process holds the test VM 'vm-test' (lease file $lockFile). The lane was not started and the VM was not restored.") {
        Ok 'exactly one attempt; the "holds" wording'
    } else { Bad "wait 0: opens=$($script:opens) sleeps=$($script:sleeps) host=$($x.Host.Count) msg=$($x.Threw)" }
    # A lock violation (0x80070021) is busy too; any other IOException is thrown as it is.
    $script:opens = 0
    $x = Invoke-Enter @{ WaitSeconds = 0; OpenStream = { param($p) $script:opens++; throw [System.IO.IOException]::new('lock', [int]0x80070021) } }
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout') { Ok '0x80070021 (lock violation) counts as busy' } else { Bad "lock violation: $($x.Threw.FullyQualifiedErrorId)" }
    $x = Invoke-Enter @{ WaitSeconds = 0; OpenStream = { param($p) throw [System.IO.IOException]::new('disk full', [int]0x80070070) } }
    if ($x.Threw -and $x.Threw.FullyQualifiedErrorId -notlike 'W32T.*' -and "$($x.Threw)" -like '*disk full*') { Ok 'another IO error is thrown as it is (not a W32T error)' } else { Bad "other io: $($x.Threw.FullyQualifiedErrorId)" }

    # ============================== [i] HyperVLeaseWaitMinutes ==============================
    Write-Host '[i] HyperVLeaseWaitMinutes: the wait the line names; invalid -> 60 + one verbose line' -ForegroundColor Cyan
    # The first attempt is busy, the second opens the real file: one wait line, then the lease.
    $script:opens = 0
    $busyOnce = { param($p) $script:opens++; if ($script:opens -eq 1) { throw [System.IO.IOException]::new('being used by another process', [int]0x80070020) }
        [System.IO.FileStream]::new($p, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read) }
    foreach ($case in @(
            @{ Value = $null; Want = '60 minutes'; Line = 0 }
            @{ Value = '5'; Want = '5 minutes'; Line = 0 }
            @{ Value = ' 240 '; Want = '240 minutes'; Line = 0 }
            @{ Value = '1'; Want = '1 minute'; Line = 0 }
            @{ Value = '0'; Want = '60 minutes'; Line = 1 }
            @{ Value = '241'; Want = '60 minutes'; Line = 1 }
            @{ Value = '1.5'; Want = '60 minutes'; Line = 1 }
            @{ Value = 'soon'; Want = '60 minutes'; Line = 1 })) {
        $script:cfg = if ($null -ne $case.Value) { @{ HyperVLeaseWaitMinutes = $case.Value } } else { @{} }
        $script:opens = 0
        $all = @(Enter-Win32ToolkitHyperVLease -VMName 'vm-test' -VMId $vmId -LockRoot $ROOT -OpenStream $busyOnce @trust -Verbose 4>&1 6>&1)
        $lease = @($all | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Kind'] })
        $hostLine = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
        $vline = @($all | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like 'HyperVLeaseWaitMinutes*is not an integer from 1 to 240; 60 minutes are used.' })
        if ($lease.Count -eq 1 -and $hostLine.Count -eq 1 -and $hostLine[0].EndsWith("up to $($case.Want)...") -and $vline.Count -eq $case.Line) {
            Ok "HyperVLeaseWaitMinutes $(if ($null -eq $case.Value) { 'absent' } else { "'$($case.Value)'" }): up to $($case.Want), $($case.Line) verbose line(s)"
        } else { Bad "value '$($case.Value)': host=$($hostLine -join ' | ') verbose=$($vline.Count) lease=$($lease.Count)" }
        foreach ($le in $lease) { $null = Exit-Win32ToolkitHyperVLease -Lease $le }
    }
    $script:cfg = @{}
    Remove-Item Function:\Start-Sleep

    # ============================== [j] the VM Id ==============================
    Write-Host '[j] the VM Id: Get-VM when not given; a given Id lower-case; a missing VM fails with the cmdlet''s error' -ForegroundColor Cyan
    $script:getVm = 0
    $x = Invoke-Enter @{ VMId = '' }
    if ($script:getVm -eq 1 -and $x.L.VMId -eq $vmId -and $x.L.Path -eq $lockFile) { Ok 'no -VMId: one Get-VM, the file named by its Id' } else { Bad "no id: getVm=$($script:getVm) $($x.L.Path) threw=$($x.Threw)" }
    $null = Exit-Win32ToolkitHyperVLease -Lease $x.L
    $script:getVm = 0
    $x = Invoke-Enter @{ VMId = $vmId.ToUpperInvariant() }
    if ($script:getVm -eq 0 -and $x.L.Path -eq $lockFile -and $x.L.VMId -ceq $vmId) { Ok 'an upper-case -VMId: no Get-VM, the same lower-case file' } else { Bad "upper id: getVm=$($script:getVm) $($x.L.Path)" }
    $null = Exit-Win32ToolkitHyperVLease -Lease $x.L
    $script:getVm = 0
    $x = Invoke-Enter @{ VMId = 'not-a-guid' }
    if ($script:getVm -eq 1 -and $x.L.Path -eq $lockFile) { Ok 'a -VMId that is not a GUID: read with Get-VM' } else { Bad "bad id: getVm=$($script:getVm) $($x.L.Path) threw=$($x.Threw)" }
    $null = Exit-Win32ToolkitHyperVLease -Lease $x.L
    $script:vmMissing = $true
    $x = Invoke-Enter @{ VMId = $null }
    $script:vmMissing = $false
    if ($x.Threw -and $x.Threw.FullyQualifiedErrorId -notlike 'W32T.*' -and "$($x.Threw)" -like '*unable to find a virtual machine*') { Ok 'a VM that does not exist: the cmdlet''s error, not a W32T error' } else { Bad "missing vm: $($x.Threw.FullyQualifiedErrorId) $($x.Threw)" }

    # ============================== [k] per-project ==============================
    Write-Host '[k] per-project: project-<first 32 hex of SHA256(lower-case full path)>.lock; W32T.ProjectLeaseTimeout' -ForegroundColor Cyan
    $projDir = Join-Path $BASE 'Projects\Contoso\Notepad++_x64_8.7'
    $null = New-Item -ItemType Directory -Path $projDir -Force
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $want = 'project-' + (-join ($sha.ComputeHash($utf8.GetBytes(([System.IO.Path]::GetFullPath($projDir)).ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') })).Substring(0, 32) + '.lock'
    $sha.Dispose()
    $p1 = Enter-Win32ToolkitHyperVLease -ProjectPath $projDir -Purpose 'test' -LockRoot $ROOT @trust
    $p2 = Enter-Win32ToolkitHyperVLease -ProjectPath ($projDir.ToUpperInvariant() + '\') -Purpose 'test' -LockRoot $ROOT @trust
    if ((Split-Path -Leaf $p1.Path) -ceq $want -and $p1.Kind -eq 'Project' -and $p1.ProjectPath -eq $projDir -and $null -eq $p1.VMName -and $p2.Nested -and $p2.Path -eq $p1.Path) {
        Ok "the file name follows the SHA256 rule ($want); another case and a trailing separator are the same lease"
    } else { Bad "project: $($p1.Path) nested=$($p2.Nested)" }
    # A relative path after Set-Location: the PowerShell location, never the process's working folder (which
    # Set-Location does not change, so .NET's GetFullPath alone would hash another folder).
    Push-Location -LiteralPath (Join-Path $BASE 'Projects\Contoso')
    try {
        $dotNet = [System.IO.Path]::GetFullPath('.\Notepad++_x64_8.7')
        $p3 = Enter-Win32ToolkitHyperVLease -ProjectPath '.\Notepad++_x64_8.7' -Purpose 'test' -LockRoot $ROOT @trust
    }
    finally { Pop-Location }
    if ($dotNet -ne $projDir -and $p3.Nested -and $p3.Path -eq $p1.Path -and $p3.Name -eq 'Notepad++_x64_8.7') {
        Ok 'a relative -ProjectPath after Set-Location is the same lease as the full path (not the process folder''s)'
    } else { Bad "relative: dotnet=$dotNet path=$($p3.Path) nested=$($p3.Nested)" }
    $null = Exit-Win32ToolkitHyperVLease -Lease $p3
    $null = Exit-Win32ToolkitHyperVLease -Lease $p2; $null = Exit-Win32ToolkitHyperVLease -Lease $p1
    $foreign = Open-Foreign -Path $p1.Path -Content "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=1`npid=$PID`nprocessStartUtc=$myStart`npurpose=lane`nacquiredUtc=2026-10-24T09:00:00Z`n"
    try { $x = Invoke-Enter @{ VMName = $null; VMId = $null; ProjectPath = $projDir; Purpose = 'test'; WaitSeconds = 1 } }
    finally { $foreign.Dispose() }
    $pn = 'Notepad++_x64_8.7'
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.ProjectLeaseTimeout' -and $x.Threw.CategoryInfo.Category -eq 'ResourceBusy' -and $x.Threw.TargetObject -eq $pn -and
        "$($x.Threw)" -ceq "Another process kept the project '$pn' for more than 1 second (lease file $($p1.Path)). The test was not started. Wait for it, or raise HyperVLeaseWaitMinutes." -and
        $x.Host.Count -eq 1 -and $x.Host[0] -ceq "Waiting for the project '$pn': another process is testing it (lane since 2026-10-24 09:00:00Z, process $PID); up to 1 second...") {
        Ok 'a busy project: W32T.ProjectLeaseTimeout naming the project, its own wait line'
    } else { Bad "project busy: $($x.Threw.FullyQualifiedErrorId) msg=$($x.Threw) host=$($x.Host -join ' | ')" }

    # ============================== [l] output shapes ==============================
    Write-Host '[l] C-12: Enter emits exactly one object, Exit nothing' -ForegroundColor Cyan
    $o1 = @(Enter-Win32ToolkitHyperVLease -VMName 'vm-test' -VMId $vmId -LockRoot $ROOT @trust)
    $o2 = @(Enter-Win32ToolkitHyperVLease -VMName 'vm-test' -VMId $vmId -LockRoot $ROOT @trust)
    $e1 = @(Exit-Win32ToolkitHyperVLease -Lease $o2[0]); $e2 = @(Exit-Win32ToolkitHyperVLease -Lease $o1[0]); $e3 = @(Exit-Win32ToolkitHyperVLease -Lease $o1[0]); $e4 = @(Exit-Win32ToolkitHyperVLease -Lease $null)
    if ($o1.Count -eq 1 -and $o2.Count -eq 1 -and ($e1.Count + $e2.Count + $e3.Count + $e4.Count) -eq 0) { Ok 'Enter (outer and nested): one object each; Exit (nested, outer, again, $null): nothing' } else { Bad "shapes: $($o1.Count) $($o2.Count) / $($e1.Count) $($e2.Count) $($e3.Count) $($e4.Count)" }

    # ============================== [m] not inherited ==============================
    Write-Host '[m] a child process started while the lease is held does not inherit the handle' -ForegroundColor Cyan
    $l = Enter-Win32ToolkitHyperVLease -VMName 'vm-test' -VMId $vmId -LockRoot $ROOT @trust
    $psi =[System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 20')) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardInput = $true
    $child = [System.Diagnostics.Process]::Start($psi)
    try {
        Start-Sleep -Milliseconds 500
        $null = Exit-Win32ToolkitHyperVLease -Lease $l
        $hr = Test-Open -Access ReadWrite -Share None
        if (-not $child.HasExited -and $null -eq $hr) { Ok 'released while the child still runs: the file opens exclusively (the child holds no copy of the handle)' } else { Bad "inherited: exited=$($child.HasExited) hr=$hr" }
    }
    finally { try { $child.Kill($true) } catch { $null = $_ }; $child.Dispose() }

    # ============================== [n] OnRemove ==============================
    Write-Host '[n] the module''s OnRemove closes a held lease (Remove-Module)' -ForegroundColor Cyan
    $childScript = @'
param($Repo, $Root, $VMId, [string[]]$Trust)
$ErrorActionPreference = 'Stop'
$mod = Import-Module (Join-Path $Repo 'win32-toolkit.psd1') -PassThru -WarningAction SilentlyContinue
$t = if ($Trust) { @{ TrustedOwnerSid = $Trust } } else { @{} }
$lease = & $mod { param($r, $i, $t) Enter-Win32ToolkitHyperVLease -VMName 'vm-onremove' -VMId $i -LockRoot $r -Purpose 'onremove' @t } $Root $VMId $t
$path = $lease.Path
function Try-Exclusive { try { $fs = [System.IO.FileStream]::new($path, 'Open', 'ReadWrite', 'None'); $fs.Dispose(); 'open' } catch { 'refused' } }
$before = Try-Exclusive
Remove-Module win32-toolkit
$after = Try-Exclusive
"$before|$after"
'@
    $childFile = Join-Path $ROOT 'onremove-child.ps1'
    [System.IO.File]::WriteAllText($childFile, $childScript, $utf8)
    $trustArg = if ($elevatedOwner) { @() } else { @('-Trust', $me) }
    $res = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $childFile -Repo $repo -Root $ROOT -VMId '22222222-3333-4444-5555-666666666666' @trustArg 2>&1
    $last = @($res | ForEach-Object { "$_" })[-1]
    if ($last -ceq 'refused|open') { Ok 'held through the real module (an exclusive open is refused), closed by Remove-Module (it opens)' } else { Bad "onremove: $(@($res) -join ' | ')" }

    # ============================== [o] file hygiene ==============================
    Write-Host '[o] file hygiene: ASCII, one function each, every catch starts with the C-2 line' -ForegroundColor Cyan
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    foreach ($name in 'Enter-Win32ToolkitHyperVLease', 'Exit-Win32ToolkitHyperVLease') {
        $file = Join-Path $repo "Private\$name.ps1"
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
        $catches = @($ast.FindAll({ param($nd) $nd -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
        $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
        $top = @($ast.EndBlock.Statements)
        $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $name -and -not $ast.ParamBlock
        if (@($errs).Count -eq 0 -and $catches.Count -ge 1 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "$name : ASCII, one function, $($catches.Count) catch(es) with the C-2 line" }
        else { Bad "$name : errors $(@($errs).Count), catches $($catches.Count), bad $($badCatch.Count), ascii $ascii, one function $oneFunction" }
    }
    # The code (not the help) uses exactly FileShare.Read (the holder) and FileShare.ReadWrite (the waiters' peek), and
    # neither FileShare.Inheritable nor FileOptions.DeleteOnClose.
    $astE = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private\Enter-Win32ToolkitHyperVLease.ps1'), [ref]$null, [ref]$null)
    $statics = @($astE.FindAll({ param($nd) $nd -is [System.Management.Automation.Language.MemberExpressionAst] -and $nd.Static -and $nd.Expression -is [System.Management.Automation.Language.TypeExpressionAst] }, $true) |
        ForEach-Object { "$($_.Expression.TypeName.FullName)::$($_.Member.Extent.Text)" })
    $shares = @($statics | Where-Object { $_ -like 'System.IO.FileShare::*' } | Sort-Object -Unique)
    if (($shares -join ',') -eq 'System.IO.FileShare::Read,System.IO.FileShare::ReadWrite' -and @($statics | Where-Object { $_ -match 'Inheritable|DeleteOnClose' }).Count -eq 0) {
        Ok 'the code shares the file for Read (holder) and ReadWrite (peek) only; no Inheritable, no DeleteOnClose'
    } else { Bad "statics: $($shares -join ', ') / $(@($statics | Where-Object { $_ -match 'Inheritable|DeleteOnClose' }) -join ', ')" }
    # The native type (a constant string): the holder's CreateFileW opens read+write, OPEN_ALWAYS, no security attributes
    # (not inheritable), FILE_FLAG_OPEN_REPARSE_POINT and never FILE_FLAG_DELETE_ON_CLOSE; Describe never follows a link.
    $addTypes = @($astE.FindAll({ param($nd) $nd -is [System.Management.Automation.Language.CommandAst] -and $nd.GetCommandName() -eq 'Add-Type' }, $true))
    $typeText = if ($addTypes.Count -eq 1) { $addTypes[0].Extent.Text } else { '' }
    if ($typeText -match [regex]::Escape('CreateFileW(path, 0xC0000000, (uint)share, IntPtr.Zero, 4, 0x80 | 0x00200000, IntPtr.Zero)') -and
        $typeText -match [regex]::Escape('CreateFileW(path, 0x00020080, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero)') -and $typeText -notmatch '0x04000000|Inherit') {
        Ok 'the native open: read+write, OPEN_ALWAYS, no security attributes, OPEN_REPARSE_POINT, no DELETE_ON_CLOSE; Describe opens without following'
    } else { Bad 'the native type text changed' }
    # The hidden -TrustedOwnerSid weakens the check: tests only, never module or runner code.
    $passers = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Private'), (Join-Path $repo 'Public'), (Join-Path $repo 'scripts') -Filter '*.ps1' -File -Recurse) + @(Get-Item -LiteralPath (Join-Path $repo 'win32-toolkit.psm1')) |
        Where-Object { $_.Name -ne 'Enter-Win32ToolkitHyperVLease.ps1' -and [System.IO.File]::ReadAllText($_.FullName) -match 'TrustedOwnerSid' }
    if ($passers.Count -eq 0) { Ok 'no module or runner file passes -TrustedOwnerSid' } else { Bad "-TrustedOwnerSid in: $(@($passers | ForEach-Object Name) -join ', ')" }

    # ============================== [p] the lock folder and file are not trusted ==============================
    Write-Host '[p] W32T.HyperVLeaseUnsafe: links, foreign owners, an untrusted creator, another file opened; nothing written' -ForegroundColor Cyan
    $isUnsafe = { param($x, [string]$Like, [string]$Category = 'SecurityError')
        $x.Threw -and $x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseUnsafe' -and "$($x.Threw.CategoryInfo.Category)" -eq $Category -and $x.Out.Count -eq 0 -and "$($x.Threw)" -like $Like }
    $files = { param([string]$Dir) @(Get-ChildItem -LiteralPath $Dir -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    $id2 = '0e5f9e66-aaaa-2222-3333-444455556666'

    # (1) a lock folder whose parent is a junction: refused, nothing in the junction's target (which has a 'locks' folder)
    $t1 = Join-Path $BASE 'p1-target'; $null = New-Item -ItemType Directory -Path (Join-Path $t1 'locks') -Force
    $j1 = Join-Path $BASE 'p1-parent'; $null = New-Item -ItemType Junction -Path $j1 -Target $t1
    $x = Invoke-Enter @{ LockRoot = (Join-Path $j1 'locks'); VMId = $id2 }
    if ((& $isUnsafe $x "The test was not started: the lock folder $j1 is a link (reparse point) or not a folder, so no lock file is written there. Remove it from an elevated session*") -and
        (& $files $t1).Count -eq 1) {
        Ok 'a lock folder whose parent is a junction: refused, nothing written in the junction''s target'
    } else { Bad "parent junction: $($x.Threw.FullyQualifiedErrorId) $($x.Threw) / target: $((& $files $t1) -join ',')" }
    # ... and a lock folder that is itself a junction
    $t1b = Join-Path $BASE 'p1b-target'; $null = New-Item -ItemType Directory -Path $t1b -Force
    $j1b = Join-Path $BASE 'p1b-locks'; $null = New-Item -ItemType Junction -Path $j1b -Target $t1b
    $x = Invoke-Enter @{ LockRoot = $j1b; VMId = $id2 }
    if ((& $isUnsafe $x "*the lock folder $j1b is a link (reparse point)*") -and (& $files $t1b).Count -eq 0) { Ok 'a lock folder that is a junction: refused, its target stays empty' } else { Bad "root junction: $($x.Threw) / $((& $files $t1b) -join ',')" }

    # (2) a folder owned by a non-admin SID (the default owners): the parent, then the lock folder itself
    $p2 = Join-Path $BASE 'p2'; $null = New-Item -ItemType Directory -Path $p2 -Force
    if ($elevatedOwner) { Set-TestOwner -Path $p2 -Sid $userSid }
    $x = Invoke-Enter @{ LockRoot = (Join-Path $p2 'locks'); VMId = $id2 } -DefaultOwners
    if ((& $isUnsafe $x "*the lock folder $p2 belongs to *($userSid), not to Administrators or SYSTEM, so another account could redirect its lock files. Remove it from an elevated session*") -and
        (& $files $p2).Count -eq 0) {
        Ok 'a parent folder owned by a non-admin SID: refused (the owner named), no lock folder created in it'
    } else { Bad "owner parent: $($x.Threw.FullyQualifiedErrorId) $($x.Threw) / $((& $files $p2) -join ',')" }
    if ($elevatedOwner) {
        $p2b = Join-Path $BASE 'p2b\locks'; $null = New-Item -ItemType Directory -Path $p2b -Force
        Set-TestOwner -Path $p2b -Sid $userSid
        $x = Invoke-Enter @{ LockRoot = $p2b; VMId = $id2 } -DefaultOwners
        if ((& $isUnsafe $x "*the lock folder $p2b belongs to *($userSid)*") -and (& $files $p2b).Count -eq 0) { Ok 'a lock folder owned by a non-admin SID: refused, no lock file in it' } else { Bad "owner locks: $($x.Threw) / $((& $files $p2b) -join ',')" }
    } else { Skip 'a lock folder owned by a non-admin SID under an admin-owned parent' }

    # (3) this session would create the folder or the lock file with an untrusted owner: PermissionDenied, nothing created
    if ($elevatedOwner) {
        $p3 = Join-Path $BASE 'p3'; $null = New-Item -ItemType Directory -Path $p3 -Force
        Set-TestOwner -Path $p3 -Sid $userSid
        $x = Invoke-Enter @{ LockRoot = (Join-Path $p3 'locks'); VMId = $id2; TrustedOwnerSid = @($userSid) }
        if ((& $isUnsafe $x "*the lock folder $(Join-Path $p3 'locks') does not exist, and this session would create it owned by *($me), not by Administrators or SYSTEM: run the session elevated." 'PermissionDenied') -and
            (& $files $p3).Count -eq 0) {
            Ok 'a missing lock folder this session would own untrusted: PermissionDenied, not created'
        } else { Bad "create folder: $($x.Threw.CategoryInfo.Category) $($x.Threw) / $((& $files $p3) -join ',')" }
        $p3l = Join-Path $p3 'locks'; $null = New-Item -ItemType Directory -Path $p3l -Force; Set-TestOwner -Path $p3l -Sid $userSid
        $x = Invoke-Enter @{ LockRoot = $p3l; VMId = $id2; TrustedOwnerSid = @($userSid) }
        if ((& $isUnsafe $x "*the lease file $(Join-Path $p3l "hyperv-$id2.lock") of the test VM 'vm-test' does not exist, and this session would create it owned by *run the session elevated." 'PermissionDenied') -and
            (& $files $p3l).Count -eq 0) {
            Ok 'a missing lock file this session would own untrusted: PermissionDenied, not created'
        } else { Bad "create file: $($x.Threw) / $((& $files $p3l) -join ',')" }
    } else { Skip 'a folder or lock file this session would create with an untrusted owner' }

    # (4) a junction at the lock file's name: refused before the open, nothing in its target
    $t4 = Join-Path $BASE 'p4-target'; $null = New-Item -ItemType Directory -Path $t4 -Force
    $null = New-Item -ItemType Junction -Path (Join-Path $ROOT "hyperv-$id2.lock") -Target $t4
    $x = Invoke-Enter @{ VMId = $id2 }
    if ((& $isUnsafe $x "*the lease file $(Join-Path $ROOT "hyperv-$id2.lock") of the test VM 'vm-test' is not written: it is a link (reparse point). Remove it from an elevated session*") -and (& $files $t4).Count -eq 0) {
        Ok 'a junction at the lock file''s name: refused, its target stays empty'
    } else { Bad "file junction: $($x.Threw) / $((& $files $t4) -join ',')" }

    # (5) a hard link at the lock file's name: refused, the other name's content unchanged
    $id5 = '0e5f9e66-bbbb-2222-3333-444455556666'
    $other = Join-Path $BASE 'p5-other.txt'; [System.IO.File]::WriteAllText($other, 'keep', $utf8)
    $null = New-Item -ItemType HardLink -Path (Join-Path $ROOT "hyperv-$id5.lock") -Target $other
    $x = Invoke-Enter @{ VMId = $id5 }
    if ((& $isUnsafe $x '*is not written: it has 2 names (hard links).*') -and [System.IO.File]::ReadAllText($other) -ceq 'keep') {
        Ok 'a hard link at the lock file''s name: refused, the linked file unchanged'
    } else { Bad "hard link: $($x.Threw) / $([System.IO.File]::ReadAllText($other))" }

    # (6) a lock file owned by another account (the default owners): refused, unchanged
    if ($elevatedOwner) {
        $id6 = '0e5f9e66-cccc-2222-3333-444455556666'
        $f6 = Join-Path $ROOT "hyperv-$id6.lock"; [System.IO.File]::WriteAllText($f6, "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=4`n", $utf8)
        Set-TestOwner -Path $f6 -Sid $userSid
        $x = Invoke-Enter @{ VMId = $id6 } -DefaultOwners
        if ((& $isUnsafe $x "*is not written: it belongs to *($userSid), not to Administrators or SYSTEM.*") -and [System.IO.File]::ReadAllText($f6).Contains('generation=4')) {
            Ok 'a lock file owned by a non-admin SID: refused, its content unchanged'
        } else { Bad "file owner: $($x.Threw)" }
    } else { Skip 'a lock file owned by another account' }

    # (7) the open handle is checked: a stream on another file (as a link planted between the check and the open
    # would give) is refused before anything is read or written, and closed.
    $id7 = '0e5f9e66-dddd-2222-3333-444455556666'
    $else7 = Join-Path $BASE 'p7-elsewhere.txt'; [System.IO.File]::WriteAllText($else7, 'keep', $utf8)
    $redirect = { param($p) [System.IO.FileStream]::new($else7, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read) }
    $x = Invoke-Enter @{ VMId = $id7; OpenStream = $redirect }
    if ((& $isUnsafe $x "*the lease file $(Join-Path $ROOT "hyperv-$id7.lock") of the test VM 'vm-test' is not written: it resolves to *p7-elsewhere.txt, outside the lock folder.*") -and
        [System.IO.File]::ReadAllText($else7) -ceq 'keep' -and $null -eq (Test-Open -Path $else7 -Access ReadWrite -Share None) -and $null -eq $script:HyperVLeases[(Join-Path $ROOT "hyperv-$id7.lock")]) {
        Ok 'a stream that opened another file: refused on the handle''s final path, nothing written, the stream closed, no lease kept'
    } else { Bad "redirect: $($x.Threw) / $([System.IO.File]::ReadAllText($else7))" }

    # ============================== [q] no error record per attempt ==============================
    Write-Host '[q] a wait with the default open leaves no error record per attempt ($Error, -ErrorVariable)' -ForegroundColor Cyan
    $holderText = "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=20`npid=$PID`nprocessStartUtc=$myStart`npurpose=lane`nacquiredUtc=2026-10-24T09:00:00Z`n"
    # Two busy attempts on a file another holder keeps open, then the holder lets go (in the second sleep).
    $script:qHolder = Open-Foreign -Path $lockFile -Content $holderText
    $script:sleeps = 0
    function Start-Sleep { param($Seconds, $Milliseconds) $script:sleeps++; if ($script:sleeps -ge 2 -and $script:qHolder) { $script:qHolder.Dispose(); $script:qHolder = $null } }
    $qev = $null; $qOut = @(); $qThrew = $null
    $Error.Clear()
    try { $qOut = @(Enter-Win32ToolkitHyperVLease -VMName 'vm-test' -VMId $vmId -LockRoot $ROOT -WaitSeconds 600 @trust -ErrorVariable qev 6>$null) } catch { $qThrew = $_ }
    $qErrors = @($Error)
    if ($script:qHolder) { $script:qHolder.Dispose(); $script:qHolder = $null }
    if (-not $qThrew -and $qOut.Count -eq 1 -and $qOut[0].PreviousGeneration -eq 20 -and $script:sleeps -eq 2 -and @($qev).Count -eq 0 -and $qErrors.Count -eq 0) {
        Ok 'two busy attempts, then the lease: nothing in $Error, nothing in the caller''s -ErrorVariable'
    } else { Bad "busy then free: threw=$qThrew out=$($qOut.Count) sleeps=$($script:sleeps) ev=$(@($qev).Count) errors=$($qErrors.Count): $(@(@($qev) + $qErrors | Select-Object -First 3 | ForEach-Object { "$_" }) -join ' | ')" }
    foreach ($le in $qOut) { $null = Exit-Win32ToolkitHyperVLease -Lease $le }
    # A wait that times out: only the W32T error, however many attempts.
    $script:qHolder = Open-Foreign -Path $lockFile -Content $holderText
    $script:sleeps = 0
    function Start-Sleep { param($Seconds, $Milliseconds) $script:sleeps++; [System.Threading.Thread]::Sleep(100) }
    $qev = $null; $qThrew = $null
    $Error.Clear()
    try { $null = Enter-Win32ToolkitHyperVLease -VMName 'vm-test' -VMId $vmId -LockRoot $ROOT -WaitSeconds 1 @trust -ErrorVariable qev 6>$null } catch { $qThrew = $_ }
    $other = @(@($qev) + @($Error) | Where-Object { -not ($_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout') })
    $script:qHolder.Dispose(); $script:qHolder = $null
    if ($qThrew.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and $script:sleeps -ge 4 -and @($qev).Count -ge 1 -and $other.Count -eq 0) {
        Ok "a timeout after $($script:sleeps + 1) busy attempts: only W32T.HyperVLeaseTimeout in -ErrorVariable and in `$Error"
    } else { Bad "timeout: $($qThrew.FullyQualifiedErrorId) sleeps=$($script:sleeps) ev=$(@($qev).Count) other=$($other.Count): $(@($other | Select-Object -First 3 | ForEach-Object { "$_" }) -join ' | ')" }
    # The open's contract: an [int] is the Win32 error of a refused open. 5 = denied (12 end the wait), 32/33 = busy,
    # anything else is thrown as an IOException naming the file (not a W32T error).
    function Start-Sleep { param($Seconds, $Milliseconds) $script:sleeps++ }
    $script:opens = 0; $script:sleeps = 0
    $x = Invoke-Enter @{ WaitSeconds = 600; OpenStream = { param($p) $script:opens++; 5 } }
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and "$($x.Threw)" -like '*(access denied): run the session elevated.' -and $script:opens -eq 12 -and $x.Host.Count -eq 0) { Ok 'code 5: access denied (12 attempts end the wait)' } else { Bad "code 5: opens=$($script:opens) $($x.Threw)" }
    $script:opens = 0
    $x = Invoke-Enter @{ WaitSeconds = 0; OpenStream = { param($p) $script:opens++; 33 } }
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and "$($x.Threw)" -like 'Another process holds*' -and $script:opens -eq 1) { Ok 'code 33: busy' } else { Bad "code 33: $($x.Threw)" }
    $x = Invoke-Enter @{ WaitSeconds = 0; OpenStream = { param($p) 112 } }
    $inner = $x.Threw.Exception; while ($inner -and $inner -isnot [System.IO.IOException] -and $inner.InnerException) { $inner = $inner.InnerException }
    if ($x.Threw -and $x.Threw.FullyQualifiedErrorId -notlike 'W32T.*' -and $inner -is [System.IO.IOException] -and $inner.HResult -eq [int]0x80070070 -and "$($x.Threw)".Contains("($lockFile)")) {
        Ok 'another code (112): an IOException with that HResult, naming the lock file, not a W32T error'
    } else { Bad "code 112: $($x.Threw.FullyQualifiedErrorId) $($x.Threw) $($inner.GetType().FullName)" }
    Remove-Item Function:\Start-Sleep
}
finally {
    if ($script:HyperVLeases) { foreach ($h in @($script:HyperVLeases.Values)) { try { $h['Stream'].Dispose() } catch { $null = $_ } } }
    $script:HyperVLeases = $null
    Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All HyperVLease tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail HyperVLease test(s) FAILED." -ForegroundColor Red; exit 1 }
