function Wait-Win32ToolkitHyperVTeardown {
    <#
    .SYNOPSIS
        Waits for this process's background restore of the test VM, keeps the clean marker it earned and releases its
        lease.
    .DESCRIPTION
        Hyper-V speed-up PR 4 (D13, D14, A1, A5, A-14, V-1, V-2). Start-Win32ToolkitHyperVBackgroundRestore records one
        background restore in $script:HyperVPendingRestore. Joining it (Receive-Job -Wait; the job's warnings and verbose
        lines are relayed here) ends it:
          * it succeeded (exactly the helper's result object): THIS session stamps the clean marker
            ($script:HyperVCleanMarker: VMName, VMId and state read now with Get-VM, CheckpointName, StampedAt = the time
            the restore returned, the lease's epoch and generation, Parked = Saved when the job left the VM Saved, else
            Running), so the next open in this process can skip its restore under the usual rules
            (New-Win32ToolkitHyperVSession). No lease, or the VM cannot be read: no marker (one extra restore next time).
          * it failed: one warning ("The background restore of '<vm>' FAILED: ... the next run restores it before
            starting"), no marker.
        Then the job is removed and its lease released (Exit-Win32ToolkitHyperVLease) - except for a pre-warm (Kind
        Prewarm), whose lease stays held until -Prewarm releases it, so the VM stays this process's from the pre-warm
        through the capture's teardown.

        Parameter sets:
          * Join (-VMName): joins the pending restore of that VM, if any (Enter-Win32ToolkitHyperVLease calls this before
            it takes a VM's lease, so every use of the VM in this process waits for its restore).
          * Owner (-ReleaseOwner): $null is a complete no-op (a command that registered no owner). The live owner's
            token joins any pending restore, releases a pre-warm hold that is still there, and clears
            $script:W32TAsyncTeardownOwner. Any other token: nothing (one verbose line).
          * Prewarm (-Prewarm): joins a pending pre-warm restore, then releases the pre-warm's lease hold (idempotent).
        Emits nothing and never throws (it runs in finally blocks; C-12).
    .PARAMETER VMName
        The VM whose pending background restore is joined.
    .PARAMETER ReleaseOwner
        The token the calling owner registered, or $null.
    .PARAMETER Prewarm
        Join the pre-warm restore (if still pending) and release its lease hold.
    .EXAMPLE
        $null = Wait-Win32ToolkitHyperVTeardown -ReleaseOwner $w32tOwner
    #>
    [CmdletBinding(DefaultParameterSetName = 'Join')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Join')]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory, ParameterSetName = 'Owner')]
        [AllowNull()]
        [Nullable[guid]]$ReleaseOwner,

        [Parameter(Mandatory, ParameterSetName = 'Prewarm')]
        [switch]$Prewarm
    )

    # Joins the pending restore: the marker on success (stamped HERE, never in the job), the warning on failure; the job
    # removed; the lease released unless it is the pre-warm's hold. Emits nothing.
    $join = {
        $p = $script:HyperVPendingRestore
        if ($null -eq $p) { return }
        $vmText = ConvertTo-Win32ToolkitSafeText -Text ([string]$p['VMName']) -MaxLength 64
        $result = $null
        $why = $null
        try {
            $res = @(Receive-Job -Job $p['Job'] -Wait -ErrorAction Stop)
            if ([string]$p['Job'].State -eq 'Failed') { $why = 'the job failed' }
            elseif ($res.Count -ne 1 -or $null -eq $res[0] -or $null -eq $res[0].PSObject.Properties['Mode']) { $why = "the job returned $($res.Count) object(s) instead of the restore's result" }
            else { $result = $res[0] }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $why = $_.Exception.Message
        }
        finally {
            # The record goes whatever happened: a job that could not be received is not joined twice.
            $script:HyperVPendingRestore = $null
            if ($null -ne $p['Job']) { Remove-Job -Job $p['Job'] -Force -ErrorAction SilentlyContinue }
        }

        if ($null -ne $why) {
            $script:HyperVCleanMarker = $null
            Write-Warning "The background restore of '$vmText' to '$(ConvertTo-Win32ToolkitSafeText -Text ([string]$p['CheckpointName']) -MaxLength 64)' FAILED: $why $([char]0x2014) the next run restores it before starting."
        }
        else {
            $lease = $p['Lease']
            $vm = $null
            try { $vm = Get-VM -Name ([string]$p['VMName']) -ErrorAction Stop }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $vm = $null
            }
            $stamped = $null
            if ($result.PSObject.Properties['CompletedAt'] -and $result.CompletedAt -is [datetime]) { $stamped = ([datetime]$result.CompletedAt).ToLocalTime() }
            if ($null -eq $lease) {
                $script:HyperVCleanMarker = $null
                Write-Verbose "Background restore of '$vmText' done: no VM lease was held, so no clean marker is kept."
            }
            elseif ($null -eq $vm -or -not $vm.Id -or $null -eq $stamped) {
                $script:HyperVCleanMarker = $null
                Write-Verbose "Background restore of '$vmText' done: the VM (or the time the restore ended) could not be read, so no clean marker is kept."
            }
            else {
                $parked = if ([string]$p['Parked'] -eq 'Saved' -and [string]$vm.State -eq 'Saved') { 'Saved' } else { 'Running' }
                $script:HyperVCleanMarker = @{ VMName = [string]$p['VMName']; VMId = [string]$vm.Id; CheckpointName = [string]$p['CheckpointName']; StampedAt = $stamped
                    LeaseEpoch = [string]$lease.Epoch; LeaseGeneration = ($lease.Generation -as [long]); Parked = $parked }
                Write-Verbose "Background restore of '$vmText' joined ($($result.Mode), the VM is $($vm.State)): clean marker kept."
            }
        }
        if ([string]$p['Kind'] -ne 'Prewarm') { $null = Exit-Win32ToolkitHyperVLease -Lease $p['Lease'] }
    }

    try {
        switch ($PSCmdlet.ParameterSetName) {
            'Join' {
                $p = $script:HyperVPendingRestore
                if ($null -ne $p -and [string]$p['VMName'] -eq $VMName) { & $join }
            }
            'Prewarm' {
                if (-not $Prewarm) { return }
                $p = $script:HyperVPendingRestore
                if ($null -ne $p -and [string]$p['Kind'] -eq 'Prewarm') { & $join }
                if ($null -ne $script:HyperVPrewarmLease) {
                    $hold = $script:HyperVPrewarmLease
                    $script:HyperVPrewarmLease = $null
                    $null = Exit-Win32ToolkitHyperVLease -Lease $hold
                    Write-Verbose 'Capture pre-warm: the test VM''s lease is released.'
                }
            }
            'Owner' {
                if ($null -eq $ReleaseOwner) { return }
                $owner = $script:W32TAsyncTeardownOwner
                if ($owner -isnot [hashtable] -or $owner['Token'] -ne $ReleaseOwner) {
                    Write-Verbose 'The async-teardown owner token is not the live one: nothing to join or release.'
                    return
                }
                try {
                    if ($null -ne $script:HyperVPendingRestore) {
                        Write-Verbose "Waiting for the background restore of the test VM before $($owner['Command']) returns..."
                        & $join
                    }
                    if ($null -ne $script:HyperVPrewarmLease) {
                        $hold = $script:HyperVPrewarmLease
                        $script:HyperVPrewarmLease = $null
                        $null = Exit-Win32ToolkitHyperVLease -Lease $hold
                    }
                }
                finally { $script:W32TAsyncTeardownOwner = $null }
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Joining the background restore failed ($($_.Exception.Message))."
    }
}
