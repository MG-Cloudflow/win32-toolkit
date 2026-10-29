# Complete-Win32ToolkitManualApp

## SYNOPSIS
Runs the install capture of a project again, then the tests, build and publish you ask for.

## SYNTAX

```
Complete-Win32ToolkitManualApp [-ProjectPath] <String> [[-RunTest] <String[]>] [-PackageIntune]
 [-PublishIntune] [-PublishUpdate] [-AllowLegacyScript] [-NoPublishPrompt]
 [<CommonParameters>]
```

## DESCRIPTION
Complete-Win32ToolkitManualApp runs the install capture of a project on your test machine.
From
the new capture, it updates the uninstall steps, the processes to close and the requirement
script of the project.
Then it runs the tests, the build and the publish that you ask for.

Use it to finish an Advanced app after you wrote its install code.
Also use it after you
changed a project by hand or changed its dependencies.
It works on projects from winget too.
In
the menu: Work with an existing project \> Finalize / refresh, which runs the install capture
only.
Right after you create an Advanced app in the menu, Finish setup now runs this command
with your test, package and publish choices.

It never changes your install code.
First it checks the deploy script
(Invoke-AppDeployToolkit.ps1).
If the script has a syntax error, nothing runs.
If it uses a
PSAppDeployToolkit (PSADT) layout or version that the toolkit does not support, re-create the
project or add the -AllowLegacyScript switch.
Copy your install code out first, because
re-creating deletes the project folder.

It stops with an error whose ID starts with W32T.
when the deploy script cannot be used
(W32T.PackageNotReady).
It also stops when a dependency cannot be prepared for the test
machine (W32T.DependencyNotStaged).

## EXAMPLES

### EXAMPLE 1
```
$project = 'C:\Win32Apps\Projects\Contoso\Fabrikam_CAD_x64_12.0'   # your project folder
Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall
```

This finishes the Advanced app after you wrote its install code.
It runs the install capture
and an install and uninstall test, and does not build or publish anything.

### EXAMPLE 2
```
Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall -PublishIntune
```

This also builds the package and publishes it to Intune as a new install app ($project as in
the first example).
A failed test does not stop the publish.

### EXAMPLE 3
```
Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

This runs the install capture again for a project from winget, for example after you changed
its dependencies.
It updates the uninstall steps and runs no test.

### EXAMPLE 4
```
$project = 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0'   # your project folder
$old = 'Contoso\Contoso_Reader_x64_3.1.0'   # the older project you packaged before
Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall
Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -BaselineProject $old
```

This tests an app that is not in winget, then tests an update from the older version 3.1.0.
Complete-Win32ToolkitManualApp -RunTest Update cannot do this for such an app.

## PARAMETERS

### -ProjectPath
The project folder, for example \<base folder\>\Projects\\\<template\>\\\<project\>.
It must contain
Invoke-AppDeployToolkit.ps1.
The command finds project dependencies under your saved base
folder, because it has no -BasePath.

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
The tests to run after the install capture.
Default: no test.
For an app that is not in winget,
use InstallUninstall only: Update has no older winget version to start from and ends as
Inconclusive.
To test an update of such an app, use Test-Win32ToolkitProject -BaselineProject.

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
Builds the package after the install capture and the tests.
The command then asks whether to
upload it to Intune, unless you also use -PublishIntune, -PublishUpdate or -NoPublishPrompt.

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
Builds the package and publishes it to Intune as a new install app.
You sign in to Intune if
needed.
A failed test does not stop the publish.

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
Publishes the update app: a second Intune app of the same version that installs only on
devices that already have the app.
Add -PublishIntune to publish the install app too.
This also
builds the package.

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

### -AllowLegacyScript
Accepts a deploy script that the toolkit never changed, or whose PSADT layout or version it
does not support, and uses it as it is.
A script with a syntax error still stops the command.
Projects from win32-toolkit 1.1.6 or older do not need it.
Command line only: the menu
does not offer this.

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
Skips the question 'Upload to Microsoft Intune now?
(Y/N)' after -PackageIntune builds the
package.
Use it in scripts.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### A result object. Check Status: Succeeded, CompletedWithProblems or Failed.
### Problems lists what went wrong. Tests gives each test result: Passed, Failed or Inconclusive.
### A W32T error stops the command and returns nothing.
## NOTES
Needs: Windows Sandbox or the Hyper-V test VM.
Time: the install capture usually takes 5 to 20
minutes, and the toolkit stops waiting after 30 minutes.

## RELATED LINKS

[https://win32toolkit.com/reference/Complete-Win32ToolkitManualApp/](https://win32toolkit.com/reference/Complete-Win32ToolkitManualApp/)

[https://win32toolkit.com/projects/](https://win32toolkit.com/projects/)

[https://win32toolkit.com/manual-apps/](https://win32toolkit.com/manual-apps/)

