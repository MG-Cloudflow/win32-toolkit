function Get-Win32ToolkitParityProbeCache {
    <#
    .SYNOPSIS
        Returns the Intune-parity pre-check's stored answer for one test VM checkpoint, or $null.
    .DESCRIPTION
        Hyper-V speed-up PR 1 (D3). The pre-check restores the test VM's checkpoint, asks the guest whether a user is
        signed in (Get-Win32ToolkitGuestSignedInUser) and restores it again: about two and a half minutes. The answer
        depends only on the checkpoint, so Set-Win32ToolkitParityProbeCache keeps it in the HyperVPrecheckProbe value
        under HKCU:\Software\CloudFlow\win32-toolkit:

            v1|<ProbeVersion>|<VM Id>|<checkpoint Id>|<checkpoint creation time, UTC ticks>|<SignedIn 0/1>|<SessionCount>

        A hit needs the whole value to match one strict pattern (GUIDs and integers only, never executed) and every
        field to equal the caller's: the VM Id, the checkpoint Id and its creation ticks (a re-taken checkpoint has a
        new Id) and the probe version (ProbeVersion, raised whenever the guest probe or its reading changes). Anything
        else is a miss. Read through Get-Win32ToolkitConfigValue; never throws.
    .PARAMETER VMId
        The test VM's Id (Get-VM .Id).
    .PARAMETER CheckpointId
        The checkpoint's Id (Get-VMCheckpoint .Id).
    .PARAMETER CreationTimeUtcTicks
        The checkpoint's creation time in UTC ticks.
    .PARAMETER ProbeVersion
        The probe version of this code (default 1; equal to Set-Win32ToolkitParityProbeCache's and
        Get-Win32ToolkitCheckpointAttestation's).
    .OUTPUTS
        [pscustomobject] SignedIn [bool], SessionCount [int]; or $null.
    .EXAMPLE
        Get-Win32ToolkitParityProbeCache -VMId $lane.VMId -CheckpointId $lane.CheckpointId -CreationTimeUtcTicks $lane.CheckpointCreationTicks
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string]$VMId,

        [AllowEmptyString()]
        [string]$CheckpointId,

        [long]$CreationTimeUtcTicks,

        [ValidateRange(1, 9999)]
        [int]$ProbeVersion = 1
    )

    try {
        $raw = [string](Get-Win32ToolkitConfigValue -Name 'HyperVPrecheckProbe' -Default '')
        $guid = '[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}'
        $m = [regex]::Match($raw, "\Av1\|([1-9][0-9]{0,3})\|($guid)\|($guid)\|([0-9]{1,19})\|([01])\|([0-9]{1,2})\z")
        if (-not $m.Success) { return $null }
        $ticks = [long]0
        if (-not [long]::TryParse($m.Groups[4].Value, [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$ticks)) { return $null }
        $same = [int]$m.Groups[1].Value -eq $ProbeVersion -and
                [string]::Equals($m.Groups[2].Value, $VMId, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals($m.Groups[3].Value, $CheckpointId, [System.StringComparison]::OrdinalIgnoreCase) -and
                $CreationTimeUtcTicks -gt 0 -and $ticks -eq $CreationTimeUtcTicks
        if (-not $same) { return $null }
        return [pscustomobject]@{
            SignedIn     = ($m.Groups[5].Value -eq '1')
            SessionCount = [int]$m.Groups[6].Value
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Intune-parity pre-check cache: the stored answer could not be read ($($_.Exception.Message))."
        return $null
    }
}
