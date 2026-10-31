<#
.SYNOPSIS
    Runs a queue of Hyper-V tests in one PowerShell process (a "lane") on one pinned test VM.
.DESCRIPTION
    Hyper-V speed-up PR 3 (D31). A repository tool, not shipped with the module. One lane = one PowerShell process, one
    import of the module (never -Force), one test VM pinned for the process (W32T_HYPERV_VM, set before the import), and
    optionally one PSAppDeployToolkit line (W32T_PSADT_VERSION). The queue's tests run one after the other with
    -Backend HyperV -Unattended, so a run whose previous run left the VM clean moments ago skips its own first
    checkpoint restore (the clean marker), and the first run restores as usual.

    1. The queue (-QueuePath) is a JSON array. Each item has exactly the keys ProjectPath (an existing folder) and
       Scenario (InstallUninstall or Update), and optionally VersionsBack (1-1000), SpecificVersion,
       BaselineInstallerType (Test-Win32ToolkitProject's values), BaselineProject and BaselineProjectPath (an existing
       folder); the optional keys are for Update only. Key names are case-sensitive. Anything else is
       W32T.LaneQueueInvalid: exit 1, nothing runs.
    2. The module is imported once without -Force; a win32-toolkit already loaded from another folder is refused
       (start a new PowerShell process). W32T_HYPERV_VM is always -VMName; W32T_HYPERV_CHECKPOINT and
       W32T_PSADT_VERSION are -CheckpointName / -PsadtVersion when given, and otherwise cleared for the lane (one line
       names a value inherited from the calling session that is not used), so the result file records what ran.
    3. -HoldLease takes the VM's lease for the whole queue (every run then nests in it, and another process waits for
       the whole lane). Refused on the registry's default test VM (HyperVVMName, else win32tk-golden): a lane holds a
       VM of its own.
    4. Each item takes the project's lease first (lock order: project, then VM). Under -HoldLease the lane already
       holds the VM, so the project lease is tried once (-WaitSeconds 0): a busy project is recorded as
       W32T.ProjectLeaseTimeout for that item, the item is not run and the queue goes on. Before an item the clean
       marker is dropped (Clear-Win32ToolkitHyperVStateCache -MarkerOnly, one line with the reason) when -FreshRestore
       is set, when more than -MaxGapSeconds passed since the previous item ended, or when a VM console (vmconnect) is
       open for the VM: the run then restores the checkpoint first. Each test runs as from the command line
       (Test-Win32ToolkitProject @item -Backend HyperV -Unattended, without -ErrorAction): the runner's own body runs in
       a child scope, so nothing it sets (its variables, its 'Stop' error preference) is global or seen by the module,
       even when the script is started with pwsh -File (which runs a script's body in the global scope).
    5. -Diagnostics: one transcript per item (<result folder>\<n>-<project>.log) and verbose output; the lane's own
       lines carry UTC times. There is no guest observer (A-17): observing the guest stays with the caller.
    6. The result file (-ResultPath, default lane-result.json next to the queue) lists every item: its start and end
       (UTC), whether it ran, the verdict and the Timing.OpenRevertSkipped / Timing.TotalSeconds of the record it
       wrote, the reason a marker was dropped, and any error id. Exit 0 = every item ran (verdicts are data), 1 = a
       W32T error (an item's, a lease's) or an invalid queue, 2 = an item failed with another error (a test that
       reported 'Test-Win32ToolkitProject failed: ...', its error id then Exception).

    The process must be elevated (Hyper-V, PowerShell Direct and the lock folder need it).
.PARAMETER QueuePath
    The queue (JSON array, see above).
.PARAMETER VMName
    The test VM of this lane (W32T_HYPERV_VM for the process).
.PARAMETER CheckpointName
    Its base checkpoint (W32T_HYPERV_CHECKPOINT); omitted: HyperVCheckpoint, else clean-base (a W32T_HYPERV_CHECKPOINT
    inherited from the calling session is cleared for the lane).
.PARAMETER PsadtVersion
    W32T_PSADT_VERSION for the process (one lane per PSAppDeployToolkit line); omitted: the variable is cleared for the
    lane, so the module selects PSAppDeployToolkit as without it (PreferredPsadtVersion, else its default choice).
.PARAMETER ModulePath
    The module to import (default: win32-toolkit.psd1 of this repository).
.PARAMETER ResultPath
    The result file (default: lane-result.json in the queue's folder).
.PARAMETER MaxGapSeconds
    Drop the clean marker when more time than this passed since the previous item ended (default 120).
.PARAMETER FreshRestore
    Drop the clean marker before every item (every run restores first: a final check).
.PARAMETER HoldLease
    Hold the VM's lease for the whole queue (never on the default test VM).
.PARAMETER Diagnostics
    A transcript per item and verbose output.
.PARAMETER Clock
    Hidden: a scriptblock that returns the current UTC time (tests).
.EXAMPLE
    pwsh -NoProfile -File scripts\Invoke-Win32ToolkitHyperVLane.ps1 -QueuePath C:\lanes\a\queue.json -VMName win32tk-lane1 -PsadtVersion 4.1.8 -HoldLease
#>
# Every parameter is read inside the body's child script block (the & { } below), which PSReviewUnusedParameter does not
# search: the body must not run in the script scope, which pwsh -File makes the global one.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'parameters are read in the child script block that holds the body')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$QueuePath,

    [Parameter(Mandatory)]
    [string]$VMName,

    [string]$CheckpointName,

    [string]$PsadtVersion,

    [string]$ModulePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'win32-toolkit.psd1'),

    [string]$ResultPath,

    [ValidateRange(0, 86400)]
    [int]$MaxGapSeconds = 120,

    [switch]$FreshRestore,

    [switch]$HoldLease,

    [switch]$Diagnostics,

    [Parameter(DontShow)]
    [scriptblock]$Clock
)

