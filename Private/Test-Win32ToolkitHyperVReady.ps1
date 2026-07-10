function Test-Win32ToolkitHyperVReady {
    <#
    .SYNOPSIS
        Returns the list of reasons the Hyper-V test backend is NOT usable (empty array = ready).
    .DESCRIPTION
        Single source of truth for "can we actually use the Hyper-V backend right now?", consumed by
        Get-Win32ToolkitTestBackend (to fall back to Sandbox) and by the prerequisite health screen.
        Checks: host elevation (PowerShell Direct needs admin), the Hyper-V PowerShell module, the
        configured VM + its clean checkpoint, and a stored guest credential. Each missing item yields a
        short human-readable reason string. See knowledge-base/designs/hyperv-backend-plan.md.
    .OUTPUTS
        [string[]] — reasons the backend is not ready; an empty array means it IS ready.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $missing = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Win32ToolkitElevated)) {
        $missing.Add('host session is not elevated (PowerShell Direct needs an Administrator)')
    }

    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        # Without the module we cannot check the VM/checkpoint either.
        $missing.Add('Hyper-V PowerShell module is not installed')
    }
    else {
        $vmName     = Get-Win32ToolkitConfigValue -Name 'HyperVVMName'     -Default 'win32tk-golden'
        $checkpoint = Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base'

        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            $missing.Add("VM '$vmName' not found")
        }
        elseif (-not (Get-VMCheckpoint -VMName $vmName -Name $checkpoint -ErrorAction SilentlyContinue)) {
            $missing.Add("checkpoint '$checkpoint' not found on VM '$vmName'")
        }
    }

    if (-not (Get-Win32ToolkitGuestCredential)) {
        $missing.Add('guest credential is not configured')
    }

    # No unary comma: callers wrap in @(), so returning the bare array lets an EMPTY result surface as
    # zero elements (ready). `, $arr` would wrap even an empty array into a 1-element array (never ready).
    return $missing.ToArray()
}
