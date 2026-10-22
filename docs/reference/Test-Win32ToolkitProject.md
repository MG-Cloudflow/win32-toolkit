# Test-Win32ToolkitProject

## SYNOPSIS
Tests a PSADT project in a disposable guest: Windows Sandbox or the Hyper-V test VM.

## SYNTAX

```
Test-Win32ToolkitProject [[-ProjectPath] <String>] [[-BasePath] <String>] [[-Scenario] <String>]
 [[-VersionsBack] <Int32>] [[-SpecificVersion] <String>] [-SkipRequirementCheck]
 [[-BaselineProjectPath] <String>] [[-BaselineProject] <String>] [[-BaselineInstallerType] <String>]
 [[-Backend] <String>] [-Unattended] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Runs a chosen test scenario against a PSADT V4 project in the configured test backend:
Windows Sandbox (default) or the local Hyper-V test VM (see New-Win32ToolkitTestVM).
If no
ProjectPath is supplied, an interactive menu lists all PSADT projects found under BasePath.

Tests run WATCHED by default (a countdown/pause gives you a verification window) or
UNATTENDED via -Unattended / the SandboxTestMode & HyperVTestMode config values (back-to-back,
no operator needed: under Sandbox PSADT runs -DeployMode Silent and the guest shuts itself down
afterwards so chained runs proceed; under Hyper-V the install, uninstall and update run as the
Intune-parity phase).
Watched runs use PSADT's Auto mode: on PSADT 4.2 the dialogs appear only
when one of the app's listed processes is running (otherwise the run is silent); on 4.1.x Auto
shows PSADT's dialogs.
(The watched Hyper-V GUI phases force -DeployMode Interactive.)

Process isolation: every PSADT package runs in its OWN Windows PowerShell process (PSADT 4.2
refuses a second copy of its module in one process, and 4.1 and 4.2 cannot share one).
Each
declared 'project:' dependency is started by Sandbox\InstallDependencies.ps1, which stops at the
first failing dependency and exits with its exit code.
A failed dependency stops the test and it
reports Failed (assertion DependenciesInstalled): the app is not installed, as Intune would not
install it either.
The app, an Update baseline project and the
update run through the guest runner Sandbox\Invoke-PsadtPackage.ps1, which appends the exact exit
code of each of its runs to Sandbox\Logs\PsadtExitCodes.log; those codes are printed after the run.

Run logs: every run, and each run of -BaselineInstallerType Both, keeps its own copy of its logs (the
assertion log, the Add/Remove Programs snapshots, its PsadtExitCodes.log lines and the PSADT and MSI
logs) in a folder under Sandbox\Logs\Runs named after its start time, its scenario and, for an Update
run, the old version's installer family, for example Sandbox\Logs\Runs\20261020-221500_Update_exe.
Its Documentation\TestResults.json record names that folder (LogFolder).
The files directly in
Sandbox\Logs gather the logs of every run: each run overwrites the files it writes (and first clears
its own scenario's assertion log), while files that only another run wrote stay there, for example
UpdateAssertions.log after an InstallUninstall run, or the log of a dependency or an earlier version.
A run's exact set of logs is its folder under Sandbox\Logs\Runs.

The function is scenario-driven: new test types can be added as additional switch cases
without changing the overall structure.

## EXAMPLES

### EXAMPLE 1
```
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario Update -VersionsBack 1 -SkipRequirementCheck
```

### EXAMPLE 2
```
# Baseline with a previous toolkit package (tattoo-overwrite test), by full path
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.55.0' -Scenario Update -BaselineProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

### EXAMPLE 3
```
# Same, by friendly reference (resolved under BasePath\Projects\)
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.55.0' -Scenario Update -BaselineProject 'Contoso\Git_x64_2.53.0'
```

