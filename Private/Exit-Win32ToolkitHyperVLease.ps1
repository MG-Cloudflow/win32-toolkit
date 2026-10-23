function Exit-Win32ToolkitHyperVLease {
    <#
    .SYNOPSIS
        Releases a lease taken with Enter-Win32ToolkitHyperVLease.
    .DESCRIPTION
        Hyper-V speed-up PR 3 (D10). A nested lease lowers the count of this process's hold; the outermost release
        closes the lock file, so another process can take it (the file itself stays, with its generation). Idempotent
        (a lease released twice, or $null, does nothing) and never throws: it runs in finally blocks after the VM work.
        Emits nothing (C-12).
    .PARAMETER Lease
        The object Enter-Win32ToolkitHyperVLease returned, or $null.
    .EXAMPLE
        $null = Exit-Win32ToolkitHyperVLease -Lease $lease
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        [object]$Lease
    )

    if ($null -eq $Lease) { return }
    try {
        if ($Lease.Released -eq $true) { return }
        $Lease.Released = $true
        if ($null -eq $script:HyperVLeases) { return }
        $held = $script:HyperVLeases[[string]$Lease.Path]
        if ($null -eq $held) { return }
        $held['Count'] = [int]$held['Count'] - 1
        if ($held['Count'] -le 0) {
            $script:HyperVLeases.Remove([string]$Lease.Path)
            $held['Stream'].Dispose()
            Write-Verbose "Lease of '$($Lease.Name)' released (generation $($held['Generation']))."
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "The lease of '$($Lease.Name)' could not be released cleanly ($($_.Exception.Message))."
    }
}
