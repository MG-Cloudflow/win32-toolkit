# Sync-Win32ToolkitAppDependency

## SYNOPSIS
Pushes a project's declared dependencies onto the app it ALREADY published in Intune - without
re-publishing it.

## SYNTAX

```
Sync-Win32ToolkitAppDependency [-ProjectPath] <String> [[-AppId] <String>] [-ProgressAction <ActionPreference>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Publish-Win32ToolkitIntuneApp always creates a NEW app (it has no update path), so "just re-publish
it" is NOT a way to fix an app's dependencies: it would create a DUPLICATE app and leave the
original - the one that is actually assigned to your users - still without them.

This is the supported way to change the dependencies of an app that is already live:

    1.
edit the declaration   (Set-Win32ToolkitAppDependency / the TUI)
    2.
Sync-Win32ToolkitAppDependency -ProjectPath \<the project\>

The app id comes from the project's publication cache (\<ProjectPath\>\Intune\Publications.json,
written when it was published from this machine).
Declared dependencies are AUTHORITATIVE: the app's
dependency set is replaced, so removing a declaration here really does remove the relationship in
Intune.
Supersedence is preserved untouched (see Set-Win32ToolkitAppRelationships).

Typical use: you published an app whose dependency was not in the tenant yet (it warned and
published anyway).
You then package + publish the dependency - and run this to link them.

## EXAMPLES

### EXAMPLE 1
```
Set-Win32ToolkitAppDependency -ProjectPath $p -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'
Sync-Win32ToolkitAppDependency -ProjectPath $p
```

## PARAMETERS

### -ProjectPath
The project whose declared dependencies should be pushed to its published app.

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

### -AppId
Override the app to update (e.g.
it was published from another machine, so there is no local cache
entry - copy the id from the Intune portal).

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

### [int] the number of dependency relationships now attached.
## NOTES

## RELATED LINKS
