function Remove-Win32ToolkitPhaseBlock {
    <#
    .SYNOPSIS
        Removes one toolkit-owned '## win32-toolkit:<Phase>:<Slot>' block from deploy-script text (pure).
    .DESCRIPTION
        Removes the whole block - its begin line, body and end line - and nothing else. A no-op when the
        block is absent. A corrupt block in the phase (begin without end, duplicate, outside its phase)
        throws W32T.PhaseAnchorMissing, because the extent of the block can no longer be trusted.
        See Set-Win32ToolkitPhaseBlock for the block format.
    .PARAMETER Content
        The deploy-script text (no BOM).
    .PARAMETER Phase
        PSADT phase name, or 'Session'.
    .PARAMETER Slot
        The block slot within the phase.
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
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Slot
    )

    $phases = @('Session', 'Pre-Install', 'Install', 'Post-Install', 'Pre-Uninstall', 'Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Repair', 'Post-Repair')
    if ($Phase -notin $phases -or $Slot -notmatch '^[a-z][a-z-]*$') {
        throw [System.ArgumentException]::new("'${Phase}:$Slot' is not a win32-toolkit deploy-script block slot.")
    }

    $layout = (Get-Win32ToolkitDeployScriptShape -Content $Content -IncludeLayout).Layout
    $issue = @($layout.BlockIssues | Where-Object { $_.Phase -eq $Phase }) | Select-Object -First 1
    if ($issue) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("win32-toolkit cannot remove the '${Phase}:$Slot' block from the deploy script: $($issue.Message). Re-create the project with this win32-toolkit version if the script was edited by hand."),
            'W32T.PhaseAnchorMissing', [System.Management.Automation.ErrorCategory]::InvalidData, "${Phase}:$Slot")
    }
    $block = @($layout.Blocks | Where-Object { $_.Phase -eq $Phase -and $_.Slot -eq $Slot }) | Select-Object -First 1
    if (-not $block) { return $Content }
    return $Content.Substring(0, $block.Start) + $Content.Substring($block.End)
}
