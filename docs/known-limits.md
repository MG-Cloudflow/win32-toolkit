---
description: "Things win32-toolkit does not do yet, and what to do instead."
---

# Known limits

This list is honest on purpose: it shows what win32-toolkit cannot do yet, and what to do instead. Each row links the
page with the details. A row disappears when a new version fixes the limit.

## Limits and workarounds

The rows follow the order of the guide. The [Glossary](glossary.md) explains the words in the table.

| Limit | What to do | Page |
|---|---|---|
| The base folder prompts keep quotation marks, for example from **Copy as path** in File Explorer. Later steps then fail. | Type the path without quotes. To fix a saved path, choose **Settings** > **Change the base folder** in the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)). | [Move or change the base folder](maintain-toolkit.md#move-or-change-the-base-folder) |
| A [tenant pin](glossary.md#pin) with a domain name, such as `contoso.onmicrosoft.com`, never matches. Connecting and publishing stop with an error that contains `Connected to tenant`. | Use the tenant ID, not a domain name. Changes to an org template reach new projects only. Re-create a project to apply them. | [Pin the tenant on your org template](intune-connection.md#pin-the-tenant-on-your-org-template) |
| Org template texts are not checked for curly double quotes (`“` and `”`), for example from Word. On devices they can cut the text short. | Use straight quotes in **Org templates** > **Edit a template**, then re-create your projects. | [Text rules](org-templates.md#text-rules) |
| Packaging from winget always takes the newest version that winget lists. You cannot choose an older one. | Download the older installer yourself and package it as an app that is not in winget. | [Which version is packaged](packaging.md#which-version-is-packaged) |
| The menu replaces an existing project of the same app, architecture and version without asking. | Re-creating a project deletes its folder. Copy your own code out first. Without `-Force`, the commands ask before they replace a project. | [Re-create a project](projects.md#re-create-a-project) |
| The packaging wizards in the menu offer only the install and uninstall test, not the update test. | After the build, choose **Work with an existing project** > choose your project > **Run a test**, then **Update from an older version**. | [Test an update from an older version](testing.md#test-an-update-from-an-older-version) |
| Every publish creates a new app in Intune. Publishing again does not change the old app. | Replace the old app with [supersedence](glossary.md#supersedence) in the Intune admin center. Delete apps that you published twice by mistake. | [Replace the old app in Intune](new-version.md#replace-the-old-app-in-intune) |
| If publishing stops after the line `✓ App created`, the incomplete app stays in Intune. | Delete the incomplete app in the Intune admin center, fix the cause, then publish again. | [If the publish fails](publishing.md#if-the-publish-fails) |
| Apps that are not in winget do not store the tenant pin. A later publish only warns that it cannot check the tenant. | Before you publish, choose **Microsoft Intune connection** > **Connect using an org template's tenant**. Check the tenant name in the banner. | [Check the tenant banner](intune-connection.md#check-the-tenant-banner) |
| An MSI app that is not in winget is published under its project folder name, such as `Contoso_Reader_x64_3.2.0`. | Rename the app in the Intune admin center. | [Known limits of manual apps](manual-apps.md#known-limits) |
| Square brackets in an installer folder path, such as `C:\Installers\Reader [x64]`, break the copy. The build then stops, usually with an error that contains `No installer (msi/exe/msix/appx) detected`. | Rename the folder, or move the files to a folder without brackets. A path to a single installer file works. | [Installer files and folders](manual-apps.md#installer-files-and-folders) |
| The update test of an app that is not in winget cannot download an old version. | Package the older version as its own project first. Then choose that project as the old version, which the menu calls the baseline. | [Test an update of a manual app](manual-apps.md#test-an-update-of-a-manual-app) |
| MSIX and APPX apps: the package installs only the app. Framework packages that the app needs, such as VCLibs, are not installed. | Deploy the framework packages to devices in another way first. Without them, Windows stops the install with error `0x80073CF3`. | [MSIX and APPX packages](manual-apps.md#msix-and-appx-packages) |
| The menu has no action to change the dependencies of an app that is already in Intune. | Change the project's dependencies, then run [`Sync-Win32ToolkitAppDependency`](reference/Sync-Win32ToolkitAppDependency.md) on the command line. Do not publish again, even if the menu says so. | [Change the dependencies of an app in Intune](dependencies.md#change-the-dependencies-of-an-app-in-intune) |
| Saving dependencies in the menu turns every `detect` dependency (only check for it) into `autoInstall`, the default. | Set it again on the command line: [`Set-Win32ToolkitAppDependency`](reference/Set-Win32ToolkitAppDependency.md) with `-DependsOn` and `-DependencyType detect`. | [Install it first or only check for it](dependencies.md#install-it-first-or-only-check-for-it) |
| After a [sibling capture](glossary.md#sibling-capture) in Windows Sandbox or an [assisted capture](glossary.md#assisted-capture), a rule can never remove that install. It can only be Block or Report. | Capture on the Hyper-V test VM, without assisted mode. If the menu says that Hyper-V is not ready, answer `n` (the default). | [Capture the other installer technologies](prior-installs.md#capture-the-other-installer-technologies) |
| An Enforce rule can remove only NSIS and Inno Setup [prior installs](glossary.md#prior-install). It cannot remove other installer technologies, such as MSI. | Keep one installer technology on your devices: package the technology that they already have. | [Installer technology](packaging.md#installer-technology) |
| Removing the test VM, in the menu or with [`Remove-Win32ToolkitTestVM`](reference/Remove-Win32ToolkitTestVM.md) `-RemoveVhdx`, can leave its base disk file behind. | Look in `<base folder>\HyperV\Golden` afterwards. Delete the `.vhdx` file there if you no longer need it. | [Remove the VM](hyperv-vm-care.md#remove-the-vm) |

If a message stops you instead, see [Troubleshooting](troubleshooting.md).
