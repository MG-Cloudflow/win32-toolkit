# Invoke-Win32Toolkit

## SYNOPSIS
Packages an app from winget, from the download to an optional test, build and publish.

## SYNTAX

```
Invoke-Win32Toolkit [[-SearchTerm] <String>] [[-Id] <String>] [[-TemplateName] <String>] [-NewTemplate]
 [[-Architecture] <String>] [-Force] [[-BasePath] <String>] [-Reconfigure] [[-RunTest] <String[]>]
 [[-UpdateVersionsBack] <Int32>] [[-UpdateSpecificVersion] <String>] [-PackageIntune] [-PublishIntune]
 [-PublishUpdate] [[-DependsOn] <String[]>] [[-DependencyType] <String>] [[-InstallerType] <String>]
 [[-UpdateBaselineInstallerType] <String>] [-CaptureSiblingTechnologies] [[-ApplySiblingCapture] <String>]
 [-NoPublishPrompt] [<CommonParameters>]
```

## DESCRIPTION
Invoke-Win32Toolkit downloads the newest winget version of an app and creates a project with
PSAppDeployToolkit (PSADT) and your org template.
Then the install capture installs the
app on a test machine (Windows Sandbox or the Hyper-V test VM) and records what the package
needs.
It can also test, build and publish the .intunewin package.

Use it in scripts, or for options the menu does not offer, such as the update test in the same
run.
In the menu: Package an app from winget (search).

The project is \<base folder\>\Projects\\\<template\>\\\<project\>.
A new run for the same version
deletes and re-creates the project folder: copy your own code out first.
The capture also
writes SupportFiles\RequirementScript.ps1, a reference file that nothing runs.
win32-toolkit
never assigns an app.
You assign it in the Intune admin center.

It stops with an error whose ID starts with W32T.
when it cannot go on safely.
For example,
W32T.DownloadFailed means that the download failed.
A run that stops during the project setup
marks the project not configured.
Package the app again before you build or publish it.

## EXAMPLES

### EXAMPLE 1
```
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso'
```

This creates the project Git_x64_2.53.0 (your version will differ) with the Contoso org template
and runs the install capture.
It does not test, build or publish anything.

### EXAMPLE 2
```
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -RunTest InstallUninstall -PublishIntune
```

This creates the project, tests the install and uninstall, then builds the package and publishes
the install app to Intune, even when the test fails.

### EXAMPLE 3
```
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -InstallerType wix -CaptureSiblingTechnologies
```

This packages the WiX MSI of Notepad++ and keeps that technology for later versions.
It then
captures the vendor NSIS setup and lists the proposed prior-install rules, but writes no rule.

### EXAMPLE 4
```
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

This starts the template wizard for the org template Contoso, saves it and stops.

### EXAMPLE 5
```
$run = @{ Id = 'Git.Git'; Architecture = 'x64'; TemplateName = 'Contoso'; Force = $true }
$test = @{ RunTest = 'InstallUninstall', 'Update'; UpdateVersionsBack = 1 }
$r = Invoke-Win32Toolkit @run @test -PackageIntune -NoPublishPrompt
if ($r.Status -ne 'Succeeded') { $r.Problems }
```

This is the form for scripts: the parameters answer the questions of the command.
It runs both
tests (the update test starts from the previous version), builds the package and prints any
problems.

## PARAMETERS

### -SearchTerm
The text to search for in winget, for example 'git'.
The command lists the results, without
Microsoft Store apps, and asks which one to use.
Without -SearchTerm and -Id, it asks for a
search text.

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

### -Id
The exact winget ID of the app, for example 'Git.Git'.
The command then shows no list to
choose from, so use it in scripts.
For an older version than the one winget lists now, use
New-Win32ToolkitManualApp with your own installer.

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

### -TemplateName
The org template to use, for example 'Contoso'.
If no template has this name, the template
wizard starts and creates it.
Without -TemplateName, the command uses your only template, asks
when you have several, and starts the wizard when you have none.
In scripts, give an existing
name: a run that cannot ask stops with W32T.OrgTemplateChoiceNeeded.

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

### -NewTemplate
Starts the template wizard, saves the org template and stops: it packages no app and returns
nothing.
If the -TemplateName template exists, the wizard starts from the default values and
replaces it.
To change a template, use Org templates \> Edit a template in the menu.

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

### -Architecture
The processor architecture of the package: x64, x86 or arm64.
Without it, the command always
asks.
Set it in scripts.

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

### -Force
Replaces an existing project of the same app, architecture and version without asking, and
skips the offer of a newer PSADT version.
The menu always does this.
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

### -BasePath
The base folder for this command only.
It is not saved.
Default: your saved base folder (the
first run asks for it).

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

### -Reconfigure
Asks for the base folder again and saves your answer for later runs.
The toolkit does not move
your templates or projects to the new folder.
In the menu: Settings \> Change the base folder.

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
The tests to run after the install capture: InstallUninstall, Update or both, in the order you
give.
They run on your test machine: Windows Sandbox, or the Hyper-V test VM when you chose it
in Settings and it is ready.
The update test installs an old version first (the console calls
it the baseline), then this package over it.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -UpdateVersionsBack
For the update test: the old version, counted back from the packaged version (1 is the version
before it).
Use it in scripts, so that the run does not ask.
If you also give
-UpdateSpecificVersion, that one wins.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -UpdateSpecificVersion
For the update test: the exact old version, for example '2.52.0'.
Without this and
-UpdateVersionsBack, the command asks you to choose.
An unattended test, or a window that
cannot ask, uses the version before the packaged one, with a warning.

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

### -PackageIntune
Builds the .intunewin package in \<base folder\>\IntuneWin\\\<template\> after the capture and the
tests.
The command then asks 'Upload to Microsoft Intune now?
(Y/N)', and Y publishes the
install app only.
Add -NoPublishPrompt to skip the question.

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
Builds the package and publishes it to Intune as a new app, the install app.
A failed test only
warns.
It does not stop packaging or publishing.

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
Builds the package and publishes the update app: a second Intune app of the same version, only
for devices that already have the app.
With -PublishIntune, the install app is published
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

### -DependsOn
Apps that Intune must install before this app, for example
'winget:Microsoft.VCRedist.2015+.x64', 'project:\<template\>\\\<project\>' or 'intune:\<app ID\>'.
The
toolkit installs them first in the capture and the tests, and links them to the app when you
publish.
A wrong reference stops the command before the download, with
W32T.InvalidDependencyReference.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 9
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DependencyType
How Intune handles the apps of -DependsOn.
Default: autoInstall, so Intune installs them first.
Use detect if Intune should only check that they are already installed.
Command line only: the
menu does not offer this.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 10
Default value: autoInstall
Accept pipeline input: False
Accept wildcard characters: False
```

