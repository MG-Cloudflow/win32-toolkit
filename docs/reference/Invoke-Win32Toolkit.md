# Invoke-Win32Toolkit

## SYNOPSIS
End-to-end Win32 app packaging automation.

## SYNTAX

```
Invoke-Win32Toolkit [[-SearchTerm] <String>] [[-Id] <String>] [[-TemplateName] <String>] [-NewTemplate]
 [[-Architecture] <String>] [-Force] [[-BasePath] <String>] [-Reconfigure] [[-RunTest] <String[]>]
 [[-UpdateVersionsBack] <Int32>] [[-UpdateSpecificVersion] <String>] [-PackageIntune] [-PublishIntune]
 [-PublishUpdate] [[-DependsOn] <String[]>] [[-DependencyType] <String>] [[-InstallerType] <String>]
 [[-UpdateBaselineInstallerType] <String>] [-CaptureSiblingTechnologies] [[-ApplySiblingCapture] <String>]
 [-NoPublishPrompt] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Searches Winget for an application, downloads it, creates a PSADT V4 project,
configures the installer, generates Intune requirement scripts, and launches
a Windows Sandbox session for targeted installation documentation.

Fails closed: when the PSADT project cannot be created, when its deploy script uses a template
layout this version does not support ("Unsupported PSADT template shape: ..."), when the
configuration or the org template cannot be applied, or when the winget download fails
(W32T.DownloadFailed; the warnings name every option that was skipped and the project folder is
kept for a retry), the command stops with a terminating error and the project is NOT documented,
tested, packaged or published.
A project folder that was created but not configured (a refused
configuration, a failed download, any error before the end of the configure step) is kept and marked
not configured (Documentation\NotConfigured.json): Export-Win32ToolkitIntuneWin and
Publish-Win32ToolkitIntuneApp refuse it (W32T.ProjectNotConfigured) until the app is packaged again.

Returns a result object (Win32Toolkit.RunResult): Status (Succeeded, CompletedWithProblems or Failed),
the capture state, the test verdicts, the .intunewin built, the apps published and one plain sentence
per problem (a failed or inconclusive test, an incomplete capture, no package built, the update app
skipped, or the error that stopped the run).
A W32T.* error is thrown instead and no object is
returned.
-NewTemplate returns nothing.

## EXAMPLES

### EXAMPLE 1
```
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force
```

### EXAMPLE 2
```
Invoke-Win32Toolkit -SearchTerm 'visual studio code' -BasePath 'D:\Packaging'
```

### EXAMPLE 3
```
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

### EXAMPLE 4
```
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune -PublishIntune
```

### EXAMPLE 5
```
# Fully scripted pipeline incl. both tests; the Update baseline is the previous release
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -RunTest InstallUninstall, Update -UpdateVersionsBack 1 -PackageIntune
```

### EXAMPLE 6
```
# Package the vendor EXE (NSIS) installer instead of winget's default MSI, and keep it for later versions
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -Force -InstallerType nullsoft
```

### EXAMPLE 7
```
# Update test from each installer technology winget ships (one run and one test record per technology)
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -Force -RunTest Update -UpdateVersionsBack 1 -UpdateBaselineInstallerType Both
```

### EXAMPLE 8
```
# Package the WiX MSI and capture the vendor NSIS setup too: Block it now, review it later
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -Force -InstallerType wix -CaptureSiblingTechnologies -ApplySiblingCapture Block
```

### EXAMPLE 9
```
# Check what happened without reading the console
$r = Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune
if ($r.Status -ne 'Succeeded') { $r.Problems }
```

## PARAMETERS

