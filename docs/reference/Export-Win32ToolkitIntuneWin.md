# Export-Win32ToolkitIntuneWin

## SYNOPSIS
Packages a PSADT project into a .intunewin file for Intune deployment.

## SYNTAX

```
Export-Win32ToolkitIntuneWin [[-ProjectPath] <String>] [[-BasePath] <String>] [-PublishIntune] [-PublishUpdate]
 [-NoPublishPrompt] [[-PublishTimeoutSeconds] <Int32>] [-ProgressAction <ActionPreference>] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Works with the win32-toolkit 3-tier folder layout:

    \<BasePath\>\
      Projects\    raw PSADT projects - never modified
      Staging\     cleaned copy produced during packaging (kept for re-runs)
      IntuneWin\   finished .intunewin files

Steps performed:
1.
Resolves the target project (interactive picker if ProjectPath is omitted).
2.
Locates or auto-downloads IntuneWinAppUtil.exe into the module's Tools\ folder.
3.
Copies the raw project into Staging\\\<ProjectName\>\ (re-copies if already present
   so the Staging copy always reflects the latest raw project state).
4.
Runs Optimize-Win32ToolkitProject against the Staging copy - removes Docs\,
   Examples\, *.md, Sandbox\, Documentation\, and empty dirs.
   The original Projects\ folder is untouched.
5.
Runs IntuneWinAppUtil.exe against the Staging copy, outputting to IntuneWin\.
6.
Renames the produced Invoke-AppDeployToolkit.intunewin → \<ProjectName\>.intunewin.

## EXAMPLES

### EXAMPLE 1
```
Export-Win32ToolkitIntuneWin
```

### EXAMPLE 2
```
Export-Win32ToolkitIntuneWin -BasePath 'D:\Packaging'
```

### EXAMPLE 3
```
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0'
```

### EXAMPLE 4
```
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -PublishIntune
```

### EXAMPLE 5
```
# Publish both the install app and the requirement-gated update app
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -PublishIntune -PublishUpdate
```

### EXAMPLE 6
```
# A big package on a slow tenant - wait up to 15 minutes for the commit
Export-Win32ToolkitIntuneWin -ProjectPath $proj -PublishIntune -PublishTimeoutSeconds 900
```

## PARAMETERS

### -ProjectPath
Full path to the raw PSADT project folder under Projects\.
If omitted, an interactive numbered list is shown.

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
Root folder containing the Templates\, Projects\, Staging\, and IntuneWin\ tiers.
If omitted,
the registry-saved value is used (see Invoke-Win32Toolkit).

When -ProjectPath is supplied, an explicit -BasePath is honoured: Staging\ and IntuneWin\ are
written under it.
If -BasePath is omitted, the base is derived from the project path, which must
follow the \<BasePath\>\Projects\\\<Template\>\\\<ProjectName\> layout - a project stored anywhere else
is an error telling you to pass -BasePath (rather than silently creating Staging\ and IntuneWin\
in an unexpected place).

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

### -PublishIntune
After packaging, upload the .intunewin file directly to Microsoft Intune via Graph API.
Requires the Microsoft.Graph.Authentication module.
You will be prompted to authenticate
interactively on the first run.

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

### -PublishUpdate
Also (or instead of -PublishIntune) publish the update app - a 2nd Intune app of the same version
with an "app already installed" requirement rule.
Use with -PublishIntune to publish both.

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

### -NoPublishPrompt
Suppress the interactive "Upload to Intune now?" prompt (used by the TUI / automation).

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

### -PublishTimeoutSeconds
Passed straight to Publish-Win32ToolkitIntuneApp -TimeoutSeconds: how long to wait for Intune's two
asynchronous steps (Azure Storage SAS URI, file commit).
Omit to use that command's default (300 s).
Raise it for very large packages or a slow tenant.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
Default value: None
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

## NOTES

## RELATED LINKS
