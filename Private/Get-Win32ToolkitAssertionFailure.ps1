function Get-Win32ToolkitAssertionFailure {
    <#
    .SYNOPSIS
        Reads the failed assertions, each with its reason, from a guest assertion log (InstallAssertions.log).
    .DESCRIPTION
        TUI coverage audit G1: the verdict reader's console line leaves the reason out
        (Wait-Win32ToolkitUpdateAssertion), so the TUI's INSTALL/UNINSTALL TEST FAILED panel reads the reasons here.
        Data only: the log is read as text, never executed.

        Only anchored result lines count, with the anchor of the verdict's reader: '[timestamp] ASSERT <name> =
        PASS|FAIL|SKIP <rest>', ASSERT being the first token after the optional timestamp. A value the guest echoes
        into a diagnostic line (an untrusted DisplayName such as 'Widget ASSERT Rigged = FAIL') never counts.
        The first result line of a name wins, as in the verdict's reader: FAIL then PASS of one name is a failure,
        PASS then FAIL is not, so the panel names exactly the failures the verdict counted.

        Reason = the rest of the line with one pair of outer parentheses removed, through
        ConvertTo-Win32ToolkitSafeText -MaxLength 512 ('' when empty); Name through ConvertTo-Win32ToolkitSafeText
        -MaxLength 128. Never throws: a missing file gives nothing; a read error is written with Write-Verbose and
        gives nothing.
    .PARAMETER LogPath
        The assertion log to read (for example <run folder>\InstallAssertions.log).
    .OUTPUTS
        [pscustomobject] Name, Reason: one per failed assertion, in first-seen order.
    .EXAMPLE
        Get-Win32ToolkitAssertionFailure -LogPath (Join-Path $runFolder 'InstallAssertions.log')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LogPath
    )

    try {
        if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return }
        $anchor = [regex]::new('^\s*(?:\[[^\]]*\]\s+)?ASSERT\s+(\S+)\s*=\s*(PASS|FAIL|SKIP)\b\s*(.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $seen = @{}
        $failed = [System.Collections.Generic.List[object]]::new()
        foreach ($line in @(Get-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $m = $anchor.Match([string]$line)
            if (-not $m.Success) { continue }
            $name = $m.Groups[1].Value
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            if ($m.Groups[2].Value -ne 'FAIL') { continue }
            $reason = $m.Groups[3].Value.Trim()
            if ($reason.Length -ge 2 -and $reason.StartsWith('(') -and $reason.EndsWith(')')) { $reason = $reason.Substring(1, $reason.Length - 2) }
            $failed.Add([pscustomobject]@{
                    Name   = ConvertTo-Win32ToolkitSafeText -Text $name -MaxLength 128
                    Reason = ConvertTo-Win32ToolkitSafeText -Text $reason -MaxLength 512
                })
        }
        $failed
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Could not read the assertion log '$LogPath': $($_.Exception.Message)"
    }
}