### -SearchTerm
Term to search for in the Winget repository.

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
Winget package ID to use directly (skips search).
Example: 'Git.Git'

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
Name of the org template to load/create.
Skips the interactive template picker.
If the template does not exist yet, the wizard is pre-filled with this name.

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
Run the org template wizard, save the template, and exit without packaging any app.

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
Architecture to use for download and project creation (x64, x86, arm64).
Skips the interactive architecture selection menu.

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
Skip the PSGallery update prompt and the project overwrite prompt.
Useful for unattended / automated runs.
PSAppDeployToolkit is only ever selected and installed inside the supported range (4.1.x and 4.2.x).
With -Force an installed supported version is used without querying the gallery; without it, only
newer STABLE versions inside that range are offered.
When no supported version is installed, the
newest stable supported version is installed (with or without -Force).

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
Base folder for all output (Templates, Projects, Staging, IntuneWin).
If omitted, the value
saved in the registry (HKCU:\Software\CloudFlow\win32-toolkit) is used; on first run you are
prompted for it and the choice is saved.
An explicit value overrides but is not persisted.

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
Re-prompt for the base folder and save the new value to the registry, ignoring any stored value.

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
Test scenario(s) to run right after the project is built and documented: 'InstallUninstall',
'Update', or both (array - scenarios run in the order given).
Each runs in the configured test
backend (Windows Sandbox by default, Hyper-V when configured and ready).
A failed scenario is
reported with a warning but does not stop packaging/publishing.

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
For -RunTest Update: automatically use the version N releases older than the packaged one as the
update baseline (1 = the immediately previous release), so a scripted pipeline never blocks on
the interactive version picker.
Ignored when -UpdateSpecificVersion is also supplied.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -UpdateSpecificVersion
For -RunTest Update: use this exact older version as the update baseline.
Takes precedence over
-UpdateVersionsBack when both are supplied.
Omit both to pick interactively; an unattended test run
(the SandboxTestMode / HyperVTestMode config value) or a host that cannot prompt (a service,
redirected input, or a console started with pwsh -NonInteractive) then uses the previous version,
with a warning.

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
After creating the project, package it into a .intunewin file using IntuneWinAppUtil.exe.

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
After packaging, upload the .intunewin file to Microsoft Intune via Graph API.
Implies -PackageIntune.
Requires the Microsoft.Graph.Authentication module.

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
Also publish the UPDATE app: a second Intune app of the same version whose requirement rule makes
it applicable only to devices that already have the app installed.
Implies packaging.

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
Dependencies to declare for this app before packaging: 'winget:\<Id\>', 'project:\<Template\>\\\<Name\>',
or 'intune:\<AppGuid\>' references (array).
Declared dependencies install first in the test guest
and are related to the Intune app at publish time.
The references are checked before anything is
searched, downloaded or created: a 'project:' reference that is not exactly '\<Template\>\\\<Name\>', an
'intune:' reference that is not a GUID, or a reference to the app being built stops the command
with the terminating error W32T.InvalidDependencyReference.

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
How Intune should treat the declared dependencies: 'autoInstall' (default) installs them
automatically; 'detect' only requires their presence.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 10
Default value: AutoInstall
Accept pipeline input: False
Accept wildcard characters: False
```

### -InstallerType
Pin the installer technology of the package: the winget installer type to download (msi, wix, burn,
nullsoft, inno, exe or msix).
winget may answer with another type of the same family (msi and wix are
one family; burn, nullsoft, inno and exe are another) and says so.
Without it, rebuilding a version
that is itself published or pinned keeps its own technology; otherwise the technology of the
highest earlier version of this app (same winget id) in the template folder that was published, or
pinned with this parameter, is kept; otherwise winget chooses.
When winget offers no installer of the
pinned family for this version, the command stops with W32T.InstallerVariantUnavailable and nothing is
downloaded.
The choice and its reason are recorded in SupportFiles\AppConfig.json (Source); the
identity checks after the download warn when the app ships another technology too.

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
For -RunTest Update: the installer technology of the old-version baseline (see
Test-Win32ToolkitProject -BaselineInstallerType).
Auto (the default when omitted) starts from the other
technology winget ships for this app when there is one, and falls back to the packaged technology with
a warning when the old version does not ship it; Both runs the Update test once per technology (one
record each); Packaged uses the packaged technology only; a type (msi, wix, burn, nullsoft, inno, exe,
msix) pins that technology.

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
After the install capture, install each OTHER installer technology winget ships for this app (for example
the vendor NSIS setup of an app packaged as MSI) on the Hyper-V test VM, record what it registered and
turn it into prior-install proposals: rules that make this package refuse (Block) or remove (Enforce)
that other install before it installs.
About 3-5 minutes per capture; a host whose Hyper-V test VM is not
ready is told before the download and captures nothing.
A refused or failed capture is reported and the
pipeline goes on.
Review and approve the proposals with Set-Win32ToolkitPriorInstall (or the menu).

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
With -CaptureSiblingTechnologies: None (default: the proposals are listed with the command that applies
each one) or Block (every High-confidence proposal without flags whose identity is not a rule yet becomes
a Block rule: devices with that install FAIL this one until the rule is Enforce).
There is no Enforce
value: removing another vendor's install as SYSTEM needs one approval per proposal and a Hyper-V proof
(Set-Win32ToolkitPriorInstall -FromSiblingCapture -Mode Enforce -ProposalId \<id\>; -RunTest Update proves
it, and demotes a captured rule that cannot be proven).

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
With -PackageIntune and neither -PublishIntune nor -PublishUpdate, do not ask 'Upload to Microsoft
Intune now?
(Y/N)' after packaging.
The menu always passes it: it asks about publishing itself.

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

### Win32Toolkit.RunResult: Command, ProjectPath, ProjectName, Mode (Winget), Status (Succeeded,
### CompletedWithProblems or Failed), Capture (Done, Problems or NotRun), Tests ({ Scenario; Verdict }
### per -RunTest scenario), IntuneWinPath, Published (the objects Publish-Win32ToolkitIntuneApp returned)
### and Problems. A W32T.* error is thrown instead and no object is returned. Check .Status, not whether an
### object came back: a failed run that stopped on a non-W32T error returns an object with Status Failed
### (and writes the error).
## NOTES

## RELATED LINKS
