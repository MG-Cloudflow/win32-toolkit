function Get-Win32ToolkitSiblingCaptureScript {
    <#
    .SYNOPSIS
        The fixed text of the sibling-capture guest script (SiblingCapture.ps1).
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.6; C-13, SV1, SV9, SV10, SV13, SV16, SV17, SV22, SV24). The script runs in
        the test VM as SYSTEM, one phase per call (Hyper-V), or every phase in order (-Phase All, the Windows Sandbox
        logon command). It reads every value from SiblingCapture.data.json next to it; nothing is spliced into the text,
        so the text is the same for every capture (byte-stable). Each phase writes its file into OutDir and exits 0,
        or exits 1 with '<Phase>Failed' in its file; an unexpected error exits 2.

          start of every phase  a 32-bit process on a 64-bit OS exits 2 (first); the data file read; CaptureKey must
                                be ^[a-z0-9_.+-]{1,80}$ and OutDir 'C:\PSADT\Out' or 'C:\W32TOut'
          PreSibling            noise control (edgeupdate, edgeupdatem, wuauserv, UsoSvc stopped and disabled; the Edge
                                update tasks disabled; Store auto-download and automatic updates off) and the snapshot (uninstall entries of
                                HKLM native, HKLM WOW6432Node and the account's HKCU; top-level folders of Program Files,
                                Program Files (x86), ProgramData; services; Start Menu and public desktop shortcuts;
                                scheduled tasks; Appx packages; pending file renames) -> SiblingPre_<key>.json
          Install               the installer with the data file's switches, the handle cached, 20 minutes for the
                                installer process (its process tree killed after that) -> SiblingInstall_<key>.json
          PostSibling           30 s settle, the 90 s late-writer poll of the uninstall keys, a full rescan, the diff,
                                the candidates (uninstaller path, install folder, files, permissions), the provisional
                                primary (the shared attribution text, embedded verbatim, with the data file's package
                                publisher - the host's input - and no signer data, so never Medium) and copies of its
                                uninstaller and main program -> SiblingCapture_<key>.json. NoiseControl is Verified when
                                every controlled service is still stopped and disabled and every task disabled; wuauserv
                                and UsoSvc started again by Windows' own update repair (WaaSMedicSvc, live checks
                                2026-10-26) count as controlled while the Windows Update client logged no installation
                                (events 19, 20, 43; Defender's intelligence and platform updates aside) since PreSibling.
                                NoiseDetail lists the states found (for the operator).
          Probe                 only an NSIS or Inno Setup primary: sentinels seeded, its uninstaller run with the
                                constant switches, the process tree waited for (15 minutes), the postconditions checked
                                -> SiblingProbe_<key>.json
          CollectLogs           up to 20 logs and the done marker -> Logs\*.log, SiblingDone_<key>.json
    .PARAMETER Part
        All (the script) or Attribution (only the shared attribution text, for the byte-identity test).
    .OUTPUTS
        [string] the text (LF line ends).
    .EXAMPLE
        [IO.File]::WriteAllText($path, (Get-Win32ToolkitSiblingCaptureScript), [Text.UTF8Encoding]::new($true))
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('All', 'Attribution')]
        [string]$Part = 'All'
    )

    $attribution = Get-Win32ToolkitSiblingAttributionScript
    if ($Part -eq 'Attribution') { return $attribution }

    $head = @'
## win32-toolkit sibling capture (installer-identity PR 3b). Runs in the test VM as SYSTEM, one phase per call, or every
## phase in order with -Phase All. Every value comes from SiblingCapture.data.json next to this script.
## Exit codes: 0 done, 1 the phase failed (its file says <Phase>Failed), 2 an unexpected error.
param([string]$Phase)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { exit 2 }
$w32tScRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$w32tScData = $null
try { $w32tScData = [IO.File]::ReadAllText((Join-Path $w32tScRoot 'SiblingCapture.data.json')) | ConvertFrom-Json } catch { exit 2 }
$w32tScKey = [string]$w32tScData.CaptureKey
if ($w32tScKey -cnotmatch '^[a-z0-9_.+-]{1,80}$') { exit 2 }
$w32tScOut = [string]$w32tScData.OutDir
if (@('C:\PSADT\Out', 'C:\W32TOut') -notcontains $w32tScOut) { exit 2 }
if (@('PreSibling', 'Install', 'PostSibling', 'Probe', 'CollectLogs', 'All') -notcontains $Phase) { exit 2 }
try { [void](New-Item -ItemType Directory -Path (Join-Path $w32tScOut 'Logs') -Force) } catch { exit 2 }

