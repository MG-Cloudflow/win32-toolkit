# Set-Win32ToolkitPriorInstall

## SYNOPSIS
Lists, adds, changes or removes the prior-install rules of a project.

## SYNTAX

### List (Default)
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> [-WhatIf] [-Confirm]
 [<CommonParameters>]
```

### SetMode
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Mode <String> -Id <String[]>
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

### FromSiblingCapture
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Mode <String> [-FromSiblingCapture]
 [-ProposalId <String[]>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

### FromUpdateTest
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Mode <String> [-VersionMin <String>]
 [-VersionMax <String>] [-ProcessName <String[]>] [-Id <String[]>] [-FromUpdateTest] [-CandidateKey <String>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Manual
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Mode <String> -Key <String> -View <String>
 -Publisher <String> [-DisplayName <String>] [-DisplayNameTemplate <String>] -VersionMin <String>
 -VersionMax <String> [-UninstallerType <String>] [-UninstallerFileName <String>] [-InstallDir <String>]
 [-MainExe <String>] [-ProcessName <String[]>] [-UninstallerSigner <String>] [-Id <String[]>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Remove
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Remove <String[]>
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Waive
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Waive <String> -Target <String> -Reason <String>
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Acknowledge
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Acknowledge <String> -Target <String> -Reason <String>
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Revoke
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Revoke <String> -Target <String>
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Set-Win32ToolkitPriorInstall shows and changes the prior-install rules of a project.
A prior
install is the same app, installed on a device with another installer technology.
For
example, a device has the vendor's NSIS setup of Notepad++, and your package installs the
MSI.
A rule names that install exactly and says what the package does with it: Block,
Enforce or Report (see -Mode).

With only -ProjectPath, the command lists the rules and writes nothing.
Use it after a
sibling capture (a capture of the other installer technologies of the app) or a failed
Update test.
In the menu: Work with an existing project \> choose your project \> Prior
installs.
Typed rules, waivers and -Revoke are command line only.

Before every change, the command shows what it will do and asks you to confirm.
In scripts,
add -Confirm:$false.
It writes only SupportFiles\AppConfig.json and
Documentation\PriorInstallDecisions.json.
The second file never goes into the package.
The
command never changes the deploy script and never writes to Intune.
Devices get a rule
change after you build the package again (Export-Win32ToolkitIntuneWin) and publish it.

An Enforce rule removes another install as SYSTEM on every device that has it.
So the
package build refuses it until an unattended Update test on the Hyper-V test VM has proved
it.
Only a rule that is not from a sibling capture can skip the proof, with a PROOF waiver.
A typed Enforce rule also needs the removal data: -UninstallerType, -UninstallerFileName,
-InstallDir, -MainExe and at least one -ProcessName.

It stops with an error whose ID starts with W32T.
when it cannot make the change, and then
writes nothing.
W32T.PriorInstallSlotsMissing: the deploy script cannot take rules, most
often because an earlier win32-toolkit version created the project.
Re-create the project,
but first copy out hand-written install code: re-creating deletes the folder.
W32T.PriorInstallRefused: the install capture has not run yet, or the change is not allowed
for this rule.
W32T.PriorInstallInvalid: a value is wrong or missing, or the rules would not
be valid.
The message says what to fix.

## EXAMPLES

### EXAMPLE 1
```
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
Set-Win32ToolkitPriorInstall -ProjectPath $project
```

This lists the rules of the project and the proposals of its sibling captures, with their
state.
It writes nothing.

### EXAMPLE 2
```
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'
Set-Win32ToolkitPriorInstall -ProjectPath $project -FromSiblingCapture -Mode Block
```

This makes a Block rule from each proposal that has High confidence and no warning flags and
is not a rule yet.
It asks you to confirm each one and lists the others with the reason.

### EXAMPLE 3
```
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'
Set-Win32ToolkitPriorInstall $project -FromSiblingCapture -Mode Enforce -ProposalId nsis-x64
```

This makes the proposal nsis-x64 an Enforce rule and records your approval.
It then shows
the Update test command that proves the rule, and any acknowledgement the package build
still needs.

### EXAMPLE 4
```
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'
Set-Win32ToolkitPriorInstall -ProjectPath $project -Id nsis-x64 -Mode Block
```

This changes the rule nsis-x64 to Block, for example while you investigate a problem on
devices.
Devices get the change after you build the package again and publish it.

### EXAMPLE 5
```
$rule = @{
    ProjectPath         = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'
    Id                  = 'nsis-x64'
    Mode                = 'Enforce'
    Key                 = 'Notepad++'
    View                = 'Native'
    Publisher           = 'Notepad++ Team'
    DisplayName         = 'Notepad++ (64-bit x64)'
    VersionMin          = '8.7.9'
    VersionMax          = '8.9.8.1'
    UninstallerType     = 'nullsoft'
    UninstallerFileName = 'uninstall.exe'
    InstallDir          = '%ProgramFiles%\Notepad++'
    MainExe             = 'notepad++.exe'
    ProcessName         = 'notepad++'
}
Set-Win32ToolkitPriorInstall @rule -Confirm:$false
```

This adds a typed Enforce rule from a script: @rule passes each line of $rule as a
parameter, and -Confirm:$false skips the question.
If nsis-x64 is a typed Block rule, this
replaces it.

## PARAMETERS

### -ProjectPath
The project folder: \<base folder\>\Projects\\\<template\>\\\<project\>.
Give only this parameter to
list the rules.
You can leave out the name -ProjectPath, because the first value is the
project folder.

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

### -Mode
What the package does on a device that has the install.
Block fails the install (exit code
69101).
Enforce runs the uninstaller of that install after the close-apps dialog, then
installs.
Report writes a marker in the registry and installs.
There is no default.

```yaml
Type: String
Parameter Sets: SetMode, FromSiblingCapture, FromUpdateTest, Manual
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Key
For a typed rule: the exact name of the uninstall key of the install, for example Notepad++.
Windows keeps these keys for Apps & Features under
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall, or for 32-bit apps under
HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall.

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -View
For a typed rule: the registry view of the key.
Native is the 64-bit view, Wow6432 is the
32-bit view (WOW6432Node).

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Publisher
For a typed rule: the exact Publisher value of the key.
On a device, an install with another
publisher is left as it is.

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DisplayName
For a typed rule: the exact DisplayName value of the key.
On a device, an install with
another name is left as it is.
Give this or -DisplayNameTemplate, not both.
A rule without a
name needs a DISPLAYNAME waiver, recorded before the rule (see -Waive).

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DisplayNameTemplate
For a typed rule: the display name with the version replaced by exactly one {v}, for example
'Wireshark {v} x64'.
Use it when the name changes with each version.

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -VersionMin
The lowest version (DisplayVersion) the rule applies to.
On a device, a lower version is
left as it is.
An empty value needs a VERSIONMIN waiver, recorded before the rule.
With
-FromUpdateTest, the default is the version the test found.

