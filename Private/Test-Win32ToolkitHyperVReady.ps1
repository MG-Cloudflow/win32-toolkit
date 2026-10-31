function Test-Win32ToolkitHyperVReady {
    <#
    .SYNOPSIS
        Returns the list of reasons the Hyper-V test backend is NOT usable (empty array = ready).
    .DESCRIPTION
        Single source of truth for "can we actually use the Hyper-V backend right now?", consumed by
        Get-Win32ToolkitTestBackend (to fall back to Sandbox) and by the prerequisite health screen.
        Checks: host elevation (PowerShell Direct needs admin), the Hyper-V PowerShell module, the
        session's VM + its clean checkpoint (Get-Win32ToolkitHyperVTarget: a W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT
        pin first, then the registry; an invalid pin is a reason), and a stored guest credential. Each missing item
        yields a short human-readable reason string. See knowledge-base/designs/hyperv-backend-plan.md.
    .OUTPUTS
        [string[]] — reasons the backend is not ready; an empty array means it IS ready.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        # Bypass the memoized verdict (used right after an action that could have changed readiness).
        [switch]$Force
    )

    # The session's VM and checkpoint (speed-up PR 3, D11): a W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT pin first. An invalid
    # pin is a reason here (the health screen and the labels show it); the run itself throws (Get-Win32ToolkitTestBackend).
    $target = Get-Win32ToolkitHyperVTarget -NoThrow
    $key = "$($target.VMName)|$($target.CheckpointName)"

    # Memoize for 60 s: a single pipeline start calls this 3-5 times (backend resolution, health screen,
    # per-scenario checks) and each probe costs a module scan + Get-VM. Any VM-management cmdlet clears
    # the cache via Clear-Win32ToolkitHyperVStateCache; the short TTL bounds staleness from actions this
    # process cannot see (another console deleting the VM), and the worst case is a 60 s-old verdict.
    # The memo is for one VM and checkpoint only (speed-up PR 3): another pin is probed afresh.
    if (-not $Force -and $script:HyperVReadyCache -and $script:HyperVReadyCache.Key -eq $key -and -not $target.Problem -and
        (((Get-Date) - $script:HyperVReadyCache.At).TotalSeconds -lt 60)) {
        return $script:HyperVReadyCache.Reasons
    }

    $missing = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Win32ToolkitElevated)) {
        $missing.Add('host session is not elevated (PowerShell Direct needs an Administrator)')
    }

    if ($target.Problem) {
        $missing.Add($target.Problem)
    }
    elseif (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        # Without the module we cannot check the VM/checkpoint either.
        $missing.Add('Hyper-V PowerShell module is not installed')
    }
    else {
        $vmName     = $target.VMName
        $checkpoint = $target.CheckpointName

        # Ignore, not SilentlyContinue: a missing VM or checkpoint is an answer here (a reason below), and SilentlyContinue
        # would still leave the cmdlet's 'not found' record in $Error and in the caller's -ErrorVariable, next to the
        # W32T.HyperVTargetNotReady a pinned run then throws (live V3 round 2).
        $vm = Get-VM -Name $vmName -ErrorAction Ignore
        if (-not $vm) {
            $missing.Add("VM '$vmName' not found")
        }
        elseif (-not (Get-VMCheckpoint -VMName $vmName -Name $checkpoint -ErrorAction Ignore)) {
            $missing.Add("checkpoint '$checkpoint' not found on VM '$vmName'")
        }
    }

    if (-not (Get-Win32ToolkitGuestCredential)) {
        $missing.Add('guest credential is not configured')
    }

    $script:HyperVReadyCache = @{ Reasons = $missing.ToArray(); At = Get-Date; Key = $key }

    # No unary comma: callers wrap in @(), so returning the bare array lets an EMPTY result surface as
    # zero elements (ready). `, $arr` would wrap even an empty array into a 1-element array (never ready).
    return $missing.ToArray()
}
