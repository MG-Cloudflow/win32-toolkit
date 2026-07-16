# Invoke-Win32Toolkit

## SYNOPSIS
End-to-end Win32 app packaging automation.

## SYNTAX

```
Invoke-Win32Toolkit [[-SearchTerm] <String>] [[-Id] <String>] [[-TemplateName] <String>] [-NewTemplate]
 [[-Architecture] <String>] [-Force] [[-BasePath] <String>] [-Reconfigure] [[-RunTest] <String[]>]
 [[-UpdateVersionsBack] <Int32>] [[-UpdateSpecificVersion] <String>] [-PackageIntune] [-PublishIntune]
 [-PublishUpdate] [[-DependsOn] <String[]>] [[-DependencyType] <String>] [-ProgressAction <ActionPreference>]
 [<CommonParameters>]
```

## DESCRIPTION
Searches Winget for an application, downloads it, creates a PSADT V4 project,
configures the installer, generates Intune requirement scripts, and launches
a Windows Sandbox session for targeted installation documentation.

## EXAMPLES

### EXAMPLE 1
```
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force
```

### EXAMPLE 2
```
Invoke-Win32Toolkit -SearchTerm 'visual studio code' -BasePath 'D:\Packaging'
```

### EXAMPLE 3
```
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

### EXAMPLE 4
```
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune -PublishIntune
```

### EXAMPLE 5
```
# Fully scripted pipeline incl. both tests; the Update baseline is the previous release
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -RunTest InstallUninstall, Update -UpdateVersionsBack 1 -PackageIntune
```

## PARAMETERS

### -SearchTerm
Term to search for in the Winget repository.

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

### -Id
Winget package ID to use directly (skips search).
Example: 'Git.Git'

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
Name of the org template to load/create.
Skips the interactive template picker.
If the template does not exist yet, the wizard is pre-filled with this name.

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

### -NewTemplate
Run the org template wizard, save the template, and exit without packaging any app.

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

### -Architecture
Architecture to use for download and project creation (x64, x86, arm64).
Skips the interactive architecture selection menu.

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

### -Force
Skip the PSGallery update prompt and the project overwrite prompt.
Useful for unattended / automated runs.

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

### -BasePath
Base folder for all output (Templates, Projects, Staging, IntuneWin).
If omitted, the value
saved in the registry (HKCU:\Software\CloudFlow\win32-toolkit) is used; on first run you are
prompted for it and the choice is saved.
An explicit value overrides but is not persisted.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Reconfigure
Re-prompt for the base folder and save the new value to the registry, ignoring any stored value.

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

### -RunTest
Test scenario(s) to run right after the project is built and documented: 'InstallUninstall',
'Update', or both (array - scenarios run in the order given).
Each runs in the configured test
backend (Windows Sandbox by default, Hyper-V when configured and ready).
A failed scenario is
reported with a warning but does not stop packaging/publishing.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -UpdateVersionsBack
For -RunTest Update: automatically use the version N releases older than the packaged one as the
update baseline (1 = the immediately previous release), so a scripted pipeline never blocks on
the interactive version picker.
Ignored when -UpdateSpecificVersion is also supplied.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -UpdateSpecificVersion
For -RunTest Update: use this exact older version as the update baseline.
Takes precedence over
-UpdateVersionsBack when both are supplied.
Omit both to pick interactively.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -PackageIntune
After creating the project, package it into a .intunewin file using IntuneWinAppUtil.exe.

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

### -PublishIntune
After packaging, upload the .intunewin file to Microsoft Intune via Graph API.
Implies -PackageIntune.
Requires the Microsoft.Graph.Authentication module.

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
Also publish the UPDATE app: a second Intune app of the same version whose requirement rule makes
it applicable only to devices that already have the app installed.
Implies packaging.

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

### -DependsOn
Dependencies to declare for this app before packaging: 'winget:\<Id\>', 'project:\<Template\>\\\<Name\>',
or 'intune:\<AppGuid\>' references (array).
Declared dependencies install first in the test guest
and are related to the Intune app at publish time.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 9
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DependencyType
How Intune should treat the declared dependencies: 'autoInstall' (default) installs them
automatically; 'detect' only requires their presence.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 10
Default value: AutoInstall
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
