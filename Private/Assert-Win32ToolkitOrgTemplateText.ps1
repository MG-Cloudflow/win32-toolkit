function Assert-Win32ToolkitOrgTemplateText {
    <#
    .SYNOPSIS
        Throws W32T.OrgTemplateInvalid when an org template carries text PSAppDeployToolkit would fail
        to expand on the device (D9); returns nothing when the template is valid.

    .DESCRIPTION
        Runs Test-Win32ToolkitOrgTemplateText on the whole template and, when it finds anything, throws
        ONE terminating error that lists every violation plus the fix. Used where a stored template
        enters the pipeline (Get-OrgTemplate) and again, as defence in depth, before a template is
        applied to a project (Apply-OrgTemplate). The wizard (New-OrgTemplate) validates each answer as
        it is typed instead, so a template it saves always passes.

        The error is an ErrorRecord with FullyQualifiedErrorId 'W32T.OrgTemplateInvalid' (spec C-1), so
        the pipeline's catch blocks re-throw it instead of turning it into a warning.

    .PARAMETER Template
        The org-template object to check.

    .PARAMETER Context
        Where the check runs, shown in the message (e.g. "template 'Contoso'" or 'apply'). Defaults to
        the template's name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Template,

        [string]$Context
    )

    $violations = @(Test-Win32ToolkitOrgTemplateText -Template $Template)
    if ($violations.Count -eq 0) { return }

    $name = ''
    if ($Template.PSObject.Properties['TemplateName']) { $name = [string]$Template.TemplateName }
    if (-not $name) { $name = '<name>' }
    if (-not $Context) { $Context = "template '$name'" }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('Org template text rejected ({0}): {1} problem(s) would make PSAppDeployToolkit fail every deployment that uses this template.' -f $Context, $violations.Count))
    foreach ($v in $violations) { $lines.Add('  - ' + $v.Message) }
    # Only the TUI edit path pre-fills the wizard. Invoke-Win32Toolkit -NewTemplate starts from the built-in
    # defaults and overwrites the file (tenant pin, hooks, Intune defaults...), so it is not offered as an edit.
    $lines.Add(('Fix: Show-Win32Toolkit > Org templates > Edit a template (pre-filled with the current values), or edit Templates\{0}.json under the base folder. Invoke-Win32Toolkit -NewTemplate -TemplateName ''{0}'' re-creates the template from the built-in defaults instead (re-enter the tenant and every other setting).' -f $name))

    throw [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new(($lines -join [Environment]::NewLine)), 'W32T.OrgTemplateInvalid',
        [System.Management.Automation.ErrorCategory]::InvalidData, $Template)
}
