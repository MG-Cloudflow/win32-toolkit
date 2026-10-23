function Remove-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Tears down the Hyper-V test VM (stop, remove checkpoints + VM, optionally delete the VHDX).
    .DESCRIPTION
        HOST-ONLY cleanup. Turns the VM off, removes all its checkpoints and the VM config, and — with
        -RemoveVhdx — deletes its virtual disks. Each step is best-effort so partial state still cleans.

        The removal holds the test VM's lease, the lock every win32-toolkit process takes before it changes the VM:
        while another PowerShell session uses the VM it waits, up to HyperVLeaseWaitMinutes (default 60), and then
        stops with the error W32T.HyperVLeaseTimeout before anything is removed.
    .PARAMETER Name
        VM name (default: the session's test VM: W32T_HYPERV_VM, else the stored HyperVVMName, else 'win32tk-golden').
    .PARAMETER RemoveVhdx
        Also delete the VM's VHDX file(s).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name = ((Get-Win32ToolkitHyperVTarget).VMName),
        [switch]$RemoveVhdx
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warning "VM '$Name' not found — nothing to remove."
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, "Stop + remove VM$(if ($RemoveVhdx) { ' + delete VHDX' })")) {
        # One process at a time on the VM (speed-up PR 3, D10): never remove it under a running test.
        $lease = Enter-Win32ToolkitHyperVLease -VMName $Name -VMId ([string]$vm.Id) -Purpose 'removal'
        try {
            # Invalidate the process-local clean marker / readiness cache before mutating VM state.
            Clear-Win32ToolkitHyperVStateCache
            $vhds = @($vm.HardDrives.Path)
            Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
            Get-VMCheckpoint -VMName $Name -ErrorAction SilentlyContinue | Remove-VMCheckpoint -ErrorAction SilentlyContinue
            Remove-VM -Name $Name -Force -ErrorAction SilentlyContinue
            if ($RemoveVhdx) {
                foreach ($path in $vhds) {
                    if ($path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
                }
            }
            Write-Host "✓ Removed VM '$Name'." -ForegroundColor Green
        }
        finally { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
    }
}
