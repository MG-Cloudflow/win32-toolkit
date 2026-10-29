# New-Win32ToolkitManualApp

## SYNOPSIS
Creates a project from your own installer, for an app that is not in winget.

## SYNTAX

```
New-Win32ToolkitManualApp [[-Name] <String>] [[-Version] <String>] [[-Architecture] <String>]
 [[-SourcePath] <String>] [[-Publisher] <String>] [[-Description] <String>] [[-InformationUrl] <String>]
 [[-SilentArgs] <String>] [[-IconPath] <String>] [[-TemplateName] <String>] [[-BasePath] <String>]
 [-Reconfigure] [-Advanced] [-Force] [-Continue] [[-RunTest] <String[]>] [-PackageIntune] [-PublishIntune]
 [-PublishUpdate] [[-DependsOn] <String[]>] [[-DependencyType] <String>] [-NoPublishPrompt]
 [<CommonParameters>]
```

## DESCRIPTION
New-Win32ToolkitManualApp creates a project from an installer that you bring.
An MSI, an MSIX
or APPX package, or an EXE with silent switches becomes an Easy app: the toolkit writes the
install.
An EXE without silent switches, or any app with -Advanced, becomes an Advanced app:
you write the install code.
The console calls it a HARD APP.
In both modes, the toolkit
writes the uninstall.
Always give -Publisher: the toolkit needs it to detect the installed
version.

For an Easy app, -Continue, -RunTest, -PackageIntune, -PublishIntune and -PublishUpdate run
the install capture and the steps you ask for.
Without them, the command only creates the
project.
For an Advanced app, the command stops after it creates the project and ignores these
options: finish it with Complete-Win32ToolkitManualApp.
In the menu: Package a manual app (not
in winget).

The project is \<base folder\>\Projects\\\<template\>\\\<name\>_\<architecture\>_\<version\>.
If the
installer or the org template cannot be set up, the folder is kept.
The toolkit then refuses
to build or publish it until you create the app again.

It stops with an error whose ID starts with W32T.
when a -DependsOn reference is wrong
(W32T.InvalidDependencyReference).
It also stops when it cannot create the project
(W32T.ProjectCreationFailed), for example when you do not let it replace an existing project.

## EXAMPLES

### EXAMPLE 1
```
$app = @{
    Name         = 'Contoso Reader'
    Version      = '3.2.0'
    Architecture = 'x64'
    SourcePath   = 'C:\Installers\ContosoReader.msi'
    Publisher    = 'Contoso Ltd'
    TemplateName = 'Contoso'
}
New-Win32ToolkitManualApp @app -RunTest InstallUninstall -PackageIntune -NoPublishPrompt
```

This creates the Easy app project Contoso_Reader_x64_3.2.0, runs the install capture and an
install and uninstall test, and builds the package.
Nothing is published to Intune.

### EXAMPLE 2
```
$cad = @{
    Name         = 'Fabrikam CAD'
    Version      = '12.0'
    Architecture = 'x64'
    SourcePath   = 'C:\Installers\FabrikamCAD'
    Publisher    = 'Fabrikam'
    TemplateName = 'Contoso'
}
New-Win32ToolkitManualApp @cad -Advanced
```

This creates the Advanced app project Fabrikam_CAD_x64_12.0 from a folder and stops.
Write your
install code in Invoke-AppDeployToolkit.ps1, then run Complete-Win32ToolkitManualApp.

### EXAMPLE 3
```
New-Win32ToolkitManualApp @app -DependsOn 'winget:Microsoft.VCRedist.2015+.x64' -Continue
```

This creates Contoso Reader with the Visual C++ redistributable as a dependency ($app as in the
first example).
The install capture installs the redistributable first.
Publish the
redistributable with the toolkit before this app, so that Intune can link it.

### EXAMPLE 4
```
$r = New-Win32ToolkitManualApp @app -RunTest InstallUninstall -PackageIntune -NoPublishPrompt
if ($r.Status -eq 'Succeeded') {
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $r.IntuneWinPath -ProjectPath $r.ProjectPath
}
```

This is the form for scripts ($app as in the first example).
It publishes the package only when
the install capture and the test had no problems.
A W32T error stops the script.

## PARAMETERS

