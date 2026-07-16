# Complete-Win32ToolkitManualApp

## SYNOPSIS
Finalises a scaffolded project: sandbox capture → uninstall automation → test/package/upload.

## SYNTAX

```
Complete-Win32ToolkitManualApp [-ProjectPath] <String> [[-RunTest] <String[]>] [-PackageIntune]
 [-PublishIntune] [-PublishUpdate] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
The second phase of the manual (non-winget) flow - run this after New-Win32ToolkitManualApp -Advanced
once you have written the Install logic in Invoke-AppDeployToolkit.ps1.
It runs the shared finalize
tail (Invoke-Win32ToolkitFinalize): launches the documentation sandbox (which installs via your
project's deploy script and captures the changes), derives the uninstall / requirement script /
processes-to-close, then optionally runs test scenarios, packages the .intunewin, and uploads to
Intune.

Works on any win32-toolkit project (manual or winget), so it can also re-finalise a project after
hand edits.

## EXAMPLES

### EXAMPLE 1
```
Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Legacy_CAD_x64_12.0' -RunTest InstallUninstall -PublishIntune
```

## PARAMETERS

### -ProjectPath
Full path to the PSADT project folder (must contain Invoke-AppDeployToolkit.ps1).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -RunTest
Sandbox test scenario(s) to run after documentation.
Only InstallUninstall applies to manual apps
(Update needs winget version history).

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -PackageIntune
Package the project into a .intunewin file.

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
Upload to Intune (implies -PackageIntune).

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
Also publish the update app (2nd app, same version, requirement-gated to installed devices).

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