$w32tScWrite = {
    param([string]$w32tName, $w32tObj)
    $w32tJson = ConvertTo-Json -InputObject $w32tObj -Depth 10 -Compress
    [IO.File]::WriteAllText((Join-Path $w32tScOut $w32tName), $w32tJson, (New-Object System.Text.UTF8Encoding($false)))
}
$w32tScRead = {
    param([string]$w32tName)
    $w32tP = Join-Path $w32tScOut $w32tName
    if (-not (Test-Path -LiteralPath $w32tP)) { return $null }
    return ([IO.File]::ReadAllText($w32tP) | ConvertFrom-Json)
}
$w32tScUtc = { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
$w32tScLeafOf = { param([string]$w32tP) if (-not $w32tP) { return '' }; $w32tI = $w32tP.LastIndexOf('\'); if ($w32tI -ge 0) { return $w32tP.Substring($w32tI + 1) }; return $w32tP }
$w32tScExeOf = {
    param([string]$w32tCmd)
    if ($w32tCmd -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($w32tCmd -match '^\s*([A-Za-z]:\\[^"]*?\.exe)(\s|$)') { return $Matches[1] }
    return ''
}
$w32tScCanonical = {
    param([string]$w32tP)
    if ($w32tP -notmatch '^[A-Za-z]:\\[^/:*?"<>|~\p{Cc}\p{Cf}]+$' -or $w32tP -match '\\[. ]*(\\|$)|[. ](\\|$)') { return $false }
    try { return ([IO.Path]::GetFullPath($w32tP) -ceq $w32tP) } catch { return $false }
}
$w32tScToken = {
    param([string]$w32tDir)
    $w32tPf = ([string]$env:ProgramFiles).TrimEnd('\')
    $w32tPf86 = ([string]${env:ProgramFiles(x86)}).TrimEnd('\')
    if ($w32tPf86 -and $w32tDir.StartsWith($w32tPf86 + '\', [StringComparison]::OrdinalIgnoreCase)) { return '%ProgramFiles(x86)%' + $w32tDir.Substring($w32tPf86.Length) }
    if ($w32tPf -and $w32tDir.StartsWith($w32tPf + '\', [StringComparison]::OrdinalIgnoreCase)) { return '%ProgramFiles%' + $w32tDir.Substring($w32tPf.Length) }
    return ''
}
$w32tScArp = {
    $w32tList = New-Object System.Collections.ArrayList
    $w32tHives = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; View = 'Native' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; View = 'Wow6432' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; View = 'User' })
    foreach ($w32tH in $w32tHives) {
        if (-not (Test-Path -LiteralPath $w32tH.Path)) { continue }
        foreach ($w32tK in @(Get-ChildItem -LiteralPath $w32tH.Path -ErrorAction SilentlyContinue)) {
            $w32tP = $null
            try { $w32tP = Get-ItemProperty -LiteralPath $w32tK.PSPath -ErrorAction Stop } catch { $w32tP = $null }
            $w32tV = { param([string]$w32tN) if ($null -ne $w32tP -and $w32tP.PSObject.Properties[$w32tN]) { return [string]$w32tP.PSObject.Properties[$w32tN].Value }; return '' }
            [void]$w32tList.Add([ordered]@{
                    Key = [string]$w32tK.PSChildName; View = $w32tH.View; DisplayName = (& $w32tV 'DisplayName'); DisplayVersion = (& $w32tV 'DisplayVersion')
                    Publisher = (& $w32tV 'Publisher'); InstallLocation = (& $w32tV 'InstallLocation'); UninstallString = (& $w32tV 'UninstallString')
                    QuietUninstallString = (& $w32tV 'QuietUninstallString'); DisplayIcon = (& $w32tV 'DisplayIcon')
                    SystemComponent = ((& $w32tV 'SystemComponent') -eq '1'); WindowsInstaller = ((& $w32tV 'WindowsInstaller') -eq '1')
                    InnoAppPath = [bool](& $w32tV 'Inno Setup: App Path') })
        }
    }
    return ,$w32tList
}
$w32tScPfro = {
    try {
        $w32tV = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
        return ,@(@($w32tV) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    catch { return ,@() }
}
$w32tScSnapshot = {
    $w32tRoots = New-Object System.Collections.ArrayList
    foreach ($w32tBase in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if (-not $w32tBase -or -not (Test-Path -LiteralPath $w32tBase)) { continue }
        foreach ($w32tD in @(Get-ChildItem -LiteralPath $w32tBase -Directory -Force -ErrorAction SilentlyContinue)) { [void]$w32tRoots.Add($w32tD.FullName) }
    }
    $w32tServices = New-Object System.Collections.ArrayList
    try {
        foreach ($w32tS in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
            [void]$w32tServices.Add([ordered]@{ Name = [string]$w32tS.Name; DisplayName = [string]$w32tS.DisplayName; ImageLeaf = (& $w32tScLeafOf (& $w32tScExeOf ([string]$w32tS.PathName))) })
        }
    }
    catch { $null = $_ }
    $w32tLinks = New-Object System.Collections.ArrayList
    foreach ($w32tL in @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'), (Join-Path $env:PUBLIC 'Desktop'))) {
        if (Test-Path -LiteralPath $w32tL) { foreach ($w32tF in @(Get-ChildItem -LiteralPath $w32tL -Recurse -Filter '*.lnk' -File -Force -ErrorAction SilentlyContinue)) { [void]$w32tLinks.Add($w32tF.FullName) } }
    }
    $w32tTasks = New-Object System.Collections.ArrayList
    try {
        foreach ($w32tT in @(Get-ScheduledTask -ErrorAction Stop)) {
            $w32tAct = ''
            if (@($w32tT.Actions).Count -gt 0 -and @($w32tT.Actions)[0].PSObject.Properties['Execute']) { $w32tAct = & $w32tScLeafOf ([string]@($w32tT.Actions)[0].Execute) }
            [void]$w32tTasks.Add([ordered]@{ Path = ([string]$w32tT.TaskPath + [string]$w32tT.TaskName); ActionLeaf = $w32tAct })
        }
    }
    catch { $null = $_ }
    $w32tAppx = New-Object System.Collections.ArrayList
    try { foreach ($w32tA in @(Get-AppxPackage -AllUsers -ErrorAction Stop)) { [void]$w32tAppx.Add([string]$w32tA.PackageFullName) } } catch { $null = $_ }
    return [ordered]@{ Arp = (& $w32tScArp); Roots = $w32tRoots; Services = $w32tServices; Shortcuts = $w32tLinks; Tasks = $w32tTasks; Appx = $w32tAppx; Pfro = (& $w32tScPfro) }
}
$w32tScTree = {
    param([int]$w32tRootId)
    $w32tAll = @()
    try { $w32tAll = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { return ,@() }
    $w32tFound = New-Object System.Collections.ArrayList
    $w32tQueue = New-Object System.Collections.Queue
    $w32tQueue.Enqueue($w32tRootId)
    while ($w32tQueue.Count -gt 0) {
        $w32tParent = [int]$w32tQueue.Dequeue()
        foreach ($w32tPr in $w32tAll) {
            if ([int]$w32tPr.ParentProcessId -eq $w32tParent -and [int]$w32tPr.ProcessId -ne $w32tRootId -and -not ($w32tFound | Where-Object { $_.Id -eq [int]$w32tPr.ProcessId })) {
                [void]$w32tFound.Add(@{ Id = [int]$w32tPr.ProcessId; Name = [string]$w32tPr.Name })
                $w32tQueue.Enqueue([int]$w32tPr.ProcessId)
            }
        }
    }
    return ,$w32tFound
}
$w32tScKillTree = {
    param([int]$w32tRootId)
    try { [void](& (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $w32tRootId /T /F 2>&1) } catch { $null = $_ }
}
## Windows Update installed nothing since this UTC time (yyyy-MM-ddTHH:mm:ssZ): no installation event (19, 20, 43) of the
## Windows Update client in the System log, Microsoft Defender's own intelligence and platform updates aside. Any read
## problem answers $false.
$w32tScWuQuiet = {
    param([string]$w32tSince)
    $w32tFrom = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($w32tSince, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$w32tFrom)) { return $false }
    $w32tEv = @()
    try { $w32tEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 20, 43; StartTime = $w32tFrom.ToLocalTime() } -ErrorAction Stop) }
    catch {
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return $true }
        return $false
    }
    foreach ($w32tE in $w32tEv) {
        $w32tTitle = ''
        try { $w32tTitle = [string]$w32tE.Properties[0].Value } catch { $w32tTitle = '' }
        if ($w32tTitle -notmatch 'Microsoft Defender|KB2267602|KB4052623') { return $false }
    }
    return $true
}
## The noise control holds: every controlled service Stopped and Disabled, every Edge update task Disabled. With a start
## time (PostSibling): wuauserv and UsoSvc may have been started again by Windows' own update repair (WaaSMedicSvc sets
## wuauserv back to Manual and starts it a few minutes later on Windows 11) while Windows Update installed nothing.
$w32tScNoiseCheck = {
    param($w32tItems, [string]$w32tSince)
    $w32tWu = $null
    foreach ($w32tN in @($w32tItems)) {
        if ($w32tN.Kind -eq 'Service') {
            $w32tS = $null
            try { $w32tS = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $_.Name -eq [string]$w32tN.Name })[0] } catch { return $false }
            if (-not $w32tS) { return $false }
            if ([string]$w32tS.State -eq 'Stopped' -and [string]$w32tS.StartMode -eq 'Disabled') { continue }
            if ($w32tSince -and @('wuauserv', 'UsoSvc') -contains [string]$w32tN.Name) {
                if ($null -eq $w32tWu) { $w32tWu = [bool](& $w32tScWuQuiet $w32tSince) }
                if ($w32tWu) { continue }
            }
            return $false
        }
        elseif ($w32tN.Kind -eq 'Task') {
            $w32tT = $null
            try { $w32tT = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { ([string]$_.TaskPath + [string]$_.TaskName) -eq [string]$w32tN.Name })[0] } catch { return $false }
            if ($w32tT -and [string]$w32tT.State -ne 'Disabled') { return $false }
        }
    }
    return $true
}
## What the noise control found, for the operator when it is not verified: '<name> <state>/<start mode>' per service,
## '<task> <state>' per task (constant names; states are WMI and Task Scheduler words).
$w32tScNoiseState = {
    param($w32tItems)
    $w32tOut = New-Object System.Collections.ArrayList
    foreach ($w32tN in @($w32tItems)) {
        $w32tText = [string]$w32tN.Name + ' ?'
        try {
            if ($w32tN.Kind -eq 'Service') {
                $w32tS = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $_.Name -eq [string]$w32tN.Name })[0]
                if ($w32tS) { $w32tText = [string]$w32tN.Name + ' ' + [string]$w32tS.State + '/' + [string]$w32tS.StartMode } else { $w32tText = [string]$w32tN.Name + ' missing' }
            }
            elseif ($w32tN.Kind -eq 'Task') {
                $w32tT = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { ([string]$_.TaskPath + [string]$_.TaskName) -eq [string]$w32tN.Name })[0]
                if ($w32tT) { $w32tText = [string]$w32tN.Name + ' ' + [string]$w32tT.State } else { $w32tText = [string]$w32tN.Name + ' missing' }
            }
        }
        catch { $null = $_ }
        [void]$w32tOut.Add($w32tText)
    }
    return ,$w32tOut
}
'@

    $body = @'

$w32tScPre = {
    $w32tNoise = New-Object System.Collections.ArrayList
    foreach ($w32tSvc in @('edgeupdate', 'edgeupdatem', 'wuauserv', 'UsoSvc')) {
        if (-not (Get-Service -Name $w32tSvc -ErrorAction SilentlyContinue)) { continue }
        try { Stop-Service -Name $w32tSvc -Force -ErrorAction Stop } catch { $null = $_ }
        try { Set-Service -Name $w32tSvc -StartupType Disabled -ErrorAction Stop } catch { $null = $_ }
        [void]$w32tNoise.Add(@{ Kind = 'Service'; Name = $w32tSvc })
    }
    try {
        foreach ($w32tT in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { [string]$_.TaskName -like 'MicrosoftEdgeUpdateTask*' })) {
            try { [void](Disable-ScheduledTask -InputObject $w32tT -ErrorAction Stop) } catch { $null = $_ }
            [void]$w32tNoise.Add(@{ Kind = 'Task'; Name = ([string]$w32tT.TaskPath + [string]$w32tT.TaskName) })
        }
    }
    catch { $null = $_ }
    try {
        [void](New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force)
        [void](New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -Value 2 -PropertyType DWord -Force)
    }
    catch { $null = $_ }
    ## Automatic updates off too: Windows' own update repair may start wuauserv again during the capture.
    try {
        [void](New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force)
        [void](New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate' -Value 1 -PropertyType DWord -Force)
    }
    catch { $null = $_ }
    $w32tOs = [string][Environment]::OSVersion.Version
    try { $w32tOs = $w32tOs + '.' + [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction Stop).UBR } catch { $null = $_ }
    & $w32tScWrite ('SiblingPre_' + $w32tScKey + '.json') ([ordered]@{
            SchemaVersion = '1.0'; CaptureKey = $w32tScKey; StartedUtc = (& $w32tScUtc); Account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            Is64 = [Environment]::Is64BitOperatingSystem; OsBuild = $w32tOs; Noise = $w32tNoise; NoiseVerified = (& $w32tScNoiseCheck $w32tNoise); Snapshot = (& $w32tScSnapshot) })
    return 0
}

$w32tScInstall = {
    $w32tLeaf = [string]$w32tScData.InstallerFile
    $w32tFile = Join-Path $w32tScRoot ('installer\' + $w32tLeaf)
    if ($w32tLeaf -notmatch '^[A-Za-z0-9 ._+()-]{1,128}$' -or -not (Test-Path -LiteralPath $w32tFile -PathType Leaf)) {
        & $w32tScWrite ('SiblingInstall_' + $w32tScKey + '.json') ([ordered]@{ InstallFailed = $true; Reason = 'the installer file is missing or its name is not plain'; ExitCode = -1; TimedOut = $false; Completed = $false; RebootRequested = $false; Lingering = @(); Seconds = 0 })
        return 1
    }
    $w32tArgs = [string]$w32tScData.InstallerArgs
    $w32tExe = $w32tFile
    if ($w32tLeaf -match '\.msi$') { $w32tExe = Join-Path $env:SystemRoot 'System32\msiexec.exe'; $w32tArgs = ('/i "' + $w32tFile + '" ' + $w32tArgs).Trim() }
    $w32tWatch = [Diagnostics.Stopwatch]::StartNew()
    if ($w32tArgs) { $w32tProc = Start-Process -FilePath $w32tExe -ArgumentList $w32tArgs -PassThru } else { $w32tProc = Start-Process -FilePath $w32tExe -PassThru }
    $null = $w32tProc.Handle
    $w32tSeen = @{}
    $w32tDone = $false
    $w32tLimit = (Get-Date).AddMinutes(20)
    while (-not $w32tDone -and (Get-Date) -lt $w32tLimit) {
        $w32tDone = $w32tProc.WaitForExit(5000)
        foreach ($w32tD in @(& $w32tScTree $w32tProc.Id)) { $w32tSeen[[string]$w32tD.Id] = [string]$w32tD.Name }
    }
    $w32tTimedOut = -not $w32tDone
    if ($w32tTimedOut) { & $w32tScKillTree $w32tProc.Id }
    $w32tAlive = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $w32tSeen.ContainsKey([string]$_.Id) } | ForEach-Object { [string]$_.ProcessName } | Select-Object -Unique -First 20)
    $w32tCode = -1
    if (-not $w32tTimedOut) { $w32tCode = [int]$w32tProc.ExitCode }
    $w32tOk = (-not $w32tTimedOut) -and (@(0, 1707, 3010, 1641) -contains $w32tCode)
    & $w32tScWrite ('SiblingInstall_' + $w32tScKey + '.json') ([ordered]@{
            InstallFailed = (-not $w32tOk); ExitCode = $w32tCode; TimedOut = $w32tTimedOut; Completed = $w32tOk; RebootRequested = (@(3010, 1641) -contains $w32tCode)
            Lingering = $w32tAlive; Seconds = [int]$w32tWatch.Elapsed.TotalSeconds })
    if ($w32tOk) { return 0 }
    return 1
}

$w32tScCandidate = {
    param($w32tE)
    $w32tCmd = [string]$w32tE.UninstallString
    $w32tExe = & $w32tScExeOf $w32tCmd
    $w32tCanon = [bool]$w32tExe -and (& $w32tScCanonical $w32tExe) -and (Test-Path -LiteralPath $w32tExe -PathType Leaf)
    $w32tDir = ''
    if ($w32tCanon) { $w32tDir = [IO.Path]::GetDirectoryName($w32tExe) }
    $w32tLeaf = & $w32tScLeafOf $w32tExe
    $w32tCfgRx = '\.(exe|ini|xml|json|config|cfg|dat)$'
    $w32tFiles = @()
    if ($w32tDir) { $w32tFiles = @(Get-ChildItem -LiteralPath $w32tDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $w32tCfgRx } | Select-Object -First 200 | ForEach-Object { $_.Name }) }
    $w32tLoc = ([string]$w32tE.InstallLocation).Trim().Trim('"').TrimEnd('\')
    $w32tLocFiles = @()
    if ($w32tLoc -and $w32tLoc -ne $w32tDir -and (& $w32tScCanonical $w32tLoc) -and (Test-Path -LiteralPath $w32tLoc -PathType Container)) {
        $w32tLocFiles = @(Get-ChildItem -LiteralPath $w32tLoc -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $w32tCfgRx } | Select-Object -First 200 | ForEach-Object { $_.Name })
    }
    $w32tIcon = & $w32tScLeafOf ((([string]$w32tE.DisplayIcon) -replace ',\s*-?\d+\s*$', '').Trim().Trim('"'))
    $w32tExes = @($w32tFiles | Where-Object { $_ -match '\.exe$' })
    $w32tMain = ''
    if ($w32tIcon -match '\.exe$' -and @($w32tExes | Where-Object { $_ -eq $w32tIcon }).Count -gt 0 -and $w32tIcon -ne $w32tLeaf) { $w32tMain = $w32tIcon }
    else {
        $w32tOthers = @($w32tExes | Where-Object { $_ -ne $w32tLeaf })
        if ($w32tOthers.Count -eq 1) { $w32tMain = [string]$w32tOthers[0] }
    }
    $w32tQuiet = [string]$w32tE.QuietUninstallString
    $w32tQuietArgs = ''
    $w32tQExe = & $w32tScExeOf $w32tQuiet
    if ($w32tQExe) { $w32tAt = $w32tQuiet.IndexOf($w32tQExe); if ($w32tAt -ge 0) { $w32tQuietArgs = $w32tQuiet.Substring($w32tAt + $w32tQExe.Length).Trim().TrimStart('"').Trim() } }
    $w32tAcl = New-Object System.Collections.ArrayList
    $w32tToken = ''
    if ($w32tDir) {
        $w32tToken = & $w32tScToken $w32tDir
        $w32tBase = ''
        if ($w32tToken.StartsWith('%ProgramFiles(x86)%')) { $w32tBase = ([string]${env:ProgramFiles(x86)}).TrimEnd('\') } elseif ($w32tToken) { $w32tBase = ([string]$env:ProgramFiles).TrimEnd('\') }
        $w32tPaths = New-Object System.Collections.ArrayList
        $w32tWalk = $w32tDir
        while ($w32tBase -and $w32tWalk -and $w32tWalk.Length -gt $w32tBase.Length -and $w32tPaths.Count -lt 15) { [void]$w32tPaths.Add($w32tWalk); $w32tWalk = [IO.Path]::GetDirectoryName($w32tWalk) }
        [void]$w32tPaths.Add($w32tExe)
        foreach ($w32tPath in $w32tPaths) {
            try {
                $w32tA = Get-Acl -LiteralPath $w32tPath
                $w32tRules = New-Object System.Collections.ArrayList
                foreach ($w32tR in @($w32tA.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
                    if ($w32tRules.Count -ge 64) { break }
                    [void]$w32tRules.Add([ordered]@{ Sid = [string]$w32tR.IdentityReference.Value; Rights = [int]$w32tR.FileSystemRights; Inheritance = [int]$w32tR.InheritanceFlags; Propagation = [int]$w32tR.PropagationFlags; Type = [string]$w32tR.AccessControlType })
                }
                [void]$w32tAcl.Add([ordered]@{ Path = $w32tPath; Owner = [string]$w32tA.GetOwner([Security.Principal.SecurityIdentifier]).Value; Rules = $w32tRules })
            }
            catch { [void]$w32tAcl.Add([ordered]@{ Path = $w32tPath; Owner = ''; Rules = @() }) }
        }
    }
    $w32tUnsDat = $false
    if ($w32tDir) { $w32tUnsDat = @(Get-ChildItem -LiteralPath $w32tDir -Filter 'unins*.dat' -File -Force -ErrorAction SilentlyContinue).Count -gt 0 }
    $w32tPath = ''
    if ($w32tCanon) { $w32tPath = $w32tExe }
    return [ordered]@{
        Key = [string]$w32tE.Key; View = [string]$w32tE.View; DisplayName = [string]$w32tE.DisplayName; DisplayVersion = [string]$w32tE.DisplayVersion
        Publisher = [string]$w32tE.Publisher; WindowsInstaller = [bool]$w32tE.WindowsInstaller; SystemComponent = [bool]$w32tE.SystemComponent
        InstallLocation = [string]$w32tE.InstallLocation; DisplayIconLeaf = $w32tIcon; UninstallerPath = $w32tPath; UninstallerCanonical = $w32tCanon
        UninstallerLeaf = $w32tLeaf; InstallDir = $w32tToken; MainExe = $w32tMain; Files = $w32tFiles; InstallLocationFiles = $w32tLocFiles
        InnoAppPath = [bool]$w32tE.InnoAppPath; UnsDat = $w32tUnsDat; QuietUninstallArgs = $w32tQuietArgs; Acl = $w32tAcl; UnsafeText = $false
    }
}

$w32tScPost = {
    $w32tPre = & $w32tScRead ('SiblingPre_' + $w32tScKey + '.json')
    $w32tInst = & $w32tScRead ('SiblingInstall_' + $w32tScKey + '.json')
    if (-not $w32tPre -or ([string]$w32tScData.Mode -ne 'Assisted' -and (-not $w32tInst -or -not $w32tInst.Completed))) {
        & $w32tScWrite ('SiblingCapture_' + $w32tScKey + '.json') ([ordered]@{ PostSiblingFailed = $true; Reason = 'the sibling install did not complete' })
        return 1
    }
    $w32tWatch = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 30
    $w32tLast = ''
    $w32tStable = 0
    for ($w32tI = 0; $w32tI -lt 9; $w32tI++) {
        $w32tNow = (@(& $w32tScArp | Where-Object { $_.View -ne 'User' } | ForEach-Object { $_.View + '|' + $_.Key }) | Sort-Object) -join ';'
        if ($w32tNow -eq $w32tLast) { $w32tStable++; if ($w32tStable -ge 2) { break } } else { $w32tStable = 0 }
        $w32tLast = $w32tNow
        Start-Sleep -Seconds 10
    }
    $w32tPost = & $w32tScSnapshot
    $w32tPreArp = @{}
    foreach ($w32tE in @($w32tPre.Snapshot.Arp)) { $w32tPreArp[[string]$w32tE.View + '|' + [string]$w32tE.Key] = $true }
    $w32tCands = New-Object System.Collections.ArrayList
    $w32tHkcu = New-Object System.Collections.ArrayList
    foreach ($w32tE in @($w32tPost.Arp)) {
        if ($w32tPreArp.ContainsKey([string]$w32tE.View + '|' + [string]$w32tE.Key)) { continue }
        if ($w32tE.View -eq 'User') { [void]$w32tHkcu.Add([ordered]@{ Key = [string]$w32tE.Key; DisplayName = [string]$w32tE.DisplayName }); continue }
        if ($w32tCands.Count -ge 64) { continue }
        [void]$w32tCands.Add((& $w32tScCandidate $w32tE))
    }
    $w32tNewRoots = @(@($w32tPost.Roots) | Where-Object { @($w32tPre.Snapshot.Roots) -notcontains $_ })
    $w32tPreSvc = @(@($w32tPre.Snapshot.Services) | ForEach-Object { [string]$_.Name })
    $w32tPreTask = @(@($w32tPre.Snapshot.Tasks) | ForEach-Object { [string]$_.Path })
    $w32tAttr = & $w32tScAttribute @($w32tCands) $w32tScData.Manifest $w32tScData.Own ([string]$w32tScData.PackagePublisher) $w32tNewRoots
    $w32tPrimary = $null
    foreach ($w32tC in $w32tCands) { if ($w32tAttr.Primary -and $w32tC.Key -eq $w32tAttr.Primary -and $w32tC.View -eq $w32tAttr.PrimaryView) { $w32tPrimary = $w32tC } }
    if ($null -ne $w32tPrimary) {
        $w32tCopies = @(@{ Source = [string]$w32tPrimary.UninstallerPath; Name = 'uninstaller' })
        if ($w32tPrimary.MainExe -and $w32tPrimary.UninstallerPath) { $w32tCopies += @{ Source = (Join-Path ([IO.Path]::GetDirectoryName([string]$w32tPrimary.UninstallerPath)) ([string]$w32tPrimary.MainExe)); Name = 'main' } }
        foreach ($w32tCopy in $w32tCopies) {
            if (-not $w32tCopy.Source -or -not (Test-Path -LiteralPath $w32tCopy.Source -PathType Leaf)) { continue }
            if ((Get-Item -LiteralPath $w32tCopy.Source -Force).Length -gt 64MB) { continue }
            Copy-Item -LiteralPath $w32tCopy.Source -Destination (Join-Path $w32tScOut ('SiblingCopy_' + $w32tScKey + '_' + $w32tCopy.Name + '.exe')) -Force
        }
    }
    $w32tNoise = 'Unverified'
    if ([bool]$w32tPre.NoiseVerified -and (& $w32tScNoiseCheck @($w32tPre.Noise) ([string]$w32tPre.StartedUtc))) { $w32tNoise = 'Verified' }
    $w32tNoiseDetail = @(& $w32tScNoiseState @($w32tPre.Noise) | Select-Object -First 16)
    & $w32tScWrite ('SiblingCapture_' + $w32tScKey + '.json') ([ordered]@{
            SchemaVersion = '1.0'; Candidates = $w32tCands
            Services = @(@($w32tPost.Services) | Where-Object { $w32tPreSvc -notcontains [string]$_.Name } | Select-Object -First 64)
            Shortcuts = @(@($w32tPost.Shortcuts) | Where-Object { @($w32tPre.Snapshot.Shortcuts) -notcontains $_ } | Select-Object -First 64)
            Tasks = @(@($w32tPost.Tasks) | Where-Object { $w32tPreTask -notcontains [string]$_.Path } | Select-Object -First 64)
            Appx = @(@($w32tPost.Appx) | Where-Object { @($w32tPre.Snapshot.Appx) -notcontains $_ } | Select-Object -First 64)
            HkcuArp = $w32tHkcu; NewRoots = @($w32tNewRoots | Select-Object -First 64); NoiseControl = $w32tNoise; NoiseDetail = $w32tNoiseDetail; PfroCount = @($w32tPost.Pfro).Count
            ProvisionalPrimary = [string]$w32tAttr.Primary; ProvisionalView = [string]$w32tAttr.PrimaryView; Seconds = [int]$w32tWatch.Elapsed.TotalSeconds })
    return 0
}

$w32tScProbe = {
    $w32tWatch = [Diagnostics.Stopwatch]::StartNew()
    $w32tResult = [ordered]@{ Result = 'NotProbed'; ProbedKey = ''; ProbedView = ''; Kind = ''; Reason = ''; ExitCode = 0; Seconds = 0; LingeringProcess = @(); PfroUnderRoot = $false; RootConfigRemoved = $false; VendorConfigRemoved = @() }
    $w32tCap = & $w32tScRead ('SiblingCapture_' + $w32tScKey + '.json')
    $w32tPrimary = $null
    if ($w32tCap -and [string]$w32tCap.ProvisionalPrimary) {
        foreach ($w32tC in @($w32tCap.Candidates)) { if ([string]$w32tC.Key -eq [string]$w32tCap.ProvisionalPrimary -and [string]$w32tC.View -eq [string]$w32tCap.ProvisionalView) { $w32tPrimary = $w32tC } }
    }
    $w32tKind = ''
    if ($null -ne $w32tPrimary) {
        if ([bool]$w32tPrimary.InnoAppPath -and ([string]$w32tPrimary.Key).EndsWith('_is1')) { $w32tKind = 'inno' }
        elseif ([string]$w32tScData.ExpectedKind -eq 'nullsoft') { $w32tKind = 'nullsoft' }
    }
    $w32tExe = ''
    if ($null -ne $w32tPrimary) { $w32tExe = [string]$w32tPrimary.UninstallerPath }
    if (-not $w32tKind -or -not $w32tExe -or -not (Test-Path -LiteralPath $w32tExe -PathType Leaf)) {
        $w32tResult.Reason = 'no NSIS or Inno Setup primary with a canonical uninstaller'
        & $w32tScWrite ('SiblingProbe_' + $w32tScKey + '.json') $w32tResult
        return 0
    }
    $w32tResult.ProbedKey = [string]$w32tPrimary.Key
    $w32tResult.ProbedView = [string]$w32tPrimary.View
    $w32tResult.Kind = $w32tKind
    $w32tDir = [IO.Path]::GetDirectoryName($w32tExe)
    $w32tSeed = New-Object System.Collections.ArrayList
    $w32tSentinel = Join-Path $w32tDir ('w32t-sentinel-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ini')
    try { [IO.File]::WriteAllText($w32tSentinel, '[w32t]'); [void]$w32tSeed.Add($w32tSentinel) } catch { $null = $_ }
    $w32tCfgSeed = Join-Path $w32tDir 'config.xml'
    if (-not (Test-Path -LiteralPath $w32tCfgSeed)) { try { [IO.File]::WriteAllText($w32tCfgSeed, '<w32t/>'); [void]$w32tSeed.Add($w32tCfgSeed) } catch { $null = $_ } }
    $w32tVendor = @(@($w32tPrimary.Files) | Where-Object { [string]$_ -match '\.(ini|xml|json|config|cfg)$' -and (Test-Path -LiteralPath (Join-Path $w32tDir ([string]$_))) })
    $w32tPfroBefore = @(& $w32tScPfro)
    if ($w32tKind -eq 'inno') { $w32tArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } else { $w32tArgs = '/S _?=' + $w32tDir }
    $w32tProc = Start-Process -FilePath $w32tExe -ArgumentList $w32tArgs -PassThru
    $null = $w32tProc.Handle
    $w32tSeen = @{}
    $w32tParentDone = $false
    $w32tLingering = @()
    $w32tLimit = (Get-Date).AddMinutes(15)
    $w32tTreeDone = $false
    while ((Get-Date) -lt $w32tLimit) {
        foreach ($w32tD in @(& $w32tScTree $w32tProc.Id)) { $w32tSeen[[string]$w32tD.Id] = [string]$w32tD.Name }
        $w32tAlive = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $w32tSeen.ContainsKey([string]$_.Id) })
        if (-not $w32tParentDone -and $w32tProc.HasExited) {
            $w32tParentDone = $true
            $w32tLingering = @($w32tAlive | ForEach-Object { [string]$_.ProcessName } | Select-Object -Unique -First 20)
        }
        if ($w32tParentDone -and $w32tAlive.Count -eq 0) { $w32tTreeDone = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $w32tTreeDone) {
        & $w32tScKillTree $w32tProc.Id
        foreach ($w32tId in @($w32tSeen.Keys)) { try { Stop-Process -Id ([int]$w32tId) -Force -ErrorAction Stop } catch { $null = $_ } }
        $w32tResult.Result = 'TimedOut'
    }
    $w32tCode = -1
    if ($w32tProc.HasExited) { $w32tCode = [int]$w32tProc.ExitCode }
    $w32tResult.ExitCode = $w32tCode
    $w32tResult.LingeringProcess = $w32tLingering
    $w32tKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + [string]$w32tPrimary.Key
    if ([string]$w32tPrimary.View -eq 'Wow6432') { $w32tKeyPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\' + [string]$w32tPrimary.Key }
    $w32tMain = ''
    if ([string]$w32tPrimary.MainExe) { $w32tMain = Join-Path $w32tDir ([string]$w32tPrimary.MainExe) }
    $w32tGone = $false
    for ($w32tI = 0; $w32tI -lt 24; $w32tI++) {
        $w32tGone = -not (Test-Path -LiteralPath $w32tKeyPath) -and (-not $w32tMain -or -not (Test-Path -LiteralPath $w32tMain)) -and ($w32tKind -ne 'inno' -or -not (Test-Path -LiteralPath $w32tExe))
        if ($w32tGone -or $w32tResult.Result -eq 'TimedOut') { break }
        Start-Sleep -Seconds 5
    }
    $w32tPfroAfter = @(& $w32tScPfro)
    $w32tRoot = $w32tDir.ToLowerInvariant()
    $w32tResult.PfroUnderRoot = @($w32tPfroAfter | Where-Object { $w32tPfroBefore -notcontains $_ -and ([string]$_).ToLowerInvariant().Replace('\??\', '').StartsWith($w32tRoot) }).Count -gt 0
    $w32tResult.RootConfigRemoved = @($w32tSeed | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0
    $w32tResult.VendorConfigRemoved = @($w32tVendor | Where-Object { -not (Test-Path -LiteralPath (Join-Path $w32tDir ([string]$_))) })
    foreach ($w32tS in $w32tSeed) { if (Test-Path -LiteralPath $w32tS) { Remove-Item -LiteralPath $w32tS -Force -ErrorAction SilentlyContinue } }
    if ($w32tResult.Result -ne 'TimedOut') {
        if (-not $w32tGone) { $w32tResult.Result = 'Survived' }
        elseif ($w32tResult.PfroUnderRoot -or @(3010, 1641) -contains $w32tCode) { $w32tResult.Result = 'NeedsRestart' }
        else { $w32tResult.Result = 'Clean' }
    }
    $w32tResult.Seconds = [int]$w32tWatch.Elapsed.TotalSeconds
    & $w32tScWrite ('SiblingProbe_' + $w32tScKey + '.json') $w32tResult
    return 0
}

$w32tScLogs = {
    $w32tN = 0
    foreach ($w32tSrc in @((Join-Path $env:SystemRoot 'Logs\Software'), (Join-Path $env:SystemRoot 'Temp'))) {
        if (-not (Test-Path -LiteralPath $w32tSrc)) { continue }
        foreach ($w32tL in @(Get-ChildItem -LiteralPath $w32tSrc -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            if ($w32tN -ge 20) { break }
            $w32tName = $w32tL.Name -replace '[^A-Za-z0-9_.-]', '_'
            if ($w32tName.Length -gt 64) { $w32tName = $w32tName.Substring($w32tName.Length - 64) }
            try { Copy-Item -LiteralPath $w32tL.FullName -Destination (Join-Path $w32tScOut ('Logs\' + $w32tName)) -Force; $w32tN++ } catch { $null = $_ }
        }
    }
    & $w32tScWrite ('SiblingDone_' + $w32tScKey + '.json') ([ordered]@{ SchemaVersion = '1.0'; CompletedUtc = (& $w32tScUtc); Logs = $w32tN })
    return 0
}

$w32tScRun = {
    param([string]$w32tWhich, $w32tStep)
    try {
        try { [void](Start-Transcript -LiteralPath (Join-Path $w32tScOut ('Logs\SiblingCapture_' + $w32tWhich + '.log')) -Force) } catch { $null = $_ }
        $w32tOut = @(& $w32tStep)
        if ($w32tOut.Count -eq 0) { return 2 }
        return [int]$w32tOut[$w32tOut.Count - 1]
    }
    catch {
        Write-Host ('ERROR in ' + $w32tWhich + ': ' + [string]$_.Exception.Message)
        return 2
    }
    finally { try { [void](Stop-Transcript) } catch { $null = $_ } }
}

$w32tScCode = 0
switch ($Phase) {
    'PreSibling' { $w32tScCode = & $w32tScRun 'PreSibling' $w32tScPre }
    'Install' { $w32tScCode = & $w32tScRun 'Install' $w32tScInstall }
    'PostSibling' { $w32tScCode = & $w32tScRun 'PostSibling' $w32tScPost }
    'Probe' { $w32tScCode = & $w32tScRun 'Probe' $w32tScProbe }
    'CollectLogs' { $w32tScCode = & $w32tScRun 'CollectLogs' $w32tScLogs }
    'All' {
        foreach ($w32tStep in @(@('PreSibling', $w32tScPre), @('Install', $w32tScInstall), @('PostSibling', $w32tScPost))) {
            $w32tScCode = & $w32tScRun $w32tStep[0] $w32tStep[1]
            if ($w32tScCode -ne 0) { break }
        }
        if ($w32tScCode -eq 0) { $w32tScCode = & $w32tScRun 'Probe' $w32tScProbe }
        [void](& $w32tScRun 'CollectLogs' $w32tScLogs)
        if ([string]$w32tScData.OutDir -eq 'C:\W32TOut') { Stop-Computer -Force }
    }
}
exit $w32tScCode
'@

    return (($head + "`n" + $attribution + $body) -replace "`r`n", "`n")
}
