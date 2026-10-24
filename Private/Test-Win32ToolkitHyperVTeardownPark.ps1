function Test-Win32ToolkitHyperVTeardownPark {
    <#
    .SYNOPSIS
        $true when the teardown should leave the clean test VM Saved instead of running (HyperVTeardownPark = Saved).
    .DESCRIPTION
        Hyper-V speed-up PR 4 (D9, B4, A-15). Between two test runs the restored VM normally keeps running (Hyper-V
        resumes the checkpoint's memory state), holding its memory on the host. With HKCU HyperVTeardownPark = Saved the
        teardown restore leaves it as the restore landed it (Saved: nothing runs, no host memory in use), and the next
        open in this process only starts it (New-Win32ToolkitHyperVSession, the clean marker's Parked rule).

        Parking needs HyperVRevertMode TurnOffFirst (the default): with Legacy the setting is ignored, with one verbose
        line, because parking after a plain restore would need a Save-VM, the very memory write TurnOffFirst avoids.
        Values compare without case and surrounding blanks; anything but Saved is Running. Fail-open: a setting that
        cannot be read counts as not parked. The callers pass this only for unattended runs (a watched run's console
        stays attached to a running VM).
    .OUTPUTS
        Exactly one [bool].
    .EXAMPLE
        $noStart = Test-Win32ToolkitHyperVTeardownPark
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $park = ([string](Get-Win32ToolkitConfigValue -Name 'HyperVTeardownPark' -Default 'Running')).Trim()
        if ($park -ne 'Saved') { return $false }
        $mode = ([string](Get-Win32ToolkitConfigValue -Name 'HyperVRevertMode' -Default '')).Trim()
        if ($mode -eq 'Legacy') {
            Write-Verbose 'HyperVTeardownPark is Saved, but HyperVRevertMode is Legacy: the test VM is not parked (parking needs TurnOffFirst).'
            return $false
        }
        return $true
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "HyperVTeardownPark could not be read ($($_.Exception.Message)); the test VM is not parked."
        return $false
    }
}
