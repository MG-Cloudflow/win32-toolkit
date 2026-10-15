function Remove-Win32ToolkitPhaseDefaultUi {
    <#
    .SYNOPSIS
        Removes PSADT's default dialog statements from one deploy-script phase (pure string transform).
    .DESCRIPTION
        Used by Apply-OrgTemplate before it places the org-template dialog block ('org-ui'), so the
        template's dialog policy is the only one left in the phase. In the phase's statements that lie
        OUTSIDE toolkit blocks (PSADT 4.2: the phase scriptblock's statements; PSADT 4.1: the direct
        statements of the deploy function inside the phase region) every statement whose text mentions
        Show-ADTInstallationWelcome, Show-ADTInstallationProgress, Show-ADTInstallationPrompt or
        $saiwParams is removed as whole lines, together with the directly preceding PSADT comment lines
        ('## Show Welcome Message', '## Show Progress Message', '## If there are processes to close',
        '## Display a message at the end'). A blank line left doubled by a removal is collapsed.

        Never touches markers, '##====' banners, the InstallPhase assignments, toolkit blocks or any other
        statement. Idempotent (a second run finds nothing to remove).
    .PARAMETER Content
        The deploy-script text (no BOM).
    .PARAMETER Phase
        Pre-Install, Pre-Uninstall, Pre-Repair, Post-Install or Post-Repair.
    .OUTPUTS
        [string] the new content.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'pure string transform; no system state')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory)]
        [ValidateSet('Pre-Install', 'Pre-Uninstall', 'Pre-Repair', 'Post-Install', 'Post-Repair')]
        [string]$Phase
    )

    $shape = Get-Win32ToolkitDeployScriptShape -Content $Content -IncludeLayout
    if ($shape.Shape -eq 'Unknown') {
        $v = if ($shape.DeployAppScriptVersion) { $shape.DeployAppScriptVersion } else { 'none' }
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Unsupported PSADT template shape: (deploy script text); shape Unknown; DeployAppScriptVersion $v; supported: $($script:PsadtSupportedRange.Display). Cannot remove the default dialogs of phase '$Phase' ($($shape.Reason)). Nothing was changed."),
            'W32T.UnsupportedTemplateShape', [System.Management.Automation.ErrorCategory]::InvalidData, $Phase)
    }
    $layout = $shape.Layout
    # The block extents decide what is "toolkit code": refuse when they cannot be trusted.
    $issue = @($layout.BlockIssues) | Select-Object -First 1
    if ($issue) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("win32-toolkit cannot remove the default dialogs of phase '$Phase': $($issue.Message). Re-create the project with this win32-toolkit version if the script was edited by hand."),
            'W32T.PhaseAnchorMissing', [System.Management.Automation.ErrorCategory]::InvalidData, $Phase)
    }
    $ph = $layout.Phases[$Phase]
    if ($ph.ContainsKey('Ast')) {
        $statements = @($ph.Ast.ScriptBlock.EndBlock.Statements)
    }
    else {
        $statements = @($ph.FunctionAst.Body.EndBlock.Statements |
                Where-Object { $_.Extent.StartOffset -ge $ph.RegionStart -and $_.Extent.EndOffset -le $ph.RegionEnd })
    }
    $spans = @($layout.Blocks)
    $uiPattern = 'Show-ADTInstallationWelcome|Show-ADTInstallationProgress|Show-ADTInstallationPrompt|\$saiwParams'
    $kill = @($statements | Where-Object {
            $s = $_
            $s.Extent.Text -match $uiPattern -and
            -not ($spans | Where-Object { $s.Extent.StartOffset -ge $_.Start -and $s.Extent.EndOffset -le $_.End })
        } | Sort-Object { $_.Extent.StartOffset } -Descending)

    $commentPattern = '^[ \t]*## (Show Welcome Message|Show Progress Message|If there are processes to close|Display a message at the end)'
    foreach ($s in $kill) {
        $start = $s.Extent.StartOffset; $end = $s.Extent.EndOffset
        # Whole lines when the statement owns its lines.
        $lineStart = if ($start -gt 0) { $Content.LastIndexOf("`n", $start - 1) + 1 } else { 0 }
        if (-not $Content.Substring($lineStart, $start - $lineStart).Trim()) { $start = $lineStart }
        $eol = $Content.IndexOf("`n", $end)
        $lineEnd = if ($eol -lt 0) { $Content.Length } else { $eol + 1 }
        if (-not $Content.Substring($end, $lineEnd - $end).Trim()) { $end = $lineEnd }
        # Directly preceding PSADT dialog comments.
        if ($start -eq $lineStart) {
            while ($start -gt 0) {
                $prevStart = if ($start -ge 2) { $Content.LastIndexOf("`n", $start - 2) + 1 } else { 0 }
                if ($Content.Substring($prevStart, $start - $prevStart) -match $commentPattern) { $start = $prevStart } else { break }
            }
        }
        # Collapse a blank line that the removal would leave doubled (whole-line removals only).
        if ($start -le $lineStart -and $end -eq $lineEnd) {
            $prevBlank = $false
            if ($start -gt 0) {
                $prevStart = if ($start -ge 2) { $Content.LastIndexOf("`n", $start - 2) + 1 } else { 0 }
                $prevBlank = -not $Content.Substring($prevStart, $start - $prevStart).Trim()
            }
            if ($prevBlank -and $end -lt $Content.Length) {
                $nextEol = $Content.IndexOf("`n", $end)
                $nextEnd = if ($nextEol -lt 0) { $Content.Length } else { $nextEol + 1 }
                if (-not $Content.Substring($end, $nextEnd - $end).Trim()) { $end = $nextEnd }
            }
        }
        $Content = $Content.Substring(0, $start) + $Content.Substring($end)
    }
    return $Content
}
