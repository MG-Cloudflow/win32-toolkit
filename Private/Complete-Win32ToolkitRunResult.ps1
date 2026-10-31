function Complete-Win32ToolkitRunResult {
    <#
    .SYNOPSIS
        Turns a run-result collector into the Win32Toolkit.RunResult a pipeline command returns (TUI audit G2, S8-F3).
    .DESCRIPTION
        Returns a NEW object (the collector is not changed) with these properties, always present, in this
        order: Command, ProjectPath, ProjectName, Mode, Status, Capture, Tests ([object[]]), IntuneWinPath,
        Published ([object[]]), Problems ([string[]]). Its first type name is Win32Toolkit.RunResult and its
        default display is ProjectName, Status, Problems.

        Status (computed here, once):
          1. Failed                - -Failed (the command stopped on a non-W32T error or found nothing to build).
          2. Scaffolded            - -Scaffolded (New-Win32ToolkitManualApp created a project that still needs
                                     Complete-Win32ToolkitManualApp) and no problem.
          3. CompletedWithProblems - the command reached its end and Problems is not empty.
          4. Succeeded             - otherwise.
        Pure: no I/O.
    .PARAMETER Result
        The collector from Initialize-Win32ToolkitRunResult.
    .PARAMETER Failed
        The command stopped before its end.
    .PARAMETER Scaffolded
        New-Win32ToolkitManualApp scaffolded a project that still has to be finished.
    .OUTPUTS
        [pscustomobject] (Win32Toolkit.RunResult)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [switch]$Failed,
        [switch]$Scaffolded
    )

    $problems = [string[]]@(@($Result.Problems) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $status = if ($Failed) { 'Failed' }
              elseif ($Scaffolded -and $problems.Count -eq 0) { 'Scaffolded' }
              elseif ($problems.Count -gt 0) { 'CompletedWithProblems' }
              else { 'Succeeded' }

    $out = [pscustomobject][ordered]@{
        Command       = [string]$Result.Command
        ProjectPath   = [string]$Result.ProjectPath
        ProjectName   = [string]$Result.ProjectName
        Mode          = [string]$Result.Mode
        Status        = $status
        Capture       = [string]$Result.Capture
        Tests         = [object[]]@($Result.Tests | Where-Object { $null -ne $_ })
        IntuneWinPath = [string]$Result.IntuneWinPath
        Published     = [object[]]@($Result.Published | Where-Object { $null -ne $_ })
        Problems      = $problems
    }
    $out.PSObject.TypeNames.Insert(0, 'Win32Toolkit.RunResult')
    $display = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('ProjectName', 'Status', 'Problems'))
    $out | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($display))
    $out
}
