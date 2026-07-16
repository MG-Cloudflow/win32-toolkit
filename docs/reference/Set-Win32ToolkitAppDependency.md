# Set-Win32ToolkitAppDependency

## SYNOPSIS
Declares which apps must be installed BEFORE this one (Intune app dependencies).

## SYNTAX

```
Set-Win32ToolkitAppDependency [-ProjectPath] <String> [[-DependsOn] <String[]>] [[-DependencyType] <String>]
 [-Clear] [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Writes the \`Dependencies\` section of the project's SupportFiles\AppConfig.json.
At publish time each
declaration is resolved to a real Intune app id and attached to the published app as a
\`mobileAppDependency\` relationship, so the Intune Management Extension installs the dependency FIRST
(the classic case: a Visual C++ redistributable).

Dependencies are stored as DATA (winget id / project name / Intune app id) and are never spliced
into a generated script.
Nothing is installed or published by this command - it only declares.

Because Intune honours the DEPENDENCY app's own detection rule, an already-present dependency is
skipped on the device automatically; there is no separate "skip if installed" setting.

NOTE: a dependency must exist in the tenant as a published Win32 app before the relationship can be
created.
If it does not, publishing warns and continues (the app still publishes, just without that
relationship) - package and publish the dependency, then re-publish this app to attach it.

## EXAMPLES

### EXAMPLE 1
```
Set-Win32ToolkitAppDependency -ProjectPath $p -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'
```

### EXAMPLE 2
```
Set-Win32ToolkitAppDependency -ProjectPath $p -DependsOn 'project:Contoso\VCRedist_x64_14.38'
```

## PARAMETERS

### -ProjectPath
The PSADT project that HAS the dependencies.

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

### -DependsOn
One or more references.
Accepts 'winget:\<id\>', 'project:\<Template\>\\\<Name\>', 'intune:\<guid\>', or a
bare string (a GUID -\> intune, one containing '\' -\> project, otherwise winget).

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

### -DependencyType
'autoInstall' (default) installs the dependency first.
'detect' ONLY detects it - if it is absent
the parent install is NOT attempted at all, so use it deliberately.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: AutoInstall
Accept pipeline input: False
Accept wildcard characters: False
```

### -Clear
Remove all declared dependencies (alone, or before adding the supplied set).

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

### PSCustomObject[] - the normalized dependency list now stored in AppConfig.json.
## NOTES

## RELATED LINKS
