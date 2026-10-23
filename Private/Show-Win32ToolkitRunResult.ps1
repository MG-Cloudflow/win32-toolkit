function Show-Win32ToolkitRunResult {
    <#
    .SYNOPSIS
        Renders the result panel of a wizard run from the command's Win32Toolkit.RunResult (TUI audit G2).
    .DESCRIPTION
        Takes the captured output of Invoke-Win32Toolkit, New-Win32ToolkitManualApp or
        Complete-Win32ToolkitManualApp, uses the LAST object whose type names contain Win32Toolkit.RunResult
        (anything else in the output is ignored) and renders one panel:

            Succeeded              'Done' (green)
            CompletedWithProblems  'Finished with problems' (red), one '- <problem>' line per problem
            Failed                 'Finished with problems' (red), "stopped before the end" and the problems
            Scaffolded             'Scaffolded' (blue), the project path and where to finish it
            no result object       'Finished' (yellow)

        The name and every problem pass Get-SpectreEscapedText. The TUI judges a run by this object only, never
        by -ErrorVariable or $? (an -ErrorVariable also collects errors of a passing run). A screen helper: it
        returns nothing and renders through its success stream; call it as a bare statement.
    .PARAMETER Result
        The captured output of the command (an array; may be empty).
    .PARAMETER Name
        The app or project name shown in the panel.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Result,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )

    $r = @(@($Result) | Where-Object { $null -ne $_ -and $_.PSObject -and $_.PSObject.TypeNames -contains 'Win32Toolkit.RunResult' }) | Select-Object -Last 1
    $safeName = Get-SpectreEscapedText -Text $Name
    if (-not $r) {
        Format-SpectrePanel -Data "$safeName`: no result came back. Review the messages above for details." -Header 'Finished' -Border Rounded -Color Yellow
        return
    }

    $bullets = (@($r.Problems) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { "`n- $(Get-SpectreEscapedText -Text ([string]$_))" }) -join ''
    switch ([string]$r.Status) {
        'Succeeded' {
            Format-SpectrePanel -Data "Finished [green]$safeName[/].`nUse [blue]Browse projects[/] to find it; review the messages above for details." -Header 'Done' -Border Rounded -Color Green
        }
        'CompletedWithProblems' {
            Format-SpectrePanel -Data "[red]$safeName[/] finished, but not everything worked:$bullets`n`nReview the messages above for details." -Header 'Finished with problems' -Border Rounded -Color Red
        }
        'Failed' {
            Format-SpectrePanel -Data "[red]$safeName[/] stopped before the end:$bullets`n`nThe steps after it did not run. Review the messages above for details." -Header 'Finished with problems' -Border Rounded -Color Red
        }
        'Scaffolded' {
            Format-SpectrePanel -Data "$safeName was created at:`n[blue]$(Get-SpectreEscapedText -Text ([string]$r.ProjectPath))[/]`nFinish it from [blue]Work with an existing project[/] > Finalize / refresh." -Header 'Scaffolded' -Border Rounded -Color Blue
        }
        default {
            Format-SpectrePanel -Data "$safeName`: no result came back. Review the messages above for details." -Header 'Finished' -Border Rounded -Color Yellow
        }
    }
}
