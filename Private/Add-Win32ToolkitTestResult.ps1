function Add-Win32ToolkitTestResult {
    <#
    .SYNOPSIS
        Appends one test-outcome entry to a project's Documentation\TestResults.json.
    .DESCRIPTION
        TestResults.json is the shared persistence file that records every install/update test run
        against a project (Sandbox or Hyper-V). The customer documentation reads it back to list
        "all the tests we did". Entries are appended newest-last.

        Each entry has the shape:
            { Scenario, Backend, Mode, TimestampUtc, Verdict, Assertions[], Notes [, Baseline] [, OldArpSurvivors[]] [, LogFolder] [, NotRun] [, Timing] [, Lane] }
        where Assertions is an array of @{ Name; Result } (Result in PASS|FAIL|SKIP). Baseline (the Update
        test's old-version variant: Version, Mode, Origin, RequestedInstallerType, InstallerType, Family,
        UsedFallback, FallbackReason, RequestedScope, Scope, ScopeRelaxed, Unavailable, Locale, Source,
        ProjectName) and OldArpSurvivors (@{ DisplayName; Key; KeyLeaf; View }) are written only when supplied,
        so entries without them keep the old shape (installer-identity PR 1, spec 2.11). LogFolder (the run's
        own log folder, Sandbox\Logs\Runs\<run>, relative to the project) is likewise written only when supplied.
        NotRun marks a test that was NOT started (Verdict Inconclusive, no assertions): the Intune-parity
        pre-check found that an unattended Hyper-V run would only wait on a PSADT 4.1 dialog (Code
        PARITY-DIALOG-WAIT, Shape, ProcessesToClose, Welcome, SignedInSessions). Such a record is listed but
        never judged, and the customer documentation shows it as 'Not run (Intune-parity pre-check)'.

        The file is written as a JSON ARRAY (even for a single entry) in BOM-less UTF-8, matching
        Set-Win32ToolkitAppConfig. A corrupt/unparseable existing file is never fatal: it is
        replaced with a fresh single-entry array and a warning is emitted.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1).
        The Documentation subfolder is created if it does not exist.
    .PARAMETER Scenario
        The test scenario: InstallUninstall or Update.
    .PARAMETER Backend
        Where the test ran: Sandbox or HyperV.
    .PARAMETER Verdict
        The overall outcome: Passed, Failed or Inconclusive.
    .PARAMETER Mode
        Interactive or Unattended. Defaults to Unattended.
    .PARAMETER Assertions
        Array of individual assertion results, each @{ Name = <string>; Result = 'PASS'|'FAIL'|'SKIP' }.
    .PARAMETER Notes
        Free-text notes for this run.
    .PARAMETER Baseline
        Update scenario: the baseline variant of this run (see DESCRIPTION). String values pass
        ConvertTo-Win32ToolkitSafeText (they come from winget manifests).
    .PARAMETER OldArpSurvivors
        Update scenario: the old-version ARP entries still registered after the update
        (ConvertFrom-Win32ToolkitArpSurvivor), at most 10.
    .PARAMETER LogFolder
        The folder that keeps this run's logs, relative to the project (Sandbox\Logs\Runs\<run>, from
        Save-Win32ToolkitTestRunLog). Omitted or empty: no LogFolder property.
    .PARAMETER NotRun
        The facts of a test the Intune-parity pre-check did not start (Invoke-Win32ToolkitParityPrecheck):
        written as the NotRun property, keys Code, Shape, ProcessesToClose, Welcome, SignedInSessions first,
        then any other key alphabetically; strings pass ConvertTo-Win32ToolkitSafeText (64 characters at most),
        integers and booleans are kept. Omitted: no NotRun property.
    .PARAMETER Timing
        A Hyper-V run's host measurements (Hyper-V speed-up PR 1, D12), written as the Timing property through an
        allow-list, keys in this order: TotalSeconds, OpenSeconds, OpenRevertSkipped, SecondsSinceTeardown,
        CopyInSeconds, CopyInSha256, Phases (at most 20 of { Label, Seconds }), TeardownSeconds, RevertMode,
        PrecheckSeconds, PrecheckFromCache. Any other key is dropped; numbers are rounded to one decimal; a value
        of the wrong type (or a CopyInSha256 that is not 64 upper-case hex characters) becomes $null; labels pass
        ConvertTo-Win32ToolkitSafeText (64 characters at most). Omitted or $null: no Timing property. The
        customer documentation never shows it.
    .PARAMETER Lane
        The test VM and checkpoint the Hyper-V run used, written as the Lane property through an allow-list, keys
        in this order: VMName, VMId, CheckpointName, CheckpointId, CheckpointCreatedUtc, CheckpointAgeDays,
        ProcessorCount, MemoryGB, ConcurrentLanes, Attestation ({ SignedIn, DefenderRealTime,
        DefenderExclusionCount, SignatureAgeDays, FromCache } or $null). Names pass ConvertTo-Win32ToolkitSafeText
        (64 characters at most); an Id that is not a GUID is ''; a value of the wrong type becomes $null. Omitted
        or $null: no Lane property.
    .EXAMPLE
        Add-Win32ToolkitTestResult -ProjectPath $p -Scenario InstallUninstall -Backend Sandbox `
            -Verdict Passed -Assertions @(@{ Name = 'Installed'; Result = 'PASS' }) -Notes 'clean run'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string]$Scenario,

        [Parameter(Mandatory)]
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend,

        [Parameter(Mandatory)]
        [ValidateSet('Passed', 'Failed', 'Inconclusive')]
        [string]$Verdict,

        [ValidateSet('Interactive', 'Unattended')]
        [string]$Mode = 'Unattended',

        [ValidateNotNull()]
        [object[]]$Assertions = @(),

        [string]$Notes = '',

        [hashtable]$Baseline,

        [AllowEmptyCollection()]
        [object[]]$OldArpSurvivors,

        [AllowEmptyString()]
        [string]$LogFolder,

        [hashtable]$NotRun,

        [hashtable]$Timing,

        [hashtable]$Lane
    )

    $docDir = Join-Path $ProjectPath 'Documentation'
    if (-not (Test-Path -LiteralPath $docDir)) {
        New-Item -ItemType Directory -Path $docDir -Force | Out-Null
    }
    $resultsPath = Join-Path $docDir 'TestResults.json'

    # Read existing entries; never throw on a corrupt/partial file — start fresh and warn.
    $entries = @()
    if (Test-Path -LiteralPath $resultsPath) {
        try {
            $raw = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json
                $entries = @($parsed)
            }
        }
        catch {
            Write-Warning "TestResults.json is unparseable; starting a fresh results file. ($($_.Exception.Message))"
            $entries = @()
        }
    }

    # Normalise assertions to plain { Name; Result } objects so serialisation is predictable.
    $normAssertions = @()
    foreach ($a in $Assertions) {
        if ($null -eq $a) { continue }
        $normAssertions += [pscustomobject]@{
            Name   = [string]$a.Name
            Result = [string]$a.Result
        }
    }

    $entry = [pscustomobject]@{
        Scenario     = $Scenario
        Backend      = $Backend
        Mode         = $Mode
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Verdict      = $Verdict
        Assertions   = $normAssertions
        Notes        = $Notes
    }

    # Optional Update-baseline facts: written only when supplied (older entries keep their shape). Known keys
    # in a stable order, then any other key alphabetically; strings are neutralised (manifest data).
    if ($PSBoundParameters.ContainsKey('Baseline') -and $null -ne $Baseline) {
        $order = @('Version', 'Mode', 'Origin', 'RequestedInstallerType', 'InstallerType', 'Family', 'UsedFallback', 'FallbackReason',
                   'RequestedScope', 'Scope', 'ScopeRelaxed', 'Unavailable', 'Locale', 'Source', 'ProjectName')
        $keys = @($order | Where-Object { $Baseline.ContainsKey($_) }) +
                @($Baseline.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $order } | Sort-Object)
        $b = [ordered]@{}
        foreach ($k in $keys) {
            $v = $Baseline[$k]
            $b[$k] = if ($v -is [bool]) { $v }
                     elseif ($null -eq $v) { '' }
                     else { ConvertTo-Win32ToolkitSafeText -Text ([string]$v) -MaxLength 256 }
        }
        $entry | Add-Member -NotePropertyName Baseline -NotePropertyValue ([pscustomobject]$b)
    }
    if ($PSBoundParameters.ContainsKey('OldArpSurvivors') -and $null -ne $OldArpSurvivors) {
        $survivors = @(foreach ($s in $OldArpSurvivors) {
                if ($null -eq $s) { continue }
                [pscustomobject]@{
                    DisplayName = ConvertTo-Win32ToolkitSafeText -Text ([string]$s.DisplayName) -MaxLength 256
                    Key         = ConvertTo-Win32ToolkitSafeText -Text ([string]$s.Key) -MaxLength 256
                    KeyLeaf     = ConvertTo-Win32ToolkitSafeText -Text ([string]$s.KeyLeaf) -MaxLength 256
                    View        = ConvertTo-Win32ToolkitSafeText -Text ([string]$s.View) -MaxLength 16
                }
            }) | Select-Object -First 10
        $entry | Add-Member -NotePropertyName OldArpSurvivors -NotePropertyValue @($survivors)
    }
    if ($LogFolder) {
        $entry | Add-Member -NotePropertyName LogFolder -NotePropertyValue ([string]$LogFolder)
    }
    # A test the Intune-parity pre-check did not start (installer-identity PR 2, spec 2.5): known keys first.
    if ($PSBoundParameters.ContainsKey('NotRun') -and $null -ne $NotRun) {
        $order = @('Code', 'Shape', 'ProcessesToClose', 'Welcome', 'SignedInSessions')
        $keys = @($order | Where-Object { $NotRun.ContainsKey($_) }) +
                @($NotRun.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $order } | Sort-Object)
        $n = [ordered]@{}
        foreach ($k in $keys) {
            $v = $NotRun[$k]
            $n[$k] = if ($v -is [bool] -or $v -is [int] -or $v -is [long]) { $v }
                     elseif ($null -eq $v) { '' }
                     else { ConvertTo-Win32ToolkitSafeText -Text ([string]$v) -MaxLength 64 }
        }
        $entry | Add-Member -NotePropertyName NotRun -NotePropertyValue ([pscustomobject]$n)
    }

    # A Hyper-V run's host measurements and VM identity (speed-up PR 1, A-7): an ALLOW-LIST, unlike Baseline/NotRun -
    # unknown keys are dropped, a value of the wrong type becomes $null, so nothing can widen the record.
    $isNumber = { param($v) ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single] -or $v -is [int16] -or $v -is [byte]) -and -not [double]::IsNaN([double]$v) -and -not [double]::IsInfinity([double]$v) }
    $isInteger = { param($v) $v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte] }
    $num = { param($v, [int]$Digits) if (& $isNumber $v) { [math]::Round([double]$v, $Digits) } else { $null } }
    $int = { param($v) if ((& $isInteger $v) -and [long]$v -ge [int]::MinValue -and [long]$v -le [int]::MaxValue) { [int]$v } else { $null } }
    $bool = { param($v) if ($v -is [bool]) { $v } else { $null } }
    $guidPattern = '^[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
    if ($PSBoundParameters.ContainsKey('Timing') -and $null -ne $Timing) {
        $t = [ordered]@{}
        foreach ($k in 'TotalSeconds', 'OpenSeconds', 'OpenRevertSkipped', 'SecondsSinceTeardown', 'CopyInSeconds', 'CopyInSha256', 'Phases',
            'TeardownSeconds', 'RevertMode', 'PrecheckSeconds', 'PrecheckFromCache') {
            $v = $Timing[$k]
            $t[$k] = switch ($k) {
                { $_ -in 'OpenRevertSkipped', 'PrecheckFromCache' } { & $bool $v; break }
                'CopyInSha256' { if ($v -is [string] -and $v -cmatch '^[0-9A-F]{64}$') { $v } else { $null }; break }
                'RevertMode' { if ($v -is [string] -and $v -cin 'TurnOffFirst', 'Legacy') { $v } else { $null }; break }
                'Phases' {
                    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary]) {
                        , @(@($v) | Where-Object { $null -ne $_ } | Select-Object -First 20 | ForEach-Object {
                                [pscustomobject][ordered]@{ Label = ConvertTo-Win32ToolkitSafeText -Text ([string]$_.Label) -MaxLength 64; Seconds = & $num $_.Seconds 1 }
                            })
                    }
                    else { $null }
                    break
                }
                default { & $num $v 1 }
            }
        }
        $entry | Add-Member -NotePropertyName Timing -NotePropertyValue ([pscustomobject]$t)
    }
    if ($PSBoundParameters.ContainsKey('Lane') -and $null -ne $Lane) {
        $l = [ordered]@{}
        foreach ($k in 'VMName', 'VMId', 'CheckpointName', 'CheckpointId', 'CheckpointCreatedUtc', 'CheckpointAgeDays', 'ProcessorCount', 'MemoryGB',
            'ConcurrentLanes', 'Attestation') {
            $v = $Lane[$k]
            $l[$k] = switch ($k) {
                { $_ -in 'VMName', 'CheckpointName' } { if ($v -is [string]) { ConvertTo-Win32ToolkitSafeText -Text $v -MaxLength 64 } elseif ($null -eq $v) { '' } else { $null }; break }
                { $_ -in 'VMId', 'CheckpointId' } { if ($v -is [string] -and $v -match $guidPattern) { $v } else { '' }; break }
                'CheckpointCreatedUtc' {
                    $parsed = [datetime]::MinValue
                    if ($v -is [string] -and [datetime]::TryParseExact($v, 'o', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $v } else { '' }
                    break
                }
                'MemoryGB' { & $num $v 2; break }
                'Attestation' {
                    if ($v -is [System.Collections.IDictionary] -or $v -is [System.Management.Automation.PSCustomObject]) {
                        $read = { param($o, [string]$Name) if ($o -is [System.Collections.IDictionary]) { $o[$Name] } elseif ($o.PSObject.Properties[$Name]) { $o.$Name } else { $null } }
                        [pscustomobject][ordered]@{
                            SignedIn               = & $bool (& $read $v 'SignedIn')
                            DefenderRealTime       = & $bool (& $read $v 'DefenderRealTime')
                            DefenderExclusionCount = & $int (& $read $v 'DefenderExclusionCount')
                            SignatureAgeDays       = & $int (& $read $v 'SignatureAgeDays')
                            FromCache              = & $bool (& $read $v 'FromCache')
                        }
                    }
                    else { $null }
                    break
                }
                default { & $int $v }
            }
        }
        $entry | Add-Member -NotePropertyName Lane -NotePropertyValue ([pscustomobject]$l)
    }

    $entries += $entry

    # Force a JSON ARRAY even for a single entry — ConvertTo-Json collapses a one-element array.
    $json = ConvertTo-Json -InputObject @($entries) -Depth 6
    # Write BOM-less UTF-8 (matches Set-Win32ToolkitAppConfig).
    [System.IO.File]::WriteAllText($resultsPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    return $entry
}
