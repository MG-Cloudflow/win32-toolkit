function Start-Win32ToolkitHyperVPrewarm {
    <#
    .SYNOPSIS
        Starts restoring the Hyper-V test VM in the background at the start of Invoke-Win32Toolkit, so the documentation
        capture finds it clean (HyperVCapturePrewarm).
    .DESCRIPTION
        Hyper-V speed-up PR 4 (D14, A5, A-13). The documentation capture of Invoke-Win32Toolkit opens the test VM after
        the winget search, the download and the configuration, and its open restores the checkpoint first. With HKCU
        HyperVCapturePrewarm = On (anything else = Off, the default) and the Hyper-V test backend in effect
        (Get-Win32ToolkitTestBackend -NoPinThrow), this takes the VM's lease (Enter-Win32ToolkitHyperVLease, purpose
        'capture pre-warm'; it waits like any other user of the VM and a W32T lease error is thrown) and starts the
        restore in a background thread job (Start-Win32ToolkitHyperVBackgroundRestore -Kind Prewarm, never -NoStart: the
        capture follows, so the VM is started whatever HyperVTeardownPark says; spec 7.3). The lease stays held
        ($script:HyperVPrewarmLease) until
        Wait-Win32ToolkitHyperVTeardown -Prewarm releases it: right after the capture (Invoke-Win32ToolkitFinalize), or
        in Invoke-Win32Toolkit's finally when the run stops earlier. The capture's own lease joins the restore, which
        stamps the clean marker, so its open only starts or keeps the VM (the marker's usual rules, among them 10 minutes).

        Nothing happens when the setting is Off, a pre-warm is already held, there are no thread jobs, the backend is not
        HyperV, or HyperVDepsCheckpoint is On (the capture may restore a project's own dependency checkpoint instead).
        Any other problem: one verbose line, the lease released, nothing started. Emits nothing.
    .EXAMPLE
        $null = Start-Win32ToolkitHyperVPrewarm
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'internal helper behind an opt-in setting; the restore is the same one the capture would run')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $on = $false
    try { $on = ([string](Get-Win32ToolkitConfigValue -Name 'HyperVCapturePrewarm' -Default 'Off')).Trim() -eq 'On' }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "HyperVCapturePrewarm could not be read ($($_.Exception.Message)); no capture pre-warm."
        $on = $false
    }
    if (-not $on) { return }
    if ($null -ne $script:HyperVPrewarmLease) {
        Write-Verbose 'Capture pre-warm: one is already held in this session.'
        return
    }
    if (-not (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Capture pre-warm: Start-ThreadJob is not available; the capture restores the test VM itself.'
        return
    }

    $lease = $null
    try {
        if (([string](Get-Win32ToolkitConfigValue -Name 'HyperVDepsCheckpoint' -Default 'Off')).Trim() -eq 'On') {
            Write-Verbose 'Capture pre-warm: HyperVDepsCheckpoint is On (the capture may restore a dependency checkpoint); no pre-warm.'
            return
        }
        $backend = [string](Get-Win32ToolkitTestBackend -NoPinThrow -WarningAction SilentlyContinue)
        if ($backend -ne 'HyperV') {
            Write-Verbose "Capture pre-warm: the test backend is $backend; nothing to restore."
            return
        }
        $target = Get-Win32ToolkitHyperVTarget
        $lease = Enter-Win32ToolkitHyperVLease -VMName $target.VMName -Purpose 'capture pre-warm'
        $started = Start-Win32ToolkitHyperVBackgroundRestore -VMName $target.VMName -CheckpointName $target.CheckpointName -Lease $lease -Kind Prewarm
        if ($started -is [bool] -and $started) {
            $script:HyperVPrewarmLease = $lease
            $lease = $null
            Write-Verbose "Capture pre-warm: restoring '$(ConvertTo-Win32ToolkitSafeText -Text $target.VMName -MaxLength 64)' in the background while the pipeline goes on."
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Capture pre-warm skipped ($($_.Exception.Message))."
    }
    finally {
        # A lease not handed to a pre-warm (no job, an error) is released at once.
        if ($null -ne $lease) { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
    }
}
