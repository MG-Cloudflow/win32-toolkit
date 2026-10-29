function Set-Win32ToolkitHyperVTarget {
    <#
    .SYNOPSIS
        Saves the test VM and its checkpoint (HyperVVMName, HyperVCheckpoint) after checking them; never touches a VM.
    .DESCRIPTION
        Menu selectors design V4-V6, V11 (knowledge-base/designs/menu-selectors.md). The menu's test VM screen saves its
        choice here:
          * this process's own background work first: a pending background restore is joined
            (Wait-Win32ToolkitHyperVTeardown -VMName, so the old VM is left clean and its lease released) and a pre-warm
            hold is released (-Prewarm); if this process still holds any VM lease after that, the change is refused;
          * both names must pass the rule of Get-Win32ToolkitTestVMChoice (1 to 100 characters, no control or wildcard
            character, no space around), and a fresh read right before the write must find exactly one VM with that name
            and exactly one checkpoint with that name on it, not a dependency layer;
          * both values are written together (-ErrorAction Stop: a blocked write is a warning), then read back;
            -Default clears both (the defaults win32tk-golden / clean-base);
          * Clear-Win32ToolkitHyperVStateCache -MarkerOnly: the next run restores the checkpoint.
        Read-only on Hyper-V: Get-VM and Get-VMCheckpoint only, never a lease. W32T_HYPERV_VM and W32T_HYPERV_CHECKPOINT
        are never set or cleared: a window that pins them keeps its pin (the screen says so). A refused change throws
        W32T.HyperVTargetRefused and writes nothing.
    .PARAMETER VMName
        The VM, as Get-Win32ToolkitTestVMChoice listed it.
    .PARAMETER CheckpointName
        Its checkpoint, as Get-Win32ToolkitTestVMChoice listed it.
    .PARAMETER Default
        Clear both values instead.
    .OUTPUTS
        [pscustomobject] VMName and CheckpointName (the values read back; '' = not set, the default), Ok ([bool] they are
        what was asked), Target (Get-Win32ToolkitHyperVTarget -NoThrow: what this window uses now).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Target')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Target')]
        [AllowEmptyString()]
        [string]$VMName,

        [Parameter(Mandatory, ParameterSetName = 'Target')]
        [AllowEmptyString()]
        [string]$CheckpointName,

        [Parameter(Mandatory, ParameterSetName = 'Default')]
        [switch]$Default
    )

    $refuse = {
        param([string]$Why)
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("The test VM was not changed: $Why"),
            'W32T.HyperVTargetRefused', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    }

    # V6: this process's own background restore or pre-warm first.
    if ($null -ne $script:HyperVPendingRestore) {
        $pendingVm = [string]$script:HyperVPendingRestore['VMName']
        if ($pendingVm) {
            Write-Host "Finishing the restore of $(ConvertTo-Win32ToolkitSafeText -Text $pendingVm -MaxLength 64) first..." -ForegroundColor DarkGray
            $null = Wait-Win32ToolkitHyperVTeardown -VMName $pendingVm
        }
    }
    if ($null -ne $script:HyperVPrewarmLease) { $null = Wait-Win32ToolkitHyperVTeardown -Prewarm }
    if ($null -ne $script:HyperVLeases) {
        $held = @($script:HyperVLeases.Values | Where-Object { $null -ne $_ -and $_['VMName'] })
        if ($held.Count -gt 0) { & $refuse "this window is still using the test VM '$(ConvertTo-Win32ToolkitSafeText -Text ([string]$held[0]['VMName']) -MaxLength 64)'. Try again when it is done." }
    }

    if ($Default) {
        $wantVm = ''; $wantCp = ''
    }
    else {
        $wantVm = $VMName; $wantCp = $CheckpointName
        $usable = { param([string]$Name) $Name -cmatch '^[^\x00-\x1F\x7F]{1,100}\z' -and $Name -ceq $Name.Trim() -and $Name -notmatch '[\*\?\[\]]' }
        $vmText = ConvertTo-Win32ToolkitSafeText -Text $wantVm -MaxLength 64
        $cpText = ConvertTo-Win32ToolkitSafeText -Text $wantCp -MaxLength 64
        if (-not (& $usable $wantVm)) { & $refuse "the VM name '$vmText' cannot be used (1 to 100 characters, no control or wildcard character)." }
        if (-not (& $usable $wantCp) -or $wantCp -like '*+deps-*') { & $refuse "the checkpoint name '$cpText' cannot be used." }
        # A fresh read right before the write (V5).
        $vms = @()
        try { $vms = @(Get-VM -Name $wantVm -ErrorAction Stop | Where-Object { $null -ne $_ }) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $vms = @()
        }
        if ($vms.Count -ne 1) { & $refuse "$($vms.Count) VMs named '$vmText' were found (exactly one is needed)." }
        $cps = @()
        try { $cps = @(Get-VMCheckpoint -VM $vms[0] -Name $wantCp -ErrorAction Stop | Where-Object { $null -ne $_ }) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $cps = @()
        }
        if ($cps.Count -ne 1) { & $refuse "VM '$vmText' has $($cps.Count) checkpoints named '$cpText' (exactly one is needed)." }
    }

    Set-Win32ToolkitConfigValue -Name 'HyperVVMName' -Value $wantVm -ErrorAction Stop
    Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Value $wantCp -ErrorAction Stop
    Clear-Win32ToolkitHyperVStateCache -MarkerOnly

    $savedVm = [string](Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default '')
    $savedCp = [string](Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default '')
    [pscustomobject]@{
        VMName         = $savedVm
        CheckpointName = $savedCp
        Ok             = ($savedVm -ceq $wantVm -and $savedCp -ceq $wantCp)
        Target         = (Get-Win32ToolkitHyperVTarget -NoThrow)
    }
}
