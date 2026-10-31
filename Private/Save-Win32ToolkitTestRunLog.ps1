function Save-Win32ToolkitTestRunLog {
    <#
    .SYNOPSIS
        Copies the logs one test run wrote into its own folder, Sandbox\Logs\Runs\<run>\, and returns that
        folder relative to the project.
    .DESCRIPTION
        The second half of Initialize-Win32ToolkitTestRunLog (test campaign F2). Called after the run's logs
        are back on the host: the Sandbox mapped folder after the log collector finished
        (Wait-Win32ToolkitCollectedLog), or the Hyper-V copy-back.

        Copied into the run folder:
          - every top-level Sandbox\Logs file that is new or changed since Initialize-Win32ToolkitTestRunLog
            (length, then SHA-256): the assertion log, the ARP snapshots, the PSADT and MSI logs the
            collector brought back. Files of earlier runs that this run did not touch are left out.
          - PsadtExitCodes.log with only this run's lines: the lines after the run's marker, up to the next
            marker.
        The top-level files are left unchanged. They gather the logs of every run (each run overwrites the
        files it writes; files only an earlier run wrote stay), so only the run folder is exactly this run's.

        Never throws for a file-system problem: a file that cannot be copied is named in one warning, and
        the folder keeps the others. Returns $null (no folder) when the run left no log at all.
    .PARAMETER Run
        The object Initialize-Win32ToolkitTestRunLog returned for this run.
    .OUTPUTS
        [string] the run folder relative to the project (Sandbox\Logs\Runs\<run>), or $null.
    .EXAMPLE
        $rel = Save-Win32ToolkitTestRunLog -Run $run
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Run
    )

    try {
        $logs = Join-Path $Run.ProjectPath 'Sandbox\Logs'
        if (-not (Test-Path -LiteralPath $logs)) { return $null }
        $dest = Join-Path $Run.ProjectPath $Run.RelativePath
        $before = if ($Run.Snapshot -is [hashtable]) { $Run.Snapshot } else { @{} }

        # Files this run wrote or changed (length first, the hash only when the length is the same).
        $changed = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        foreach ($file in @(Get-ChildItem -LiteralPath $logs -File -Force -ErrorAction Stop)) {
            if ($file.Name -eq 'PsadtExitCodes.log') { continue }
            $was = [string]$before[$file.Name]
            if (-not $was) { $changed.Add($file); continue }
            $wasLength, $wasHash = $was.Split(':', 2)
            if ([string]$file.Length -ne $wasLength) { $changed.Add($file); continue }
            $hash = '?'
            try { $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Test run logs: could not hash '$($file.Name)': $($_.Exception.Message)"
            }
            if ($hash -ne $wasHash) { $changed.Add($file) }
        }

        # This run's exit-code lines: after its marker, up to the next marker.
        $codeLines = @()
        $codes = Join-Path $logs 'PsadtExitCodes.log'
        if ($Run.Marker -and (Test-Path -LiteralPath $codes)) {
            $all = @(Get-Content -LiteralPath $codes -Encoding UTF8 -ErrorAction Stop)
            $at = [array]::LastIndexOf([string[]]$all, [string]$Run.Marker)
            if ($at -ge 0) {
                for ($i = $at + 1; $i -lt $all.Count; $i++) {
                    if ($all[$i] -match '^\[[^\]]*\]\s+-- test run ') { break }
                    if ($all[$i]) { $codeLines += $all[$i] }
                }
            }
            else {
                Write-Verbose "Test run logs: the start marker of run '$($Run.RunName)' is not in PsadtExitCodes.log; its exit codes are not kept separately."
            }
        }

        if ($changed.Count -eq 0 -and $codeLines.Count -eq 0) {
            Write-Verbose "Test run logs: run '$($Run.RunName)' left no log in Sandbox\Logs."
            return $null
        }

        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        $missed = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $changed) {
            try { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dest $file.Name) -Force -ErrorAction Stop }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $missed.Add("$($file.Name) ($($_.Exception.Message))")
            }
        }
        if ($codeLines.Count -gt 0) {
            [System.IO.File]::WriteAllText((Join-Path $dest 'PsadtExitCodes.log'), (($codeLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        }
        if ($missed.Count -gt 0) {
            Write-Warning "Some logs of this test run could not be copied to $($Run.RelativePath): $($missed -join '; ')"
        }
        return [string]$Run.RelativePath
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning "This test run's logs could not be kept in their own folder ($($Run.RelativePath)): $($_.Exception.Message)"
        return $null
    }
}
