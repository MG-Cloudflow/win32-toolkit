function Initialize-Win32ToolkitTestRunLog {
    <#
    .SYNOPSIS
        Prepares the per-run evidence folder of one test run: names it, marks the run's start in
        PsadtExitCodes.log and remembers the Sandbox\Logs files that existed before the run.
    .DESCRIPTION
        Every test run keeps its own evidence in Sandbox\Logs\Runs\<yyyyMMdd-HHmmss>_<Scenario>[_<Family>]\
        (test campaign F2): an InstallUninstall run, an Update run, and each leg of an Update
        '-BaselineInstallerType Both' run. The top-level Sandbox\Logs files stay as they were (the latest
        run's logs, for compatibility); the next run overwrites them.

        Called right before the guest run starts (both backends). It:
          - picks the run name from the local time, the scenario and the baseline family ('-2', '-3', ...
            when that folder already exists);
          - appends the marker line '[<time>] -- test run <name> --' to Sandbox\Logs\PsadtExitCodes.log:
            the guest runner's exit-code lines that follow it belong to this run (the host prints only
            those, Save-Win32ToolkitTestRunLog keeps only those, and the watched countdown reads its verdict
            after the last marker);
          - removes the log collector's completion file (Sandbox\Logs\CollectLogs.done) of an earlier run;
          - records the length and SHA-256 of every top-level Sandbox\Logs file, so
            Save-Win32ToolkitTestRunLog copies only the files this run wrote or changed.

        Never throws for a file-system problem: it warns and returns $null, and the run goes on without
        per-run evidence.
    .PARAMETER ProjectPath
        The PSADT project folder under test.
    .PARAMETER Scenario
        InstallUninstall or Update (part of the folder name).
    .PARAMETER Family
        Update: the installer family of this run's baseline (msi, exe, msix, ...), part of the folder name.
        Characters other than letters and digits are dropped.
    .OUTPUTS
        [pscustomobject] ProjectPath, RunName, RelativePath (Sandbox\Logs\Runs\<name>), Marker, Snapshot
        (hashtable: file name -> '<length>:<sha256>'), StartedUtc. $null when the evidence cannot be prepared.
    .EXAMPLE
        $run = Initialize-Win32ToolkitTestRunLog -ProjectPath $p -Scenario Update -Family exe
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

        [AllowEmptyString()]
        [string]$Family = ''
    )

    try {
        $logs = Join-Path $ProjectPath 'Sandbox\Logs'
        if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }

        # The run name: local time (what the operator sees), the scenario and the baseline family.
        $fam = ([string]$Family -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($fam.Length -gt 16) { $fam = $fam.Substring(0, 16) }
        $stem = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Scenario
        if ($fam) { $stem = '{0}_{1}' -f $stem, $fam }
        $runsRoot = Join-Path $logs 'Runs'
        $name = $stem
        for ($n = 2; Test-Path -LiteralPath (Join-Path $runsRoot $name); $n++) { $name = '{0}-{1}' -f $stem, $n }

        # The exit-code log keeps the lines of every run of one outer call; this marker starts this run's lines.
        $marker = '[{0}] -- test run {1} --' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $name
        $codes = Join-Path $logs 'PsadtExitCodes.log'
        $prefix = ''
        if (Test-Path -LiteralPath $codes) {
            $bytes = [System.IO.File]::ReadAllBytes($codes)
            if ($bytes.Length -gt 0 -and $bytes[-1] -ne 10) { $prefix = "`r`n" }
        }
        [System.IO.File]::AppendAllText($codes, $prefix + $marker + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

        # The completion file of an earlier run's log collector would end the wait for this run's logs at once.
        $done = Join-Path $logs 'CollectLogs.done'
        if (Test-Path -LiteralPath $done) { Remove-Item -LiteralPath $done -Force -ErrorAction Stop }

        # What the top-level logs held before the run: a file this run writes or changes differs from it.
        $snapshot = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $logs -File -Force -ErrorAction Stop)) {
            if ($file.Name -eq 'PsadtExitCodes.log') { continue }
            $hash = '?'
            try { $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Test run logs: could not hash '$($file.Name)' ($($_.Exception.Message)); it is kept with this run if it is still there."
            }
            $snapshot[$file.Name] = '{0}:{1}' -f $file.Length, $hash
        }

        return [pscustomobject]@{
            ProjectPath  = $ProjectPath
            RunName      = $name
            RelativePath = Join-Path 'Sandbox\Logs\Runs' $name
            Marker       = $marker
            Snapshot     = $snapshot
            StartedUtc   = [datetime]::UtcNow
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning "This test run's logs will not be kept in their own folder under Sandbox\Logs\Runs: $($_.Exception.Message)"
        return $null
    }
}