```yaml
Type: String
Parameter Sets: FromUpdateTest
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -VersionMax
The highest version the rule applies to.
With Block or Enforce, a device with a newer
version fails the install (exit code 69102).
With -FromUpdateTest, the default is the
package version.
If your package installs from an .exe file, the value must be lower than
the package version.
The default with -FromUpdateTest is then the version the test found.

```yaml
Type: String
Parameter Sets: FromUpdateTest
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -UninstallerType
For a typed rule: the kind of uninstaller.
Use nullsoft for an NSIS setup and inno for Inno
Setup.
It sets the silent switches, which are fixed: /S _?=\<folder\> for nullsoft, and
/VERYSILENT /SUPPRESSMSGBOXES /NORESTART for inno.
An Enforce rule needs it.

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -UninstallerFileName
For a typed rule: the file name of the uninstaller in the install folder, for example
uninstall.exe.
An Enforce rule needs it.

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -InstallDir
For a typed rule: the install folder, as %ProgramFiles%\\\<folder\> or
%ProgramFiles(x86)%\\\<folder\> with 1 to 4 folder names.
An Enforce rule needs it.
On a device
with the install in another folder, an Enforce rule fails the install (exit code 69105).

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -MainExe
For a typed rule: the file name of the main program in the install folder, for example
notepad++.exe.
It must differ from the uninstaller.
An Enforce rule needs it.
If the program
is missing on a device, the package leaves that install as it is.

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProcessName
The process names of the app, without .exe, for example notepad++.
A typed Enforce rule
needs at least one, and a rule takes at most 8.
The names of Block and Enforce rules are
added to ProcessesToClose, so the close-apps dialog can close the app before a removal.
Default with -FromUpdateTest: the names the test found.

```yaml
Type: String[]
Parameter Sets: FromUpdateTest, Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -UninstallerSigner
For a typed rule: the exact subject of the certificate that signs the uninstaller.
Optional.
If you give it, a device runs the uninstaller only when its signature is valid and has this
subject.
Otherwise the install fails there (exit code 69105).

```yaml
Type: String
Parameter Sets: Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Id
The rule ID, for example nsis-x64: lower-case letters, digits and hyphens, 40 characters or
fewer.
A new rule gets a default ID.
With -Mode and no rule data, -Id names the existing
rules whose mode you change.
A typed Block rule without removal data cannot become Enforce
with -Id and -Mode alone.
Type the rule again with the same ID, -Mode Enforce and all
removal data.

