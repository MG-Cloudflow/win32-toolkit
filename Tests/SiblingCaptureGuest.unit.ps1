<#
    Installer-identity PR 3b (spec 2.14.6; C-13, SV16, SV22, SV24): the sibling-capture guest script is a fixed text.

      [1] it parses under PowerShell 7 and Windows PowerShell 5.1; ASCII; LF only; the same bytes on every call; the
          capture writes it with a UTF-8 BOM (Windows PowerShell 5.1 reads a BOM-less file as ANSI).
      [2] nothing of a capture is in it: it reads SiblingCapture.data.json, and no sample value (an id, a version, a key,
          a switch) appears in the text; the 64-bit check is the first statement after the preferences, before the data
          file is read; OutDir is restricted to 'C:\PSADT\Out' / 'C:\W32TOut'; the capture key is checked.
      [3] the shared attribution text is embedded verbatim (-Part Attribution is byte-identical to the catalog text and
          appears exactly once in -Part All) and called once, with the data file's PackagePublisher (the host's input,
          SV16); the two constant uninstall switch texts appear exactly once each; the
          phases and their files are the frozen names the host allow-list expects.

    Run:  pwsh -File Tests\SiblingCaptureGuest.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitSiblingAttributionScript.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitSiblingCaptureScript.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitPS51Syntax.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w32scg_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    # == [1] ===============================================================================================
    Write-Host '[1] parse, encoding, stability' -ForegroundColor Cyan
    $text = Get-Win32ToolkitSiblingCaptureScript
    $file = Join-Path $tmp 'SiblingCapture.ps1'
    [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($true))
    $errs = $null; $null = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    $e51 = @(Test-Win32ToolkitPS51Syntax -Path $file)
    if (@($errs).Count -eq 0 -and $e51.Count -eq 0) { Ok 'parses under PowerShell 7 and Windows PowerShell 5.1' } else { Bad "parse: $(@($errs).Count) / $($e51 -join ' | ')" }
    if (@($text.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -eq 0 -and -not $text.Contains("`r")) { Ok 'ASCII, LF only' } else { Bad 'encoding' }
    if ((Get-Win32ToolkitSiblingCaptureScript) -ceq $text) { Ok 'the same text on every call (byte-stable)' } else { Bad 'not stable' }
    $inv = [IO.File]::ReadAllText((Join-Path $repo 'Private\Invoke-Win32ToolkitSiblingCapture.ps1'))
    if ($inv -match '\[Text\.UTF8Encoding\]::new\(\$true\)\.GetPreamble\(\)' -and $inv -match "WriteAllBytes\(\(Join-Path \`$inDir 'SiblingCapture\.ps1'\)") { Ok 'the capture writes it with a UTF-8 BOM (in\SiblingCapture.ps1)' } else { Bad 'BOM write' }

    # == [2] ===============================================================================================
    Write-Host '[2] value-free; the first checks' -ForegroundColor Cyan
    $samples = @('Notepad++', '8.9.8.1', 'nullsoft-8.9.8', '/ALLUSERS', 'KeePass', '{5C6F8543', 'Contoso')
    $leaked = @($samples | Where-Object { $text.Contains($_) })
    if ($leaked.Count -eq 0 -and $text.Contains("'SiblingCapture.data.json'")) { Ok 'no capture value in the text; it reads SiblingCapture.data.json' } else { Bad "leaked: $($leaked -join ', ')" }
    $i64 = $text.IndexOf('Is64BitProcess'); $iData = $text.IndexOf('(Join-Path $w32tScRoot ''SiblingCapture.data.json'')')
    $firstStatement = @($text -split "`n" | Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^param\(' -and $_ -notmatch '^\$(ErrorActionPreference|ProgressPreference) =' })[0]
    if ($i64 -gt 0 -and $iData -gt $i64 -and $firstStatement -match 'Is64BitOperatingSystem -and -not \[Environment\]::Is64BitProcess\) \{ exit 2 \}') { Ok 'the 64-bit check comes first (a 32-bit process exits 2 before the data file is read)' } else { Bad "first: $firstStatement" }
    if ($text -match [regex]::Escape("if (@('C:\PSADT\Out', 'C:\W32TOut') -notcontains `$w32tScOut) { exit 2 }") -and $text -match [regex]::Escape("if (`$w32tScKey -cnotmatch '^[a-z0-9_.+-]{1,80}$') { exit 2 }")) { Ok 'OutDir restricted to C:\PSADT\Out or C:\W32TOut; the capture key checked' } else { Bad 'OutDir / key checks' }

    # == [3] ===============================================================================================
    Write-Host '[3] the shared text, the constants, the files' -ForegroundColor Cyan
    $attr = Get-Win32ToolkitSiblingAttributionScript
    $part = Get-Win32ToolkitSiblingCaptureScript -Part Attribution
    $at = $text.IndexOf($attr)
    if ($part -ceq $attr -and $at -ge 0 -and $text.IndexOf($attr, $at + 1) -lt 0) { Ok 'the attribution text is embedded verbatim, exactly once (-Part Attribution is byte-identical to the catalog)' } else { Bad 'attribution embedding' }
    # SV16: the guest ranks with the host's inputs - the package's publisher comes from the data file (never ''), so a
    # Microsoft entry of a Microsoft package is ranked in the guest exactly as on the host.
    $calls = @([regex]::Matches($text, '& \$w32tScAttribute [^\n]*') | ForEach-Object { $_.Value })
    if ($calls.Count -eq 1 -and $calls[0] -ceq '& $w32tScAttribute @($w32tCands) $w32tScData.Manifest $w32tScData.Own ([string]$w32tScData.PackagePublisher) $w32tNewRoots') { Ok "the guest calls the attribution once, with the data file's PackagePublisher" } else { Bad "attribution call: $($calls -join ' | ')" }
    $nsis = ([regex]::Matches($text, [regex]::Escape("'/S _?='"))).Count
    $inno = ([regex]::Matches($text, [regex]::Escape("'/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'"))).Count
    if ($nsis -eq 1 -and $inno -eq 1) { Ok "the constant uninstall switches ('/S _?=<folder>', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART') appear exactly once each" } else { Bad "constants: nsis $nsis inno $inno" }
    $names = @('SiblingPre_', 'SiblingInstall_', 'SiblingCapture_', 'SiblingProbe_', 'SiblingDone_', "'SiblingCopy_'")
    if (@($names | Where-Object { -not $text.Contains($_) }).Count -eq 0 -and $text -match "'Logs\\SiblingCapture_' \+ \`$w32tWhich \+ '\.log'") { Ok 'the phase files are the frozen names (Sibling<Phase>_<key>.json, SiblingCopy_<key>_*.exe, Logs\*.log) the host allow-list expects' } else { Bad 'file names' }
    foreach ($ph in 'PreSibling', 'Install', 'PostSibling', 'Probe', 'CollectLogs', 'All') { if (-not $text.Contains("'$ph'")) { Bad "phase $ph missing" } }
    Ok 'every phase is dispatched (PreSibling, Install, PostSibling, Probe, CollectLogs, All)'
    # Live row ASSISTED (SV18): an assisted record said Account SYSTEM and read SYSTEM's HKCU; the operator who installs is the
    # user signed in to the console (HKEY_USERS\<SID>). Other captures keep the phase's own account.
    if ($text -match [regex]::Escape("if ([string]`$w32tScData.Mode -eq 'Assisted') {") -and $text.Contains("Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName") -and
        $text.Contains("`$w32tScUserArp = 'Registry::HKEY_USERS\' + `$w32tScSid + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'") -and $text.Contains("@{ Path = `$w32tScUserArp; View = 'User' }") -and
        $text.Contains('Account = $w32tScAccount') -and -not $text.Contains("@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; View = 'User' }")) {
        Ok 'an assisted capture snapshots the console user''s HKEY_USERS\<SID> uninstall entries and records that account (SV18)'
    } else { Bad 'assisted account / HKCU' }
    # Live row INNO: an absent PendingFileRenameOperations wrote TerminatingError(Get-ItemProperty) lines into the transcript.
    if ($text -notmatch 'PendingFileRenameOperations -ErrorAction Stop' -and $text.Contains("GetValue('PendingFileRenameOperations', `$null)")) { Ok 'pending file renames are read through the registry API (an absent value is no TerminatingError record)' } else { Bad 'PFRO read' }

    # == [4] ===============================================================================================
    # Live checks GOAL-CAPTURE, GOAL-APPROVE, DEMOTE, RAISE, INNO, TUI (2026-10-26): on Windows 11 26200 Windows' own update
    # repair (WaaSMedicSvc) set wuauserv back to Manual and started it about 135 s after PreSibling disabled it, so every
    # Hyper-V capture recorded NoiseControl Unverified and no proposal could ever be Enforce. The check, under Windows
    # PowerShell 5.1 with the WMI, Task Scheduler and event log reads shadowed.
    Write-Host '[4] the noise check (Windows PowerShell 5.1): Windows Update restarted by its repair, nothing installed' -ForegroundColor Cyan
    $ps51n = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51n)) { Bad 'Windows PowerShell 5.1 is not available for the noise check' }
    else {
        $defs = @('$w32tScWuSeen', '$w32tScWuQuiet', '$w32tScNoiseCheck', '$w32tScNoiseState', '$w32tScNoiseFailed', '$w32tScHold', '$w32tScNoiseDetail', '$w32tScPre' | ForEach-Object { [regex]::Match($text, '(?s)\n' + [regex]::Escape($_) + ' = \{.*?\n\}\n').Value })
        # Every cmdlet that would change or read this host (services, tasks, the registry policies, the snapshot) is shadowed;
        # the phase file goes to a variable. Get-WinEvent writes 'no events' as a NON-terminating NoMatchingEventsFound error,
        # as the real one does.
        $harness = @'
param([string]$Case)
$ErrorActionPreference = 'Stop'
$script:svc = @{ edgeupdate = @('Stopped', 'Disabled'); edgeupdatem = @('Stopped', 'Disabled'); wuauserv = @('Stopped', 'Disabled'); UsoSvc = @('Stopped', 'Disabled') }
$script:events = $null
$script:evThrows = ''
$script:sticky = @{}
$script:medic = $false
$script:holds = 0
$script:sleeps = 0
switch ($Case) {
    'quiet'     { }
    'wu-norun'  { $script:svc.wuauserv = @('Running', 'Manual') }
    'wu-cu'     { $script:svc.wuauserv = @('Running', 'Manual'); $script:events = @('2026-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5099999)') }
    'wu-def'    { $script:svc.wuauserv = @('Running', 'Manual'); $script:svc.UsoSvc = @('Running', 'Manual'); $script:events = @('Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.441.1.0)') }
    'wu-noread' { $script:svc.wuauserv = @('Running', 'Manual'); $script:evThrows = 'other' }
    'edge'      { $script:svc.edgeupdate = @('Running', 'Auto') }
    'pre-medic' { $script:svc = @{ edgeupdate = @('Running', 'Auto'); edgeupdatem = @('Stopped', 'Manual'); wuauserv = @('Running', 'Manual'); UsoSvc = @('Running', 'Auto') }; $script:medic = $true }
    'pre-medic-cu' { $script:svc = @{ edgeupdate = @('Running', 'Auto'); edgeupdatem = @('Stopped', 'Manual'); wuauserv = @('Running', 'Manual'); UsoSvc = @('Running', 'Auto') }; $script:medic = $true; $script:events = @('2026-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5099999)') }
    'pre-edge'  { $script:svc = @{ edgeupdate = @('Running', 'Auto'); edgeupdatem = @('Stopped', 'Manual'); wuauserv = @('Running', 'Manual'); UsoSvc = @('Running', 'Auto') }; $script:sticky = @{ edgeupdate = 3 } }
    'pre-late'  { $script:svc = @{ edgeupdate = @('Running', 'Auto'); edgeupdatem = @('Stopped', 'Manual'); wuauserv = @('Running', 'Manual'); UsoSvc = @('Running', 'Auto') }; $script:sticky = @{ edgeupdate = 1 } }
}
function Get-CimInstance { [CmdletBinding()] param($ClassName) foreach ($k in $script:svc.Keys) { New-Object psobject -Property @{ Name = $k; State = $script:svc[$k][0]; StartMode = $script:svc[$k][1] } } }
function Get-ScheduledTask { [CmdletBinding()] param() New-Object psobject -Property @{ TaskPath = '\'; TaskName = 'MicrosoftEdgeUpdateTaskMachineCore'; State = 'Disabled' } }
function Disable-ScheduledTask { [CmdletBinding()] param($InputObject) }
function Get-Service { [CmdletBinding()] param($Name) if ($script:svc.ContainsKey([string]$Name)) { New-Object psobject -Property @{ Name = $Name } } }
# A sticky service resists the first N holds (still starting); Windows Update Medic sets wuauserv back to Manual and starts it
# again right after it was stopped and disabled.
function Stop-Service { [CmdletBinding()] param($Name, [switch]$Force) if ($script:sticky.ContainsKey([string]$Name) -and $script:sticky[[string]$Name] -gt 0) { throw 'cannot stop' }; $script:svc[[string]$Name] = @('Stopped', $script:svc[[string]$Name][1]) }
function Set-Service {
    [CmdletBinding()] param($Name, $StartupType)
    if ($script:sticky.ContainsKey([string]$Name) -and $script:sticky[[string]$Name] -gt 0) { $script:sticky[[string]$Name]--; throw 'cannot change' }
    $script:svc[[string]$Name] = @($script:svc[[string]$Name][0], 'Disabled')
    if ($script:medic -and [string]$Name -eq 'wuauserv') { $script:svc.wuauserv = @('Running', 'Manual') }
}
function New-Item { [CmdletBinding()] param($Path, [switch]$Force) }
function New-ItemProperty { [CmdletBinding()] param($Path, $Name, $Value, $PropertyType, [switch]$Force) }
function Get-ItemProperty { [CmdletBinding()] param($LiteralPath, $Name) New-Object psobject -Property @{ UBR = 1 } }
function Start-Sleep { [CmdletBinding()] param($Seconds) $script:sleeps++ }
function Get-WinEvent {
    [CmdletBinding()] param($FilterHashtable)
    if ($script:evThrows) { throw 'The event log cannot be read' }
    if ($null -eq $script:events) { $PSCmdlet.WriteError((New-Object System.Management.Automation.ErrorRecord ((New-Object System.Exception 'No events were found that match the specified selection criteria.')), 'NoMatchingEventsFound', 'ObjectNotFound', $null)); return }
    foreach ($t in $script:events) { $p = New-Object psobject -Property @{ Value = $t }; New-Object psobject -Property @{ Properties = @($p) } }
}
'@ + "`n" + ($defs -join "`n") + "`n" + @'
$items = @(@{ Kind = 'Service'; Name = 'edgeupdate' }, @{ Kind = 'Service'; Name = 'edgeupdatem' }, @{ Kind = 'Service'; Name = 'wuauserv' }, @{ Kind = 'Service'; Name = 'UsoSvc' }, @{ Kind = 'Task'; Name = '\MicrosoftEdgeUpdateTaskMachineCore' })
if ($Case -like 'pre-*') {
    $w32tScKey = 'nullsoft-8.9.8'; $w32tScAccount = 'NT AUTHORITY\SYSTEM'
    $w32tScUtc = { '2026-10-28T06:15:41Z' }
    $w32tScSnapshot = { [ordered]@{} }
    $global:w32tPreFile = $null
    $w32tScWrite = { param([string]$w32tName, $w32tObj) $global:w32tPreFile = ConvertTo-Json -InputObject $w32tObj -Depth 6 -Compress }
    $null = & $w32tScPre
    $pre = $global:w32tPreFile | ConvertFrom-Json
    'pre=' + $pre.NoiseVerified + ';started=' + $pre.StartedUtc + ';sleeps=' + $script:sleeps + ';failed=' + (@($pre.NoiseFailed) -join ',')
    'json=' + (ConvertTo-Json -InputObject ([ordered]@{ NoiseDetail = (& $w32tScNoiseDetail $items ([string]$pre.StartedUtc) ([bool]$pre.NoiseVerified) @($pre.NoiseFailed)) }) -Compress)
    return
}
$tr = Join-Path $env:TEMP ('w32scg-tr-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
$null = Start-Transcript -LiteralPath $tr
'strict=' + (& $w32tScNoiseCheck $items) + ';post=' + (& $w32tScNoiseCheck $items '2026-10-26T17:20:00Z') + ';detail=' + ((& $w32tScNoiseState $items) -join ',')
'json=' + (ConvertTo-Json -InputObject ([ordered]@{ NoiseDetail = (& $w32tScNoiseDetail $items '2026-10-26T17:20:00Z' $false @()) }) -Compress)
$null = Stop-Transcript
'transcript-terminating=' + ([IO.File]::ReadAllText($tr) -match 'TerminatingError')
Remove-Item -LiteralPath $tr -Force
'@
        $hf = Join-Path $tmp 'noise.ps1'
        [IO.File]::WriteAllText($hf, $harness, [Text.UTF8Encoding]::new($true))
        $run = { param($c) (@(& $ps51n -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hf -Case $c 2>&1) | ForEach-Object { "$_" }) -join ' | ' }
        $want = @{
            'quiet'     = 'strict=True;post=True;'
            'wu-norun'  = 'strict=False;post=True;'
            'wu-cu'     = 'strict=False;post=False;'
            'wu-def'    = 'strict=False;post=True;'
            'wu-noread' = 'strict=False;post=False;'
            'edge'      = 'strict=False;post=False;'
        }
        foreach ($c in 'quiet', 'wu-norun', 'wu-cu', 'wu-def', 'wu-noread', 'edge') {
            $o = & $run $c
            if ($defs.Count -eq 8 -and @($defs | Where-Object { -not $_ }).Count -eq 0 -and $o.StartsWith($want[$c])) { Ok "${c}: $($o -replace ';detail=.*$', '')" } else { Bad "${c}: $o" }
        }
        # Live row ASSISTED: 'no events' (the usual answer) wrote PS>TerminatingError(Get-WinEvent) into the phase transcript.
        $o = & $run 'wu-norun'
        if ($o -match 'transcript-terminating=False') { Ok 'Windows Update installed nothing: no TerminatingError(Get-WinEvent) line in the transcript (read from -ErrorVariable)' } else { Bad "transcript: $o" }
        $o = & $run 'wu-norun'
        if ($o -match 'detail=edgeupdate Stopped/Disabled,edgeupdatem Stopped/Disabled,wuauserv Running/Manual,UsoSvc Stopped/Disabled,\\MicrosoftEdgeUpdateTaskMachineCore Disabled( \||$)') { Ok 'NoiseDetail names each service state and the task state' } else { Bad "detail: $o" }
        # Live rows RAISE, ASSISTED: '@(& $w32tScNoiseState ... | Select-Object -First 16)' wrapped the returned list, so
        # Windows PowerShell 5.1 wrote {"NoiseDetail":[[...]]} and the host showed one string cut at 80 characters. One flat
        # list now, with what Windows Update installed (or why its log could not be read) when not verified.
        $o = & $run 'wu-cu'
        if ($o -match [regex]::Escape('json={"NoiseDetail":["edgeupdate Stopped/Disabled","edgeupdatem Stopped/Disabled","wuauserv Running/Manual","UsoSvc Stopped/Disabled","\\MicrosoftEdgeUpdateTaskMachineCore Disabled","Windows Update installed: 2026-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5099999)"]}')) {
            Ok 'NoiseDetail under 5.1 is one flat JSON list: the states, then what Windows Update installed'
        } else { Bad "flat detail: $o" }
        $o = & $run 'wu-noread'
        if ($o -match 'json=\{"NoiseDetail":\["edgeupdate .*,"Windows Update event log unreadable"\]\}') { Ok 'an unreadable Windows Update log is named in NoiseDetail' } else { Bad "noread detail: $o" }
        if ($text.Contains('$w32tNoiseDetail = & $w32tScNoiseDetail @($w32tPre.Noise) ([string]$w32tPre.StartedUtc) ($w32tNoise -eq ''Verified'') @($w32tPre.NoiseFailed)') -and $text -notmatch '@\(& \$w32tScNoiseState [^\n]*\| Select-Object') { Ok 'PostSibling assigns NoiseDetail from the helper directly (no @() around the returned list), with what PreSibling could not hold' } else { Bad 'NoiseDetail call site' }
        if ($text.Contains("(& `$w32tScNoiseCheck @(`$w32tPre.Noise) ([string]`$w32tPre.StartedUtc))") -and $text.Contains('$w32tHeld = [bool](& $w32tScNoiseCheck $w32tNoise $w32tStarted)') -and $text.Contains("-Name 'NoAutoUpdate' -Value 1")) { Ok 'PreSibling checks from its own start time and turns automatic updates off; PostSibling checks from the PreSibling start time' } else { Bad 'noise check call sites' }

        # == [5] ===========================================================================================
        # Live rows DEMOTE, INNO, ASSISTED (2026-10-28): wuauserv running again seconds after the restored VM resumed failed the
        # strict check BEFORE the install, the capture was NoiseUnverified for good (a sticky record flag) while Windows Update
        # installed nothing, and the warning blamed Windows Update. PreSibling, under Windows PowerShell 5.1, every cmdlet that
        # touches the host shadowed.
        Write-Host '[5] PreSibling (Windows PowerShell 5.1): the update repair excused, three tries, what it could not hold' -ForegroundColor Cyan
        $o = & $run 'pre-medic'
        if ($o -match '^pre=True;started=2026-10-28T06:15:41Z;sleeps=0;failed= \|' -and $o -match [regex]::Escape('json={"NoiseDetail":["edgeupdate Stopped/Disabled","edgeupdatem Stopped/Disabled","wuauserv Running/Manual","UsoSvc Stopped/Disabled","\\MicrosoftEdgeUpdateTaskMachineCore Disabled"]}')) {
            Ok 'Windows Update Medic starts wuauserv again right after PreSibling disabled it, nothing installed -> held (Verified possible), no retry'
        } else { Bad "pre-medic: $o" }
        $o = & $run 'pre-medic-cu'
        if ($o -match '^pre=False;started=2026-10-28T06:15:41Z;sleeps=2;failed=wuauserv Running/Manual \|' -and $o -match [regex]::Escape('json={"NoiseDetail":["before the install: wuauserv Running/Manual","edgeupdate Stopped/Disabled"') -and $o -match [regex]::Escape(',"Windows Update installed: 2026-10 Cumulative Update')) {
            Ok 'the same with a Windows Update installation since the start -> not held after three tries; NoiseDetail leads with ''before the install: wuauserv Running/Manual'' and names the update'
        } else { Bad "pre-medic-cu: $o" }
        $o = & $run 'pre-edge'
        if ($o -match '^pre=False;[^|]*sleeps=2;failed=edgeupdate Running/Auto \|' -and $o -match [regex]::Escape('json={"NoiseDetail":["before the install: edgeupdate Running/Auto"')) { Ok 'an Edge update service that cannot be stopped (strict, never excused) -> not held; the detail names it before the install' } else { Bad "pre-edge: $o" }
        $o = & $run 'pre-late'
        if ($o -match '^pre=True;[^|]*sleeps=1;failed= \|') { Ok 'a service still starting on the first try is held on the second (5 s later)' } else { Bad "pre-late: $o" }
    }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingCaptureGuest tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingCaptureGuest test(s) FAILED." -ForegroundColor Red; exit 1 }
