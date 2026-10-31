function Assert-Win32ToolkitProjectConfigured {
    <#
    .SYNOPSIS
        Refuses to package or publish a project marked not configured (TUI audit G4, S10-F2): W32T.ProjectNotConfigured.
    .DESCRIPTION
        A project whose build stopped after its folder was created (a refused configuration, a failed download, no
        installer found, any other error before the end of the configure step) carries
        Documentation\NotConfigured.json (Write-Win32ToolkitNotConfiguredMarker). Such a project would ship without
        its org template or installer configuration, so Export-Win32ToolkitIntuneWin and
        Publish-Win32ToolkitIntuneApp call this gate first and stop with W32T.ProjectNotConfigured (ErrorCategory
        InvalidOperation, TargetObject the project path). There is no override: re-create the project.

        Without a marker it returns nothing. A marker that cannot be read still refuses (fail closed). The marker's
        reason is shown without its final period (it sits inside the bracket the message closes with one).
    .PARAMETER ProjectPath
        The project folder.
    .PARAMETER Operation
        Export (cannot be packaged; nothing was packaged or published) or Publish (cannot be published).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][ValidateSet('Export', 'Publish')][string]$Operation
    )

    $marker = Get-Win32ToolkitNotConfiguredMarker -ProjectPath $ProjectPath
    if (-not $marker) { return }

    $name = Split-Path -Path ([string]$ProjectPath).TrimEnd('\', '/') -Leaf
    $stageText = switch ([string]$marker.Stage) {
        'Configure' { 'its configuration failed or was refused' }
        'Download'  { 'its installer could not be downloaded or added' }
        default     { 'the marker could not be read' }
    }
    # The reason is usually a whole sentence (every W32T message ends with a period): inside the bracket, which the
    # message closes with '.', its own final period would print '.).'. An ellipsis (a reason cut at 1024 characters)
    # stays.
    $reason = ([string]$marker.Reason).Trim() -replace '(?<!\.)\.$', ''
    $bracket = if ($marker.Stage -notin @('Configure', 'Download')) { '' }   # the stage text already says it
               elseif ($marker.ErrorId -and $reason) { " ($($marker.ErrorId): $reason)" }
               elseif ($marker.ErrorId) { " ($($marker.ErrorId))" }
               elseif ($reason) { " ($reason)" }
               else { '' }
    $verb    = if ($Operation -eq 'Export') { 'packaged' } else { 'published' }
    $nothing = if ($Operation -eq 'Export') { 'packaged or published' } else { 'published' }
    $message = "'$name' is marked not configured and cannot be ${verb}: $stageText$bracket. It would ship without its org template or installer configuration (PSADT's default dialogs, no org hooks). " +
               'Re-create it once the cause is fixed: package the app again (Invoke-Win32Toolkit or New-Win32ToolkitManualApp; in the menu, Package an app or Package a manual app), which replaces the folder. ' +
               "Nothing was $nothing. Marker: $($marker.Path)"
    throw [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new($message),
        'W32T.ProjectNotConfigured', [System.Management.Automation.ErrorCategory]::InvalidOperation, $ProjectPath)
}