```yaml
Type: String[]
Parameter Sets: SetMode
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

```yaml
Type: String[]
Parameter Sets: FromUpdateTest, Manual
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -FromUpdateTest
Makes the rule from the candidate of the last failed Update test.
When the old version stays
installed after the update, the test saves it as a candidate in
Documentation\PriorInstallCandidates.json.
In the menu: Prior installs \> Declare from the
last Update test.

```yaml
Type: SwitchParameter
Parameter Sets: FromUpdateTest
Aliases:

Required: True
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -CandidateKey
With -FromUpdateTest: the uninstall key of the candidate to use.
Use it when there is not
exactly one candidate with High confidence.
Command line only: the menu does not offer this.

```yaml
Type: String
Parameter Sets: FromUpdateTest
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -FromSiblingCapture
Makes rules from the proposals of the project: the rules that its sibling captures suggest.
Without -ProposalId, it writes every proposal with High confidence and no warning flags that
is not a rule yet, as Block or Report.
It lists the others with the reason and never changes
an existing rule.
Run the capture first with Test-Win32ToolkitProject -Scenario
SiblingCapture.

```yaml
Type: SwitchParameter
Parameter Sets: FromSiblingCapture
Aliases:

Required: True
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProposalId
The IDs of the proposals to write, as the list shows them, for example nsis-x64.
Use it for
a proposal that is left out without -ProposalId, or to change a rule from a capture.
Enforce
needs it, and the proposal must allow Enforce (the list shows Enforce-eligible).
You confirm
each proposal, and the command records one approval (your recorded yes) for each.

```yaml
Type: String[]
Parameter Sets: FromSiblingCapture
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Remove
The IDs of the rules to remove.
Devices with that install then keep it next to this package.
The process names of the rules stay in ProcessesToClose.
If the previous version had the
rule, acknowledge ID-PRIOR-DROPPED before you build the package.

```yaml
Type: String[]
Parameter Sets: Remove
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Waive
Records a waiver for -Target: the package build then accepts a rule without one thing it
normally needs.
PROOF: an Enforce rule without a proof.
VERSIONMIN: no VersionMin, or one
below the oldest version a proof run removed.
DISPLAYNAME: no display name.
Not allowed for
a rule from a sibling capture.
Command line only: the menu does not offer this.

```yaml
Type: String
Parameter Sets: Waive
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Acknowledge
Records an acknowledgement for -Target: you accept a known risk.
DATA-LOSS: the uninstaller
of the prior install deletes user data or configuration files.
SIGNER-MISMATCH: the
uninstaller of a captured install has another signer than your package.
ID-PRIOR-DROPPED: a
rule of the previous version is missing on purpose.
The package build stops until the ones
that apply are recorded.

```yaml
Type: String
Parameter Sets: Acknowledge
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Revoke
Removes the waiver or acknowledgement with this code for -Target, for example when its
reason is no longer true.
It needs no -Reason.
Command line only: the menu does not offer
this.

```yaml
Type: String
Parameter Sets: Revoke
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Target
The ID of the rule that a waiver, acknowledgement or -Revoke is about.
The rule does not
have to exist yet: record a DISPLAYNAME or VERSIONMIN waiver before you type the rule.

```yaml
Type: String
Parameter Sets: Waive, Acknowledge, Revoke
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Reason
Why you accept the waiver or acknowledgement, in 1 to 512 characters.
It stays on your PC
with the decision and never goes into the package.

```yaml
Type: String
Parameter Sets: Waive, Acknowledge
Aliases:

Required: True
Position: Named
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

### One object for each rule of the project, as it is when the command ends.
### Id, Mode, Key and Proof are shown.
### Proof is Proven or NotProven for an Enforce rule, and NotNeeded for the others.
### Other properties: Kind, View, Window, Source, Lineage, Decisions and Consequence.
### Lineage is Capture for a rule from a sibling capture.
### Consequence is the effect of the rule on a device.
## NOTES

## RELATED LINKS

[https://win32toolkit.com/reference/Set-Win32ToolkitPriorInstall/](https://win32toolkit.com/reference/Set-Win32ToolkitPriorInstall/)

[https://win32toolkit.com/prior-installs/](https://win32toolkit.com/prior-installs/)

[https://win32toolkit.com/prior-installs-enforce/](https://win32toolkit.com/prior-installs-enforce/)

