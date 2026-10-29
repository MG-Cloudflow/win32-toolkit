# Publish-Win32ToolkitIntuneApp

## SYNOPSIS
Uploads a .intunewin package to Intune as a new Win32 app.

## SYNTAX

```
Publish-Win32ToolkitIntuneApp [-IntuneWinPath] <String> [-ProjectPath] <String> [-AsUpdate]
 [[-UpdateNameSuffix] <String>] [[-TimeoutSeconds] <Int32>] [-AllowNoDetectionRule]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Publish-Win32ToolkitIntuneApp uploads a .intunewin package to Microsoft Intune as a new Win32
app.
It takes the app name, version and settings from the project.
Every publish creates a
new app and never changes an older one.

Use it for a package that you built before.
Export-Win32ToolkitIntuneWin -PublishIntune builds
and publishes in one step, so the package always matches the project.
In the menu: Work with
an existing project \> Publish to Intune.
The menu builds the package again before it publishes.

The command checks the project and shows warnings before it signs in.
These warnings appear
once per action: Export-Win32ToolkitIntuneWin -PublishIntune -PublishUpdate prints them once.
A warning also comes on every publish when the maximum run time
(IntuneDefaults.MaxRuntimeMinutes in the org template) is 30 minutes or less.
Keep it above 30
minutes: the uninstall stops an EXE uninstaller after 30 minutes.

If you are not signed in, it signs you in and saves the sign-in on disk.
Run
Connect-Win32ToolkitIntune first to keep the sign-in in this PowerShell window only.
If the
project has the tenant ID of its org template, the command refuses any other tenant before it
creates the app.
Without a tenant ID, it only warns.

In the project, the command writes only Intune\Publications.json, the record of the install
app.
With -AsUpdate, it writes SupportFiles\UpdateRequirement.ps1 instead.
win32-toolkit never
assigns an app.
You assign it in the Intune admin center.

If an error stops the command after the line "App created", an incomplete app stays in
Intune.
Delete it in the Intune admin center, fix the cause and publish again.

It stops with an error whose ID starts with W32T.
when it cannot publish safely, before it
signs in.
W32T.ProjectNotConfigured means that the project build stopped halfway: re-create
the project.
W32T.PackageNotReady means that the package does not match the prior-install
rules of the project: build it again.
W32T.NoDetectionRule means that no detection rule can
be built.

## EXAMPLES

### EXAMPLE 1
```
$file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project
```

This signs you in if needed and publishes the package as a new install app.
At the end, it
prints the app ID and a link to the app in the Intune admin center.

### EXAMPLE 2
```
$file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project -WhatIf
```

This runs every check that needs no sign-in and shows the warnings.
It does not sign in and
changes nothing.

### EXAMPLE 3
```
$file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project -AsUpdate
```

This publishes the update app, a second app whose name ends with " (Update)".
Intune installs
it only on devices that already have the app.

### EXAMPLE 4
```
$file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project -AllowNoDetectionRule
```

This publishes the app without a detection rule.
Add a detection rule in the Intune admin
center before you assign the app.

### EXAMPLE 5
```
Connect-Win32ToolkitIntune -Template 'Contoso' -Force -ErrorAction Stop
$file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
$app = Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project
$app.PortalUri
```

This is the form for scripts.
It signs in to the Contoso tenant first, so the sign-in stays in
this PowerShell window.
$app holds the app ID and the link to the app.

## PARAMETERS

### -IntuneWinPath
The package to upload: \<base folder\>\IntuneWin\\\<template\>\\\<project\>.intunewin.
It must be
built from the project in -ProjectPath.
Apart from prior-install rules, the command does not
check this.
If the command says that Detection.xml is missing, the file is not a valid package.

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

### -ProjectPath
The project that the package was built from: \<base folder\>\Projects\\\<template\>\\\<project\>.
Never give the Staging copy.
It has no install capture (the record of what the installer
changed) and no test results.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -AsUpdate
Publishes the update app: a second app of the same version, only for devices that already
have the app.
Its name ends with " (Update)".
The command stops if the project gives no sign
that the app is installed.
Such a sign is the install tattoo (a registry value that the
package writes), the MSI UpgradeCode or the app name.

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

### -UpdateNameSuffix
The text added to the name of the update app.
Default: " (Update)", with a space first.
Command line only: the menu and Export-Win32ToolkitIntuneWin always use the default.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: (Update)
Accept pipeline input: False
Accept wildcard characters: False
```

### -TimeoutSeconds
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
Position: 4
Default value: 300
Accept pipeline input: False
Accept wildcard characters: False
```

### -AllowNoDetectionRule
Publishes the app even if no detection rule can be built: the project has no install tattoo
and no usable install capture.
Add a detection rule in the Intune admin center before you
assign the app.
Use it only for per-user apps and some MSIX packages.
Command line only: the
menu does not offer this.

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

### An object with AppId, DisplayName, IsUpdateApp and PortalUri.
### PortalUri is the link to the app in the Intune admin center.
### With -WhatIf, or when an error stops the command, it returns nothing.
## NOTES
Needs: the Microsoft.Graph.Authentication module and an account that may create apps in
Intune.
In a script, run Connect-Win32ToolkitIntune -Force first to install the module.
Time:
usually a few minutes, longer for big packages.

## RELATED LINKS

[https://win32toolkit.com/reference/Publish-Win32ToolkitIntuneApp/](https://win32toolkit.com/reference/Publish-Win32ToolkitIntuneApp/)

[https://win32toolkit.com/publishing/](https://win32toolkit.com/publishing/)

[https://win32toolkit.com/intune-connection/](https://win32toolkit.com/intune-connection/)

