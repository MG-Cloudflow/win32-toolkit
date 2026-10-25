# Set-Win32ToolkitPriorInstall

## SYNOPSIS
Lists or sets the prior-install rules of a project: another installer technology of the app that the package
refuses (Block), removes before it installs (Enforce) or only reports (Report).

## SYNTAX

### List (Default)
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm]
 [<CommonParameters>]
```

### SetMode
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Mode <String> -Id <String[]>
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

### FromUpdateTest
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Mode <String> [-VersionMin <String>]
 [-VersionMax <String>] [-ProcessName <String[]>] [-Id <String[]>] [-FromUpdateTest] [-CandidateKey <String>]
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Manual
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Mode <String> -Key <String> -View <String>
 -Publisher <String> [-DisplayName <String>] [-DisplayNameTemplate <String>] -VersionMin <String>
 -VersionMax <String> [-UninstallerType <String>] [-UninstallerFileName <String>] [-InstallDir <String>]
 [-MainExe <String>] [-ProcessName <String[]>] [-UninstallerSigner <String>] [-Id <String[]>]
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Remove
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Remove <String[]> [-ProgressAction <ActionPreference>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Waive
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Waive <String> -Target <String> -Reason <String>
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Acknowledge
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Acknowledge <String> -Target <String> -Reason <String>
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

### Revoke
```
Set-Win32ToolkitPriorInstall [-ProjectPath] <String> -Revoke <String> -Target <String>
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
A device can already have the app from ANOTHER installer technology (for example the vendor's NSIS setup of
Notepad++ while the package installs the WiX MSI).
Installing next to it leaves two registrations over one
folder.
A prior-install rule names that other install EXACTLY - its uninstall key in HKLM, the registry view,
the publisher, the display name (or a {v} template) and a version window - and says what the package does when
it finds it:

  Block    the install FAILS on such a device (exit code 69101) until the rule is Enforce;
  Enforce  the package runs that install's own uninstaller (NSIS '/S _?=\<its folder\>', Inno Setup
           '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART') after the close-apps dialog and before it installs;
  Report   the device gets a marker (LastSeen) and the install goes on; nothing is removed.

A device whose install is NEWER than the window fails with 69102; an exact key that is not the declared install
(another publisher, name or version) is left as it is and the install goes on; a declared install in another
folder than InstallDir fails with 69105.
The rules are DATA in SupportFiles\AppConfig.json (PriorInstalls): the
deploy script reads them when it runs.
After a change, re-package (Export-Win32ToolkitIntuneWin) and publish the
new .intunewin - a project created by this win32-toolkit version needs no re-creation.
A project created before
it has no remove-prior blocks: re-create it first (copy hand-written Install code out); this command refuses to
write rules into it.

An Enforce rule removes another vendor's install as SYSTEM, so Export refuses it until a Hyper-V Unattended
Update test proved it (Test-Win32ToolkitProject -Scenario Update -Backend HyperV -TestMode Unattended), or an
operator rule carries a PROOF waiver.
Every rule needs the package's own identity, recorded by the install
capture, and its process names are merged into ProcessesToClose so the close-apps dialog closes the app first.

Parameter sets:
  List (default)  the rules, their source and lineage, their proof state, the decisions and what each does on a
                  device.
Writes nothing.
  Manual          one rule typed by the operator (Source Operator).
  FromUpdateTest  a rule from the last failed Update test's candidates (Documentation\PriorInstallCandidates.json,
                  Source UpdateTest): the High candidate, or -CandidateKey.
  SetMode         change the mode of existing rules (Block -\> Enforce after the proof; Enforce -\> Block in an
                  incident).
  Remove          remove rules (the merged process names stay).
  Waive / Acknowledge / Revoke   host-side decisions (Documentation\PriorInstallDecisions.json; never shipped).

Every write shows the resulting rule and its device consequence first and asks for confirmation (ConfirmImpact
High; pass -Confirm:$false in scripts).
-Mode has no default.

## EXAMPLES

