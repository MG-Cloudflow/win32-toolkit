# Export-Win32ToolkitIntuneWin

## SYNOPSIS
Packages a PSADT project into a .intunewin file for Intune deployment.

## SYNTAX

```
Export-Win32ToolkitIntuneWin [[-ProjectPath] <String>] [[-BasePath] <String>] [-PublishIntune] [-PublishUpdate]
 [-NoPublishPrompt] [[-PublishTimeoutSeconds] <Int32>] [-AllowLegacyScript]
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Works with the win32-toolkit template-grouped folder layout:

    \<BasePath\>\
      Projects\\\<Template\>\\\<App\>\    raw PSADT projects - never modified
      Staging\\\<Template\>\\\<App\>\     cleaned copy produced during packaging (kept for re-runs)
      IntuneWin\\\<Template\>\         finished .intunewin files

Steps performed:
1.
Resolves the target project (interactive picker if ProjectPath is omitted).
   Then refuses to package a deploy script win32-toolkit cannot vouch for
   (Assert-Win32ToolkitPackageReady -Stage Export), before anything is downloaded or copied: the
   script must exist and parse (also under Windows PowerShell 5.1, which Intune uses), carry the
   AppConfig loader written by win32-toolkit, use a supported PSAppDeployToolkit template layout
   and version that matches the bundled module, and Invoke-AppDeployToolkit.exe (the launcher
   Intune starts) must sit next to it, and every uninstall cleanup path must be a folder the
   app's own install created (no override).
Every problem is listed in one W32T.PackageNotReady error.
   A missing install tattoo, a project patched by win32-toolkit 1.1.6 or older, or a bundled
   prerelease PSAppDeployToolkit (e.g.
4.2.0-rc2) only warns.
2.
Locates or auto-downloads IntuneWinAppUtil.exe into the module's Tools\ folder
   (Authenticode-verified as Microsoft-signed before use).
3.
Copies the raw project into Staging\\\<Template\>\\\<ProjectName\>\, EXCLUDING everything that
   must never ship: Docs\, Examples\, Sandbox\ (test artifacts), Documentation\ (captures),
   and Intune\ (Publications.json - tenant + app ids that must never travel to a device).
   Re-copied on every run so Staging always reflects the latest raw project.
4.
Runs Optimize-Win32ToolkitProject against the Staging copy as a safety net - strips any
   surviving non-shipping folder (a locked Intune\ folder aborts packaging), root *.md and
   *.wsb files, the TargetedDocumentationScript, and empty dirs.
Projects\ stays untouched.
5.
Runs IntuneWinAppUtil.exe against the Staging copy, outputting to IntuneWin\\\<Template\>\.
6.
Renames the produced Invoke-AppDeployToolkit.intunewin → \<ProjectName\>.intunewin.
6b.
Warns (never stops) when the latest Update test failed, a technology switch was seen, or
   identity checks found something (for example winget also ships another installer technology
   for this app that no Update test has covered).
Shown once per run, also when Export publishes.

-WhatIf is a dry run: the gate (step 1) and the warnings (6b) run, nothing is downloaded, staged,
optimised or built (steps 2-6), an older .intunewin is not reported as created, and a requested
publish is only announced.
-Confirm asks once for the whole package build.

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

### EXAMPLE 7
```
# A hand-maintained deploy script that win32-toolkit never patched
Export-Win32ToolkitIntuneWin -ProjectPath $proj -NoPublishPrompt -AllowLegacyScript
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
A project with no detection rule (no install tattoo and no install
capture) is not published: the W32T.NoDetectionRule error is passed through unchanged.
To publish
such an app anyway, call Publish-Win32ToolkitIntuneApp -AllowNoDetectionRule on the package.

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

### -AllowLegacyScript
Package a deploy script that win32-toolkit never patched (no AppConfig loader), or whose PSADT
template layout or bundled module version this win32-toolkit version does not support, as-is: those
findings become warnings instead of stopping the export.
Projects patched by older win32-toolkit
versions do not need it.
A script that does not parse, or a missing Invoke-AppDeployToolkit.exe,
still stops the export.

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