# pwsh -File runs a script's body in the global scope: the whole body runs in this child scope instead, so nothing the
# runner sets is global. Module functions read their own scope chain (module, then global), never this one: the 'Stop'
# below applies to the runner's own statements only, and every test runs with the error handling of a command-line run.
& {
    $ErrorActionPreference = 'Stop'
    $clockBlock = $Clock   # hidden test seam: the current UTC time
    $now = { if ($clockBlock) { ([datetime](& $clockBlock)).ToUniversalTime() } else { [datetime]::UtcNow } }
    $say = { param([string]$Text, [string]$Color = 'Cyan') Write-Host ('[{0:HH:mm:ss}Z] lane: {1}' -f (& $now), $Text) -ForegroundColor $Color }
    $safe = { param($Text, [int]$Max = 200) $s = (([string]$Text) -replace '[\x00-\x1F\x7F]', '?').Trim(); if ($s.Length -gt $Max) { $s.Substring(0, $Max - 3) + '...' } else { $s } }
    $invalid = {
        param([string]$Message)
        & $say ("W32T.LaneQueueInvalid: " + $Message + ' Nothing was run.') 'Red'
        exit 1
    }
    $validName = { param($Value) $null -ne $Value -and ([string]$Value).Trim() -cmatch '^[^\x00-\x1F\x7F]{1,100}\z' }

    # -- 1. the queue ------------------------------------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $QueuePath -PathType Leaf)) { & $invalid "the queue file $(& $safe $QueuePath) does not exist." }
    $queue = $null
    try { $queue = Get-Content -LiteralPath $QueuePath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop }
    catch { & $invalid "the queue is not valid JSON ($(& $safe $_.Exception.Message))." }
    if ($queue -isnot [System.Collections.IList] -or $queue -is [string]) { & $invalid 'the queue must be a JSON array of items.' }
    if ($queue.Count -eq 0) { & $invalid 'the queue is empty.' }
    $installerTypes = @('Auto', 'Both', 'Packaged', 'msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')
    $updateOnly = @('VersionsBack', 'SpecificVersion', 'BaselineInstallerType', 'BaselineProject', 'BaselineProjectPath')
    $items = [System.Collections.Generic.List[hashtable]]::new()
    for ($i = 0; $i -lt $queue.Count; $i++) {
        $raw = $queue[$i]
        $n = $i + 1
        if ($raw -isnot [System.Collections.IDictionary]) { & $invalid "item $n is not a JSON object." }
        foreach ($k in @($raw.Keys)) { if ([string]$k -cnotin (@('ProjectPath', 'Scenario') + $updateOnly)) { & $invalid "item $n has the unknown key '$(& $safe $k 40)'." } }
        foreach ($k in 'ProjectPath', 'Scenario') { if (-not $raw.Contains($k)) { & $invalid "item $n has no $k." } }
        $item = @{}
        $p = $raw['ProjectPath']
        if ($p -isnot [string] -or [string]::IsNullOrWhiteSpace($p) -or $p -match '[\x00-\x1F]' -or -not (Test-Path -LiteralPath $p -PathType Container)) { & $invalid "item ${n}: ProjectPath $(& $safe $p) is not an existing folder." }
        $item['ProjectPath'] = $p
        $sc = $raw['Scenario']
        if ($sc -isnot [string] -or $sc -cnotin 'InstallUninstall', 'Update') { & $invalid "item ${n}: Scenario must be InstallUninstall or Update." }
        $item['Scenario'] = $sc
        foreach ($k in $updateOnly) {
            if (-not $raw.Contains($k)) { continue }
            if ($sc -ne 'Update') { & $invalid "item ${n}: $k applies to the Update scenario only." }
            $v = $raw[$k]
            switch ($k) {
                'VersionsBack' {
                    if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 1 -or $v -gt 1000) { & $invalid "item ${n}: VersionsBack must be a whole number from 1 to 1000." }
                    $item[$k] = [int]$v
                }
                'BaselineInstallerType' {
                    if ($v -isnot [string] -or $v -cnotin $installerTypes) { & $invalid "item ${n}: BaselineInstallerType must be one of $($installerTypes -join ', ')." }
                    $item[$k] = $v
                }
                'BaselineProjectPath' {
                    if ($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v) -or $v -match '[\x00-\x1F]' -or -not (Test-Path -LiteralPath $v -PathType Container)) { & $invalid "item ${n}: BaselineProjectPath $(& $safe $v) is not an existing folder." }
                    $item[$k] = $v
                }
                default {
                    if ($v -isnot [string] -or -not (& $validName $v)) { & $invalid "item ${n}: $k must be a text of 1 to 100 characters without control characters." }
                    $item[$k] = $v.Trim()
                }
            }
        }
        $items.Add($item)
    }
    if (-not (& $validName $VMName)) { & $invalid '-VMName must be 1 to 100 characters without control characters.' }
    if ($CheckpointName -and -not (& $validName $CheckpointName)) { & $invalid '-CheckpointName must be 1 to 100 characters without control characters.' }
    $outPath = if ($ResultPath) { $ResultPath } else { Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($QueuePath))) 'lane-result.json' }
    $resultDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($outPath))

    # -- 2. the pin and the module -----------------------------------------------------------------------------------
    # Only the lane's own values: a W32T_HYPERV_CHECKPOINT or W32T_PSADT_VERSION inherited from the calling session is
    # cleared when the matching parameter is omitted (one line), so the lane runs, and records, what it was given.
    $env:W32T_HYPERV_VM = $VMName.Trim()
    if ($CheckpointName) { $env:W32T_HYPERV_CHECKPOINT = $CheckpointName.Trim() }
    elseif ($env:W32T_HYPERV_CHECKPOINT) {
        & $say "W32T_HYPERV_CHECKPOINT '$(& $safe $env:W32T_HYPERV_CHECKPOINT 100)' of the calling session is not used: -CheckpointName was not given (HyperVCheckpoint, else clean-base)." 'Yellow'
        Remove-Item -LiteralPath Env:\W32T_HYPERV_CHECKPOINT
    }
    if ($PsadtVersion) { $env:W32T_PSADT_VERSION = $PsadtVersion }
    elseif ($env:W32T_PSADT_VERSION) {
        & $say "W32T_PSADT_VERSION '$(& $safe $env:W32T_PSADT_VERSION 100)' of the calling session is not used: -PsadtVersion was not given." 'Yellow'
        Remove-Item -LiteralPath Env:\W32T_PSADT_VERSION
    }
    if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) { & $invalid "the module $(& $safe $ModulePath) does not exist." }
    $moduleBase = Split-Path -Parent ([System.IO.Path]::GetFullPath($ModulePath))
    $loaded = @(Get-Module -Name 'win32-toolkit')
    if ($loaded.Count -gt 0 -and @($loaded | Where-Object { [System.IO.Path]::GetFullPath($_.ModuleBase).TrimEnd('\') -ne $moduleBase.TrimEnd('\') }).Count -gt 0) {
        & $invalid "win32-toolkit is already loaded from $(& $safe $loaded[0].ModuleBase) in this process: start a new PowerShell process for the lane."
    }
    $mod = if ($loaded.Count -gt 0) { $loaded[0] } else { @(Import-Module -Name $ModulePath -PassThru -ErrorAction Stop)[0] }
    # -Diagnostics: verbose output from the module's own functions (their preference is not this scope's).
    $vb = @{}
    if ($Diagnostics) { $vb['Verbose'] = $true }

    $result = [ordered]@{
        Runner = 'Invoke-Win32ToolkitHyperVLane'; VMName = $env:W32T_HYPERV_VM; CheckpointName = $(if ($CheckpointName) { $env:W32T_HYPERV_CHECKPOINT } else { $null })
        PsadtVersion = $(if ($PsadtVersion) { $PsadtVersion } else { $null }); HoldLease = [bool]$HoldLease; FreshRestore = [bool]$FreshRestore; MaxGapSeconds = $MaxGapSeconds
        StartedUtc = (& $now).ToString('o'); EndedUtc = $null; ExitCode = $null; Error = $null; Items = [System.Collections.Generic.List[object]]::new()
    }
    $writeResult = {
        $result.EndedUtc = (& $now).ToString('o')
        try {
            if (-not (Test-Path -LiteralPath $resultDir)) { $null = New-Item -ItemType Directory -Path $resultDir -Force -ErrorAction Stop }
            [System.IO.File]::WriteAllText($outPath, (ConvertTo-Json -InputObject $result -Depth 6), [System.Text.UTF8Encoding]::new($false))
        }
        catch { & $say "the result file could not be written: $(& $safe $_.Exception.Message)" 'Red' }
    }
    $errorId = { param($Record) $id = [string]$Record.FullyQualifiedErrorId; if ($id -like 'W32T.*') { ($id -split ',', 2)[0] } else { $null } }

    # -- 3. -HoldLease -----------------------------------------------------------------------------------------------
    $hold = $null
    if ($HoldLease) {
        $defaultVm = [string](& $mod { Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden' })
        if ($defaultVm -and $env:W32T_HYPERV_VM -eq $defaultVm) {
            & $invalid "-HoldLease is refused on the default test VM '$(& $safe $defaultVm 64)' (HyperVVMName): it would keep every other PowerShell session off it for the whole queue. Use a lane VM of its own."
        }
        try { $hold = & $mod { param($Name, $Vb) Enter-Win32ToolkitHyperVLease -VMName $Name -Purpose 'lane' @Vb } $env:W32T_HYPERV_VM $vb }
        catch {
            $result.Error = & $safe $_.Exception.Message 400
            $result.ExitCode = 1
            & $say "the VM's lease could not be taken: $($result.Error)" 'Red'
            & $writeResult
            exit 1
        }
    }

    # -- 4. the items ------------------------------------------------------------------------------------------------
    $exitCode = 0
    $prevEnd = $null
    try {
        for ($i = 0; $i -lt $items.Count; $i++) {
            $item = $items[$i]
            $n = $i + 1
            $leaf = Split-Path -Leaf $item.ProjectPath
            $rec = [ordered]@{ Index = $n; ProjectPath = $item.ProjectPath; Scenario = $item.Scenario; StartUtc = (& $now).ToString('o'); EndUtc = $null
                Ran = $false; Verdict = $null; OpenRevertSkipped = $null; TotalSeconds = $null; MarkerCleared = $null; ErrorId = $null; Error = $null }
            $transcript = $false
            $projectLease = $null
            try {
                if ($Diagnostics) {
                    $logName = ('{0}-{1}.log' -f $n, ($leaf -replace '[^A-Za-z0-9._+-]', '_'))
                    $null = Start-Transcript -LiteralPath (Join-Path $resultDir $logName) -Force
                    $transcript = $true
                }
                & $say "item ${n}: $(& $safe $leaf 80) ($($item.Scenario))"

                # The project's lease first (lock order: project, then VM); tried once while the lane holds the VM (V-18).
                try {
                    $projectLease = & $mod { param($Path, $Once, $Vb) if ($Once) { Enter-Win32ToolkitHyperVLease -ProjectPath $Path -Purpose 'lane' -WaitSeconds 0 @Vb } else { Enter-Win32ToolkitHyperVLease -ProjectPath $Path -Purpose 'lane' @Vb } } $item.ProjectPath ([bool]$HoldLease) $vb
                }
                catch {
                    $id = & $errorId $_
                    $rec.ErrorId = $(if ($id) { $id } else { 'Exception' }); $rec.Error = & $safe $_.Exception.Message 400
                    if ($id) { if ($exitCode -lt 1) { $exitCode = 1 } } else { $exitCode = 2 }
                    & $say "item ${n} not run: $($rec.Error)" 'Yellow'
                    continue
                }

                # A fresh restore when asked, after a long gap, or with a console open (E1 guard).
                $why = $null
                if ($FreshRestore) { $why = 'a fresh restore was asked for (-FreshRestore)' }
                elseif ($null -ne $prevEnd -and ((& $now) - $prevEnd).TotalSeconds -gt $MaxGapSeconds) {
                    $why = "$([int]((& $now) - $prevEnd).TotalSeconds) s since the previous item (more than $MaxGapSeconds s)"
                }
                elseif ($null -ne $prevEnd -and (& $mod { param($Name, $Vb) Test-Win32ToolkitVMConnectOpen -VMName $Name @Vb } $env:W32T_HYPERV_VM $vb)) {
                    $why = 'a VM console (vmconnect) is open'
                }
                if ($why) {
                    & $mod { param($Vb) Clear-Win32ToolkitHyperVStateCache -MarkerOnly @Vb } $vb
                    $rec.MarkerCleared = $why
                    & $say "item ${n}: the run restores the checkpoint first ($why)."
                }

                $resultsFile = Join-Path $item.ProjectPath 'Documentation\TestResults.json'
                $readRecords = { if (Test-Path -LiteralPath $resultsFile) { try { @(Get-Content -LiteralPath $resultsFile -Raw | ConvertFrom-Json) } catch { @() } } else { @() } }
                $before = @(& $readRecords).Count
                $testArgs = @{} + $item + $vb
                $testArgs['Backend'] = 'HyperV'
                $testArgs['Unattended'] = $true
                $rec.Ran = $true
                # As from the command line (no -ErrorAction): a W32T error is thrown; any other failure is the command's
                # own non-terminating 'Test-Win32ToolkitProject failed: ...' error, found in -ErrorVariable (exit 2).
                # Errors that its helpers report and go on from are shown as in any run and change nothing here.
                $testErrors = $null
                try {
                    $null = Test-Win32ToolkitProject @testArgs -ErrorVariable testErrors
                    $failed = @($testErrors | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and "$_" -like 'Test-Win32ToolkitProject failed:*' })
                    if ($failed.Count -gt 0) {
                        $rec.ErrorId = 'Exception'; $rec.Error = & $safe ([string]$failed[-1]) 400
                        $exitCode = 2
                        & $say "item ${n} failed: $($rec.Error)" 'Yellow'
                    }
                }
                catch {
                    $id = & $errorId $_
                    $rec.ErrorId = $(if ($id) { $id } else { 'Exception' }); $rec.Error = & $safe $_.Exception.Message 400
                    if ($id) { if ($exitCode -lt 1) { $exitCode = 1 } } else { $exitCode = 2 }
                    & $say "item ${n} failed: $($rec.Error)" 'Yellow'
                }
                $after = @(& $readRecords)
                if ($after.Count -gt $before) {
                    $last = $after[-1]
                    $rec.Verdict = [string]$last.Verdict
                    if ($last.PSObject.Properties['Timing'] -and $last.Timing) {
                        $rec.OpenRevertSkipped = $last.Timing.OpenRevertSkipped
                        $rec.TotalSeconds = $last.Timing.TotalSeconds
                    }
                }
                & $say "item ${n}: $(if ($rec.Verdict) { $rec.Verdict } else { 'no record' })$(if ($null -ne $rec.TotalSeconds) { ", $($rec.TotalSeconds) s" })$(if ($rec.OpenRevertSkipped -eq $true) { ', no open restore' })."
            }
            finally {
                if ($null -ne $projectLease) { & $mod { param($Lease, $Vb) $null = Exit-Win32ToolkitHyperVLease -Lease $Lease @Vb } $projectLease $vb }
                $rec.EndUtc = (& $now).ToString('o')
                $result.Items.Add($rec)
                $prevEnd = & $now
                if ($transcript) { try { $null = Stop-Transcript } catch { & $say "the transcript could not be stopped: $(& $safe $_.Exception.Message)" 'Yellow' } }
            }
        }
    }
    finally {
        if ($null -ne $hold) { & $mod { param($Lease, $Vb) $null = Exit-Win32ToolkitHyperVLease -Lease $Lease @Vb } $hold $vb }
    }

    $result.ExitCode = $exitCode
    & $writeResult
    & $say "done: $($items.Count) item(s), exit $exitCode; $outPath"
    exit $exitCode
}
