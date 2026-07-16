function Remove-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Tears down the Hyper-V test VM (stop, remove checkpoints + VM, optionally delete the VHDX).
    .DESCRIPTION
        HOST-ONLY cleanup. Turns the VM off, removes all its checkpoints and the VM config, and — with
        -RemoveVhdx — deletes its virtual disks. Each step is best-effort so partial state still cleans.
    .PARAMETER Name
        VM name (default: the stored HyperVVMName, else 'win32tk-golden').
    .PARAMETER RemoveVhdx
        Also delete the VM's VHDX file(s).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name = (Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden'),
        [switch]$RemoveVhdx
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warning "VM '$Name' not found — nothing to remove."
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, "Stop + remove VM$(if ($RemoveVhdx) { ' + delete VHDX' })")) {
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
}
