function Get-Win32ToolkitCheckpointAutoSetting {
    <#
    .SYNOPSIS
        Tells whether a test VM checkpoint was taken with Hyper-V automatic checkpoints on.
    .DESCRIPTION
        Hyper-V speed-up PR 1 (D5, B5). A checkpoint keeps the VM's AutomaticCheckpointsEnabled setting of the moment it
        was taken, and restoring it brings that setting back: with it on, Hyper-V takes an "Automatic Checkpoint" of
        the VM at every start from Off, and the faster restore of the speed-up work needs it off. This reads the
        checkpoint's own setting from WMI (root\virtualization\v2, Msvm_VirtualSystemSettingData whose InstanceID is
        'Microsoft:<checkpoint Id>', property AutomaticSnapshotsEnabled). Read-only.

        A checkpoint's settings never change (a re-take has a new Id), so a definite answer is kept for the process in
        $script:HyperVCheckpointAutoSetting (Clear-Win32ToolkitParityProbeCache forgets it). Never throws: an Id that
        is not a GUID, no instance, a value that is not a boolean, or a WMI error returns $null (unknown).
    .PARAMETER CheckpointId
        The checkpoint's Id (Get-VMCheckpoint .Id).
    .OUTPUTS
        [bool] $true / $false, or $null when unknown.
    .EXAMPLE
        if ((Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $cp.Id) -eq $true) { 'taken with automatic checkpoints on' }
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [string]$CheckpointId
    )

    try {
        $id = ([string]$CheckpointId).Trim()
        if ($id -notmatch '\A[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\z') { return $null }
        $id = $id.ToUpperInvariant()
        if ($script:HyperVCheckpointAutoSetting -isnot [hashtable]) { $script:HyperVCheckpointAutoSetting = @{} }
        if ($script:HyperVCheckpointAutoSetting.ContainsKey($id)) { return $script:HyperVCheckpointAutoSetting[$id] }
        # The Id is a validated GUID: nothing else reaches the WQL filter.
        $settings = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_VirtualSystemSettingData' -Filter "InstanceID = 'Microsoft:$id'" -ErrorAction Stop)
        if ($settings.Count -ne 1) { return $null }
        $value = $settings[0].AutomaticSnapshotsEnabled
        if ($value -isnot [bool]) { return $null }
        $script:HyperVCheckpointAutoSetting[$id] = $value
        return $value
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "The checkpoint's automatic-checkpoint setting could not be read ($($_.Exception.Message))."
        return $null
    }
}
