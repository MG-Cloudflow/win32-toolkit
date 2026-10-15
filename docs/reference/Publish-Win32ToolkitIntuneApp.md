# Publish-Win32ToolkitIntuneApp

## SYNOPSIS
Uploads a packaged Win32 app (.intunewin) to Microsoft Intune via the Graph API.

## SYNTAX

```
Publish-Win32ToolkitIntuneApp [-IntuneWinPath] <String> [-ProjectPath] <String> [-AsUpdate]
 [[-UpdateNameSuffix] <String>] [[-TimeoutSeconds] <Int32>] [-AllowNoDetectionRule]
 [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Authenticates to Microsoft Graph with the DeviceManagementApps.ReadWrite.All scope,
then executes the full Win32 Lob App upload sequence:

1.
Reads app metadata (name, publisher, version, description, URL) from AppConfig.json (winget YAML fallback).
2.
Builds a detection rule (install-tattoo version rule preferred; else from the NEWEST
   InstallationChanges_*.json capture in Documentation\\) BEFORE signing in to Graph.
No rule at
   all stops the publish with a W32T.NoDetectionRule error unless -AllowNoDetectionRule is given.
   A project that bundles a prerelease PSAppDeployToolkit (e.g.
4.2.0-rc2) only gets a warning.
3.
Extracts encryption metadata from the .intunewin archive (metadata.xml).
4.
Creates the app shell in Intune.
5.
Registers a content version and file entry.
6.
Waits for the Azure Storage SAS URI.
7.
Uploads the encrypted content using the Azure Block Blob API (6 MB chunks).
8.
Commits the file and waits for confirmation.
9.
Links the content version to the app.

Requires the Microsoft.Graph.Authentication module (installed automatically on prompt).

Command lines (from Get-Win32ToolkitIntuneCommandLine, the single source; the app runs as SYSTEM):

    Install   : Invoke-AppDeployToolkit.exe -DeploymentType Install
    Uninstall : Invoke-AppDeployToolkit.exe -DeploymentType Uninstall

The package is started through PSADT's launcher, not through 'powershell.exe -File'.
The Intune
Management Extension is a 32-bit process, so a bare 'powershell.exe' resolves to the 32-bit
(SysWOW64) Windows PowerShell on 64-bit devices: PSADT 4.2 then refuses to run (exit 60008), and
PSADT 4.1 runs 32-bit and writes the install tattoo under HKLM\SOFTWARE\WOW6432Node, where the
64-bit tattoo detection rule never finds it.
Invoke-AppDeployToolkit.exe is AnyCPU and always starts
the 64-bit Windows PowerShell.
No -DeployMode is passed: PSADT chooses the mode itself.

Apps published by win32-toolkit 1.1.6 or older keep their old 'powershell.exe -File' command line:
this command always creates a NEW app and never edits an existing one.
Republish those apps (and
retire the old ones), or edit their install and uninstall command lines in the Intune portal to the
two lines above.
The update requirement (-AsUpdate) also accepts the WOW6432Node tattoo those
32-bit installs left behind.

With -AsUpdate the same .intunewin is published as a SECOND app of the same version whose
requirement rule (a PowerShell presence check, built by Get-Win32ToolkitRequirementRule) makes it
applicable only to devices that already have the app - the classic Intune "install app + update
app" pattern.
Detection stays the version-aware tattoo rule, so the update installs on machines
with an older version and is detected once they reach this version.
(Supersedence is separate.)

## EXAMPLES

### EXAMPLE 1
```
Publish-Win32ToolkitIntuneApp `
    -IntuneWinPath 'C:\Win32Apps\IntuneWin\Git_x64_2.53.0.intunewin' `
    -ProjectPath   'C:\Win32Apps\Projects\Git_x64_2.53.0'
```

### EXAMPLE 2
```
# Publish the update app (2nd app, requirement-gated to devices that already have it)
Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $proj -AsUpdate
```

### EXAMPLE 3
```
# A per-user app with no detectable footprint: publish it, then add a detection rule in the portal
Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $proj -AllowNoDetectionRule
```

## PARAMETERS

### -IntuneWinPath
Full path to the .intunewin file produced by Export-Win32ToolkitIntuneWin.

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
Full path to the raw PSADT project folder.
Used for YAML metadata and detection rules.

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
Publish the update variant: append -UpdateNameSuffix to the display name and attach the
"app already installed" requirement rule.
Fails fast if no requirement rule can be built.

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
Display-name suffix for the update app (default ' (Update)').

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
How long to wait for each of the two ASYNCHRONOUS Intune steps - the Azure Storage SAS URI (step 6)
and the file commit (step 8) - before giving up.
Default 300 s.

Why 300 and not the old 60: both waits used to be a fixed 20 x 3 s loop, i.e.
a hard 60-second
ceiling that could not be raised.
Intune's commit does the server-side decrypt/validate of the whole
package, so it scales with package size; a 200 MB+ .intunewin (normal for a PSADT project with a
bundled installer) regularly needs more than a minute, and the timeout fired AFTER the blob had
already been uploaded - throwing away a publish that would have succeeded.
300 s covers the observed
worst case with headroom while still failing in a reasonable time when the tenant is genuinely stuck.

Polling backs off exponentially (2 s, doubling, capped at 15 s), so a slow tenant is polled patiently
rather than hammered.

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
Publish even when no detection rule can be built (no install tattoo and no usable install capture).
The app is created with an empty detection-rule list and you must add a rule in the Intune portal
before assigning it - Intune cannot tell whether such an app installed.
Meant for apps a capture
cannot describe (per-user installs, some MSIX packages).
Without it the publish stops before any
Graph call with a W32T.NoDetectionRule error.

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

### System.Management.Automation.PSObject
## NOTES

## RELATED LINKS