### -Name
The name of the app.
The project name starts with it, and Intune shows it as the app name.
If
you leave it out, the command asks for it.
For an MSI, Intune shows the project name instead,
for example Contoso_Reader_x64_3.2.0.
You can rename the app in the Intune admin center.

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
The app version, for example 3.2.0.
It is part of the project name.
With a publisher, the
detection rule checks for this exact version.
If you leave it out, the command asks for it.

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
The processor architecture of the app.
It is part of the project name, and Intune uses it as
the architecture of the app.
If you leave it out, the command asks for it (Enter means x64).

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
The installer file, or a folder with the installer and the files it needs.
The command copies
it into the project.
In a folder, the installer must be at the top level.
An MSI wins over an
EXE, and an EXE over an MSIX or APPX package.
If you leave it out, the command asks for it.

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
The publisher of the app.
Always give it: the command does not ask for it.
Without a
publisher, the package does not record the installed version.
Intune then uses a weaker
detection rule from the install capture, and shows the publisher as Unknown.

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
The description of the app in Intune.

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
A web page with information about the app, shown in Intune.

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
The silent switches of an EXE installer, for example /S.
With them, the EXE becomes an Easy
app.
Without them, it becomes an Advanced app.
The command ignores this value for an MSI, MSIX
or APPX package.

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
An image file for the app icon, for example a .png file.
The toolkit uses it instead of the
icon that the install capture finds.
If the file does not exist, the command ignores it without
a message.

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
The org template to use.
If you leave it out, the command uses your only org template, or asks
you to choose when there are several.
If the name does not exist yet, the org template wizard
starts and creates it.

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
The base folder for this command only.
Default: your saved base folder.
The value is not saved.

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
Asks for the base folder again and saves your answer as the new default.

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
Creates an Advanced app: you write the install code in Invoke-AppDeployToolkit.ps1, between
the '## win32-toolkit:Install:manual-install' block and the 'install-done' block.
The code runs
under Windows PowerShell 5.1 on devices and must stop with throw, never return.
It must not
assign PSADT variables such as $envTemp.

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
Replaces an existing project with the same name, architecture and version without asking.
This
deletes the old folder with its install code, install captures, test results, dependencies and
publication record.
Prior-install rules are kept.
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

### -Continue
Runs the install capture right after the project is created.
The capture records what the
installer changes, and the toolkit builds the uninstall steps from it.
Ignored for an Advanced
app.

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
The tests to run after the install capture.
Default: no test.
Use InstallUninstall: Update has
no older version to start from here and ends as Inconclusive.
To test an update, run
Test-Win32ToolkitProject -BaselineProject later.
Ignored for an Advanced app.

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
Builds the package after the install capture and the tests.
The command then asks whether to
upload it to Intune, unless you also use -PublishIntune, -PublishUpdate or -NoPublishPrompt.
Ignored for an Advanced app.

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
Ignored for an Advanced app.

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
runs the install capture and builds the package.
Ignored for an Advanced app.

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
The apps that Intune must install before this app: 'winget:\<id\>',
'project:\<template\>\\\<project\>' or 'intune:\<app ID\>'.
The install capture and the tests also
install winget and project dependencies first.
A wrong reference stops the command before
anything is created.

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
How Intune treats the dependencies.
Default: autoInstall (Intune installs them first).
With
detect, Intune only checks that a dependency is there and does not install this app when it is
missing.
Command line only: the menu does not offer this.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 14
Default value: autoInstall
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

### A result object. Check Status: Succeeded, CompletedWithProblems, Failed or Scaffolded.
### Scaffolded means: finish with Complete-Win32ToolkitManualApp. Problems lists what went wrong.
### A W32T error stops the command and returns nothing.
## NOTES
Needs: Windows Sandbox or the Hyper-V test VM for the install capture and the tests.
Time: the
install capture usually takes 5 to 20 minutes, and the toolkit stops waiting after 30 minutes.

## RELATED LINKS

[https://win32toolkit.com/reference/New-Win32ToolkitManualApp/](https://win32toolkit.com/reference/New-Win32ToolkitManualApp/)

[https://win32toolkit.com/manual-apps/](https://win32toolkit.com/manual-apps/)

[https://win32toolkit.com/dependencies/](https://win32toolkit.com/dependencies/)

