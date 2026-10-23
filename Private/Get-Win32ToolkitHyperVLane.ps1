function Get-Win32ToolkitHyperVLane {
    <#
    .SYNOPSIS
        Reads the identity of the test VM and its checkpoint for a Hyper-V run's record (the Lane object).
    .DESCRIPTION
        Hyper-V speed-up PR 1 (D12): the Lane of a Hyper-V run's TestResults.json record, and the identity the
        Intune-parity pre-check and the checkpoint attestation key their caches on. One Get-VMCheckpoint (the named
        checkpoint) and, when -VM is not given, one Get-VM. Read-only.

        Returns a hashtable with VMName, VMId, CheckpointName, CheckpointId, CheckpointCreatedUtc (round-trip 'o'
        text, UTC), CheckpointAgeDays, ProcessorCount, MemoryGB, ConcurrentLanes (1), plus two internal keys for the
        cache identity: CheckpointCreationTicks (the checkpoint's creation time in UTC ticks) and CheckpointObjectId
        (the checkpoint's Id as read). Add-Win32ToolkitTestResult writes only the Lane keys of its allow-list. The
        caller adds Attestation.

        Fail-open: a value it could not read is '' (identities) or $null (numbers), with one verbose line; it never
        throws. A checkpoint name that matches more than one checkpoint is treated as unreadable.
    .PARAMETER VMName
        The test VM.
    .PARAMETER CheckpointName
        The checkpoint the run restores (the deps checkpoint when the run uses one).
    .PARAMETER VM
        The Get-VM object the caller already read (saves one Get-VM).
    .OUTPUTS
        [hashtable]
    .EXAMPLE
        $lane = Get-Win32ToolkitHyperVLane -VMName 'win32tk-golden' -CheckpointName 'clean-base'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CheckpointName,

        [object]$VM
    )

    $guid = '^[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
    $lane = @{
        VMName                  = $VMName
        VMId                    = ''
        CheckpointName          = $CheckpointName
        CheckpointId            = ''
        CheckpointCreatedUtc    = ''
        CheckpointAgeDays       = $null
        ProcessorCount          = $null
        MemoryGB                = $null
        ConcurrentLanes         = 1
        CheckpointCreationTicks = $null
        CheckpointObjectId      = ''
    }

    try {
        if ($null -eq $VM) { $VM = Get-VM -Name $VMName -ErrorAction Stop }
        $vmId = [string]$VM.Id
        if ($vmId -match $guid) { $lane.VMId = $vmId }
        if ($null -ne $VM.ProcessorCount) { $lane.ProcessorCount = [int]$VM.ProcessorCount }
        if ($null -ne $VM.MemoryStartup -and [double]$VM.MemoryStartup -gt 0) { $lane.MemoryGB = [math]::Round([double]$VM.MemoryStartup / 1GB, 2) }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Hyper-V lane: the VM could not be read ($($_.Exception.Message)); its identity is left empty."
    }

    try {
        $cps = @(Get-VMCheckpoint -VMName $VMName -Name $CheckpointName -ErrorAction Stop | Where-Object { $null -ne $_ })
        if ($cps.Count -ne 1) {
            Write-Verbose "Hyper-V lane: $($cps.Count) checkpoints answer to the run's checkpoint name; its identity is left empty."
        }
        else {
            $cpId = [string]$cps[0].Id
            if ($cpId -match $guid) {
                $lane.CheckpointId = $cpId
                $lane.CheckpointObjectId = $cpId
            }
            if ($cps[0].CreationTime -is [datetime]) {
                $created = $cps[0].CreationTime.ToUniversalTime()
                $lane.CheckpointCreatedUtc = $created.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
                $lane.CheckpointCreationTicks = [long]$created.Ticks
                $lane.CheckpointAgeDays = [int][math]::Floor(([datetime]::UtcNow - $created).TotalDays)
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Hyper-V lane: the checkpoint could not be read ($($_.Exception.Message)); its identity is left empty."
    }

    return $lane
}
