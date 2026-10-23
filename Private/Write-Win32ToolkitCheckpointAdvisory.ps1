function Write-Win32ToolkitCheckpointAdvisory {
    <#
    .SYNOPSIS
        Prints a non-blocking test-VM checkpoint advisory once per process, checkpoint and kind.
    .DESCRIPTION
        Hyper-V speed-up PR 1 (A-8, D5, D34). The advisories about the test VM's checkpoint (taken with automatic
        checkpoints on, older than 35 days, nobody signed in, Defender real-time protection off, Defender exclusions,
        old or never-updated Defender signatures) would otherwise repeat on every queued run. One Write-Warning per
        "<Kind>|<Key>" per process ($script:HyperVAdvised); Clear-Win32ToolkitParityProbeCache forgets them. The key is
        the checkpoint's identity ("<VM Id>|<checkpoint Id>"). Never blocks, never throws, writes nothing to the
        output (a value here would join the [bool] of the Hyper-V run, V-1).
    .PARAMETER Kind
        AutoCheckpoints, Age, SignedIn, RealTime, Exclusions or Signatures.
    .PARAMETER Key
        The checkpoint identity the advisory is about.
    .PARAMETER Message
        The constant warning text (host values only, as safe text).
    .EXAMPLE
        Write-Win32ToolkitCheckpointAdvisory -Kind Age -Key "$vmId|$cpId" -Message $text
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AutoCheckpoints', 'Age', 'SignedIn', 'RealTime', 'Exclusions', 'Signatures')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Key,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    if ($script:HyperVAdvised -isnot [hashtable]) { $script:HyperVAdvised = @{} }
    $id = "$Kind|$Key"
    if ($script:HyperVAdvised.ContainsKey($id)) { return }
    $script:HyperVAdvised[$id] = $true
    Write-Warning $Message
}
