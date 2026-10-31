function Get-Win32ToolkitTestVMChoice {
    <#
    .SYNOPSIS
        Lists the Hyper-V VMs and checkpoints the menu can offer as the test VM (read-only; never changes a VM).
    .DESCRIPTION
        Menu selectors design section 4, V1, V5, V10 (knowledge-base/designs/menu-selectors.md). Reads Get-VM and
        Get-VMCheckpoint only (no other Hyper-V call, no PowerShell Direct, never a lease) and the lease state of each VM
        (Get-Win32ToolkitHyperVLeaseState). A VM is offered when:
          * exactly one VM has its name (the lease and every VM command need a unique name);
          * the name is usable as the toolkit uses it: 1 to 100 characters, no control character, no leading or trailing
            space (the pin rule of Get-Win32ToolkitHyperVTarget), and no wildcard character (* ? [ ]), because every VM
            command passes the name to -Name, which treats those as wildcards;
          * it has at least one clean checkpoint: not a dependency layer ('+deps-' in the name), not a Recovery, Planned,
            Missing or replica checkpoint, a name usable by the same rule, and unique on that VM.
        Checkpoints are listed newest first; an automatic checkpoint (Hyper-V's own, at a start) is marked. Fail open per
        VM: a VM whose checkpoints cannot be read is listed and not offered.
    .OUTPUTS
        [pscustomobject] Problem ('' or why nothing can be listed: 'NotElevated', 'NoHyperV' or a sanitized error) and
        Rows: one per VM name with Name, Id, State, Count (VMs with that name), Offered, WhyNot, Lease (the probe's
        object, or $null), Checkpoints (Name, CreatedUtc, Automatic, Offered, WhyNot; newest first).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $out = { param([string]$Problem, [object[]]$Rows) [pscustomobject]@{ Problem = $Problem; Rows = @($Rows) } }
    if (-not (Test-Win32ToolkitElevated)) { return (& $out 'NotElevated' @()) }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { return (& $out 'NoHyperV' @()) }

    $vms = @()
    try { $vms = @(Get-VM -ErrorAction Stop | Where-Object { $null -ne $_ }) }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        return (& $out "The VMs could not be read: $(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)" @())
    }

    # The pin rule (Get-Win32ToolkitHyperVTarget) plus: no space around it, no wildcard character.
    $usable = { param([string]$Name) $Name -cmatch '^[^\x00-\x1F\x7F]{1,100}\z' -and $Name -ceq $Name.Trim() -and $Name -notmatch '[\*\?\[\]]' }
    $notBase = @('Recovery', 'Planned', 'Missing', 'Replica', 'AppConsistentReplica', 'SyncedReplica')

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($vms | Group-Object -Property { [string]$_.Name } | Sort-Object -Property Name)) {
        $name = [string]$group.Name
        $vm = $group.Group[0]
        $row = [ordered]@{
            Name = $name; Id = ''; State = ''; Count = $group.Count; Offered = $false; WhyNot = ''; Lease = $null; Checkpoints = @()
        }
        if ($group.Count -gt 1) {
            $row.WhyNot = "$($group.Count) VMs have this name"
            $rows.Add([pscustomobject]$row)
            continue
        }
        $row.Id = [string]$vm.Id
        $row.State = [string]$vm.State
        $row.Lease = Get-Win32ToolkitHyperVLeaseState -VMId $row.Id
        if (-not (& $usable $name)) {
            $row.WhyNot = 'the name cannot be used (1 to 100 characters, no control or wildcard character)'
            $rows.Add([pscustomobject]$row)
            continue
        }
        try {
            $cps = @(Get-VMCheckpoint -VM $vm -ErrorAction Stop | Where-Object { $null -ne $_ })
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $row.WhyNot = 'its checkpoints could not be read'
            $rows.Add([pscustomobject]$row)
            continue
        }
        $names = @($cps | ForEach-Object { [string]$_.Name })
        $list = foreach ($cp in $cps) {
            $cpName = [string]$cp.Name
            $type = [string]$cp.SnapshotType
            $created = if ($cp.CreationTime -is [datetime]) { $cp.CreationTime.ToUniversalTime() } else { $null }
            $autoProp = $cp.PSObject.Properties['IsAutomaticCheckpoint']
            $auto = ($cpName -like 'Automatic Checkpoint*') -or ($null -ne $autoProp -and $autoProp.Value -eq $true)
            $why = ''
            if ($cpName -like '*+deps-*') { $why = 'a dependency layer' }
            elseif ($type -in $notBase) { $why = "a $type checkpoint" }
            elseif (-not (& $usable $cpName)) { $why = 'the name cannot be used' }
            elseif (@($names | Where-Object { $_ -eq $cpName }).Count -gt 1) { $why = 'two or more checkpoints have this name' }
            [pscustomobject]@{ Name = $cpName; CreatedUtc = $created; Automatic = [bool]$auto; Offered = (-not $why); WhyNot = $why }
        }
        $row.Checkpoints = @(@($list) | Sort-Object -Property @{ Expression = { if ($_.CreatedUtc) { $_.CreatedUtc } else { [datetime]::MinValue } } } -Descending)
        if (@($row.Checkpoints | Where-Object Offered).Count -gt 0) { $row.Offered = $true }
        else { $row.WhyNot = 'no clean checkpoint' }
        $rows.Add([pscustomobject]$row)
    }
    return (& $out '' $rows.ToArray())
}
