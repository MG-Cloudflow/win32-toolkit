---
description: "Plain explanations of the words used in the win32-toolkit guide."
hide:
  - toc
---

# Glossary

This page explains the words of the win32-toolkit guide, the menu and the console. Each entry links to the page where
the word matters most.

Letters: [A](#a) [B](#b) [C](#c) [D](#d) [E](#e) [F](#f) [G](#g) [H](#h) [I](#i) [K](#k) [L](#l) [M](#m) [N](#n)
[O](#o) [P](#p) [R](#r) [S](#s) [T](#t) [U](#u) [V](#v) [W](#w) [Z](#z).

## A

### Acknowledgement

Your recorded acceptance of a known risk of a prior-install rule, such as `DATA-LOSS`. You give it again for each new
version.
See: [Enforce rules](prior-installs-enforce.md#acknowledgements-and-waivers).

### Admin consent

A one-time approval by a tenant administrator that lets an app use a permission. The toolkit's sign-in needs it.
See: [Connect to Intune](intune-connection.md#what-your-account-needs).

### Advanced app

An app that is not in winget, where you write the install code yourself. Also called: hard app (in the console).
See: [Apps not in winget](manual-apps.md#easy-or-advanced).

### App ID

The fixed ID, a [GUID](#guid), that Intune gives every app. An `intune:` dependency uses it.
See: [Dependencies](dependencies.md#three-kinds-of-reference).

### App script author

The org template answer that names your packaging team (default `IT Packaging Team`). The registry paths of the
install tattoo and the kill switch use it.
See: [Org templates](org-templates.md#answer-the-questions-that-matter).

### Approval

Your recorded "yes" to remove exactly one captured prior install. Every Enforce rule from a sibling capture needs one.
See: [Enforce rules](prior-installs-enforce.md#approve-a-proposal-as-enforce).

### Assertion

See [Check](#check).

### Assignment

Which users or devices get an app, and how. win32-toolkit never assigns an app. You assign it in the Intune admin
center.
See: [Publishing](publishing.md#finish-in-the-intune-admin-center).

### Assisted capture

A sibling capture where you run each setup yourself, in the window of the Hyper-V test VM (virtual machine). What it
records can only become a Block or Report rule, never Enforce. It is a command line option only.
See: [Prior installs](prior-installs.md#capture-more-versions-or-capture-by-hand).

### AutoLogon

A Windows setting that signs a user in at start. The Hyper-V test VM uses it, so PSAppDeployToolkit (PSADT) dialogs
can appear.
See: [Hyper-V test VM](hyperv-vm.md#prepare-windows-inside-the-vm).

## B

### Base folder

The one folder for your org templates, projects and packages (default `C:\Win32Apps`). Also called: `BasePath`.
See: [Install](install.md#choose-your-base-folder).

### Baseline

The console's word for the old version in an update test. The test installs it first, then your package over it.
See: [Testing](testing.md#test-an-update-from-an-older-version).

### Block

A prior-install rule mode: if the prior install is on the device, your install fails. Nothing is removed.
See: [Prior installs](prior-installs.md#block-enforce-and-report).

## C

### Check

One automatic check in a test, with the result PASS, FAIL or SKIP. Also called: assertion (in the console and the logs).
See: [Testing](testing.md#what-the-checks-mean).

### Checkpoint

A saved state that a VM can go back to. Every test on the test VM starts from its clean checkpoint, by default
`clean-base`.
See: [Hyper-V test VM](hyperv-vm.md#re-take-the-checkpoint).

### Cleanup folders

Folders that the uninstall deletes, as SYSTEM, after the app's own uninstaller has run. They must be inside the app's
own install folder.
See: [Build the package](build-intunewin.md#the-package-check).

### Company Portal

The Microsoft app where users install the apps that you made Available.
See: [Publishing](publishing.md#finish-in-the-intune-admin-center).

### Customer document

A one-page `Documentation.md` about a packaged app, for your customer. By default it has no tenant or app IDs.
See: [Publishing](publishing.md#give-your-customer-a-one-page-summary).

## D

### Default Switch

The built-in Hyper-V network that shares your PC's internet connection. The test VM uses it by default.
See: [New-Win32ToolkitTestVM](reference/New-Win32ToolkitTestVM.md).

### Deferral

The person at the device postpones the install in a PSADT dialog, and Intune tries again later. The org template
allows 3 deferrals by default.
See: [Org templates](org-templates.md#when-dialogs-appear-on-devices).

### Dependency

Another app that must be on the device first. Intune installs it first, or only checks that it is there.
See: [Dependencies](dependencies.md).

### Deploy script

`Invoke-AppDeployToolkit.ps1`, the PowerShell script in each project. It installs and removes the app on the device.
See: [Projects](projects.md#change-a-project-by-hand).

### Detection key

See [Install tattoo](#install-tattoo).

### Detection rule

How Intune checks that the app is installed. The toolkit uses the install tattoo, or else the install capture.
See: [Publishing](publishing.md#how-intune-detects-the-app).

### Device code sign-in

A sign-in where PowerShell shows a short code. You type it on a Microsoft web page, on any computer or phone. Only
[`Connect-Win32ToolkitIntune`](reference/Connect-Win32ToolkitIntune.md) offers it.
See: [Connect to Intune](intune-connection.md#connect).

### Dry run

A run that shows what a command would do, without doing it (`-WhatIf`).
See: [Publishing](publishing.md#try-it-first-with-a-dry-run).

## E

### Easy app

An app not in winget where the toolkit writes the install for you. It is an MSI, an MSIX or APPX package, or an EXE
with silent switches.
See: [Apps not in winget](manual-apps.md#easy-or-advanced).

### Elevated

A PowerShell window started with **Run as administrator**. You need it only to turn on Windows features and for the
Hyper-V test VM.
See: [Install](install.md#turn-on-windows-sandbox).

### Enforce

A prior-install rule mode: remove the prior install, then install. Enforce removes another install as SYSTEM. Assign
the package to a pilot group first.
See: [Enforce rules](prior-installs-enforce.md).

### Environment variable

A named value that a PowerShell window can read, such as `W32T_HYPERV_VM`.
See: [Settings and folders](settings.md#environment-variables).

### Exit code

The number a program returns when it ends. 0 usually means success, and 3010 means success with a restart.
See: [Exit codes](exit-codes.md).

### Extension module

A PowerShell module with your own functions. PSADT loads it in every package of your org template.
See: [Org template files](org-template-files.md#add-an-extension-module).

## F

### Fluent and Classic

The modern and the older look of PSADT dialogs. The org template chooses one (default Fluent).
See: [Org templates](org-templates.md#when-dialogs-appear-on-devices).

## G

### Guest

See [Test machine](#test-machine).

### GUID

A long ID of letters and digits in five groups, such as `11111111-2222-3333-4444-555555555555`. It never changes.
See: [Tenant pin](intune-connection.md#pin-the-tenant-on-your-org-template).

## H

### Hard app

See [Advanced app](#advanced-app).

### Hook script

A `.ps1` file from your org template, such as `PreInstall.ps1`, that runs at a fixed step.
See: [Org template files](org-template-files.md#add-hook-scripts).

### Hyper-V

The virtual machine software in Windows Pro, Enterprise and Education.
See: [Hyper-V test VM](hyperv-vm.md#prepare-your-pc).

### Hyper-V test VM

An optional Windows VM that you build once for tests. It goes back to a clean checkpoint before each test.
See: [Hyper-V test VM](hyperv-vm.md).

## I

### Inconclusive

A result without a clear answer: the test stopped early, was closed, timed out or did not start.
See: [Testing](testing.md#passed-failed-inconclusive).

### Install app

The normal Intune app of your package. Every publish creates a new app in Intune. Publishing again does not change the
old app.
See: [New versions](new-version.md#install-app-update-app-or-both).

### Install capture

The toolkit installs the app on a clean test machine and records what changed. It usually takes 5 to 20 minutes. Also
called: documentation capture or targeted documentation (in the console).
See: [Packaging](packaging.md#the-install-capture).

### Install tattoo

A registry value that the package writes after a good install. Intune reads it to see which version is installed. Also
called: detection key.
See: [Settings and folders](settings.md#the-detection-key).

### Installer family

Installer technologies that register the same way. MSI and WiX, for example, are both the MSI family.
See: [Packaging](packaging.md#pin-it-on-the-command-line).

### Installer technology

How the vendor built the setup, for example MSI, NSIS or MSIX. Also called: installer type.
See: [Packaging](packaging.md#installer-technology).

### Interactive test

A test that you watch, with a pause to check the app yourself.
See: [Testing](testing.md#interactive-or-unattended).

### Intune admin center

The Microsoft web portal for Intune. Also called: Intune portal (in the console).
See: [Publishing](publishing.md#finish-in-the-intune-admin-center).

### Intune Management Extension

The Intune program that installs Win32 apps on a device. It is a 32-bit program.
See: [Exit codes and logs](exit-codes.md#where-to-find-logs).

### Intune parity

Testing a package the way Intune runs it: the same command, as SYSTEM, from a 32-bit program.
See: [Testing](testing.md#test-as-intune-does).

### Intune role

The Intune permissions of your account. Linking apps to each other also needs the Relate permission.
See: [Connect to Intune](intune-connection.md#what-your-account-needs).

### Intune-parity pre-check

A check before an unattended Hyper-V test. It does not start a test that would only wait for a PSADT 4.1 dialog.
See: [Testing](testing.md#when-a-test-is-not-started).

### Intunewin file

The encrypted file format that Intune needs for a Win32 app. This guide calls it the package.
See: [Build the package](build-intunewin.md).

### IntuneWinAppUtil

The free Microsoft tool that builds `.intunewin` files. If it is missing, the toolkit downloads it the first time you
build.
See: [Build the package](build-intunewin.md#what-happens-when-you-build).

### ISO

A file that holds a Windows installation disc. You can build the Hyper-V test VM from one.
See: [Hyper-V test VM](hyperv-vm.md#prepare-your-pc).

## K

### Kill switch

A registry value, `RemovePriorDisabled` = `1`, that stops every prior-install removal on a device. An install that
would remove a prior install then fails with 69111.
See: [Kill switch](prior-installs-devices.md#stop-all-removals-with-the-kill-switch).

## L

### Launcher

`Invoke-AppDeployToolkit.exe`, the small program that Intune starts. It runs the deploy script in 64-bit Windows
PowerShell.
See: [Publishing](publishing.md#why-the-install-command-is-invoke-appdeploytoolkitexe).

### Lease

A lock that lets only one PowerShell window use the test VM. Messages call it the lease file.
See: [Test VM care](hyperv-vm-care.md#when-another-window-is-using-the-vm).

## M

### Manual app

An app that is not in winget: you give the installer yourself. The menu and the command names use this word. It is an
Easy app or an Advanced app.
See: [Apps not in winget](manual-apps.md).

### Maximum run time

How long Intune lets an install run before it stops it. The org template sets it (default 60 minutes).
See: [Org templates](org-templates.md#all-questions-and-their-defaults).

### Menu

The text menu that [`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md) starts. Use the arrow keys and
<kbd>Enter</kbd>.
See: [The menu](menu.md).

### Microsoft Entra ID

The Microsoft cloud service for accounts and sign-in, once called Azure AD.
See: [Connect to Intune](intune-connection.md#what-your-account-needs).

### Microsoft Graph

The Microsoft web interface that the toolkit uses to create apps in Intune.
See: [Connect to Intune](intune-connection.md).

### Module

A package of PowerShell commands that you install once. win32-toolkit is a module.
See: [Install](install.md#install-win32-toolkit).

### MSI

A Windows Installer package. Windows installs and removes it silently, without extra switches.
See: [Apps not in winget](manual-apps.md#package-an-easy-app).

### MSIX and APPX

Modern Windows app packages, alone or in a bundle. They must be signed and need no switches.
See: [Apps not in winget](manual-apps.md#msix-and-appx-packages).

## N

### Not-configured project

A project whose build stopped halfway. The toolkit refuses to build or publish it until you package the app again.
See: [Projects](projects.md#recover-from-a-stopped-build).

### NSIS, Inno Setup, WiX and Burn

Tools that build setup programs, named `nullsoft`, `inno`, `wix` and `burn` in winget. Enforce can remove only NSIS
and Inno Setup installs.
See: [Packaging](packaging.md#why-it-matters).

## O

### Old version

See [Baseline](#baseline).

### Org template

Your saved settings for one organization or customer. Changes to an org template reach new projects only. Re-create
a project to apply them.
See: [Org templates](org-templates.md).

## P

### Package

The `.intunewin` file that you upload to Intune. The toolkit builds it from your project.
See: [Build the package](build-intunewin.md).

### Package check

The checks the toolkit runs on a project before it builds the package. A serious problem stops the build. Others
only warn.
See: [Build the package](build-intunewin.md#the-package-check).

### Pilot group

A small group of users or devices that gets a new app before everyone else.
See: [Prior installs on devices](prior-installs-devices.md#roll-out-safely).

### Pin

To save one choice, so the toolkit always uses it: a tenant, an installer technology, a PSADT version or a test VM.
See: [Tenant pin](intune-connection.md#pin-the-tenant-on-your-org-template).

### PowerShell 7 and Windows PowerShell 5.1

The toolkit needs PowerShell 7.4 or later. Devices run the deploy script in the built-in Windows PowerShell 5.1.
See: [Install](install.md#install-powershell-7).

### PowerShell Gallery

The Microsoft online store for PowerShell modules, such as win32-toolkit and PSADT.
See: [Install](install.md#install-win32-toolkit).

### Prerelease

A test version of software, such as PSADT `4.2.0-rc2`. The toolkit never installs one for you.
See: [Choose the PSADT version](maintain-toolkit.md#choose-the-psadt-version-for-new-projects).

### Prior install

The same app on a device, from another installer technology than your package.
See: [Prior installs](prior-installs.md).

### Prior-install rule

An exact description of one prior install, and what your package does when it finds it.
See: [Prior installs](prior-installs.md#see-change-or-remove-rules).

### Processes to close

Programs of the app that PSADT asks the person at the device to close before it installs or removes the app.
See: [Projects](projects.md#change-a-project-by-hand).

### Project

The folder with everything for one app version, such as `Git_x64_2.53.0`.
See: [Settings and folders](settings.md#inside-a-project).

### Proof

A passed unattended update test on the Hyper-V test VM. It shows that the package removes the prior install of an
Enforce rule correctly.
See: [Enforce rules](prior-installs-enforce.md#prove-the-rule).

### Proposal

A prior-install rule that a sibling capture suggests. It does nothing until you apply it.
See: [Prior installs](prior-installs.md#review-the-proposals).

### PSADT

PSAppDeployToolkit, the free PowerShell tool that installs and removes the app in every package. The toolkit supports 4.1
and 4.2.
See: [Choose the PSADT version](maintain-toolkit.md#choose-the-psadt-version-for-new-projects).

### Publication record

The file `Intune\Publications.json` in a project. It remembers the app ID of the install app in each tenant that you
published to. It never goes to devices.
See: [Settings and folders](settings.md#inside-a-project).

### Publish

To upload the package to Intune and create the app there. win32-toolkit never assigns an app. You assign it in the
Intune admin center.
See: [Publishing](publishing.md#publish-your-app).

### PwshSpectreConsole

The free module that draws the menu. The menu offers to install it on the first start.
See: [Install](install.md#what-the-toolkit-installs-later).

## R

### Re-create

To make a project again from the start. Re-creating a project deletes its folder. Copy your own code out first.
See: [Projects](projects.md#re-create-a-project).

### Registry

The Windows database of settings. The toolkit keeps its settings under `HKCU:\Software\CloudFlow\win32-toolkit`.
See: [Settings and folders](settings.md#other-places-the-toolkit-writes).

### Registry view

On 64-bit Windows, 32-bit programs write to a separate part of the registry, `WOW6432Node`.
See: [Prior installs on devices](prior-installs-devices.md#stop-all-removals-with-the-kill-switch).

### Report

A prior-install rule mode: the package notes the prior install and installs anyway.
See: [Prior installs](prior-installs.md#block-enforce-and-report).

### Requirement rule

A condition that a device must meet before Intune installs an app there. The update app uses one.
See: [New versions](new-version.md#install-app-update-app-or-both).

### Result

The outcome of a test: Passed, Failed or Inconclusive. A failed test only warns. It does not stop packaging or
publishing. Also called: verdict.
See: [Testing](testing.md#passed-failed-inconclusive).

### Result object

What a command returns to a script, with its `Status` and `Problems`. When a W32T error stops the command, it
returns nothing.
See: [Check the result](automation.md#check-the-result).

### Return code

An exit code listed in an Intune app, with its meaning: success, restart, retry or failed.
See: [Exit codes](exit-codes.md#codes-intune-treats-as-success-or-retry).

## S

### Sibling capture

A capture of the other installer technologies of the app. Each capture run takes 3 to 5 minutes, and each technology
is captured twice.
See: [Prior installs](prior-installs.md#capture-the-other-installer-technologies).

### Silent switches

Options that make an installer run without windows, such as `/S`. An MSI or MSIX needs none.
See: [Projects](projects.md#change-a-project-by-hand).

### Staging copy

A cleaned copy of a project, used only to build the package. The project itself does not change.
See: [Build the package](build-intunewin.md#what-happens-when-you-build).

### Supersedence

An Intune setting that says one app replaces another. The toolkit never sets it.
See: [New versions](new-version.md#replace-the-old-app-in-intune).

### SYSTEM account

The built-in Windows account that Intune uses to install apps. It has full rights on the device.
See: [Testing](testing.md#test-as-intune-does).

### System check

The table on the menu's main screen. It shows what is installed and what is missing.
See: [Install](install.md#read-the-system-check).

## T

### Technology switch

A warning of an update test. The old version, from another installer technology, was still registered after your
package installed. Devices with that old install would get two installs.
See: [Packaging](packaging.md#when-a-test-reports-a-technology-switch).

### Tenant

One organization's own space in Microsoft 365, Entra ID and Intune.
See: [Connect to Intune](intune-connection.md#check-the-tenant-banner).

### Tenant ID

The fixed ID of a tenant, a GUID. Use the tenant ID, not a domain name.
See: [Tenant pin](intune-connection.md#pin-the-tenant-on-your-org-template).

### Test backend

The kind of test machine that a test uses. In the menu, you choose it at **Which test backend?**
See: [Testing](testing.md#choose-where-the-test-runs).

### Test machine

The clean Windows where the toolkit installs the app for a capture or a test: Windows Sandbox or the Hyper-V test VM.
Also called: guest.
See: [How it works](how-it-works.md#windows-sandbox-or-the-hyper-v-test-vm).

### Token

Proof of your sign-in that PowerShell keeps for a while, so you do not sign in for every step.
See: [Connect to Intune](intune-connection.md#sign-out).

### Toolkit block

A part of the deploy script that starts with `## win32-toolkit:`. The toolkit may rewrite it, so never change the
code inside it.
See: [Apps not in winget](manual-apps.md#write-the-install-code).

## U

### Unattended test

A test that runs from start to end without a person or pauses. On the Hyper-V test VM, it runs as Intune does.
See: [Testing](testing.md#interactive-or-unattended).

### Uninstall entry

The registry record that lists an app in Installed apps, with its uninstall command. Also called: Add/Remove Programs
entry.
See: [Type a rule by hand](prior-installs-enforce.md#type-a-rule-by-hand).

### Update app

A second Intune app of the same package, only for devices with an older version. By default, its name ends with
"(Update)".
See: [New versions](new-version.md#install-app-update-app-or-both).

### Update test

A test that installs an old version, then your package over it, and checks the update.
See: [Testing](testing.md#test-an-update-from-an-older-version).

## V

### Verdict

See [Result](#result).

### Version window

The versions that a prior-install rule covers, from `VersionMin` to `VersionMax`.
See: [Prior installs](prior-installs.md#review-the-proposals).

### VHDX

The file that holds the virtual disk of a VM. If you build the test VM from an ISO, its disk is in
`<base folder>\HyperV\Golden`.
See: [Remove the VM](hyperv-vm-care.md#remove-the-vm).

### Virtual machine

A complete Windows computer that runs as a program inside your PC. Also called: VM.
See: [Hyper-V test VM](hyperv-vm.md#when-you-need-the-test-vm).

## W

### W32T error

An error that stops a command on purpose. Its ID starts with `W32T.`, for example `W32T.ProjectNotConfigured`.
See: [Troubleshooting](troubleshooting.md#error-ids).

### Waiver

A recorded exception for a prior-install rule, for example to build without a proof. Only a rule that you typed or
took from an update test can get one. A rule from a sibling capture cannot. You give it again for each new version.
See: [Enforce rules](prior-installs-enforce.md#acknowledgements-and-waivers).

### Win32 app

The Intune app type for classic Windows installers, uploaded as one `.intunewin` file.
See: [How it works](how-it-works.md).

### Windows Sandbox

A clean, temporary Windows inside your PC. It forgets everything when it closes. win32-toolkit never turns on Windows
features. You turn them on once.
See: [Install](install.md#turn-on-windows-sandbox).

### winget

The Microsoft command-line app store. The toolkit uses it to find and download installers.
See: [Install](install.md#check-your-pc).

### winget ID

The exact name of an app in winget, such as `Git.Git`.
See: [Packaging](packaging.md#run-the-wizard).

### winget manifest

The small `.yaml` file that describes an installer in winget, such as its silent switches.
See: [Packaging](packaging.md#warnings-after-the-download).

## Z

### Zero-Config MSI

A PSADT feature that installs and removes an MSI by itself. The toolkit uses it for MSI installers.
See: [Packaging](packaging.md).
