---
description: "A map of the win32-toolkit menu: how to move around, what each screen does, and what only the menu or only the commands can do."
---

# The menu at a glance

This page is a map of the win32-toolkit [menu](glossary.md#menu): its keys, screens and panels.

## Start the menu

Type [Show-Win32Toolkit](reference/Show-Win32Toolkit.md) in a PowerShell 7 window to start the menu.

```powershell
Show-Win32Toolkit
```

After a Git clone or a ZIP download, you can also double-click `Launch-Win32Toolkit.cmd`. A PowerShell Gallery install
does not include this file.

The first time, the toolkit asks to install [PwshSpectreConsole](glossary.md#pwshspectreconsole), the
module that draws the menu. Answer `Y`. See [Start the menu for the first time](install.md#start-the-menu-for-the-first-time).

The [base folder](glossary.md#base-folder) holds all your files. To use another one for this session
only, add `-BasePath`. The menu does not save it and does not ask the first-run question.

```powershell
Show-Win32Toolkit -BasePath 'D:\Win32Apps'
```

## Move around the menu

| Key | What it does |
|---|---|
| Arrow keys and <kbd>Enter</kbd> | Move in a list and choose an item. |
| Type a few letters | Filter a list that says "(type to filter)". |
| <kbd>Space</kbd> | Tick or clear a box. <kbd>Enter</kbd> accepts the list. |
| `y` or `n`, then <kbd>Enter</kbd> | Answer a yes or no question. <kbd>Enter</kbd> alone keeps the default. |
| Any key | Continue after "Press any key". |
| <kbd>Ctrl</kbd>+<kbd>C</kbd> | End the menu at once. The normal way out is **Exit**. |

The questions before a build or an upload default to No.

## The main screen

The main screen starts with the win32-toolkit banner and the version. Then comes the [system check](glossary.md#system-check) table, with one row for each part the toolkit needs. On a new PC, up to three red
rows are normal. See [Read the system check](install.md#read-the-system-check).

A line that starts with `Update available:` means that a newer version exists. Only the menu checks for updates, at
most once every 24 hours. See [Update win32-toolkit](maintain-toolkit.md#update-win32-toolkit).

## The main menu

The main menu asks **What would you like to do?** A [project](glossary.md#project) is the folder of one
app version. An [org template](glossary.md#org-template) holds the settings of one company or customer.
The Microsoft tool [winget](glossary.md#winget) finds and downloads installers.

<!-- SCREENSHOT: The TUI main menu with the figlet banner and the option list -->

| Menu item | What it opens |
|---|---|
| **Package an app from winget** | [The winget wizard](packaging.md): find an app and build it. |
| **Package a manual app** | [The wizard for an app that is not in winget](manual-apps.md). |
| **Work with an existing project** | [Actions for one project](#work-with-an-existing-project). |
| **Browse projects** | [A table of all projects](#browse-projects). |
| **Org templates** | [Create, edit, view, duplicate or delete an org template](org-templates.md). |
| **Microsoft Intune connection** | [Connect to Intune or sign out](intune-connection.md). |
| **Settings** | [The base folder, the update check and Hyper-V](#settings). |
| **Exit** | Leaves the menu. |

## Work with an existing project

Choose **Work with an existing project**, then a project. `(not configured)` after a name marks a [not-configured project](glossary.md#not-configured-project): its build stopped halfway. **Package to .intunewin** and
**Publish to Intune** refuse it until you [package the app again](projects.md#recover-from-a-stopped-build).

Tests run in [Windows Sandbox](glossary.md#windows-sandbox), a clean, temporary Windows on your PC. The
other choice is the [Hyper-V test VM](glossary.md#hyper-v-test-vm), a virtual machine (VM) that you
build once.

| Action | What it does |
|---|---|
| **Run a test** | [Tests the package](testing.md) in Windows Sandbox or on the Hyper-V test VM. |
| **Dependencies** | [Changes the apps](dependencies.md#change-the-dependencies-of-a-project) that Intune installs first. |
| **Prior installs** | [Shows and changes the rules](prior-installs.md#see-change-or-remove-rules) for other installs on devices. |
| **Finalize / refresh** | [Installs the app on a clean Windows again and records the changes](projects.md#run-the-install-capture-again). |
| **Package to .intunewin** | [Builds the `.intunewin` package](build-intunewin.md). |
| **Publish to Intune** | Asks **Publish which app?**, builds the package again and [uploads it](publishing.md). |
| **Generate customer documentation** | Writes a [one-page summary](publishing.md#give-your-customer-a-one-page-summary) for your customer. |
| **Open the project folder** | Opens the project in File Explorer. |
| **Pick another project** | Goes back to the project list. |
| **Back to the main menu** | Goes back. |

!!! warning "Do not publish again for dependencies"
    The **Dependencies** panel tells you to publish again. Every publish creates a new app in Intune. Publishing
    again does not change the old app. For an app in Intune, run
    [Sync-Win32ToolkitAppDependency](reference/Sync-Win32ToolkitAppDependency.md) instead.

## Browse projects

**Browse projects** shows all projects in one table, sorted by org template. The PSADT column shows the version of
[PSAppDeployToolkit (PSADT)](glossary.md#psadt) in each project. PSADT runs the install on devices. The
column can also show one of these words:

| Word | What it means |
|---|---|
| `(legacy)` | [win32-toolkit 1.1.6 or older](maintain-toolkit.md#coming-from-win32-toolkit-116-or-older) made the project. It still builds, with one warning. |
| `(unsupported)` | The toolkit does not support its PSADT copy or its deploy script (`Invoke-AppDeployToolkit.ps1`). It refuses to build the package. |
| `unknown` | The toolkit cannot read the PSADT version. |

## Settings

**Settings** shows your base folder, then six items. [Settings and folders](settings.md) lists every setting.

| Item | What it does |
|---|---|
| **Change the base folder** | Saves a new base folder and uses it at once. Nothing is moved. |
| **PSAppDeployToolkit version** | Shows the version that new projects get, and why. Opens the screen to [choose or install a version](maintain-toolkit.md#choose-the-psadt-version-for-new-projects). |
| **Hyper-V test VM** | Shows the test VM and checkpoint that tests use. Opens the **Hyper-V test VM** screen. |
| **Update check: On** or **Off** | Turns the update check off, or on again. Turning it on checks at once. |
| **Re-run the system check** | Shows the system check table again. |
| **Back to main menu** | Goes back. |

The **Hyper-V test VM** screen shows the test VM and checkpoint that tests use, and whether the VM is ready. Then come
these items. Each item that changes the VM names it in its question.

| Item | What it does |
|---|---|
| [**Choose the test VM and checkpoint**](hyperv-vm-care.md#choose-another-test-vm) | Chooses the VM and checkpoint that tests use. |
| [**Set the default test backend**](hyperv-vm.md#make-the-test-vm-your-default) | Chooses Windows Sandbox or the test VM for tests. |
| [**Provision the test VM from a Windows 11 ISO**](hyperv-vm.md#build-the-vm) | Builds the test VM. |
| [**Change VM resources**](hyperv-vm-care.md#change-processors-or-memory) | Changes its processors or memory. |
| [**Reset the VM to its clean checkpoint**](hyperv-vm-care.md#reset-the-vm-by-hand) | Resets the VM. |
| [**Configure guest AutoLogon + re-checkpoint**](hyperv-vm-care.md#repair-a-broken-vm) | Repairs the VM. The guest is the Windows inside the VM. |
| [**Remove the test VM**](hyperv-vm-care.md#remove-the-vm) | Removes the VM and its disks. |
| **Back** | Goes back. |

## Result panels and errors

A wizard build and **Finalize / refresh** end with one result panel.

| Panel | What it means |
|---|---|
| Green **Done** | Everything worked. Find the project in **Browse projects**. |
| Red **Finished with problems** | One line per problem. "stopped before the end" means that the later steps did not run. |
| Blue **Scaffolded** | The project was created, but it is not finished. Finish it with **Finalize / refresh**. |
| Yellow **Finished** | No result came back. Read the messages above the panel. |

<!-- SCREENSHOT: The red "Finished with problems" panel after a winget build of Git (Git.Git), with one line per problem -->

A test ends with [its own result panel](testing.md#read-the-result).

If a screen stops on an error, a red **Something went wrong** panel shows the message. A gray `Error id:` line can
follow. Press any key, and you are back in the main menu.

An ID that starts with `W32T.` belongs to a [W32T error](glossary.md#w32t-error): the toolkit stopped on
purpose. See [Error IDs](troubleshooting.md#error-ids).

Many actions show their own red **Error** panel, for example **Package to .intunewin** and **Publish to Intune**. This
panel shows only the message, without an `Error id:` line. Press any key, and you stay on the same screen.

## What the menu decides for you

The menu answers some questions for you. The commands ask them, or take a parameter.

- **It replaces a project of the same version without asking.**
  [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md) asks `Do you want to overwrite it? (y/n)` first.
- **It never offers a newer PSADT.** A command without `-Force` can. See
  [Choose the PSADT version for new projects](maintain-toolkit.md#choose-the-psadt-version-for-new-projects).
- **It never asks to upload after a build.** A command asks **Upload to Microsoft Intune now?** after it builds a
  package. In the menu, you tick **Publish to Intune** in a wizard, or use the **Publish to Intune** action.
- **Run a test asks for the test machine every time.** A [test machine](glossary.md#test-machine) is
  Windows Sandbox or the Hyper-V test VM. **Run a test** asks **Which test backend?** and ignores your default.
- **The wizards use your default test machine.** The default is Windows Sandbox. Change it in [Settings](#settings).
- **The wizards offer only the install and uninstall test.** To test an update, use **Run a test**.
- **The wizards publish only the [install app](glossary.md#install-app)**, the app you assign to devices.
  An [update app](glossary.md#update-app) updates only devices that have an older version. Publish it
  with the **Publish to Intune** action.

!!! warning "The menu re-creates the project"
    Re-creating a project deletes its folder. Copy your own code out first.

## Only in the menu or only with commands

### Only in the menu

- See all projects in one table: **Browse projects**.
- View, duplicate or delete an org template. A command can only create or edit one.
- Repair a half-built test VM: **Configure guest AutoLogon + re-checkpoint**.
- Choose a dependency by name from the apps in Intune. A command needs the app ID.

### Only with commands

| Task | Command |
|---|---|
| [Change the dependencies of an app that is already in Intune](dependencies.md#change-the-dependencies-of-an-app-in-intune) | [Sync-Win32ToolkitAppDependency](reference/Sync-Win32ToolkitAppDependency.md) |
| [Keep rules that remove another install on the next version](prior-installs-enforce.md#keep-enforce-rules-on-the-next-version): test the update in the same run as the build | [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md) |
| [Type a rule for another install by hand](prior-installs-enforce.md#type-a-rule-by-hand), or record a [waiver](glossary.md#waiver): an exception to a rule | [Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md) |
| [Build a package from a deploy script that the toolkit did not prepare](build-intunewin.md#the-allowlegacyscript-option), with `-AllowLegacyScript` | [Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md) |
| [Publish an app without a detection rule](publishing.md#apps-that-cannot-be-detected-automatically) | [Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md) |
| [Wait longer for Intune during a big upload](publishing.md#if-the-publish-fails) | Publish-Win32ToolkitIntuneApp or Export-Win32ToolkitIntuneWin |
| [Check a publish first, without signing in or uploading](publishing.md#try-it-first-with-a-dry-run), with `-WhatIf` | Publish-Win32ToolkitIntuneApp |
| [Build the test VM from your own virtual disk](hyperv-vm.md#use-your-own-virtual-disk) | [New-Win32ToolkitTestVM](reference/New-Win32ToolkitTestVM.md) |
| [Build and test with nobody to answer questions](automation.md) | The commands, with parameters |
