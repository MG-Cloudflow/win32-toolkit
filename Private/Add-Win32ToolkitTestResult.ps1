function Add-Win32ToolkitTestResult {
    <#
    .SYNOPSIS
        Appends one test-outcome entry to a project's Documentation\TestResults.json.
    .DESCRIPTION
        TestResults.json is the shared persistence file that records every install/update test run
        against a project (Sandbox or Hyper-V). The customer documentation reads it back to list
        "all the tests we did". Entries are appended newest-last.

        Each entry has the shape:
            { Scenario, Backend, Mode, TimestampUtc, Verdict, Assertions[], Notes }
        where Assertions is an array of @{ Name; Result } (Result in PASS|FAIL|SKIP).

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

        [string]$Notes = ''
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

    $entries += $entry

    # Force a JSON ARRAY even for a single entry — ConvertTo-Json collapses a one-element array.
    $json = ConvertTo-Json -InputObject @($entries) -Depth 6
    # Write BOM-less UTF-8 (matches Set-Win32ToolkitAppConfig).
    [System.IO.File]::WriteAllText($resultsPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    return $entry
}
