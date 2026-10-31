# Sync-Win32ToolkitAppDependency

## SYNOPSIS
Updates the dependencies of an app that is already in Intune, without publishing it again.

## SYNTAX

```
Sync-Win32ToolkitAppDependency [-ProjectPath] <String> [[-AppId] <String>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Sync-Win32ToolkitAppDependency gives the Intune app of a project the dependencies that the
project declares now.
Use it after you change them with Set-Win32ToolkitAppDependency, or
after you publish a dependency that was missing when you published the app.
Do not publish
the app again: that creates a new app, and the assigned app keeps its old dependencies.
Command line only.

The command signs in to Intune when needed.
It uses the tenant pinned on the project, if
there is one.
If it signs you in, the sign-in is saved on disk: run
Connect-Win32ToolkitIntune first to keep it in this PowerShell window only.

The command finds the app, looks up each dependency and replaces the dependencies of the
app with the ones it found.
A dependency that it cannot find now is removed from the app.
Read the warnings, and run the command again when the cause is fixed.
Supersedence set in
Intune is kept.

The app is the one in the publication record of the project (Intune\Publications.json).
This is the app you last published from this PC to the tenant you are signed in to.

It stops with an error when there is no publication record and no -AppId.
It also stops
when the sign-in lands on another tenant than the one pinned on the project.

## EXAMPLES

### EXAMPLE 1
```
$project = 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0'   # your project folder
Sync-Win32ToolkitAppDependency -ProjectPath $project
```

This gives the Contoso Reader app in Intune the dependencies that the project declares now.
The app keeps its ID and its assignments.

### EXAMPLE 2
```
$vcredist = 'winget:Microsoft.VCRedist.2015+.x64'
Set-Win32ToolkitAppDependency -ProjectPath $project -DependsOn $vcredist
Sync-Win32ToolkitAppDependency -ProjectPath $project
```

This adds the Visual C++ redistributable to the project ($project as in the first example)
and links it to the app in Intune.
Publish the redistributable with the toolkit first:
Sync-Win32ToolkitAppDependency links only an app that is already in the tenant.

### EXAMPLE 3
```
$appId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'   # from the Intune admin center
Sync-Win32ToolkitAppDependency -ProjectPath $project -AppId $appId
```

This updates the app with the ID that you copied, for example an app published from
another PC ($project as in the first example).

### EXAMPLE 4
```
Sync-Win32ToolkitAppDependency -ProjectPath $project -WhatIf
```

This signs in and looks up the dependencies ($project as in the first example), but
changes nothing in Intune.

## PARAMETERS

### -ProjectPath
The project of the app, for example \<base folder\>\Projects\\\<template\>\\\<project\>.
The
command reads the dependencies and the publication record from it.
A project from
New-Win32ToolkitManualApp has no tenant pinned: the command then only warns and uses the
tenant you are signed in to.

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
The Intune app ID of the app to update, from the Intune admin center.
Default: the app in
the publication record of the project.
Use it when there is no record, for example after a
publish from another PC.
Also use it to update a copy of the app other than the one you
published last.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### The number of dependencies that the app now has in Intune.
### With -WhatIf, the number it would set.
## NOTES
Needs: the Microsoft.Graph.Authentication module, and an Intune admin role with the Relate
permission for mobile apps.
Time: seconds after the sign-in.

## RELATED LINKS

[https://win32toolkit.com/reference/Sync-Win32ToolkitAppDependency/](https://win32toolkit.com/reference/Sync-Win32ToolkitAppDependency/)

[https://win32toolkit.com/dependencies/](https://win32toolkit.com/dependencies/)

