# Getting started — package your first app

This tutorial walks you through packaging **Git for Windows** (winget ID `Git.Git`) end-to-end
using the interactive menu (TUI): search winget, build a PSADT project, capture the install in
Windows Sandbox, and produce an `.intunewin` file ready for Intune. No PowerShell knowledge is
required beyond copy-pasting the commands below.

## 0. Prerequisites

You need two things before the first run:

| Prerequisite | How to get it |
|---|---|
| **PowerShell 7.2 or later** | In a normal command prompt, run: `winget install Microsoft.PowerShell` |
| **Windows Sandbox** | Windows 10/11 **Pro, Enterprise, or Education** only. Enable it (elevated PowerShell), then **reboot**. |

To enable Windows Sandbox, open PowerShell **as administrator** and run:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All
```

Then **restart the PC** — the feature does not work until after a reboot.

Don't worry about getting everything perfect: the very first screen of the TUI is a **system
check** table that names each prerequisite (PowerShell version, winget, PSAppDeployToolkit v4,
Windows Sandbox, base folder, and the publish/packaging tools), marks what is missing, and tells
you what it is needed for. Fixable items can be resolved from **Settings**, or the toolkit offers
to fix them the first time you use a feature that needs them.

<!-- SCREENSHOT: The TUI health/system-check table showing OK and missing rows -->

Everything else (PSAppDeployToolkit v4, `IntuneWinAppUtil.exe`, the Graph module for publishing)
is installed or downloaded on demand — you will simply be asked to confirm.

## 1. Launch the menu

Two equivalent ways:

- **Double-click `Launch-Win32Toolkit.cmd`** in the toolkit folder. It opens PowerShell 7,
  imports the module, and starts the menu.
- Or from a PowerShell 7 window:

```powershell
Import-Module C:\path\to\win32-toolkit\win32-toolkit.psd1
Show-Win32Toolkit
```

On the very first launch you are offered a **one-time install of PwshSpectreConsole** — the
component that renders the menus. Answer `Y`; it installs for your user account only.

<!-- SCREENSHOT: The TUI main menu with the figlet banner and the option list -->

## 2. First-run setup

Two short one-time steps, both guided:

1. **Base folder** — a welcome panel asks where all output should live (default `C:\Win32Apps`).
   Press Enter to accept. The choice is saved to the registry, so you pick it exactly once.
2. **Org template** — before your first package, create a template that stores your company
   branding and dialog preferences (company name, accent colour, install/uninstall messages,
   deferral behaviour, and so on). Open **Org templates** from the main menu and follow the
   wizard — one question per line, sensible defaults everywhere. See
   [Org templates](org-templates.md) for what each prompt controls.

## 3. Package Git

From the main menu choose **Package an app from winget (search)**. The wizard walks you through:

1. **Search** — type `git` and press Enter.
2. **Select** — a filterable list of winget results appears; pick **Git (Git.Git)**.
3. **Architecture** — pick `x64` (the wizard only asks when the app ships more than one).
4. **Template** — pick the org template you created in step 2.
5. **Dependencies** — asked whether this app needs another app installed first. For Git, answer
   `n`.
6. **After building** — a multi-select of extra actions: run an install/uninstall test, package
   to `.intunewin`, publish to Intune. For a first run, toggle **Package to .intunewin** with the
   space bar and press Enter.
7. **Review and confirm** — a summary panel shows the app, ID, architecture, template, and chosen
   actions. Confirm to start the build.

### What you'll see

The build runs on its own from here — this is what happens, in order:

- **Download** — winget downloads the Git installer into the new project's `Files\` folder.
- **Project scaffold** — a full PSAppDeployToolkit v4 project is created under
  `<BasePath>\Projects\<Template>\Git_x64_<version>\`, the installer is detected (EXE/MSI) and
  the deployment script is configured, and your org-template branding is applied.
- **A Windows Sandbox window opens** — this is normal, don't close it. The toolkit installs Git
  inside the disposable sandbox and records every change it makes (files, registry, services,
  shortcuts).
- **The capture runs unattended** — expect roughly **10–20 minutes** depending on the app and
  your hardware (Windows Sandbox boots a clean Windows every time). You don't need to touch
  anything; go get a coffee. The sandbox closes itself when done.
- **Results are processed** — from the captured changes the toolkit generates:
  - `SupportFiles\RequirementScript.ps1` — a ready-to-paste Intune requirement script;
  - the **uninstall logic** in the deployment script (for EXE installers, derived from the
    captured uninstall registry entry — you never write it by hand);
  - the list of app processes to close before install/uninstall;
  - the app icon (from winget, or extracted from the actual install when winget has none).

When the wizard reports **Done**, the project is complete. Use **Browse projects** from the main
menu to inspect it.

## 4. Where your .intunewin lands

Because you toggled **Package to .intunewin**, the toolkit also copied the project to a staging
area, cleaned it, and ran Microsoft's `IntuneWinAppUtil.exe`. The result is:

```
<BasePath>\IntuneWin\<Template>\Git_x64_<version>.intunewin
```

That file is what you upload to Intune — manually via the portal, or automatically (next step).
You can package any existing project at any time via **Work with an existing project** →
package.

## 5. Optional: publish to Intune

The wizard's **Publish to Intune** action (or the same option under *Work with an existing
project*) uploads the `.intunewin` straight to your tenant via Microsoft Graph, creating the
Win32 app with metadata, icon, and a detection rule derived from the sandbox capture. Publishing
is deliberately gated behind an extra confirmation in the TUI.

Two things to know before you try it:

- You sign in interactively (browser pop-up); the toolkit requests only the
  `DeviceManagementApps.ReadWrite.All` Graph scope.
- **The first sign-in may require admin consent** in your tenant for that scope — if consent has
  not been granted, ask a Global Administrator or use a pre-consented account.

Details, dependencies between apps, and troubleshooting: [Publishing](publishing.md).

## 6. The same thing as one command

Everything the wizard just did is a thin front-end over one public command. This single line
reproduces the whole tutorial — build, sandbox capture, package — without any menus:

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso' -Force -PackageIntune
```

Add `-RunTest InstallUninstall` to also test the package, or `-PublishIntune` to upload it. See
[Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md) for the full parameter reference.
