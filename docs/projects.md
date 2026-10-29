---
description: "Look inside a project, change switches, icon or processes to close, run the install capture again, and re-create a project safely."
---

# Change or re-create a project

win32-toolkit keeps every app version you package in its own folder: the [project](glossary.md#project). It holds the installer, the scripts and the settings. Building the package never
changes the project, but an [install capture](glossary.md#install-capture), a test and some other
commands do. An install capture installs the app in a clean, temporary Windows and records what changed.

## Before you start

- You have a project from [Package an app from winget](packaging.md) or
  [Package an app that is not in winget](manual-apps.md).
- Time: a few minutes, then usually 5 to 20 minutes for each install capture. The toolkit stops waiting after 30
  minutes.

## Find and open a project

Every project is in `<base folder>\Projects\<template>\<app>_<arch>_<version>`. The [base folder](glossary.md#base-folder) is where the toolkit keeps all its files. The template part is the name of the
[org template](glossary.md#org-template): your saved settings for one customer.

For example, Git 2.53.0 for x64 is in `C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0`. Your version will differ.

To see all projects, choose **Browse projects** in the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)).
The table has three columns: Template, Application and PSADT. Application adds `(not configured)` when a build
stopped halfway.

The PSADT column shows the version of [PSAppDeployToolkit (PSADT)](glossary.md#psadt) inside the
project. PSADT is the free PowerShell tool that runs the install on devices. The column can add a marker:

- `(legacy)`: win32-toolkit 1.1.6 or older made the project. See
  [Coming from win32-toolkit 1.1.6 or older](maintain-toolkit.md#coming-from-win32-toolkit-116-or-older).
- `(unsupported)`: this version of the toolkit does not support the project. [Re-create it](#re-create-a-project).

To open a project, choose **Work with an existing project** > choose your project > **Open the project folder**.

## Change a project by hand

The [deploy script](glossary.md#deploy-script), `Invoke-AppDeployToolkit.ps1`, installs and removes
the app on the device. It reads its settings from `SupportFiles\AppConfig.json`. [Silent switches](glossary.md#silent-switches) install an EXE without any window. [Processes to close](glossary.md#processes-to-close) are programs that must be closed before the install or uninstall.

| What you change | Where | Then |
|---|---|---|
| Silent switches of an EXE | `Installer.SilentArgs` in `AppConfig.json` | Run the install capture again. |
| Uninstall switches of an EXE | `Uninstall.Uninstallers[].Args` in `AppConfig.json`, when the capture warns about them | Build the package again. Set them again after every capture: it rewrites `Uninstall`. |
| App icon (Intune tile and dialog logo) | `Assets\AppIcon.png` | Build the package again. Do this after your last capture: a capture can replace the file. |
| Processes to close | `ProcessesToClose` in `AppConfig.json` | Build the package again. A capture adds the names it finds and keeps yours. |
| Your own install code | `Invoke-AppDeployToolkit.ps1`, outside the `## win32-toolkit:` blocks | Run the install capture again, then test. |

Keep `AppConfig.json` valid JSON. If the toolkit cannot read it, building and publishing refuse the project. For the
rules of your own code, see [Write the install code](manual-apps.md#write-the-install-code).

Never change these parts:

- The `Files\` folder, which holds the installer. An extra file there can confuse the toolkit.
- Anything inside a `## win32-toolkit:` block of the deploy script. The toolkit writes these blocks.
- The `PSAppDeployToolkit\` folder, the copy of PSADT that the project uses.

!!! warning "Hand edits do not last"
    Every hand edit is lost when you re-create the project or package the next version. Put code that every app of a
    customer needs in the org template. See [Add a logo, hook scripts or an extension module](org-template-files.md).

### Signs of wrong switches

If winget has no silent switches for an EXE, the toolkit guesses `/S`. That works for setups made with NSIS, a common
setup tool. Setups made with Inno Setup, another setup tool, need `/VERYSILENT`.

The install capture shows the result of wrong switches. It warns
`The PSADT install in the capture run failed with exit code` ... or `The capture recorded NO changes` .... Correct
`Installer.SilentArgs`, then run the capture again.

For the uninstaller of an EXE, the capture adds the known silent switch for NSIS and Inno Setup. For other setups, it
warns `Uninstaller(s)` ... `have no silent switch` .... Set `Args` yourself then. Without a switch, the uninstall shows
its window as SYSTEM, the account Intune uses.

## Run the install capture again

Run the install capture again in these cases:

- You changed the silent switches, your own install code or other files by hand.
- The capture failed or recorded no changes.
- You added or changed a dependency: an app that must be installed first.

The capture runs in [Windows Sandbox](glossary.md#windows-sandbox), a temporary Windows desktop that
comes with Windows. It runs on the Hyper-V test VM (virtual machine) instead if you
[made the test VM your default](hyperv-vm.md#make-the-test-vm-your-default) and it is ready.

=== "Menu"

    In the main menu, choose **Work with an existing project** > choose your project > **Finalize / refresh**.

    The menu runs the capture only. To test or build after it, choose **Run a test** or **Package to .intunewin**.

=== "Command line"

    Run [`Complete-Win32ToolkitManualApp`](reference/Complete-Win32ToolkitManualApp.md). In spite of its name, it
    works for every project, including apps from winget.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Complete-Win32ToolkitManualApp -ProjectPath $project
    ```

    Add `-RunTest InstallUninstall` to test right after the capture. For every option, see
    [Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md).

In Windows Sandbox, a window opens. Do not close it: it closes by itself.

The capture deletes the older capture files in `Documentation\` and writes a new one. For an EXE, it rewrites the
uninstall data. It adds the processes to close that it finds, and it never changes your install code.

Some projects get their [detection rule](glossary.md#detection-rule) from the newest capture, even a
failed one. Intune uses this rule to check if the app is installed. So after a failed capture, capture again before
you publish. See [How Intune detects the app](publishing.md#how-intune-detects-the-app).

The [installer technology](glossary.md#installer-technology) is how the vendor built the setup, for
example MSI or NSIS. [Prior-install rules](glossary.md#prior-install-rule) handle devices that already
have the app from another installer technology. A new capture takes away the proof of the rules that remove that
install (Enforce rules). If your project has such rules, read
[What takes a proof away](prior-installs-enforce.md#what-takes-a-proof-away) first.

### Start the capture by hand

If Windows Sandbox does not start, the toolkit warns
`The sandbox did NOT auto-launch - start it manually by double-clicking:`. Double-click the file it names,
`<project>_TargetedDocumentation.wsb`, while the toolkit waits. The file exists only for Windows Sandbox. Do not
open it at other times: it then writes a capture file but does not update `AppConfig.json`.

## Re-create a project

To [re-create](glossary.md#re-create) a project is to make it again from the start: the same app, version
and org template, in the same folder. The new project uses the org template and the PSADT version as they are now.

!!! warning "Copy your code out first"
    Re-creating a project deletes its folder. Copy your own code out first. The menu re-creates a project without
    asking when you package the same version again.

Re-create a project in these cases:

- You changed the org template. Changes to an org template reach new projects only. Re-create a project to apply them.
- The [package check](glossary.md#package-check), which runs before every build, asks for it. It says
  `Re-create the project with this win32-toolkit version` ....
- **Browse projects** shows `(legacy)`, `(unsupported)` or `(not configured)`.
- You want to undo your hand edits, or to use
  [another PSADT version](maintain-toolkit.md#choose-the-psadt-version-for-new-projects).

The toolkit always packages the newest version in winget. If winget has a newer version now, you get a new project
next to the old one. See [Ship a new version](new-version.md).

=== "Menu"

    In the main menu, choose **Package an app from winget** or **Package a manual app**. Give the same answers as
    before.

=== "Command line"

    Run the same command as before, with `-Force`. For an app from winget, that is
    [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md):

    ```powershell
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso' -Force
    ```

    For an app that is not in winget, run [`New-Win32ToolkitManualApp`](reference/New-Win32ToolkitManualApp.md) again
    with `-Force`.

    Without `-Force`, the command warns `Project directory already exists:` and asks
    `Do you want to overwrite it? (y/n)`. Any answer other than `y` deletes nothing. The command then stops: the
    error `W32T.ProjectCreationFailed` says that no project was created.

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

### What is kept and what is lost

The [publication record](glossary.md#publication-record) is the file `Intune\Publications.json` in the
project. It keeps the ID of the app that you published to Intune.

| What | After you re-create the project |
|---|---|
| Installer technology | Kept, if you published this version or chose its technology in the menu or with `-InstallerType`. |
| Prior-install rules and your decisions | Kept. Each Enforce rule needs a new proof: see [Next versions and re-created projects](prior-installs.md#next-versions-and-re-created-projects). |
| The publication record, `Intune\Publications.json` | Kept for apps from winget. Lost for apps that are not in winget. |
| Your hand edits, captures and test results | Lost. The new project needs its own capture and tests. |
| Dependencies you declared | Lost. Answer the dependency question again, or pass `-DependsOn` again. |

After you re-create an app that is not in winget,
[`Sync-Win32ToolkitAppDependency`](reference/Sync-Win32ToolkitAppDependency.md) needs `-AppId`. See
[Change the dependencies of an app in Intune](dependencies.md#change-the-dependencies-of-an-app-in-intune).

Re-creating a project does not change the app in Intune. Every publish creates a new app in Intune. Publishing again
does not change the old app. See [Replace the old app in Intune](new-version.md#replace-the-old-app-in-intune).

## Recover from a stopped build

### After a failed download

If winget cannot download the installer, the toolkit warns `Download FAILED for` .... It lists the options you passed
that it skipped. It keeps the project folder, marks it not configured and stops with the error `W32T.DownloadFailed`.

- If winget reported a network error or a timeout, run the same command or wizard again.
- Do not copy an installer into `Files\` yourself. The next run deletes the folder and creates it again.
- To use an installer you have yourself, see [Package an app that is not in winget](manual-apps.md).

### Fix a project marked not configured

When a build stops after the project folder was created, the toolkit marks the project [not configured](glossary.md#not-configured-project). The menu shows `(not configured)` next to its name.

Building the package and publishing refuse such a project with `'<project>' is marked not configured` .... No option
skips this check. Fix the cause, then package the app again to re-create the folder. A capture or a test still runs on
such a project, but the project stays marked not configured.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `'<project>' is marked not configured` ... | Its build stopped halfway. Fix the cause, then package the app again. |
| `Do you want to overwrite it? (y/n)` | Copy your own code out, then type `y`. In scripts, pass `-Force`. |
| `The capture recorded NO changes` ... | The install did nothing. Check the silent switches, then capture again. |
| `The PSADT install in the capture run failed with exit code` ... | Check the silent switches and the log under `Sandbox\Logs`, then capture again. |
| `Uninstaller(s)` ... `have no silent switch` ... | Set `Args` of that uninstaller in `SupportFiles\AppConfig.json`, again after every capture. |

For more messages, see [The install capture](troubleshooting.md#the-install-capture) in Troubleshooting.

## Next steps

- [Ship a new version](new-version.md).
- [Inside a project](settings.md#inside-a-project): every file and folder of a project.
- [Add a logo, hook scripts or an extension module](org-template-files.md).
