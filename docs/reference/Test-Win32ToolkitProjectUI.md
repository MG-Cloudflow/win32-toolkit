# Test-Win32ToolkitProjectUI

## SYNOPSIS
Drives and validates a project's PSADT dialogs in the Hyper-V test VM - standalone, no operator.

## SYNTAX

```
Test-Win32ToolkitProjectUI [[-ProjectPath] <String>] [[-BasePath] <String>] [[-TemplateName] <String>]
 [-IncludeDefer] [-IncludeUninstall] [-CaptureHostConsole] [[-VMName] <String>] [[-Credential] <PSCredential>]
 [[-CheckpointName] <String>] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Runs the app's PSADT deploy in the local Hyper-V test VM (see New-Win32ToolkitTestVM) and drives
every dialog automatically with UI Automation: it launches the deploy in the interactive user
session, clicks Install (or Defer), screenshots each dialog, and records a structured state-log.
The results are copied back and validated against the org template the app was branded from -
company subtitle, deferrals, countdown, the progress and completion dialogs - producing a
PASS / WARN / FAIL / GAP report.
GAP checks are the visual ones UI Automation cannot read from a
window (accent color, the logo image, rendered language, the toast); judge those from the captured
PNGs in Sandbox\Shots.

Nothing here needs a human: no vmconnect window opens and no phase pauses.
This is the automated
counterpart of a hands-on "watch the PSADT GUI" run.
Hyper-V ONLY - Windows Sandbox has no
persistent interactive session to drive.

Each requested run reverts the VM to its clean checkpoint first, so Install, Defer, and Uninstall
runs are independent and never contaminate one another.

## EXAMPLES

### EXAMPLE 1
```
Test-Win32ToolkitProjectUI -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

### EXAMPLE 2
```
# Install + Defer + Uninstall, with a host-side console capture as well
Test-Win32ToolkitProjectUI -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -IncludeDefer -IncludeUninstall -CaptureHostConsole
```

## PARAMETERS

### -ProjectPath
Full path to the PSADT project folder (the one containing Invoke-AppDeployToolkit.ps1).
If omitted,
a numbered selection menu lists the projects under BasePath.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -BasePath
Root folder to scan for projects when ProjectPath is omitted.
Defaults to the registry-saved value.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -TemplateName
Org template to validate against.
If omitted, it is resolved from the project's parent folder (the
template segment) - pass this explicitly if that lookup can't find it.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeDefer
Also run a Defer pass: click Defer on the Welcome dialog and confirm the deferral path is offered.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeUninstall
Also run an Uninstall pass and validate the uninstall Welcome dialog.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -CaptureHostConsole
Additionally capture the VM console framebuffer from the host on a cadence (best-effort fallback
view into Sandbox\HostShots).
Off by default - the in-guest screenshots are the primary evidence.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -VMName
{{ Fill VMName Description }}

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Credential
{{ Fill Credential Description }}

```yaml
Type: PSCredential
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CheckpointName
{{ Fill CheckpointName Description }}

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: Clean-base
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction
{{ Fill ProgressAction Description }}

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### [PSCustomObject] with one entry per run (.Install, .Defer, .Uninstall), each the validation report.
## NOTES

## RELATED LINKS
