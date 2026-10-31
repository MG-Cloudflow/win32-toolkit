# Set-Win32ToolkitAppDependency

## SYNOPSIS
Sets the apps that Intune must install before this app.

## SYNTAX

```
Set-Win32ToolkitAppDependency [-ProjectPath] <String> [[-DependsOn] <String[]>] [[-DependencyType] <String>]
 [-Clear] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Set-Win32ToolkitAppDependency saves the dependencies of a project: the apps that Intune
must install before this app, for example the Visual C++ redistributable.
New references
are added to the list that the project already has.
The command changes only
SupportFiles\AppConfig.json in the project: it installs nothing and changes nothing in
Intune.

The install capture and the tests install winget and project dependencies first on the
test machine.
When you publish, the toolkit links each dependency to the new install app.
The dependency must already be published in the same tenant, or the app is published
without it, with a warning.
A winget reference finds only an app that the toolkit
published from winget.
Intune uses the detection rule of each dependency, so a device that
already has it does not install it again.

After a change, run Complete-Win32ToolkitManualApp so that the install capture uses the
new list.
For an app that is already in Intune, also run Sync-Win32ToolkitAppDependency.
Do not publish the app again: that creates a new app.
In the menu: Work with an existing
project \> Dependencies.

It stops with the error W32T.InvalidDependencyReference, and writes nothing, when a
reference is wrong or names this project itself.

## EXAMPLES

### EXAMPLE 1
```
$project = 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0'   # your project folder
$vcredist = 'winget:Microsoft.VCRedist.2015+.x64'
Set-Win32ToolkitAppDependency -ProjectPath $project -DependsOn $vcredist
```

This adds the Visual C++ redistributable from winget to the project.
The install capture
and the tests now install it first.
If the app is already in Intune, also run
Sync-Win32ToolkitAppDependency.

### EXAMPLE 2
```
Set-Win32ToolkitAppDependency -ProjectPath $project -Clear -DependsOn $vcredist
```

This replaces the whole list with the Visual C++ redistributable ($project and $vcredist as
in the first example).
Use this form to remove one dependency.

### EXAMPLE 3
```
Set-Win32ToolkitAppDependency -ProjectPath $project -Clear
Sync-Win32ToolkitAppDependency -ProjectPath $project
```

This removes all dependencies from the project, then from its app in Intune ($project as
in the first example).
Supersedence in Intune is kept.

### EXAMPLE 4
```
$git = 'project:Contoso\Git_x64_2.53.0'
Set-Win32ToolkitAppDependency -ProjectPath $project -DependsOn $git -DependencyType detect
```

This adds Git, packaged with the toolkit, as a dependency that Intune only checks.
Intune
installs Contoso Reader only on devices that already have Git.

## PARAMETERS

### -ProjectPath
The project that needs the dependencies, for example
\<base folder\>\Projects\\\<template\>\\\<project\>.

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
One or more references: 'winget:\<id\>', 'project:\<template\>\\\<project\>' or
'intune:\<app ID\>'.
Without a prefix, a GUID counts as intune, text with a backslash as
project, and anything else as winget.
Use intune for an app that the toolkit did not
publish.
The test machine cannot install an intune dependency.
Needed unless you use
the -Clear switch.

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
How Intune treats the references of this call.
Default: autoInstall (Intune installs the
dependency first).
With detect, Intune only checks that the dependency is there and does
not install this app when it is missing.
Command line only: saving in the menu sets every
dependency back to autoInstall.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: autoInstall
Accept pipeline input: False
Accept wildcard characters: False
```

### -Clear
Removes all dependencies.
With -DependsOn, it replaces the whole list with the new
references.
There is no option to remove one dependency: use -Clear with -DependsOn and
give the ones to keep.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### The full list of dependencies that the project now has, with Source, Ref and DependencyType.
### With -WhatIf, the list that would be saved.
## NOTES

## RELATED LINKS

[https://win32toolkit.com/reference/Set-Win32ToolkitAppDependency/](https://win32toolkit.com/reference/Set-Win32ToolkitAppDependency/)

[https://win32toolkit.com/dependencies/](https://win32toolkit.com/dependencies/)