### -InstallerType
Pins the installer technology of the package, for example wix for a WiX MSI or nullsoft for an
NSIS setup.
Without it, the toolkit keeps the technology of an earlier version that you
published or pinned, or winget chooses.
If winget has no installer of the same kind (MSI, EXE
or MSIX) for this version, the command stops with W32T.InstallerVariantUnavailable.
More: https://win32toolkit.com/packaging/#installer-technology

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

### -UpdateBaselineInstallerType
For the update test: the installer technology of the old version.
Default: Auto, which uses the
other technology that winget ships for this app, or the packaged one when there is no other.
Both runs the test once for each technology, Packaged uses only the packaged one, and a type
such as nullsoft uses only its installer family.
More: https://win32toolkit.com/testing/#choose-the-installer-technology-of-the-old-version

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 12
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CaptureSiblingTechnologies
Also runs a sibling capture: it installs the other installer technologies of this app, such as
an NSIS setup, and records what they register.
It then proposes prior-install rules: what the
package does on devices with that other install.
Without a ready Hyper-V test VM, it runs in
Windows Sandbox, and its proposals can only become Block or Report rules.
More: https://win32toolkit.com/prior-installs/

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

### -ApplySiblingCapture
Default: None, which only lists the proposals of -CaptureSiblingTechnologies, each with the
command that applies it.
Block turns each clean proposal (high confidence, no flags) into a
Block rule, so the install fails on devices that have that other install.
There is no Enforce
value: each rule that removes the other install needs your own approval with
Set-Win32ToolkitPriorInstall.
More: https://win32toolkit.com/prior-installs/#apply-proposals-from-the-command-line

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 13
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -NoPublishPrompt
Skips the question 'Upload to Microsoft Intune now?
(Y/N)' after -PackageIntune, so the package
is built but not published.
Use it in scripts.
The menu always skips this question.

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

### Win32Toolkit.RunResult. A W32T error stops the command and returns nothing.
### Check Status: Succeeded, CompletedWithProblems or Failed. Problems has one sentence per problem.
### Tests has one Verdict per test: Passed, Failed or Inconclusive. IntuneWinPath is the package.
### Capture is Done, Problems or NotRun. Published lists the new Intune apps.
## NOTES
Needs: winget, and Windows Sandbox or a ready Hyper-V test VM.
Publishing also needs an Intune
sign-in and the Microsoft.Graph.Authentication module, which the command offers to install.

Time: the install capture usually takes 5 to 20 minutes.
The toolkit stops waiting after 30
minutes.

## RELATED LINKS

[https://win32toolkit.com/reference/Invoke-Win32Toolkit/](https://win32toolkit.com/reference/Invoke-Win32Toolkit/)

[https://win32toolkit.com/packaging/](https://win32toolkit.com/packaging/)

