function Clear-Win32ToolkitParityProbeCache {
    <#
    .SYNOPSIS
        Deletes the toolkit's stored test-VM checkpoint answers (the pre-check answer and the checkpoint attestation).
    .DESCRIPTION
        Hyper-V speed-up PR 1 (D3, D34). Removes the two toolkit-written values HyperVPrecheckProbe and
        HyperVCheckpointAttestation from HKCU:\Software\CloudFlow\win32-toolkit (and nothing else), and forgets this
        process's warning dedupe ($script:HyperVAdvised) and checkpoint-setting memo ($script:HyperVCheckpointAutoSetting).
        Clear-Win32ToolkitHyperVStateCache calls it (without -MarkerOnly), so every VM-management command (provision,
        reset, resource change, repair, removal) starts the caches over. Never throws and writes nothing to the output.
    .EXAMPLE
        Clear-Win32ToolkitParityProbeCache
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    foreach ($name in 'HyperVPrecheckProbe', 'HyperVCheckpointAttestation') {
        try {
            $null = Remove-ItemProperty -LiteralPath 'HKCU:\Software\CloudFlow\win32-toolkit' -Name $name -ErrorAction Ignore
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Could not remove the stored test-VM value '$name' ($($_.Exception.Message))."
        }
    }
    $script:HyperVAdvised = $null
    $script:HyperVCheckpointAutoSetting = $null
}
