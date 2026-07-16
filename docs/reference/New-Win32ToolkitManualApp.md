# New-Win32ToolkitManualApp

## SYNOPSIS
Creates a Win32 packaging project for an app that is NOT in winget.

## SYNTAX

```
New-Win32ToolkitManualApp [[-Name] <String>] [[-Version] <String>] [[-Architecture] <String>]
 [[-SourcePath] <String>] [[-Publisher] <String>] [[-Description] <String>] [[-InformationUrl] <String>]
 [[-SilentArgs] <String>] [[-IconPath] <String>] [[-TemplateName] <String>] [[-BasePath] <String>]
 [-Reconfigure] [-Advanced] [-Force] [-Continue] [[-RunTest] <String[]>] [-PackageIntune] [-PublishIntune]
 [-PublishUpdate] [[-DependsOn] <String[]>] [[-DependencyType] <String>] [-ProgressAction <ActionPreference>]
 [<CommonParameters>]
```

## DESCRIPTION
Scaffolds a PSADT v4 project from an operator-supplied installer, applies the org template, and
writes the data-driven AppConfig.json - the same downstream automation (sandbox capture →
uninstall, testing, packaging, upload) used by the winget flow then applies.

Input is hybrid: pass what you can as parameters; you are prompted for any missing required field
(Name, Version, Architecture, SourcePath).

Two modes:
- Easy  - provide -SilentArgs, or an MSI (Zero-Config), or an MSIX/APPX package (installed via
          Add-AppxPackage/provisioning, uninstalled by package identity): the install runs
          data-driven.
Add -Continue (or -RunTest/-PackageIntune/-PublishIntune) to finalise.
- Hard  - pass -Advanced (or an EXE with no -SilentArgs): the Install region of
          Invoke-AppDeployToolkit.ps1 is left for you to author.
The uninstall stays automated.
          Finish later with Complete-Win32ToolkitManualApp.

## EXAMPLES

### EXAMPLE 1
```
# Easy app, end to end
New-Win32ToolkitManualApp -Name 'Acme Tool' -Version '3.1.0' -Architecture x64 `
    -SourcePath 'C:\src\AcmeTool.exe' -SilentArgs '/S' -Publisher 'Acme' -TemplateName 'Contoso' `
    -Continue -RunTest InstallUninstall -PublishIntune
```

### EXAMPLE 2
```
# Hard app - scaffold, then finish after editing the Install region
New-Win32ToolkitManualApp -Name 'Legacy CAD' -Version '12.0' -Architecture x64 `
    -SourcePath 'C:\src\LegacyCAD\' -Advanced -TemplateName 'Contoso'
Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Legacy_CAD_x64_12.0' -RunTest InstallUninstall
```

## PARAMETERS

### -Name
Application display name (required; prompted if omitted).

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

### -Version
Application version (required; prompted if omitted).

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

### -Architecture
x64 | x86 | arm64 (required; prompted if omitted).

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

### -SourcePath
Installer file, or a folder of files, copied into the project's Files\ folder (required).

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

### -Publisher
Publisher / vendor (used for the PSADT AppVendor and the Intune app-shell publisher).

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

### -Description
App description (Intune app shell).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -InformationUrl
Information URL (Intune app shell).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SilentArgs
Silent-install switches.
Providing them selects the "easy" (data-driven) install.

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

### -IconPath
Optional local image copied to Assets\AppIcon.png.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 9
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -TemplateName
Org template to apply (under \<BasePath\>\Templates).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 10
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -BasePath
Base folder (registry-backed default; prompts on first run).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 11
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

### -Advanced
Hard app - leave the Install region for manual authoring.

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

### -Force
Overwrite an existing project folder of the same name without prompting.

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

### -Continue
Easy app - run the finalize phase (sandbox capture → uninstall → optional test/package/publish) inline.

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
Test scenario(s) to run during the finalize phase: 'InstallUninstall', 'Update', or both.
Implies
-Continue behavior for easy apps.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 12
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -PackageIntune
Package the project into a .intunewin during the finalize phase.

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
Upload the packaged app to Microsoft Intune during the finalize phase (implies packaging).

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
Also publish the UPDATE app (a second, requirement-gated Intune app of the same version).

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
Dependencies to declare: 'winget:\<Id\>', 'project:\<Template\>\\\<Name\>', or 'intune:\<AppGuid\>'
references.
Installed first in the test guest and related to the Intune app at publish time.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 13
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DependencyType
How Intune treats the declared dependencies: 'autoInstall' (default) or 'detect'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 14
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

### System.Management.Automation.PSObject
## NOTES

## RELATED LINKS
