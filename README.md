<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/win32-toolkit-logo-dark.svg">
    <img alt="win32-toolkit" src="docs/assets/win32-toolkit-logo.svg" width="420">
  </picture>
</h1>

Turn an installer into a tested Intune Win32 app, then keep it up to date. Use a guided menu or 17 PowerShell
commands.

**Read the full guide at [win32toolkit.com](https://win32toolkit.com).**

## What it does

win32-toolkit is a PowerShell module for Intune administrators and packagers. It works in five stages. You can do
each stage in the menu ([`Show-Win32Toolkit`](docs/reference/Show-Win32Toolkit.md)) or with a command.

```mermaid
flowchart LR
    A[Org template] --> B[Download and install capture]
    B --> C[Test]
    C --> D[Package]
    D --> E[Publish to Intune]
```

- Org template: you save the branding, dialogs and Intune defaults of a customer in an [org template](docs/glossary.md#org-template).
- Download and install capture: the toolkit downloads the installer from [winget](docs/glossary.md#winget), Microsoft's command-line app store, or you bring your own. It installs the app
  in a clean, temporary copy of Windows and records the changes. This [install capture](docs/glossary.md#install-capture) gives the app a working uninstall.
- Test: the toolkit installs and uninstalls the app and checks the result.
- Package: the toolkit builds the [package](docs/glossary.md#package), the `.intunewin` file that
  Intune needs.
- Publish: the toolkit uploads the package to Intune as a new Win32 app, with a detection rule.

## What it never does

- win32-toolkit never assigns an app. You assign it in the Intune admin center.
- Every publish creates a new app in Intune. Publishing again does not change the old app.
- win32-toolkit never turns on Windows features. You turn them on once.
- A failed test only warns. It does not stop packaging or publishing.

## What you need

The toolkit installs and tests your apps in [Windows Sandbox](docs/glossary.md#windows-sandbox), a
clean, temporary copy of Windows. It can also use the [Hyper-V test VM](docs/glossary.md#hyper-v-test-vm), an optional virtual machine that it builds once.

| You need | Notes |
|---|---|
| Windows 10 or 11 Pro, Enterprise or Education | The Home edition has no Windows Sandbox or Hyper-V. |
| PowerShell 7.4 or later | Install it with `winget install Microsoft.PowerShell`. |
| Windows Sandbox or the Hyper-V test VM | Windows Sandbox is the default. |
| winget | Only for apps and dependencies from winget. It comes with App Installer from the Microsoft Store. |
| Internet access | To download the toolkit, its tools and your installers, and to publish. |
| Admin rights | Only to turn on Windows features, to install PowerShell 7 and for the Hyper-V test VM. |

Turn on Windows Sandbox once in PowerShell as administrator, then restart the PC.

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All
```

For every step, see [Install the toolkit](docs/install.md).

## Installed later, when needed

| What | Asks first? |
|---|---|
| [PSAppDeployToolkit (PSADT)](docs/glossary.md#psadt), the free PowerShell tool that installs your app on devices | No. The toolkit installs the newest stable 4.1.x or 4.2.x version when you first package an app. |
| PwshSpectreConsole, which draws the menu | Yes, the first time you start the menu. |
| Microsoft Graph module (Microsoft.Graph.Authentication), which signs you in to Intune | Yes, the first time you connect or publish. |
| IntuneWinAppUtil.exe, which builds the `.intunewin` file | No. If it is missing, the toolkit downloads it when you build a package. It always checks the Microsoft signature. |

The toolkit installs them for your Windows account only, without admin rights.

> [!NOTE]
> On a new PC, the [system check](docs/glossary.md#system-check), a table on the main screen, shows
> some of these tools in red. This is normal. They arrive when needed.

## Install

Open PowerShell 7. Install the toolkit from the [PowerShell Gallery](docs/glossary.md#powershell-gallery), Microsoft's public store for PowerShell modules. Then start the
menu.

```powershell
Install-Module win32-toolkit -Scope CurrentUser
Show-Win32Toolkit
```

Always use `-Scope CurrentUser`. The toolkit later saves a Microsoft tool in its own folder, so it needs write access
there.

A Git clone or a ZIP download also works. Only these two include the double-click file `Launch-Win32Toolkit.cmd`.
See [Install win32-toolkit](docs/install.md#install-win32-toolkit).

## Your first app

This walk-through packages Git for Windows (`Git.Git`) in the menu. Time: about 1 to 1.5 hours the first time, much
of it waiting.

You need your [tenant ID](docs/glossary.md#tenant-id): the ID of your organization in Microsoft Entra
ID. It looks like `11111111-2222-3333-4444-555555555555`. Use the tenant ID, not a domain name.

1. Start PowerShell 7 and type `Show-Win32Toolkit`. If you see
   **Install it now for your user account? (Y/N)**, answer `Y`.
2. In the **First-run setup** panel, press <kbd>Enter</kbd> to keep `C:\Win32Apps` as your [base folder](docs/glossary.md#base-folder), the folder for all your work.
3. Choose **Org templates** > **Create a new template**. At **Template name**, type `Contoso`.
4. At **Intune tenant**, type your tenant ID. Press <kbd>Enter</kbd> at every other question to keep its default.
5. Choose **Back to the main menu** > **Package an app from winget**. Type `git` and choose `Git.Git`.
6. When asked, choose `x64` and `Contoso`. Press <kbd>Enter</kbd> at the other questions.
7. At **Build this now?** answer `y`. (The default is No.) Wait for the green **Done** panel.
8. Choose **Work with an existing project** > your project > **Run a test** > **Windows Sandbox** > **Install then
   uninstall**.
9. Choose **Publish to Intune** > **Install app**. At **Package and upload now?** answer `y`. (The default is No.)

In step 4, the answer to **App script author** stays `IT Packaging Team`, the default. This name is part of the
registry key that Intune uses to detect your apps. To use your team name, type it in step 4 and never change it later.
See [Choose the app script author once](docs/org-templates.md#choose-the-app-script-author-once).

In step 7, the toolkit creates a [project](docs/glossary.md#project): the folder of one app version,
here `Git_x64_2.53.0`. Your version will differ. Then the install capture runs in Windows Sandbox, usually for 5 to 20
minutes.

In step 9, you sign in to Intune. The first time, answer `Y` at **Install it now from PSGallery? (Y/N)**. Your org
template holds your tenant ID, so publishing refuses any other tenant.

[`Invoke-Win32Toolkit`](docs/reference/Invoke-Win32Toolkit.md) does the same work in one command. This example
tests the app and builds the package.

```powershell
# Contoso is the name of your org template
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso' -RunTest InstallUninstall -PackageIntune
```

At the end, it asks **Upload to Microsoft Intune now? (Y/N)**. Answer `n` to keep the package on your PC. For every
step, see [Package an app from winget](docs/packaging.md).

## Where your files go

Projects are grouped by org template, so you can package the same app for several customers.

```text
<base folder>\                               C:\Win32Apps by default
  Templates\<template>.json                  your org templates
  Templates\<template>\                      optional logo and scripts of a template
  Projects\<template>\<project>\             one project per app version
  Staging\<template>\<project>\              a cleaned copy, used to build the package
  IntuneWin\<template>\<project>.intunewin   the finished package
  Cache\winget\                              old installers for update tests
  HyperV\                                    only with the Hyper-V test VM
```

Building a package never changes a project. For every folder, see
[The base folder layout](docs/settings.md#the-base-folder-layout).

## Commands

To use the commands in a script, read
[Use the commands in scripts](docs/automation.md).

### Start and package

| Command | What it does |
|---|---|
| [Show-Win32Toolkit](docs/reference/Show-Win32Toolkit.md) | Starts the win32-toolkit menu, where you do every task step by step. |
| [Invoke-Win32Toolkit](docs/reference/Invoke-Win32Toolkit.md) | Packages an app from winget, from the download to an optional test, build and publish. |
| [New-Win32ToolkitManualApp](docs/reference/New-Win32ToolkitManualApp.md) | Creates a project from your own installer, for an app that is not in winget. |
| [Complete-Win32ToolkitManualApp](docs/reference/Complete-Win32ToolkitManualApp.md) | Runs the install capture of a project again, then the tests, build and publish you ask for. |

### Test a project

| Command | What it does |
|---|---|
| [Test-Win32ToolkitProject](docs/reference/Test-Win32ToolkitProject.md) | Tests a project in Windows Sandbox or the Hyper-V test VM and records the result. |

### Build and publish

| Command | What it does |
|---|---|
| [Export-Win32ToolkitIntuneWin](docs/reference/Export-Win32ToolkitIntuneWin.md) | Checks a project and builds its .intunewin package, and can publish it to Intune. |
| [Publish-Win32ToolkitIntuneApp](docs/reference/Publish-Win32ToolkitIntuneApp.md) | Uploads a .intunewin package to Intune as a new Win32 app. |
| [Export-Win32ToolkitDocumentation](docs/reference/Export-Win32ToolkitDocumentation.md) | Writes a one-page summary of a packaged app for your customer. |

### Intune sign-in

| Command | What it does |
|---|---|
| [Connect-Win32ToolkitIntune](docs/reference/Connect-Win32ToolkitIntune.md) | Signs in to Intune and shows which tenant you are connected to. |
| [Disconnect-Win32ToolkitIntune](docs/reference/Disconnect-Win32ToolkitIntune.md) | Signs out of the Intune session that win32-toolkit uses. |

### Dependencies and prior installs

| Command | What it does |
|---|---|
| [Set-Win32ToolkitAppDependency](docs/reference/Set-Win32ToolkitAppDependency.md) | Sets the apps that Intune must install before this app. |
| [Sync-Win32ToolkitAppDependency](docs/reference/Sync-Win32ToolkitAppDependency.md) | Updates the dependencies of an app that is already in Intune, without publishing it again. |
| [Set-Win32ToolkitPriorInstall](docs/reference/Set-Win32ToolkitPriorInstall.md) | Lists, adds, changes or removes the prior-install rules of a project. |

### Hyper-V test VM

| Command | What it does |
|---|---|
| [New-Win32ToolkitTestVM](docs/reference/New-Win32ToolkitTestVM.md) | Builds the Hyper-V test VM once, from a Windows 11 ISO or your own virtual disk. |
| [Set-Win32ToolkitTestVMResource](docs/reference/Set-Win32ToolkitTestVMResource.md) | Changes the processors and memory of the Hyper-V test VM and takes a new clean checkpoint. |
| [Reset-Win32ToolkitTestVM](docs/reference/Reset-Win32ToolkitTestVM.md) | Puts the Hyper-V test VM back to its clean checkpoint. |
| [Remove-Win32ToolkitTestVM](docs/reference/Remove-Win32ToolkitTestVM.md) | Deletes the Hyper-V test VM and, if you ask, its disk files. |

## Documentation

Start with [How win32-toolkit works](docs/how-it-works.md), then follow the seven steps.

1. [Install the toolkit](docs/install.md)
2. [Create your org template](docs/org-templates.md)
3. [Package an app from winget](docs/packaging.md)
4. [Test the package](docs/testing.md)
5. [Build the package](docs/build-intunewin.md)
6. [Connect to Intune](docs/intune-connection.md)
7. [Publish to Intune](docs/publishing.md)

When you are stuck, use [Find a task](docs/tasks.md), [Troubleshooting](docs/troubleshooting.md) or the
[Glossary](docs/glossary.md). For apps and projects from an older toolkit, read
[Coming from win32-toolkit 1.1.6 or older](docs/maintain-toolkit.md#coming-from-win32-toolkit-116-or-older). For
offline help, type `Get-Help <command> -Full`.

## Credits

[Community tools and credits](docs/credits.md) lists the free tools that the toolkit uses, with their authors and
licenses.

## License

win32-toolkit is free and open source under the [MIT license](LICENSE).
