function Get-Win32ToolkitHyperVTarget {
    <#
    .SYNOPSIS
        Resolves the Hyper-V test VM and its base checkpoint for this PowerShell session: the one reader of both names.
    .DESCRIPTION
        Hyper-V speed-up PR 3 (D11, A-10). Every place that needs the test VM's name or its base checkpoint asks this
        resolver: the test run, the Intune-parity pre-check, the readiness check, the backend label, the TUI's test VM
        screen and the defaults of the VM commands. Precedence, per value:
          VM:         $env:W32T_HYPERV_VM          -> HKCU HyperVVMName     -> 'win32tk-golden'
          checkpoint: $env:W32T_HYPERV_CHECKPOINT  -> HKCU HyperVCheckpoint -> 'clean-base'
        An environment value pins this process (and its children) only: a lane runner or a test session can use its
        own VM while every other session keeps the registry's. A pin is trimmed and must be 1-100 characters with no
        control character; anything else throws W32T.HyperVTargetNotReady (fail closed: a pinned process never falls
        back to another VM). Pinned = the VM comes from W32T_HYPERV_VM; the VM commands then save no name, checkpoint
        or size as the user's defaults (A-10).
    .PARAMETER NoThrow
        Report an invalid pin in Problem instead of throwing (the readiness check and the backend label only: they show
        it as a reason; the run itself still throws).
    .OUTPUTS
        [pscustomobject] VMName, CheckpointName, Source and CheckpointSource ('Environment', 'Registry' or 'Default'),
        Pinned ([bool]: the VM comes from W32T_HYPERV_VM) and Problem ($null, or with -NoThrow the reason a pin is
        invalid; the invalid value's name is then $null).
    .EXAMPLE
        $target = Get-Win32ToolkitHyperVTarget
        $vm = $target.VMName; $cp = $target.CheckpointName
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$NoThrow
    )

    $problem = $null
    $pick = {
        param([string]$EnvName, [string]$ConfigName, [string]$Default, [string]$What)
        $raw = [System.Environment]::GetEnvironmentVariable($EnvName)
        if ($null -ne $raw) {
            $value = $raw.Trim()
            # 1-100 characters, none of them a control character (\z: no trailing newline either).
            if ($value -cmatch '^[^\x00-\x1F\x7F]{1,100}\z') { return @{ Value = $value; Source = 'Environment'; Problem = $null } }
            return @{ Value = $null; Source = 'Environment'; Problem = "$EnvName is not a valid $What name (1 to 100 characters, no control character)" }
        }
        $stored = [string](Get-Win32ToolkitConfigValue -Name $ConfigName -Default '')
        if (-not [string]::IsNullOrWhiteSpace($stored)) { return @{ Value = $stored; Source = 'Registry'; Problem = $null } }
        @{ Value = $Default; Source = 'Default'; Problem = $null }
    }
    $vm = & $pick 'W32T_HYPERV_VM' 'HyperVVMName' 'win32tk-golden' 'VM'
    $cp = & $pick 'W32T_HYPERV_CHECKPOINT' 'HyperVCheckpoint' 'clean-base' 'checkpoint'
    $problem = @(@($vm.Problem, $cp.Problem) | Where-Object { $_ }) -join '; '
    if ($problem -and -not $NoThrow) {
        $target = if ($vm.Problem) { 'W32T_HYPERV_VM' } else { 'W32T_HYPERV_CHECKPOINT' }
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("$problem. Nothing was started. Fix the variable, or remove it to use the registry's test VM."),
            'W32T.HyperVTargetNotReady', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $target)
    }

    [pscustomobject]@{
        VMName           = $vm.Value
        CheckpointName   = $cp.Value
        Source           = $vm.Source
        CheckpointSource = $cp.Source
        Pinned           = ($vm.Source -eq 'Environment')
        Problem          = $(if ($problem) { $problem } else { $null })
    }
}
