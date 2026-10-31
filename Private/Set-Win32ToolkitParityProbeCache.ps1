function Set-Win32ToolkitParityProbeCache {
    <#
    .SYNOPSIS
        Stores the Intune-parity pre-check's answer for one test VM checkpoint (HyperVPrecheckProbe).
    .DESCRIPTION
        Hyper-V speed-up PR 1 (D3): the writer of the value Get-Win32ToolkitParityProbeCache reads, in its format

            v1|<ProbeVersion>|<VM Id>|<checkpoint Id>|<checkpoint creation time, UTC ticks>|<SignedIn 0/1>|<SessionCount>

        One value: a second VM or checkpoint overwrites it. The caller (Invoke-Win32ToolkitParityPrecheck) decides when
        an answer may be stored: a complete answer, from an open that restored the checkpoint and landed warm, with no
        VM console attached. Identities that are not GUIDs, or no creation time, store nothing. Written through
        Set-Win32ToolkitConfigValue; a failed write is one verbose line. Never throws and writes nothing to the output.
    .PARAMETER VMId
        The test VM's Id.
    .PARAMETER CheckpointId
        The checkpoint's Id.
    .PARAMETER CreationTimeUtcTicks
        The checkpoint's creation time in UTC ticks.
    .PARAMETER SignedIn
        The probe's answer: a user is signed in.
    .PARAMETER SessionCount
        The probe's session count (0-99).
    .PARAMETER ProbeVersion
        The probe version of this code (default 1; equal to Get-Win32ToolkitParityProbeCache's).
    .EXAMPLE
        Set-Win32ToolkitParityProbeCache -VMId $id -CheckpointId $cp -CreationTimeUtcTicks $ticks -SignedIn $true -SessionCount 1
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A toolkit-written cache value; callers decide when to store it.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowEmptyString()]
        [string]$VMId,

        [AllowEmptyString()]
        [string]$CheckpointId,

        [long]$CreationTimeUtcTicks,

        [bool]$SignedIn,

        [ValidateRange(0, 99)]
        [int]$SessionCount,

        [ValidateRange(1, 9999)]
        [int]$ProbeVersion = 1
    )

    try {
        $guid = '\A[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\z'
        if ($VMId -notmatch $guid -or $CheckpointId -notmatch $guid -or $CreationTimeUtcTicks -le 0) {
            Write-Verbose 'Intune-parity pre-check cache: the VM or checkpoint identity is not known; nothing is stored.'
            return
        }
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $value = 'v1|' + $ProbeVersion.ToString($inv) + '|' + $VMId + '|' + $CheckpointId + '|' + $CreationTimeUtcTicks.ToString($inv) + '|' +
                 $(if ($SignedIn) { '1' } else { '0' }) + '|' + $SessionCount.ToString($inv)
        $writeWarnings = $null
        $null = Set-Win32ToolkitConfigValue -Name 'HyperVPrecheckProbe' -Value $value -WarningAction SilentlyContinue -WarningVariable writeWarnings
        if (@($writeWarnings).Count -gt 0) { Write-Verbose "Intune-parity pre-check cache: the answer was not stored ($(@($writeWarnings)[0]))." }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Intune-parity pre-check cache: the answer was not stored ($($_.Exception.Message))."
    }
}
