# A stub of the win32-toolkit module for Tests\HyperVLaneRunner.unit.ps1 (scripts\Invoke-Win32ToolkitHyperVLane.ps1).
# Never shipped, never a real Hyper-V call. Every function logs one line to $env:W32T_LANE_STUB_LOG; its behaviour comes
# from the JSON file $env:W32T_LANE_STUB (DefaultVM, BusyProjects, HoldBusy, VMConnect, Behaviour: leaf -> w32t | plain |
# inner | norecord | Failed). The test writes a record per run into the project's Documentation\TestResults.json, as the
# real one. Test-Win32ToolkitProject ends like the real command: a W32T error is thrown, any other failure becomes the
# non-terminating 'Test-Win32ToolkitProject failed: ...' error; it also logs the error preference it runs with and any
# lane-runner variable it can see in the global scope (state:<leaf>:eap=<preference>:globals=<names>).

$script:stubLog = $env:W32T_LANE_STUB_LOG
$script:stubCfg = @{}
if ($env:W32T_LANE_STUB -and (Test-Path -LiteralPath $env:W32T_LANE_STUB)) { $script:stubCfg = Get-Content -LiteralPath $env:W32T_LANE_STUB -Raw | ConvertFrom-Json -AsHashtable }
$script:runs = 0

function Write-StubLog { param([string]$Line) if ($script:stubLog) { Add-Content -LiteralPath $script:stubLog -Value $Line -Encoding utf8 } }
function New-StubError { param([string]$Id, [string]$Target) [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("stub $Id"), $Id, [System.Management.Automation.ErrorCategory]::ResourceBusy, $Target) }

Write-StubLog "import:vm=$env:W32T_HYPERV_VM;cp=$env:W32T_HYPERV_CHECKPOINT;psadt=$env:W32T_PSADT_VERSION"

function Get-Win32ToolkitConfigValue {
    [CmdletBinding()]
    param([string]$Name, [string]$Default)
    Write-StubLog "cfg:$Name"
    if ($Name -eq 'HyperVVMName' -and $script:stubCfg['DefaultVM']) { return [string]$script:stubCfg['DefaultVM'] }
    $Default
}

function Enter-Win32ToolkitHyperVLease {
    [CmdletBinding()]
    param([string]$VMName, [string]$VMId, [string]$ProjectPath, [string]$Purpose, [int]$WaitSeconds)
    $leaf = if ($ProjectPath) { Split-Path -Leaf $ProjectPath } else { '' }
    $wait = if ($PSBoundParameters.ContainsKey('WaitSeconds')) { [string]$WaitSeconds } else { '' }
    Write-StubLog "enter:vm=$VMName|project=$leaf|purpose=$Purpose|wait=$wait"
    if ($ProjectPath -and @($script:stubCfg['BusyProjects']) -contains $leaf) { throw (New-StubError 'W32T.ProjectLeaseTimeout' $leaf) }
    if ($VMName -and $script:stubCfg['HoldBusy']) { throw (New-StubError 'W32T.HyperVLeaseTimeout' $VMName) }
    [pscustomobject]@{ Kind = $(if ($ProjectPath) { 'Project' } else { 'VM' }); Name = $(if ($ProjectPath) { $leaf } else { $VMName }); Epoch = 'stub'; Generation = 1; PreviousGeneration = 0; Nested = $false; Released = $false }
}

function Exit-Win32ToolkitHyperVLease {
    [CmdletBinding()]
    param($Lease)
    Write-StubLog "exit:$($Lease.Kind):$($Lease.Name)"
}

function Test-Win32ToolkitVMConnectOpen {
    [CmdletBinding()]
    param([string]$VMName, [string]$VMId)
    Write-StubLog "vmc:$VMName"
    [bool]$script:stubCfg['VMConnect']
}

function Clear-Win32ToolkitHyperVStateCache {
    [CmdletBinding()]
    param([switch]$MarkerOnly)
    Write-StubLog "clear:markeronly=$($MarkerOnly.IsPresent)"
}

# A helper that reports a problem and goes on (Write-Error, non-terminating), as some real helpers do.
function Invoke-StubHelper {
    [CmdletBinding()]
    param([string]$Leaf)
    Write-Error "stub: a helper of $Leaf reported a problem and went on"
    Write-StubLog "helper-went-on:$Leaf"
}

function Test-Win32ToolkitProject {
    [CmdletBinding()]
    param([string]$ProjectPath, [string]$Scenario, [int]$VersionsBack, [string]$SpecificVersion, [string]$BaselineInstallerType, [string]$BaselineProject,
        [string]$BaselineProjectPath, [string]$Backend, [switch]$Unattended)
    $leaf = Split-Path -Leaf $ProjectPath
    $keys = @($PSBoundParameters.Keys | Where-Object { $_ -notin [System.Management.Automation.Cmdlet]::CommonParameters } | Sort-Object) -join ','
    Write-StubLog "test:${leaf}:${Scenario}:backend=${Backend}:unattended=$($Unattended.IsPresent):keys=$keys"
    $seen = @('item', 'items', 'rec', 'n', 'why', 'queue', 'result', 'hold', 'exitCode', 'testArgs', 'say', 'mod', 'clockBlock') | Where-Object { Get-Variable -Scope Global -Name $_ -ErrorAction SilentlyContinue }
    Write-StubLog "state:${leaf}:eap=${ErrorActionPreference}:globals=$($seen -join ',')"
    try {
        # As the real run: the VM's lease inside the test (nested when the lane holds it).
        $vmLease = Enter-Win32ToolkitHyperVLease -VMName $env:W32T_HYPERV_VM -Purpose 'test run'
        Exit-Win32ToolkitHyperVLease -Lease $vmLease
        $script:runs++
        $how = if ($script:stubCfg['Behaviour']) { [string]$script:stubCfg['Behaviour'][$leaf] } else { '' }
        if ($how -eq 'w32t') { throw (New-StubError 'W32T.HyperVTargetNotReady' $leaf) }
        if ($how -eq 'plain') { throw "stub: something broke in $leaf" }
        if ($how -eq 'inner') { Invoke-StubHelper -Leaf $leaf }
        if ($how -eq 'norecord') { return $null }
        $verdict = if ($how -eq 'Failed') { 'Failed' } else { 'Passed' }
        $docs = Join-Path $ProjectPath 'Documentation'
        $null = New-Item -ItemType Directory -Path $docs -Force
        $file = Join-Path $docs 'TestResults.json'
        $records = @()
        if (Test-Path -LiteralPath $file) { $records = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -NoEnumerate) }
        $records += [pscustomobject]@{ Scenario = $Scenario; Backend = $Backend; Verdict = $verdict; TimestampUtc = [datetime]::UtcNow.ToString('o')
            Timing = [pscustomobject]@{ TotalSeconds = 100.5 + $script:runs; OpenRevertSkipped = ($script:runs -gt 1) } }
        [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject @($records) -Depth 5), [System.Text.UTF8Encoding]::new($false))
        $verdict -eq 'Passed'
    }
    catch {
        # As Test-Win32ToolkitProject's outer catch (C-2): W32T errors are thrown, anything else is reported, not thrown.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Error "Test-Win32ToolkitProject failed: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Test-Win32ToolkitProject