### EXAMPLE 1
```
Set-Win32ToolkitPriorInstall -ProjectPath 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'
```

### EXAMPLE 2
```
# Declare the vendor NSIS install the last Update test left behind, Block first
Set-Win32ToolkitPriorInstall -ProjectPath $p -FromUpdateTest -Mode Block
```

### EXAMPLE 3
```
# After the Hyper-V proof run: remove it before installing
Set-Win32ToolkitPriorInstall -ProjectPath $p -Id nsis-x64 -Mode Enforce
```

### EXAMPLE 4
```
Set-Win32ToolkitPriorInstall -ProjectPath $p -Mode Block -Key 'Notepad++' -View Native -Publisher 'Notepad++ Team' `
    -DisplayName 'Notepad++ (64-bit x64)' -VersionMin 8.7.9 -VersionMax 8.9.8.1
```

### EXAMPLE 5
```
Set-Win32ToolkitPriorInstall -ProjectPath $p -Acknowledge DATA-LOSS -Target nsis-x64 -Reason 'user settings live in %APPDATA%'
```

## PARAMETERS

### -ProjectPath
The PSADT project folder.

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
Block, Enforce or Report (no default).

```yaml
Type: String
Parameter Sets: SetMode, FromUpdateTest, Manual
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Key
Manual: the exact uninstall key name under HKLM\SOFTWARE\[\WOW6432Node\]\Microsoft\Windows\CurrentVersion\Uninstall.

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
Manual: Native (the 64-bit view) or Wow6432 (the 32-bit view).

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
Manual: the exact Publisher value of that key.

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
Manual: the exact DisplayName value (or use -DisplayNameTemplate; an empty name needs a DISPLAYNAME waiver).

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
Manual: the DisplayName with the version replaced by exactly one {v} (for example 'Wireshark {v} x64').

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
The lowest DisplayVersion the rule applies to (four parts, padded).
FromUpdateTest: defaults to the version the
test observed.
A lower one is never removed (it is left as it is).

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
The highest DisplayVersion the rule applies to; a newer install fails with 69102.
For a package of the same
technology family (an EXE package) it must be lower than the package version.
FromUpdateTest: defaults to the
observed version (same family) or the package version (another family).

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
Manual, Enforce: nullsoft or inno (selects the constant uninstall switches).

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
Manual, Enforce: the uninstaller's file name (for example uninstall.exe).

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
Manual, Enforce: the install folder as %ProgramFiles%\\\<folder\> or %ProgramFiles(x86)%\\\<folder\>.

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
Manual, Enforce: the app's main program file in InstallDir (its absence makes the registration a leftover).

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
The app's process names (no .exe; merged into ProcessesToClose).

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
Manual: the exact signer subject the uninstaller must have (Get-AuthenticodeSignature Valid).

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
The rule id (^\[a-z0-9-\]{1,40}$).
Manual / FromUpdateTest: one id (default: derived, for example nsis-x64).
SetMode: the rules to change.

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
Declare the rule from the last failed Update test's candidates.

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
FromUpdateTest: the uninstall key of the candidate to use when it is not the single High candidate.

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

### -Remove
The ids of the rules to remove.

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
PROOF (ship an Enforce rule without a proof), VERSIONMIN (no or a lower VersionMin than proven) or DISPLAYNAME
(no display name) for -Target, with -Reason.
Never for a rule from a sibling capture.

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
ID-PRIOR-DROPPED (a rule of the previous version is gone on purpose), DATA-LOSS (the prior's uninstaller deleted
user data in the proof run) or SIGNER-MISMATCH, for -Target, with -Reason.

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
Remove the Waive or Acknowledge decision of that code for -Target.

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
The rule id a decision is about (it may be declared before the rule exists).

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
Why (1-512 characters; kept on the host, never shipped).

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

### PSCustomObject[] - one per rule: Id, Mode, Kind, Key, View, Window, Source, Lineage, Proof, Decisions, Consequence.
## NOTES

## RELATED LINKS
