function Get-Win32ToolkitCheckpointAttestation {
    <#
    .SYNOPSIS
        Returns the sign-in and Defender state of the test VM's checkpoint, checked once per checkpoint.
    .DESCRIPTION
        Hyper-V speed-up PR 1 (D34, A-4, V-9, V-10, V-11). What a Hyper-V test proves depends on the checkpoint it
        restores: a user signed in (PSADT shows its dialogs to one), Defender real-time protection on, no Defender
        exclusions (installs are scanned as on a device) and current signatures. The answer is kept in the
        HyperVCheckpointAttestation value under HKCU:\Software\CloudFlow\win32-toolkit:

            v1|<AttestVersion>|<ProbeVersion>|<VM Id>|<checkpoint Id>|<creation ticks>|<SignedIn 0/1>|<RealTime 0/1>|<ExclusionCount 0-999>|<SignatureAgeDays 0-9998>

        A hit needs one strict pattern and every identity and BOTH versions equal to this code's (the cached SignedIn
        comes from the sign-in probe, so a new ProbeVersion re-attests too); it returns FromCache $true with no guest
        call. On a miss, and only with -AllowLive and a session, it asks the guest: SignedIn from -SignedInAnswer (the
        pre-check's) or Get-Win32ToolkitGuestSignedInUser, and the Defender state from ONE fixed, read-only Windows
        PowerShell 5.1 scriptblock (no -ArgumentList, no host value, every variable $w32t*).

        Fail-open, never throws: an unreadable sign-in answer, a hidden ('N/A: Must be an administrator') or partial
        Defender answer, or a guest error returns $null (no store, no advisory). A signature age of 9999 days or more
        (Defender reports 65535 when the signatures were never updated) returns the object with SignatureAgeDays $null
        and stores nothing. A complete answer is stored only with -AllowStore and when no VM console is attached right
        before the write (Test-Win32ToolkitVMConnectOpen, V-10).
    .PARAMETER Session
        An open PowerShell Direct session to the test VM (needed for a live answer only).
    .PARAMETER VMName
        The test VM's name.
    .PARAMETER CheckpointName
        The checkpoint the run restored.
    .PARAMETER VMId
        The test VM's Id.
    .PARAMETER CheckpointId
        The checkpoint's Id.
    .PARAMETER CreationTimeUtcTicks
        The checkpoint's creation time in UTC ticks.
    .PARAMETER AllowLive
        Ask the guest on a miss (the caller's open restored the checkpoint and landed warm, and the run is unattended).
    .PARAMETER AllowStore
        Store a complete live answer (the caller saw no VM console after its open).
    .PARAMETER SignedInAnswer
        The Get-Win32ToolkitGuestSignedInUser answer the caller already has (the pre-check's); saves one guest call.
    .PARAMETER AttestVersion
        The attestation version of this code (default 1).
    .PARAMETER ProbeVersion
        The sign-in probe version of this code (default 1; equal to Get-/Set-Win32ToolkitParityProbeCache's).
    .OUTPUTS
        [pscustomobject] SignedIn, DefenderRealTime, DefenderExclusionCount, SignatureAgeDays (int or $null), FromCache;
        or $null.
    .EXAMPLE
        $lane.Attestation = Get-Win32ToolkitCheckpointAttestation -Session $s -VMName $vm -CheckpointName $cp -VMId $id -CheckpointId $cpId -CreationTimeUtcTicks $t -AllowLive
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CheckpointName,

        [AllowEmptyString()]
        [string]$VMId,

        [AllowEmptyString()]
        [string]$CheckpointId,

        [long]$CreationTimeUtcTicks,

        [switch]$AllowLive,

        [switch]$AllowStore,

        [object]$SignedInAnswer,

        [ValidateRange(1, 9999)]
        [int]$AttestVersion = 1,

        [ValidateRange(1, 9999)]
        [int]$ProbeVersion = 1
    )

    $guid = '[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}'
    $identityKnown = $VMId -match "\A$guid\z" -and $CheckpointId -match "\A$guid\z" -and $CreationTimeUtcTicks -gt 0

    # 1. The stored answer for this checkpoint.
    if ($identityKnown) {
        try {
            $raw = [string](Get-Win32ToolkitConfigValue -Name 'HyperVCheckpointAttestation' -Default '')
            $m = [regex]::Match($raw, "\Av1\|([1-9][0-9]{0,3})\|([1-9][0-9]{0,3})\|($guid)\|($guid)\|([0-9]{1,19})\|([01])\|([01])\|([0-9]{1,3})\|([0-9]{1,4})\z")
            $ticks = [long]0
            if ($m.Success -and [long]::TryParse($m.Groups[5].Value, [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$ticks) -and
                [int]$m.Groups[1].Value -eq $AttestVersion -and [int]$m.Groups[2].Value -eq $ProbeVersion -and
                [string]::Equals($m.Groups[3].Value, $VMId, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals($m.Groups[4].Value, $CheckpointId, [System.StringComparison]::OrdinalIgnoreCase) -and
                $ticks -eq $CreationTimeUtcTicks -and [int]$m.Groups[9].Value -le 9998) {
                return [pscustomobject]@{
                    SignedIn               = ($m.Groups[6].Value -eq '1')
                    DefenderRealTime       = ($m.Groups[7].Value -eq '1')
                    DefenderExclusionCount = [int]$m.Groups[8].Value
                    SignatureAgeDays       = [int]$m.Groups[9].Value
                    FromCache              = $true
                }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Checkpoint attestation: the stored answer could not be read ($($_.Exception.Message))."
        }
    }
    if (-not $AllowLive -or $null -eq $Session) { return $null }

    # 2. A live answer: the sign-in state, then the Defender state (one fixed, read-only 5.1 scriptblock, C-6).
    try {
        Write-Verbose "Checkpoint attestation: asking the guest about checkpoint '$(ConvertTo-Win32ToolkitSafeText -Text $CheckpointName -MaxLength 64)' of '$(ConvertTo-Win32ToolkitSafeText -Text $VMName -MaxLength 64)'."
        $signed = $SignedInAnswer
        if ($null -eq $signed) { $signed = Get-Win32ToolkitGuestSignedInUser -Session $Session }
        if ($null -eq $signed -or -not $signed.PSObject.Properties['Checked'] -or $signed.Checked -ne $true -or $signed.SignedIn -isnot [bool]) {
            Write-Verbose 'Checkpoint attestation: the sign-in state could not be read; no attestation for this run.'
            return $null
        }
        $answer = @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                $w32tStatus = Get-MpComputerStatus
                $w32tPref = Get-MpPreference
                $w32tList = @(@($w32tPref.ExclusionPath) + @($w32tPref.ExclusionProcess) + @($w32tPref.ExclusionExtension) | Where-Object { $_ })
                $w32tHidden = @($w32tList | Where-Object { ([string]$_) -like 'N/A*' }).Count -gt 0
                [pscustomobject]@{ RealTime = [bool]$w32tStatus.RealTimeProtectionEnabled; Exclusions = $w32tList.Count; Hidden = $w32tHidden; SignatureAgeDays = [int]$w32tStatus.AntivirusSignatureAge }
            })
        $answer = @($answer | Where-Object { $null -ne $_ })
        $names = 'RealTime', 'Exclusions', 'Hidden', 'SignatureAgeDays'
        if ($answer.Count -ne 1 -or @($names | Where-Object { -not $answer[0].PSObject.Properties[$_] }).Count -gt 0) {
            Write-Verbose 'Checkpoint attestation: the Defender answer was missing or incomplete; no attestation for this run.'
            return $null
        }
        $d = $answer[0]
        $count = 0; $age = 0
        if ($d.Hidden -ne $false -or $d.RealTime -isnot [bool] -or -not [int]::TryParse([string]$d.Exclusions, [ref]$count) -or $count -lt 0 -or
            -not [int]::TryParse([string]$d.SignatureAgeDays, [ref]$age) -or $age -lt 0) {
            Write-Verbose 'Checkpoint attestation: the Defender state is hidden or unreadable in the guest; no attestation for this run.'
            return $null
        }
        $known = $age -lt 9999
        $result = [pscustomobject]@{
            SignedIn               = [bool]$signed.SignedIn
            DefenderRealTime       = [bool]$d.RealTime
            DefenderExclusionCount = $count
            SignatureAgeDays       = $(if ($known) { $age } else { $null })
            FromCache              = $false
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Checkpoint attestation: the guest could not be asked ($($_.Exception.Message)); no attestation for this run."
        return $null
    }

    # 3. Store a complete answer (a known signature age, at most 999 exclusions) when allowed and no console is attached now.
    if ($AllowStore -and $identityKnown -and $known -and $count -le 999) {
        try {
            $vmcAtStore = Test-Win32ToolkitVMConnectOpen -VMName $VMName -VMId $VMId
            if (-not $vmcAtStore) {
                $inv = [System.Globalization.CultureInfo]::InvariantCulture
                $value = 'v1|' + $AttestVersion.ToString($inv) + '|' + $ProbeVersion.ToString($inv) + '|' + $VMId + '|' + $CheckpointId + '|' +
                         $CreationTimeUtcTicks.ToString($inv) + '|' + $(if ($result.SignedIn) { '1' } else { '0' }) + '|' + $(if ($result.DefenderRealTime) { '1' } else { '0' }) + '|' +
                         $count.ToString($inv) + '|' + $age.ToString($inv)
                $writeWarnings = $null
                $null = Set-Win32ToolkitConfigValue -Name 'HyperVCheckpointAttestation' -Value $value -WarningAction SilentlyContinue -WarningVariable writeWarnings
                if (@($writeWarnings).Count -gt 0) { Write-Verbose "Checkpoint attestation: the answer was not stored ($(@($writeWarnings)[0]))." }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Checkpoint attestation: the answer was not stored ($($_.Exception.Message))."
        }
    }
    return $result
}
