# Test-Win32ToolkitProject

## SYNOPSIS
Tests a project in Windows Sandbox or the Hyper-V test VM and records the result.

## SYNTAX

```
Test-Win32ToolkitProject [[-ProjectPath] <String>] [[-BasePath] <String>] [[-Scenario] <String>]
 [[-VersionsBack] <Int32>] [[-SpecificVersion] <String>] [-SkipRequirementCheck]
 [[-BaselineProjectPath] <String>] [[-BaselineProject] <String>] [[-BaselineInstallerType] <String>]
 [[-Backend] <String>] [-Unattended] [[-TestMode] <String>] [[-ProofEntryId] <String[]>]
 [[-SiblingInstallerType] <String[]>] [[-SiblingVersion] <String[]>] [[-SiblingCaptureVersionsBack] <Int32>]
 [-IncludeReportOnly] [[-SiblingCaptureCoverage] <Int32>] [[-SiblingCaptureMaxExtra] <Int32>]
 [[-SiblingArchitecture] <String>] [-Assisted] [[-SiblingProof] <String>]
 [<CommonParameters>]
```

## DESCRIPTION
Test-Win32ToolkitProject installs the package of a project in a test machine (Windows Sandbox
or the Hyper-V test VM), runs automatic checks and records the result.
The dependencies of the
app are installed first, and a failed dependency makes the test fail.

InstallUninstall installs the app, checks it and uninstalls it.
Update installs an older version
first, then your package over it.
SiblingCapture is a sibling capture: it installs the other
installer technologies of the app and records what they register, for prior-install rules.

Run a test before you publish.
In the menu: Work with an existing project \> choose your project
\> Run a test.
The menu always asks for the test machine.
For a sibling capture: Work with an
existing project \> choose your project \> Prior installs \> Capture the other installer
technologies.

By default you run an interactive test: it pauses so that you can check the app.
An unattended
test has no pause and, on the Hyper-V test VM, runs the package the way Intune does.

Before an unattended test on the Hyper-V test VM, the Intune-parity pre-check runs.
A
PSAppDeployToolkit (PSADT) 4.1 package with no processes to close and a welcome dialog that can
be deferred would wait 25 minutes.
The toolkit does not start such a test and records it as
not run.
Run it as an interactive test, or add the app's process to ProcessesToClose.

The result goes to Documentation\TestResults.json in the project, and the logs of each run to a
folder under Sandbox\Logs\Runs.
These folders never go into the package.
The command changes
nothing in Intune.
A failed test only warns.
It does not stop packaging or publishing.

It stops with an error whose ID starts with W32T.
when a test must not start or cannot be
trusted.
W32T.PriorInstallRefused means that a project with prior-install rules or
sibling-capture records cannot have an interactive test in Windows Sandbox.
Use -Backend HyperV
or -TestMode Unattended.
W32T.GuestTamper means that the test machine changed the project:
re-create it.

## EXAMPLES

### EXAMPLE 1
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Test-Win32ToolkitProject -ProjectPath $project -Scenario InstallUninstall
```

This installs and uninstalls Git on your default test machine.
By default it pauses so that you
can check the app.

### EXAMPLE 2
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -SpecificVersion '2.52.0'
```

This installs Git 2.52.0 from winget, then updates it with your package.

### EXAMPLE 3
```
$project = 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0'   # your project folder
$older = 'Contoso\Contoso_Reader_x64_3.1.0'   # the older project
Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -BaselineProject $older
```

This tests the update of an app that is not in winget, from your older project.

### EXAMPLE 4
```
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
Test-Win32ToolkitProject -ProjectPath $project -Scenario SiblingCapture
```

This captures the other installer technologies of Notepad++.
It writes proposals, never rules:
you approve them with Set-Win32ToolkitPriorInstall.

### EXAMPLE 5
```
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -Backend HyperV -Unattended
```

This is the proof run for Enforce prior-install rules: only a passed unattended Update test on
the Hyper-V test VM proves them.
A later change to the package or a newer failed Update test
takes the proof away.

