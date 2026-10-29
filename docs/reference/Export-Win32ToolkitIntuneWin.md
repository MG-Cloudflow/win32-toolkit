# Export-Win32ToolkitIntuneWin

## SYNOPSIS
Checks a project and builds its .intunewin package, and can publish it to Intune.

## SYNTAX

```
Export-Win32ToolkitIntuneWin [[-ProjectPath] <String>] [[-BasePath] <String>] [-PublishIntune] [-PublishUpdate]
 [-NoPublishPrompt] [[-PublishTimeoutSeconds] <Int32>] [-AllowLegacyScript] [-PassThru]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Export-Win32ToolkitIntuneWin builds the .intunewin package of a project: the file that Intune
needs.
It first runs the package check, which refuses a project that is not safe to ship and
lists every problem with its fix.
Then it builds the package from a clean copy of the project,
without test files, Intune IDs or other data that must not reach devices.

Use it to get the package file, or to see the package check before you publish.
In the menu:
Work with an existing project \> Package to .intunewin.
Unless you give -PublishIntune,
-PublishUpdate or -NoPublishPrompt, the command asks "Upload to Microsoft Intune now?
(Y/N)"
after the build.
The answer Y publishes the install app only.

The package is \<base folder\>\IntuneWin\\\<template\>\\\<project\>.intunewin, and it replaces an older
one.
The clean copy stays in \<base folder\>\Staging\\\<template\>\\\<project\>.
Building never changes
the project.
The first build downloads IntuneWinAppUtil.exe, the Microsoft tool that builds
the package.
Every run checks the Microsoft signature of this tool.

After the build, the command shows warnings, for example about a failed test.
A failed test
only warns: it does not stop packaging or publishing.

It stops with an error whose ID starts with W32T.
when the project is not safe to build.
W32T.ProjectNotConfigured means that the project build stopped halfway: re-create the project.
W32T.PackageNotReady lists the problems that the package check found.

## EXAMPLES

### EXAMPLE 1
```
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

This builds C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin.
Then it asks if you want
to upload the package to Intune.

### EXAMPLE 2
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune
```

This builds the package and publishes it to Intune as the install app.

### EXAMPLE 3
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune -PublishUpdate
```

This builds the package and publishes the install app first.
Then it publishes the update app,
for devices that already have the app.

### EXAMPLE 4
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune -WhatIf
```

This runs the package check and shows the warnings.
It builds nothing and publishes nothing.

### EXAMPLE 5
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
$result = Export-Win32ToolkitIntuneWin -ProjectPath $project -NoPublishPrompt -PassThru
$result.IntuneWinPath
```

This is the form for scripts.
It builds the package without the upload question and shows the
path of the package.

## PARAMETERS

### -ProjectPath
The project folder: \<base folder\>\Projects\\\<template\>\\\<project\>.
Without it, the command shows
a numbered list of your projects and asks for a number.

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
The base folder for this command only.
It is not saved.
Default: the base folder that holds
the project, or your saved base folder when you give no -ProjectPath.
You need it when the
project is not in \<base folder\>\Projects\\\<template\>\\\<project\>.

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
After the build, publishes the package to Intune as the install app, with
Publish-Win32ToolkitIntuneApp.
You sign in if you are not signed in yet.
If no detection rule
can be built, it stops with W32T.NoDetectionRule and publishes nothing.
To publish such a
package without a rule, use Publish-Win32ToolkitIntuneApp -AllowNoDetectionRule.

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
After the build, publishes the update app: a second app of the same version that applies only
to devices that already have the app.
Add -PublishIntune to publish both, the install app
first.
If the toolkit has no sure way to see that the app is installed, it skips the update app
with a warning.

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
Removes the question "Upload to Microsoft Intune now?
(Y/N)" after the build.
Use it in
scripts that only build the package.

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
How many seconds to wait for Intune at two points of the upload: for the upload address, and
for the check of the uploaded file.
Default: 300 (from 5 to 7200).
Raise it, for example to
900, for a very large package or a slow tenant.
Command line only: the menu does not offer
this.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -AllowLegacyScript
Builds the package even if win32-toolkit did not prepare the deploy script, or does not
support its PSAppDeployToolkit version or layout.
These problems become warnings.
Projects
from win32-toolkit 1.1.6 or older do not need it.
It never overrides syntax errors, a missing
Invoke-AppDeployToolkit.exe, unsafe uninstall cleanup folders or other checks.
Command line
only: the menu does not offer this.

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

### -PassThru
Returns a summary object instead of nothing.
Use it in scripts to read the package path, the
published apps and the problems.

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

### Nothing by default.
### With -PassThru, one object with ProjectPath, IntuneWinPath, Published and Problems.
### Published holds the published apps.
### Problems lists what went wrong without stopping the command.
### An error stops the command and returns nothing.
## NOTES
Time: seconds to a few minutes to build.
A publish usually takes a few minutes, longer for big
packages.

## RELATED LINKS

[https://win32toolkit.com/reference/Export-Win32ToolkitIntuneWin/](https://win32toolkit.com/reference/Export-Win32ToolkitIntuneWin/)

[https://win32toolkit.com/build-intunewin/](https://win32toolkit.com/build-intunewin/)

[https://win32toolkit.com/publishing/](https://win32toolkit.com/publishing/)

