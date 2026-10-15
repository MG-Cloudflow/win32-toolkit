# Test-Win32ToolkitProject

## SYNOPSIS
Tests a PSADT project in a disposable guest: Windows Sandbox or the Hyper-V test VM.

## SYNTAX

```
Test-Win32ToolkitProject [[-ProjectPath] <String>] [[-BasePath] <String>] [[-Scenario] <String>]
 [[-VersionsBack] <Int32>] [[-SpecificVersion] <String>] [-SkipRequirementCheck]
 [[-BaselineProjectPath] <String>] [[-BaselineProject] <String>] [[-Backend] <String>] [-Unattended]
 [-ProgressAction <ActionPreference>] [<CommonParameters>]
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
The app, an Update baseline project and the
update run through the guest runner Sandbox\Invoke-PsadtPackage.ps1, which appends the exact exit
code of each of its runs to Sandbox\Logs\PsadtExitCodes.log; those codes are printed after the run.

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
Position: 8
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
