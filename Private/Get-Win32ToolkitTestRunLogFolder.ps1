function Get-Win32ToolkitTestRunLogFolder {
    <#
    .SYNOPSIS
        Returns the per-run log folders (Sandbox\Logs\Runs\<run>) of the test runs recorded since a given
        time, for a hint that names the logs of a failed run.
    .DESCRIPTION
        Reads Documentation\TestResults.json (Get-Win32ToolkitTestResult) and returns the LogFolder of every
        record of -Scenario with -Verdict whose TimestampUtc is at or after -SinceUtc, oldest first (test
        campaign F2: the legs of an Update '-BaselineInstallerType Both' run each have their own folder).
        Only a folder of the shape Sandbox\Logs\Runs\<name> is returned (the record is data); records
        written before per-run folders existed have none and are skipped.

        Never throws: an unreadable results file returns nothing.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Scenario
        InstallUninstall or Update.
    .PARAMETER SinceUtc
        Only records at or after this UTC time (taken before the test started).
    .PARAMETER Verdict
        The verdict of the records to return (default Failed).
    .OUTPUTS
        [string[]] full paths of the run folders.
    .EXAMPLE
        Get-Win32ToolkitTestRunLogFolder -ProjectPath $p -Scenario Update -SinceUtc $started
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string]$Scenario,

        [Parameter(Mandatory)]
        [datetime]$SinceUtc,

        [ValidateSet('Passed', 'Failed', 'Inconclusive')]
        [string]$Verdict = 'Failed'
    )

    try {
        $since = $SinceUtc.ToUniversalTime()
        # Assigned, not wrapped in @(): the reader returns its array as ONE object (unary comma).
        $records = Get-Win32ToolkitTestResult -ProjectPath $ProjectPath -WarningAction SilentlyContinue
        $folders = foreach ($r in @($records)) {
            if ($null -eq $r -or -not $r.PSObject.Properties['LogFolder']) { continue }
            if ([string]$r.Scenario -ne $Scenario -or [string]$r.Verdict -ne $Verdict) { continue }
            $stamp = $r.TimestampUtc
            $when = [datetime]::MinValue
            if ($stamp -is [datetime]) { $when = $stamp.ToUniversalTime() }
            elseif (-not [datetime]::TryParse([string]$stamp, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$when)) { continue }
            if ($when -lt $since) { continue }
            $rel = [string]$r.LogFolder
            if ($rel -notmatch '^Sandbox\\Logs\\Runs\\[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$' -or $rel -match '\.\.') { continue }
            Join-Path $ProjectPath $rel
        }
        return [string[]]@($folders)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Could not read the test run log folders: $($_.Exception.Message)"
        return [string[]]@()
    }
}
