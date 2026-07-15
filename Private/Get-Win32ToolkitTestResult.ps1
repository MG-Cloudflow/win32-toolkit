function Get-Win32ToolkitTestResult {
    <#
    .SYNOPSIS
        Reads a project's recorded test outcomes (Documentation\TestResults.json).
    .DESCRIPTION
        Returns the array of test-outcome entries written by Add-Win32ToolkitTestResult. Returns an
        empty array (@()) when the file is absent, empty or unparseable — reading never throws. The
        documentation generator uses this to list every test run against the project.

        Each entry has the shape { Scenario, Backend, Mode, TimestampUtc, Verdict, Assertions[], Notes }.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1).
    .EXAMPLE
        $results = Get-Win32ToolkitTestResult -ProjectPath $p
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $resultsPath = Join-Path $ProjectPath 'Documentation\TestResults.json'
    # Unary comma keeps the empty/array result from being unrolled to $null by the pipeline.
    if (-not (Test-Path -LiteralPath $resultsPath)) {
        return , @()
    }

    try {
        $raw = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return , @()
        }
        return , @($raw | ConvertFrom-Json)
    }
    catch {
        Write-Warning "TestResults.json is unparseable; returning no results. ($($_.Exception.Message))"
        return , @()
    }
}
