---
description: "Run packaging, tests and publishing from a script, a scheduled task or a pipeline, and check the results in code."
---

# Use the commands in scripts

Most tasks of win32-toolkit also exist as commands. This page shows how to run them in a script without questions,
and how to check each result in code.

## When you need this

Use the commands in these cases:

- You package many apps in one run.
- You repeat the same job on a schedule.
- You run it in continuous integration (CI), an automated build system.

Some tasks still need a person:

- Create an [org template](glossary.md#org-template): your saved company settings. The template wizard
  asks questions.
- Build the [Hyper-V test VM](glossary.md#hyper-v-test-vm), a virtual machine (VM) for tests. You
  prepare Windows inside the VM by hand.
- Sign in to Intune to publish.

## Prepare the PC once

Run the script as the Windows account that set up the toolkit. The toolkit saves its settings and modules for one
Windows account only.

1. Open PowerShell 7 and start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)).
2. Choose your base folder when the menu asks for it.
3. Choose **Org templates** > **Create a new template** and answer the questions.
4. Choose **Back to the main menu** > **Package an app from winget** and build one app.
5. Install the Microsoft Graph module for your account.

The [base folder](glossary.md#base-folder) holds all your templates, projects and packages. You can
also pass `-BasePath` to a command. That value is for this command only, and the toolkit does not save it.

Step 4 also installs [PSAppDeployToolkit (PSADT)](glossary.md#psadt), which every package uses. Step 5
is only for publishing. This command installs the Graph module:

```powershell
Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser
```

[Connect-Win32ToolkitIntune](reference/Connect-Win32ToolkitIntune.md) with `-Force` also installs it, without a
question.

If you use the Hyper-V test VM, start PowerShell as administrator. Without administrator rights, the toolkit uses
Windows Sandbox and prints a warning.

## Answer every question with a parameter

A script cannot answer questions, so give every answer as a parameter. This table is for
[Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md), which packages an app from winget.

| Question | Parameter that answers it | What happens without it |
|---|---|---|
| Base folder | `-BasePath 'C:\Win32Apps'` | The saved folder is used. If none is saved, the command asks. In `pwsh -NonInteractive` the run fails. |
| Org template | `-TemplateName 'Contoso'` | With one template, the command uses it. With none or several, it asks. A run that cannot ask stops with `W32T.OrgTemplateChoiceNeeded`. |
| App | `-Id 'Git.Git'` | The command asks for a search term, then for a number from a list. |
| Architecture | `-Architecture x64` | The command always asks. |
| Overwrite the project, update PSADT | `-Force` | The command asks `Do you want to overwrite it? (y/n)` and can offer a newer PSADT. |
| Old version for an update test | `-UpdateVersionsBack 1` or `-UpdateSpecificVersion '2.52.0'` | An interactive test shows a list of versions. An unattended test uses the previous version and warns. |
| Upload after the build | `-NoPublishPrompt` | After `-PackageIntune`, the command asks `Upload to Microsoft Intune now? (Y/N)`. |

If a project of the same version exists, `-Force` re-creates it. Re-creating a project deletes its folder. Copy your
own code out first.

The [install capture](glossary.md#install-capture) needs no answers. It records what the installer
changes. For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

For an app that is not in winget, [New-Win32ToolkitManualApp](reference/New-Win32ToolkitManualApp.md) asks for the
name, version, architecture and installer path. Give them as parameters too.

## Check the result

`Invoke-Win32Toolkit` returns a [result object](glossary.md#result-object): one object that says what
the run did. The commands for apps that are not in winget return the same object.

| Property | What it holds |
|---|---|
| `Status` | `Succeeded`, `CompletedWithProblems` or `Failed`. |
| `Problems` | One plain sentence per problem, for example a failed test. |
| `Tests` | One entry per test, with `Scenario` and `Verdict` (`Passed`, `Failed` or `Inconclusive`). |
| `Capture` | The state of the install capture: `Done`, `Problems` or `NotRun`. |
| `IntuneWinPath` | The package file, when the run built one. |
| `Published` | The apps the run published, each with its app ID and a link to the Intune admin center. |

A failed test only warns. It does not stop packaging or publishing. The run then ends with the status
`CompletedWithProblems`.

`New-Win32ToolkitManualApp` can also return the status `Scaffolded`. It means that the project exists, but you still
need to finish it with [Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md).

An error whose ID starts with `W32T.` is a [W32T error](glossary.md#w32t-error). It stops the command,
and the command returns no object. Catch it with `try` and `catch`.

Any other error returns an object with `Status` set to `Failed`, and the command prints the error. So check `Status`.
Do not only check whether an object came back.

```powershell
try {
    # The result object is the last output
    $result = Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso' -Force -RunTest InstallUninstall | Select-Object -Last 1
}
catch {
    # A W32T error: the run stopped, no result object
    Write-Warning "Stopped: $($_.FullyQualifiedErrorId)"
    return
}
if ($result.Status -ne 'Succeeded') {
    $result.Problems
}
```

For what each ID means, see [Error IDs](troubleshooting.md#error-ids).

## Tests without a person

[Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md) runs one test. Always pass `-ProjectPath` and
`-Scenario`, or the command shows a menu.

An [interactive test](glossary.md#interactive-test) adds a 2-minute pause, so that you can check the
app. An [unattended test](glossary.md#unattended-test) runs without a pause. In Windows Sandbox, an
unattended install and uninstall test takes about 2 minutes. This command runs one:

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
$passed = Test-Win32ToolkitProject -ProjectPath $project -Scenario InstallUninstall -Unattended
```

The command returns one of three values:

- `$true`: the test Passed.
- `$false`: the test Failed.
- `$null`: no result. The test was Inconclusive or did not run.

If nobody can answer, for example in a service, the toolkit runs the test unattended. It then prints a warning that
starts with `The host session is non-interactive`. Do not depend on this. `Invoke-Win32Toolkit -RunTest` has no
`-Unattended` option, so set the test mode once on this PC:

```powershell
$key = 'HKCU:\Software\CloudFlow\win32-toolkit'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name 'SandboxTestMode' -Value 'Unattended'
```

For the Hyper-V test VM, set `HyperVTestMode` too. See [Tests](settings.md#tests).

An [update test](glossary.md#update-test) installs an old version of the app first, then your package
over it. Without an old version as a parameter, an unattended update test uses the previous version, with a warning.

To run several tests in a row, run them unattended. The Windows Sandbox of an interactive test stays open, so the
next test waits 90 seconds and then has no result.

## Publish from a script

Publishing needs a person to sign in. Build and test unattended, then publish from an interactive PowerShell window.

In the build script, add `-NoPublishPrompt`, so the run does not stop at the upload question.

To publish, connect first in the same PowerShell window. With `-Template`, `Connect-Win32ToolkitIntune` signs in to
the [tenant ID](glossary.md#tenant-id) saved on your org template: the ID of your Intune organization.
[Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md) then uses this sign-in.

A failed connect only prints an error that starts with `Connect failed:`. The script continues, so add
`-ErrorAction Stop`. These lines check, connect and publish:

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
$package = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'
# Dry run: every check, no sign-in, no upload
Publish-Win32ToolkitIntuneApp -IntuneWinPath $package -ProjectPath $project -WhatIf
# Sign in to the tenant of the org template
Connect-Win32ToolkitIntune -Template 'Contoso' -Force -ErrorAction Stop
# Publish the install app
Publish-Win32ToolkitIntuneApp -IntuneWinPath $package -ProjectPath $project
```

The [dry run](glossary.md#dry-run) runs every check that needs no sign-in and prints the warnings.
Then it stops with a line that starts with `WhatIf: would connect to Microsoft Graph and publish`. For every option,
see [Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md).

!!! warning "Each publish creates an app"
    Every publish creates a new app in Intune. Publishing again does not change the old app. Run a publish script
    once for each version.

## Example script

This script packages, tests and builds three winget apps for the org template `Contoso`. It prints the status of each
app and does not publish. The install capture usually takes 5 to 20 minutes per app. The toolkit stops waiting after
30 minutes.

The script uses **splatting**: it puts the parameters in a list of names and values (a hashtable) and passes the list
with `@`. Long commands are easier to read this way.

!!! note "Set the test mode first"
    Set `SandboxTestMode` to `Unattended` first, as in [Tests without a person](#tests-without-a-person).
    Otherwise the Windows Sandbox of the first test stays open, and the next capture does not start.

```powershell
# Package, test and build three winget apps for Contoso
$apps = 'Git.Git', 'Notepad++.Notepad++', 'Microsoft.VCRedist.2015+.x64'

foreach ($id in $apps) {
    # Every answer as a parameter, so nothing asks
    $params = @{
        Id              = $id
        Architecture    = 'x64'
        TemplateName    = 'Contoso'
        Force           = $true
        RunTest         = 'InstallUninstall'
        PackageIntune   = $true
        NoPublishPrompt = $true
    }
    try {
        $result = Invoke-Win32Toolkit @params | Select-Object -Last 1
    }
    catch {
        # A W32T error stops this app only
        Write-Warning "$id stopped: $($_.FullyQualifiedErrorId)"
        continue
    }
    Write-Output "$id : $($result.Status)"
    foreach ($problem in $result.Problems) {
        Write-Output "    $problem"
    }
}
```

## Commands that ask for confirmation

Some commands ask you to confirm before they change something.

- [Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md) asks before every change to a
  [prior-install rule](glossary.md#prior-install-rule): a rule for devices that have the app from
  another installer technology. Before it writes a rule, it shows the rule and what it does on devices. In a script,
  add `-Confirm:$false`.
- [Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md) asks only when you add `-Confirm`. It
  then asks once for the whole publish.
- [Disconnect-Win32ToolkitIntune](reference/Disconnect-Win32ToolkitIntune.md) also asks only with `-Confirm`.

This command sets the rule `nsis-x64` to Block without a question:

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
Set-Win32ToolkitPriorInstall -ProjectPath $project -Id nsis-x64 -Mode Block -Confirm:$false
```

!!! warning "Review a rule before you skip"
    With `-Confirm:$false`, nobody checks the rule before the command writes it. Enforce removes another install as
    SYSTEM. Assign the package to a pilot group first. See [Remove a prior install](prior-installs-enforce.md).

## Environment variables

An [environment variable](glossary.md#environment-variable) is a named value that lasts until you close
the PowerShell window. Set it in the script before the first toolkit command, for example
`$env:W32T_PSADT_VERSION = '4.1'`.

- `W32T_PSADT_VERSION`: the PSADT version for new projects, for example `4.1` or `4.1.8`. It must be installed already.
- `W32T_HYPERV_VM`: in this window, Hyper-V tests use this VM instead of your usual test VM. `W32T_HYPERV_CHECKPOINT`
  names its checkpoint. If that VM is not ready, the test does not start. It never uses Windows Sandbox instead.
- `WIN32TOOLKIT_NO_UPDATE_CHECK`: any value turns off the update check of the menu. The commands never check for
  updates.
- `CI`: any value also turns off the update check of the menu. Many build systems set it for you.

For all variables, see [Environment variables](settings.md#environment-variables).

## Next steps

- [Only in the menu or only with commands](menu.md#only-in-the-menu-or-only-with-commands): what each way can do.
- [Error IDs](troubleshooting.md#error-ids): what each `W32T.` error means and what to do.
- [Commands](reference/README.md): every command and all its options.
