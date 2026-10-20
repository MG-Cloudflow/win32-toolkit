function Add-Win32ToolkitTestResult {
    <#
    .SYNOPSIS
        Appends one test-outcome entry to a project's Documentation\TestResults.json.
    .DESCRIPTION
        TestResults.json is the shared persistence file that records every install/update test run
        against a project (Sandbox or Hyper-V). The customer documentation reads it back to list
        "all the tests we did". Entries are appended newest-last.

        Each entry has the shape:
            { Scenario, Backend, Mode, TimestampUtc, Verdict, Assertions[], Notes [, Baseline] [, OldArpSurvivors[]] [, LogFolder] }
        where Assertions is an array of @{ Name; Result } (Result in PASS|FAIL|SKIP). Baseline (the Update
        test's old-version variant: Version, Mode, Origin, RequestedInstallerType, InstallerType, Family,
        UsedFallback, FallbackReason, RequestedScope, Scope, ScopeRelaxed, Unavailable, Locale, Source,
        ProjectName) and OldArpSurvivors (@{ DisplayName; Key; KeyLeaf; View }) are written only when supplied,
        so entries without them keep the old shape (installer-identity PR 1, spec 2.11). LogFolder (the run's
        own log folder, Sandbox\Logs\Runs\<run>, relative to the project) is likewise written only when supplied.

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
        [string]$LogFolder
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

    $entries += $entry

    # Force a JSON ARRAY even for a single entry — ConvertTo-Json collapses a one-element array.
    $json = ConvertTo-Json -InputObject @($entries) -Depth 6
    # Write BOM-less UTF-8 (matches Set-Win32ToolkitAppConfig).
    [System.IO.File]::WriteAllText($resultsPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    return $entry
}