### EXAMPLE 6
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
$ok = Test-Win32ToolkitProject -ProjectPath $project -Scenario InstallUninstall -Unattended
```

This is the form for scripts.
A failed test is not an error, so check $ok: it is $true, $false,
or $null when the test gave no result.

## PARAMETERS

### -ProjectPath
The project folder: \<base folder\>\Projects\\\<template\>\\\<project\>.
Without it, the command shows
a list of your projects.

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
The base folder for this command only, to list projects and to find -BaselineProject.
Default:
your saved base folder.

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

### -Scenario
The test to run.
Without it, the command asks you to choose InstallUninstall or Update.
SiblingCapture needs a winget project whose install capture has run.

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

### -VersionsBack
Update test only: installs the winget version that is this many versions before your package
(1 is the previous one).
Without it or -SpecificVersion, you choose from a list.
A test that
cannot ask uses 1, with a warning.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SpecificVersion
Update test only: the exact older winget version to install, for example '2.52.0'.
It wins over
-VersionsBack.

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

### -SkipRequirementCheck
Update test only: skips the check that the update app would find the old install.
A test with
this switch never proves an Enforce rule.

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

### -BaselineProjectPath
Update test only: the full path of an older project that the toolkit built.
The test installs
it as the old version instead of a winget download, and never changes it.
Use it for an app not
in winget.

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

### -BaselineProject
The same as -BaselineProjectPath, given as '\<template\>\\\<project\>' under \<base folder\>\Projects,
for example 'Contoso\Git_x64_2.52.0'.

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

### -BaselineInstallerType
Update test from winget only: the installer technology of the old version.
Default: Auto, the
other technology that winget offers (or your package's technology if there is none).
Both runs
one test for each technology.
Packaged uses only your package's technology, and a type such as
nullsoft uses only its installer family: an old version without it gives no result.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: Auto
Accept pipeline input: False
Accept wildcard characters: False
```

### -Backend
The test machine for this run.
Default: your TestBackend setting (Sandbox until you change it).
If the Hyper-V test VM is not ready, the test warns and uses Windows Sandbox, or stops if
W32T_HYPERV_VM is set.
A sibling capture uses the test VM whenever it is ready, else Windows
Sandbox, where its proposals can only become Block or Report rules.

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

### -Unattended
Runs the test with no pause, whatever your test mode settings say.
In Windows Sandbox, PSADT
runs silently.
On the Hyper-V test VM, the package runs as Intune runs it: as SYSTEM, from a
32-bit program.

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

### -TestMode
The test mode for this run only: it wins over the SandboxTestMode and HyperVTestMode settings.
The command refuses Interactive together with -Unattended.
A console that cannot answer prompts
always runs unattended.

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

### -ProofEntryId
Update test only: the IDs of the Enforce prior-install rules that this run checks, for example
nsis-x64.
They must be in one proof group: rules that one run can prove together.
Default: the
first group.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 11
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SiblingInstallerType
Sibling capture only: captures only these installer technologies.
Default: nullsoft, inno and
exe (the others need -IncludeReportOnly).
Command line only: the menu does not offer this.

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

### -SiblingVersion
Sibling capture only: captures exactly these versions.
Without it, the toolkit normally takes
the newest version and the oldest one from the last 12 months.
In the menu, Widen on a review
card captures one older version.

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

### -SiblingCaptureVersionsBack
Sibling capture only: the older capture is this many versions before the newest one (1 to 20).
Command line only: the menu does not offer this.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 14
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeReportOnly
Sibling capture only: also captures msi, wix, burn and msix, which the toolkit cannot remove
yet.
They never become proposals.
Command line only: the menu does not offer this.

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

### -SiblingCaptureCoverage
Sibling capture only: captures the newest version of each recent version line, such as 8.9 and
8.8.
The value is how many lines (1 to 10).
A rule then covers more of the versions that devices
may have.
Command line only: the menu does not offer this.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 15
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SiblingCaptureMaxExtra
Sibling capture only: the highest number of extra captures (0 to 10).
The toolkit runs them
only when a technology changed how it registers, to find the version where it changed.
Default: 4.
Command line only: the menu does not offer this.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 16
Default value: 4
Accept pipeline input: False
Accept wildcard characters: False
```

### -SiblingArchitecture
Sibling capture only: x86 captures the 32-bit installers of a 64-bit app.
Default: the
architecture of your package.
Command line only: the menu does not offer this.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 17
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Assisted
Sibling capture only: you install each other technology yourself in the VM window, for an
installer that cannot run silently.
It needs the Hyper-V test VM and a console that can answer
prompts, and its proposals can only become Block or Report rules.
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

### -SiblingProof
Update test only, for rules from a sibling capture: Floor tests the update from the oldest
captured version.
FloorAndNewest also tests it from the newest captured version: that run never
proves a rule, but its failure takes the proof away.
The menu always uses Floor.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 18
Default value: Floor
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### $true if the test passed, $false if it failed, else $null.
### A sibling capture: $true if it recorded something, $false if no capture worked, else $null.
### A W32T error stops the command, and other errors start with "Test-Win32ToolkitProject failed:".
## NOTES
Needs: Windows Sandbox turned on, or the Hyper-V test VM and an administrator session.
Only one
PowerShell window at a time can use the test VM.
Time: an unattended install and uninstall test
takes about 2 minutes in Windows Sandbox.
On the Hyper-V test VM it takes about 4 to 5 minutes
(depends on your PC).

## RELATED LINKS

[https://win32toolkit.com/reference/Test-Win32ToolkitProject/](https://win32toolkit.com/reference/Test-Win32ToolkitProject/)

[https://win32toolkit.com/testing/](https://win32toolkit.com/testing/)

[https://win32toolkit.com/prior-installs/](https://win32toolkit.com/prior-installs/)