### EXAMPLE 4
```
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

### EXAMPLE 5
```
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario InstallUninstall
```

### EXAMPLE 6
```
# Unattended Intune-parity run (published command line, 32-bit parent, SYSTEM), no operator needed - ideal for automation
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario InstallUninstall -Backend HyperV -Unattended
```

### EXAMPLE 7
```
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario Update -SpecificVersion '2.47.0'
```

### EXAMPLE 8
```
Test-Win32ToolkitProject -BasePath 'D:\Packaging' -Scenario Update
```

### EXAMPLE 9
```
# One Update run per installer technology winget ships (e.g. the vendor EXE and the MSI), each recorded separately
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1' -Scenario Update -VersionsBack 1 -BaselineInstallerType Both
```

### EXAMPLE 10
```
# Pin the old version to the vendor EXE (NSIS) technology
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1' -Scenario Update -SpecificVersion '8.8.9' -BaselineInstallerType nullsoft
```

## PARAMETERS

### -ProjectPath
Full path to the PSADT project folder (the folder that contains
Invoke-AppDeployToolkit.ps1).
If omitted, a numbered selection menu is shown.

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
Root folder to scan for PSADT projects when ProjectPath is not provided.
If omitted, the
registry-saved value is used (see Invoke-Win32Toolkit).

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
The test scenario to execute.
If omitted, an interactive menu is shown.
- InstallUninstall : Install → 2-minute countdown → Uninstall
- Update           : Install an older baseline → assert the update-app requirement rule detects
                     it → 2-minute countdown → run the PSADT update → assert the requirement is
                     still met and the install tattoo holds the new version.
Assertion results
                     stream back to the host (Sandbox\Logs\UpdateAssertions.log) and the command
                     reports a real PASS/FAIL verdict.

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
Update scenario only.
Automatically selects the version that is X positions older
than the currently packaged version (e.g.
1 = the immediately previous release).
Mutually exclusive intent with SpecificVersion; SpecificVersion takes priority.
When neither is given, an interactive run shows a list of older versions to pick from; an unattended
run (-Unattended, or the SandboxTestMode / HyperVTestMode config value) or a host that cannot prompt
(a service, redirected input, or a console started with pwsh -NonInteractive) uses the previous
version (as -VersionsBack 1) and says so in a warning.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -SpecificVersion
Update scenario only.
Installs this exact version as the baseline.
Overrides
VersionsBack if both are supplied.

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
Update scenario only.
Skip generating/running the update-app requirement script in the sandbox
(its assertions report SKIP); the tattoo/detection assertion still runs.
Use when the project
has no usable requirement rule yet or you only want the plain install-over-old check.

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
Update scenario only.
Install a PREVIOUS toolkit package (this folder) as the baseline instead of
downloading the old vendor installer - exercises the tattoo-overwrite path (old tattoo → new
tattoo) and works for manual (non-winget) projects.
Mutually exclusive with -VersionsBack /
-SpecificVersion.
The baseline project is mapped READ-ONLY (its raw copy is never modified).

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
Update scenario only.
Same as -BaselineProjectPath but by FRIENDLY reference: '\<Template\>\\\<Name\>'
(or 'project:\<Template\>\\\<Name\>'), resolved to \<BasePath\>\Projects\\\<Template\>\\\<Name\> - exactly how a
'project:' dependency is referenced, so you don't type the full path.
Mutually exclusive with
-BaselineProjectPath / -VersionsBack / -SpecificVersion.

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
Update scenario, winget baseline only: the installer technology the old-version baseline must use.
The baseline download always pins an installer type (never an unpinned retry) and never a locale.
The resolved technology is printed as 'Baseline technology : ...' before the version is picked.
- Auto (default): the other installer technology winget ships for this app, when there is one (read
  from Documentation\IdentityDelta.json, written on first use), so an MSI package is tested over the
  vendor EXE install that devices may already have; otherwise the packaged one.
  When the chosen version does not ship that technology, the run falls back to the packaged one with a
  warning and records UsedFallback (such a run cannot show a technology switch).
- Both: one Update run per technology (the packaged one, then each other one winget ships) at the same
  version, each with its own verdict and TestResults.json record.
  Returns $false when a run failed, $null when a run had no verdict, else $true.
- Packaged: the packaged installer technology only.
- msi, wix, burn, nullsoft, inno, exe, msix: exactly that technology family, no fallback.
A pinned scope (machine or user) is only a preference: when the version has no installer of that
scope, winget's choice of scope is used and ScopeRelaxed is recorded.
When the version has no installer of the required technology, the run records an Inconclusive result
(Baseline.Unavailable) and returns $null.
When an old install of ANOTHER technology is still registered after the update, an ID-TECH-SWITCH
warning names it.
Not valid with -BaselineProject / -BaselineProjectPath (that package has its own technology).

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
Which test backend to use for this run: 'Sandbox' (Windows Sandbox) or 'HyperV' (the local
Hyper-V test VM over PowerShell Direct).
Omit to use the configured default (the TestBackend
config value - Sandbox unless HyperV is configured AND ready; an unready HyperV falls back to
Sandbox with a warning).

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
Run back-to-back on either backend with no countdown or pause; under Sandbox the guest shuts
itself down afterwards so chained runs proceed unaided.
The default is
watched/interactive.
Overrides the SandboxTestMode / HyperVTestMode config values; on a
non-interactive host Unattended is auto-selected with a warning.
Note the context difference:
Sandbox-unattended runs the package -DeployMode Silent as the sandbox admin user, while
HyperV-unattended runs an INTUNE-PARITY phase for install, uninstall and update: the exact
published command line (Invoke-AppDeployToolkit.exe -DeploymentType Install|Uninstall, no
-DeployMode) from a 32-bit cmd.exe parent, as SYSTEM, in the package folder - the way the Intune
Management Extension launches it - with the exit code checked (0, 1707, 3010, 1641 = success).
Their results are not equivalent evidence.
The Intune-parity uninstall may run 35 minutes, longer than the device's 30-minute limit for an
EXE uninstaller, so a hung uninstaller ends with exit code 69113 as on a device.
The run's TestResults.json record says how each Intune-parity phase that failed ended: its Notes
name the phase and its exit code, and say what 69113 (the app's own uninstaller was still running
at the device's 30-minute limit and was stopped) and 1460 (the test's own limit for the phase was
reached) mean.
A HyperV-unattended run of a PSADT 4.1 package with no processes to close and a deferrable welcome
is not started while a user is signed in to the VM, which the toolkit's VM always is (it would wait
on the dialog until the 25-minute limit): it is recorded as Inconclusive (not run) with the reason.
Run it watched, or list the app's process in ProcessesToClose.

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

## NOTES

## RELATED LINKS
