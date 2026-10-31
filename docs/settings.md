---
description: "Every win32-toolkit setting and environment variable, the base folder layout, and what is inside a project."
---

# Settings and folders

This page lists every setting of win32-toolkit and every folder it creates. Use it to look up a name, a default or
the place of a file.

## Change a setting

The [base folder](glossary.md#base-folder) is the one folder where the toolkit keeps all your work. You
change it and a few other settings in the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)). All other
settings need a short PowerShell command.

### Use the Settings screen

1. In PowerShell 7, type `Show-Win32Toolkit` and press <kbd>Enter</kbd>.
2. Choose **Settings**. The first line shows your base folder.

<!-- SCREENSHOT: the TUI Settings screen showing the base folder and the Hyper-V test VM entry -->

The screen has these items:

- **Change the base folder** asks **Enter the base folder for all output** and saves your answer. The default is
  your current base folder. It does not move your files.
- **PSAppDeployToolkit version** shows the version that new projects get. There you
  [choose a version, or install one](maintain-toolkit.md#choose-the-psadt-version-for-new-projects).
- **Hyper-V test VM** shows the VM and checkpoint that tests use. It opens the screen of the
  [Hyper-V test VM](glossary.md#hyper-v-test-vm), a virtual machine (VM) for tests that run as Intune does. There
  you choose the test VM and where tests run, and build or remove the VM.
- **Update check** turns the check for new toolkit versions on or off. Turning it on checks at once.
- **Re-run the system check** shows the system check table again.

To move your files too, see [Move or change the base folder](maintain-toolkit.md#move-or-change-the-base-folder).

### Change a value in the registry

All other settings are values in the [registry](glossary.md#registry), the Windows settings database.
They are in the key `HKCU:\Software\CloudFlow\win32-toolkit`, so each Windows user has their own settings.

There is no settings file, and no toolkit command for most of them. A missing or blank value means the default. These
commands create the key when it is missing, change one value, show all values and remove the value again.

```powershell
$key = 'HKCU:\Software\CloudFlow\win32-toolkit'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }   # only when missing
Set-ItemProperty -Path $key -Name 'PipelineCache' -Value 'Off'    # change one value
Get-ItemProperty -Path $key                                       # show all values
Remove-ItemProperty -Path $key -Name 'PipelineCache'              # back to the default
```

!!! warning "Never create the key again"
    Do not run `New-Item -Force` on this key when it exists. It replaces the key and deletes every value in it,
    including your base folder and the test VM password.

The toolkit reads a value each time it needs it, so a change applies to the next command. One exception: an open
menu keeps its base folder. Change it in **Settings**, or start the menu again.

## All settings

The tables list the values in alphabetical order. Case does not matter. For a setting with a fixed list of values, any
other value counts as the default.

### General

[PSAppDeployToolkit (PSADT)](glossary.md#psadt) is the free tool that every package uses to install
the app on devices.

| Setting | Default | Allowed values | What it does |
|---|---|---|---|
| `BasePath` | Asked on the first run (suggests `C:\Win32Apps`) | A full folder path | Your base folder. Menu: **Settings** > **Change the base folder**. |
| `PipelineCache` | `On` | `On`, `Off` | Keeps downloaded old versions for update tests and prepared dependency installers for later tests. |
| `PreferredPsadtVersion` | Not set: the newest supported PSADT installed | An installed version (`4.1.8`), or `4.1` or `4.2` | The PSADT version for new projects. A version that is not installed stops project creation. Menu: **Settings** > **PSAppDeployToolkit version**. |
| `UpdateCheck` | `On` | `On`, `Off` | The menu checks GitHub for a new toolkit version, once a day at most. Menu: **Settings** > **Update check**. |

Type the base folder without quotes. Keep it short and local, such as `C:\Win32Apps`. A `-BasePath` parameter wins for
one command and is not saved. To pin a PSADT version, see
[Choose the PSADT version for new projects](maintain-toolkit.md#choose-the-psadt-version-for-new-projects).

### Tests

Tests run in [Windows Sandbox](glossary.md#windows-sandbox) or on the Hyper-V test VM. Windows Sandbox
is a clean, temporary copy of Windows. It forgets everything when it closes.

| Setting | Default | Allowed values | What it does |
|---|---|---|---|
| `HyperVTestMode` | `Interactive` | `Interactive`, `Unattended` | How tests on the test VM run. `Unattended`: as Intune runs them, with no pause. The menu question **Hyper-V run mode** lists this value first. |
| `SandboxTestMode` | `Interactive` | `Interactive`, `Unattended` | How tests in Windows Sandbox run. `Interactive`: a 2-minute pause to watch the app. `Unattended`: no pause. |
| `TestBackend` | `Sandbox` | `Sandbox`, `HyperV` | Where tests and captures run. Menu: **Settings** > **Hyper-V test VM** > **Set the default test backend**. |
| `TestProjectLease` | `Off` | `On`, `Off` | `On`: only one PowerShell window at a time can test a project. Works only in a window run as administrator. |

If `TestBackend` is `HyperV` and the VM is not ready, the toolkit warns and uses Windows Sandbox. Building the test VM
does not change `TestBackend`.

The `-TestMode` parameter of [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md) wins for one test. A
test in a service, or with redirected input, always runs unattended. In other scripts, set the test mode yourself, as
[Tests without a person](automation.md#tests-without-a-person) shows. See
[Choose where the test runs](testing.md#choose-where-the-test-runs).

### Hyper-V test VM

A [checkpoint](glossary.md#checkpoint) is a saved state of the VM. Every test returns the VM to its
clean checkpoint. The VM build saves the name, checkpoint, processors and memory for you. To use another VM, see
[Choose another test VM](hyperv-vm-care.md#choose-another-test-vm).

| Setting | Default | Allowed values | What it does |
|---|---|---|---|
| `HyperVAsyncTeardown` | `Off` | `On`, `Off` | Speed switch. `On`: after an unattended test in the menu or in [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md), the VM returns to its checkpoint in the background. |
| `HyperVCapturePrewarm` | `Off` | `On`, `Off` | Speed switch. `On`: `Invoke-Win32Toolkit` prepares the test VM during the download, so the capture starts sooner. Ignored when `HyperVDepsCheckpoint` is `On`. |
| `HyperVCheckpoint` | `clean-base` | A checkpoint name | The clean checkpoint of the test VM. Menu: **Settings** > **Hyper-V test VM** > **Choose the test VM and checkpoint**. |
| `HyperVDepsCheckpoint` | `Off` | `On`, `Off` | Speed switch. `On`: keeps a checkpoint with the dependencies of a project installed, for its later tests. |
| `HyperVLeaseWaitMinutes` | `60` | A whole number from 1 to 240. Other values count as `60`. | How long to wait while another PowerShell window uses the test VM or tests the same project. Then the test stops. |
| `HyperVMemoryStartupBytes` | `4294967296` (4 GB) | A number of bytes | VM memory. The default is 4 GB. Give the VM 6 to 8 GB if your PC has the memory. |
| `HyperVPrecheckCache` | `On` | `On`, `Off` | Saves the answer of the [Intune-parity pre-check](testing.md#when-a-test-is-not-started) for the checkpoint: is a user signed in to the test VM? `Off`: the toolkit asks every time. |
| `HyperVProcessorCount` | `2` | A whole number from 1 to 64 | Number of processors of the test VM. |
| `HyperVRevertMode` | `TurnOffFirst` | `TurnOffFirst`, `Legacy` | How the VM returns to its checkpoint. `TurnOffFirst` is faster. Use `Legacy` only if `TurnOffFirst` causes problems on your PC. |
| `HyperVTeardownPark` | `Running` | `Running`, `Saved` | Speed switch. `Saved`: after an unattended test, the clean VM waits in the Saved state and uses no memory. Needs `TurnOffFirst`. |
| `HyperVVMName` | `win32tk-golden` | A VM name | The name of the test VM. Menu: **Settings** > **Hyper-V test VM** > **Choose the test VM and checkpoint**. |

Change processors and memory with **Settings** > **Hyper-V test VM** > **Change VM resources**, or with
[Set-Win32ToolkitTestVMResource](reference/Set-Win32ToolkitTestVMResource.md). A registry change alone only affects the
next VM build.

!!! tip "Measure the speed switches first"
    The four speed switches are off by default. Turn one on, run a few unattended tests and compare the times. With
    `HyperVAsyncTeardown` on, other PowerShell windows wait for the VM while the menu is open. See
    [Make Hyper-V tests faster](hyperv-vm.md#make-hyper-v-tests-faster).

### Values the toolkit writes

The toolkit writes these values itself. Never edit them.

| Setting | Default | Allowed values | What it does |
|---|---|---|---|
| `HyperVBaseVhdx` | Not set | Written by the toolkit | Where the VM build put the virtual disk. |
| `HyperVCheckpointAttestation` | Not set | Written by the toolkit | The saved sign-in and Microsoft Defender state of the checkpoint. |
| `HyperVGuestSecret` | Not set | Written by the toolkit | The password of the account in the VM, encrypted for your Windows user on this PC. |
| `HyperVGuestUser` | Not set | Written by the toolkit | The name of the account in the VM (suggested: `w32admin`). |
| `HyperVPrecheckProbe` | Not set | Written by the toolkit | The saved answer of the Intune-parity pre-check: is a user signed in to the test VM? |

To change the password, see [Fix a wrong VM password](hyperv-vm-care.md#fix-a-wrong-vm-password). Removing the test VM
keeps its name, the account and `TestBackend` in the registry. If `TestBackend` is still `HyperV`, later tests warn and
use Windows Sandbox.

## Environment variables

An [environment variable](glossary.md#environment-variable) is a named value in one PowerShell window.
It lasts until you close the window. It wins over the matching registry value.

| Variable | Wins over | What it does |
|---|---|---|
| `CI`, `DO_NOT_TRACK`, `NO_UPDATE_NOTIFIER`, `WIN32TOOLKIT_NO_UPDATE_CHECK` | `UpdateCheck` | Any value turns off the update check. Most build systems set `CI` for you. |
| `W32T_HYPERV_CHECKPOINT` | `HyperVCheckpoint` | Hyper-V tests in this window use this checkpoint. |
| `W32T_HYPERV_VM` | `HyperVVMName` | Hyper-V tests in this window use this VM. If it is not ready, the test stops instead of using Windows Sandbox. |
| `W32T_PSADT_VERSION` | `PreferredPsadtVersion` | New projects in this window use this PSADT version. |

This example sets a variable and removes it again.

```powershell
$env:W32T_PSADT_VERSION = '4.2'               # this window only
Remove-Item -Path Env:\W32T_PSADT_VERSION     # back to the registry value
```

For a second test VM, see [Use another VM in one PowerShell window](hyperv-vm-care.md#use-another-vm-in-one-powershell-window).

## The base folder layout

Everything you make is under the base folder. Each [org template](glossary.md#org-template), a saved
set of your company's settings, gets its own folders. So you can package one app for several customers side by side.

A [project](glossary.md#project) holds everything for one app version. The [package](glossary.md#package) is the `.intunewin` file that you publish to Intune.

```text title="The base folder"
<base folder>\                             default C:\Win32Apps
  Templates\
    <template>.json                        an org template
    <template>\                            optional: Hooks\, Assets\, PSAppDeployToolkit.<name>\
  Projects\
    <template>\<app>_<arch>_<version>\     a project
  Staging\
    <template>\<app>_<arch>_<version>\     the cleaned copy the package is built from
  IntuneWin\
    <template>\<app>_<arch>_<version>.intunewin   the package
  Cache\winget\                            downloaded installers, used again for update tests
  HyperV\                                  the test VM (secret): Golden\ (its disk), VMs\
```

The toolkit creates no folder at the first run. Each folder appears the first time a step needs it. For example,
`IntuneWin\` appears with your first package, and `HyperV\` when you build the test VM.

In the folder names under `Projects\`, `Staging\` and `IntuneWin\`, spaces and the characters `\ / : * ? " < > |`
become `_`. So the org template `Contoso IT` gets the folder `Contoso_IT`. A project is named
`<app>_<arch>_<version>`, for example `Git_x64_2.53.0`.

To build the package, the toolkit copies the project to `Staging\` and cleans only that copy. Each build replaces the
copy and the package.

!!! warning "Keep the test VM files secret"
    `HyperV\Golden\` holds the disk of the test VM. The disk contains the VM password as plain text. Never share
    the files in `HyperV\`.

Keep projects in this layout. A moved project stops the build with `Cannot derive the BasePath from this project path`
... Move it back, or pass `-BasePath` to [Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md).
`Cache\` and `HyperV\` always use the saved base folder, even when you pass `-BasePath`.

## Inside a project

A project is the folder `<base folder>\Projects\<template>\<app>_<arch>_<version>`. Building the package never
changes it, but other steps write into it. For example, the [install capture](glossary.md#install-capture) saves its results here. It records what the installer changes in a clean
copy of Windows.

The main file is the [deploy script](glossary.md#deploy-script), `Invoke-AppDeployToolkit.ps1`. It
installs and uninstalls the app on a device. The toolkit keeps its own code in [toolkit blocks](glossary.md#toolkit-block), between lines that start with `## win32-toolkit:`. Most blocks hold one line that calls the [toolkit extension](glossary.md#toolkit-extension).

| Item | What it is | In the package? | May you edit it? |
|---|---|---|---|
| `Assets\` | The app icon `AppIcon.png` (dialogs and Intune tile) and the dialog banner. | Yes | Yes. Replace `AppIcon.png` before you publish. |
| `Config\`, `Strings\` | PSADT settings and dialog texts from your org template. | Yes | No. Change the org template. |
| `Documentation\` | Install capture results, `TestResults.json` and prior-install files. | No | No |
| `Files\` | The installer, and the winget manifest of a winget app. | Yes | No. Never add another installer. |
| `Intune\Publications.json` | The Intune app ID of the install app, for each tenant that you published to. | No | No |
| `PSAppDeployToolkit\` | The PSADT version this project was built with. | Yes | No |
| `PSAppDeployToolkit.Win32Toolkit\` | The [toolkit extension](glossary.md#toolkit-extension): the install, uninstall, tattoo, dialog and prior-install code that the deploy script calls. | Yes | No. The package check refuses a changed copy. |
| `PSAppDeployToolkit.Extensions\`, `PSAppDeployToolkit.<name>\` | The empty extension folder of PSADT, and your org extension module. | Yes | Change your module in the org template. |
| `Sandbox\` | Test files, test logs and old versions for update tests. | No | No |
| `SupportFiles\AppConfig.json` | The app data the deploy script reads: names, switches, processes to close, uninstall. | Yes | With care. The main safe edit is `Installer.SilentArgs` of an EXE. |
| `SupportFiles\OrgHooks\` | Copies of the hook scripts of your org template. | Yes | No. Change the org template. |
| `SupportFiles\RequirementScript.ps1` | A reference script from the install capture. Nothing runs it. | Yes | No need |
| `SupportFiles\TargetedDocumentationScript.ps1` | The install capture script, next to its log. | No | No |
| `Documentation.md` | The customer document, if you made one. | No | Yes |
| `<project>_TargetedDocumentation.wsb` | The Windows Sandbox file of the install capture. Open it only while the toolkit waits for the capture. Only after a capture in Windows Sandbox. | No | No |
| `Invoke-AppDeployToolkit.exe` | The launcher that Intune starts for every install and uninstall. | Yes | No |
| `Invoke-AppDeployToolkit.ps1` | The deploy script. | Yes | Outside the toolkit blocks only. Devices run it with Windows PowerShell 5.1, so use 5.1 syntax. |

!!! warning "Re-creating deletes your edits"
    Re-creating a project deletes its folder. Copy your own code out first.

Changes to an org template reach new projects only. Re-create a project to apply them. For safe edits, see
[Change a project by hand](projects.md#change-a-project-by-hand).

## The detection key

A package writes an [install tattoo](glossary.md#install-tattoo): a registry value that tells Intune
which version is installed. The deploy script writes it at the end of a successful install and deletes it at
uninstall.

```text title="Where the install tattoo is"
HKLM\SOFTWARE\<app script author>\<publisher>\<app name>
    Version = <app version>
```

The key is in the 64-bit registry, not under `WOW6432Node`. The detection rule in Intune checks that `Version` equals
the version of your package. The names in the path come from three places.

- The [app script author](glossary.md#app-script-author) is a name in your org template, by default
  `IT Packaging Team`.
- The publisher comes from winget, or from the publisher you give for an app that is not in winget.
- The app name comes from winget, or from the name you give for an app that is not in winget.

Without a publisher there is no install tattoo. See
[How Intune detects the app](publishing.md#how-intune-detects-the-app).

Another app script author, publisher or app name changes the key. Devices that have the app keep the old key.

The [update app](glossary.md#update-app) updates only devices that already have the app. It looks for the
new key, so it can miss these devices. Never change the app script author of an org template that you already use.

The switch that stops all prior-install removals on a device also uses the app script author:
`HKLM\SOFTWARE\<app script author>\win32-toolkit`. See
[Stop all removals with the kill switch](prior-installs-devices.md#stop-all-removals-with-the-kill-switch).

If the key changes compared with an earlier version you published or pinned, the toolkit warns:
`The detection key changed from` ...

## Other places the toolkit writes

| Place | What is there |
|---|---|
| `HKCU:\Software\CloudFlow\win32-toolkit` | All settings on this page. |
| `%LOCALAPPDATA%\CloudFlow\win32-toolkit` | `update-check.json` (the last update check) and `tenants.json` (tenant names for the tenant banner). |
| `Tools\` in the toolkit folder | `IntuneWinAppUtil.exe`, the Microsoft tool that builds the package. A PowerShell Gallery install downloads it on the first build, and again after each update. |
| `%ProgramData%\win32-toolkit\locks` | Lock files, so that only one window uses the test VM or tests a project at a time. |

An update of the toolkit keeps your settings and your base folder. To remove everything, see
[Remove the toolkit](maintain-toolkit.md#remove-the-toolkit).
