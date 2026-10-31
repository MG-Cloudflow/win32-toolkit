---
description: "Create a project for an app from winget, understand the install capture, and choose the installer technology on purpose."
---

# Package an app from winget

In this step, win32-toolkit builds a [project](glossary.md#project): the folder with the installer, the
scripts and the settings for one app version. It gets the app from [winget](glossary.md#winget), the
Windows Package Manager. The toolkit also installs the app once on a clean copy of Windows, to learn how to remove and
detect it.

## Before you start

Step 3 of 7.

- You installed the toolkit in [step 1](install.md). In [step 2](org-templates.md) you created an [org template](glossary.md#org-template): your saved settings for one customer. This guide uses the org template
  `Contoso`.
- winget works on your PC. It comes with the App Installer app from the Microsoft Store.
- [Windows Sandbox](glossary.md#windows-sandbox) is turned on. It is a clean, temporary copy of Windows
  where the toolkit tests apps. See [Turn on Windows Sandbox](install.md#turn-on-windows-sandbox). A ready Hyper-V test
  virtual machine (VM) also works. See [Set up the Hyper-V test VM](hyperv-vm.md).
- Your PC can download from the internet. The toolkit uses winget, GitHub and, the first time, the PowerShell Gallery.
- Time: 2 to 5 minutes, then usually 5 to 20 minutes of waiting for the install capture.

## Run the wizard

The example app is Git for Windows. Its [winget ID](glossary.md#winget-id) is `Git.Git`: the exact,
unique name of the app in winget. The [installer technology](glossary.md#installer-technology) is how
the vendor built the setup program, for example as an MSI or as an EXE. Some apps ship more than one.

=== "Menu"

    Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) and answer the questions of the wizard.

    1. In the main menu, choose **Package an app from winget**.
    2. At **Search winget for**, type `git` and press <kbd>Enter</kbd>.
    3. At **Select the application**, choose **Git (Git.Git)**.
    4. If the wizard asks **Target architecture**, choose `x64`.
    5. At **Choose an org template**, choose `Contoso`. Some apps then ask more questions: see after this list.
    6. At **Does this app need another app installed FIRST**, answer `n`. (The default is No.)
    7. At **After building, also…**, tick nothing and press <kbd>Enter</kbd>.
    8. Read the **Review** panel. Check the app, the architecture and the template.
        <!-- SCREENSHOT: The winget wizard Review panel for Git (Git.Git), x64, org template Contoso, right before the Build this now? question -->
    9. At **Build this now?**, type `y` and press <kbd>Enter</kbd>. (The default is No.)

    The search never shows Microsoft Store results. **Target architecture** appears only when there is a choice. Only
    some apps get these extra questions after the org template:

    - A question about the installer technology, when winget ships more than one. Read
      [Installer technology](#installer-technology) before you answer.
    - **Also capture the other installer technologies…?** Answer `n` for now (the default is No). This is for
      [devices that already have the app](prior-installs.md).

    Dependencies are explained in [Apps that need another app first](dependencies.md). **After building, also…**
    offers a test, the package and the publish. In this guide you do each of these steps yourself.

    !!! warning "The menu replaces existing projects"

        If a project of the same app, architecture and version exists, the menu replaces it without asking.
        Re-creating a project deletes its folder. Copy your own code out first.

=== "Command line"

    This command builds the same project for Git.

    ```powershell
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso'
    ```

    [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md) runs the same steps as the wizard. It chooses the
    installer technology itself, as described in [How the toolkit chooses](#how-the-toolkit-chooses). It does not
    test, build the package or publish.

    If the project exists already, the command asks `Do you want to overwrite it? (y/n)`. Any answer except `y`
    stops the command and keeps the old project. The command can also ask
    `Install PSAppDeployToolkit <version> now? (y/n)` when a newer version exists. In a script, add `-Force`: it
    replaces the project and skips both questions.

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

## What you see while it runs

The build runs on its own. These are the most useful lines in the console.

```text title="What you see"
Installer technology: winget's choice
✓ Downloaded: <installer file>
✓ Org template 'Contoso' applied to project
✓ PSADT project configured (data-driven)!
Generating targeted installation documentation (Sandbox)...
✓ Windows Sandbox launched successfully!
Waiting for this run's capture: InstallationChanges_<time>.json
...
✓ Documentation processing completed successfully!
```

The words `(data-driven)` mean that the app settings are in a data file, not in the script.

After the download, the [install capture](glossary.md#install-capture) starts. It installs the app on a
clean copy of Windows and records what changes. The console calls it "targeted documentation".

A Windows Sandbox window opens, with a PowerShell window that shows each step. Do not close Windows Sandbox: it closes
itself after a countdown of up to 30 seconds.

<!-- SCREENSHOT: Windows Sandbox window during a capture run, showing the targeted documentation script logging its pre/post snapshots -->

On the Hyper-V test VM, no window opens. The console shows `Running documentation capture inside the Hyper-V VM...`
instead.

At the end, the menu shows a green **Done** panel or a red **Finished with problems** panel. The red panel lists one
line for each problem. A red **Something went wrong** panel means that an error stopped the build. In scripts, see
[Check the result](automation.md#check-the-result).

## The install capture

The install capture installs the app in a clean [test machine](glossary.md#test-machine) and compares
the machine before and after. The test machine is Windows Sandbox, or the Hyper-V test VM if you
[made it your default](hyperv-vm.md#make-the-test-vm-your-default) and it is ready. Because the test machine starts
clean, every change comes from this installer.

The capture records new files, registry keys, services and entries in the Windows list of installed apps. From these
changes, the toolkit fills in your project:

- The uninstall of an EXE app. MSI and MSIX packages uninstall without the capture.
- The [processes to close](glossary.md#processes-to-close): the programs of the app that must not run
  during an install or uninstall.
- The package's own identity, so that rules about other installs never remove your own app.
- The app icon, when winget has none, and a backup way for Intune to detect the app.
- `SupportFiles\RequirementScript.ps1`, a reference script that nothing runs. Do not add it to an app in Intune as a
  requirement, or new devices never get the app.

An EXE needs [silent switches](glossary.md#silent-switches): options that install it with no window.
The toolkit takes them from winget. If winget has none, the toolkit guesses `/S`. This guess is right for setups made
with NSIS, a common setup tool, but wrong for others, such as Inno Setup.

The install capture always runs. It usually takes 5 to 20 minutes, and the toolkit stops waiting after 30 minutes. To
run it again, for example after you change the switches, see
[Run the install capture again](projects.md#run-the-install-capture-again).

## What you have now

When the build ends, the menu shows the green **Done** panel.

<!-- SCREENSHOT: The green Done panel after the winget build of Git, telling you to use Browse projects to find it -->

If you kept the default folder in step 1, your project folder is `C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0\`. Your
version number will differ: the toolkit packages the version that winget lists today.

```text title="Your project"
C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0\
    Invoke-AppDeployToolkit.ps1     the deploy script
    Files\                          the installer and the winget manifest
    SupportFiles\AppConfig.json     the settings of the app
    Documentation\                  the results of the install capture and the checks
    Sandbox\                        test files and logs
    PSAppDeployToolkit\             a copy of PSADT for this project
```

The [deploy script](glossary.md#deploy-script) installs and removes the app on devices. It uses
[PSAppDeployToolkit (PSADT)](glossary.md#psadt), a free PowerShell tool that adds dialogs, logs and
exit codes around an installer.

To find the project later, choose **Browse projects** in the main menu. Every file and folder is explained in
[Inside a project](settings.md#inside-a-project). Nothing changed in Intune, and there is no package yet. The app was
installed only in the test machine, not on your PC.

## Installer technology

This section explains how to keep one installer technology for each app. Some toolkit messages link here.

### Why it matters

Many apps ship one version as two installer technologies. Notepad++, for example, ships a setup EXE made with NSIS and
an MSI made with WiX. NSIS and WiX are common tools for building setup programs.

The two register differently in Windows. A device that has one and then gets the other has two registrations. Its
list of installed apps then shows two entries for one program folder. So choose one technology for each app when you
package its first version, and keep it from version to version.

### How the toolkit chooses

Your own choice always wins. To [pin](glossary.md#pin) a technology means to choose it yourself:
with `-InstallerType` on the command line, or with your answer in the menu. Without a pin, the toolkit uses the first
rule that fits.

1. You re-create a version that you published or pinned. The toolkit keeps the technology of that version.
2. An earlier version of the app in the same org template was published or pinned. The toolkit keeps the technology
   of the highest one.
3. Otherwise winget chooses.

Published means that you published the version from this PC. A version that was only built does not count. A version
that only kept the technology of an earlier version does not count either.

The toolkit prints its decision before the download, in one of these forms.

```text title="The decision before the download"
Installer technology: wix (kept from Notepad++_x64_8.8.9 (published))
Installer technology: wix (kept from Notepad++_x64_8.9.8.1 (published, rebuilt))
Installer technology: wix (requested)
Installer technology: winget's choice
```

`kept from` names the version whose technology the toolkit keeps. `rebuilt` means you re-create the same version.
`(requested)` means that you chose it. `winget's choice` means that none of the three rules applied.

### Choose it in the menu

After the org template, the wizard checks on GitHub which technologies winget ships for this version. It then shows
one of these lines or questions.

| What the wizard shows | What to do |
|---|---|
| `Installer technology: winget ships ... nothing to choose.` | Nothing. The app ships one technology. |
| `Devices that already have the other technology would get two registrations; ...` and the question **Installer technology for Notepad++** | Choose the technology your devices already have. The first entry is winget's default. |
| The question **Installer technology for Notepad++ in this tenant**, with `Keep ... (recommended: ...)` first | An earlier version is published or pinned. Keep its technology, unless you plan the switch. |
| `winget does not ship ...` in yellow | The new version dropped your technology. See [When a new version no longer ships it](#when-a-new-version-no-longer-ships-it). |
| `winget also ships ... it cannot be packaged.` | Nothing. A zip file or a Microsoft Store app cannot be packaged. |
| `Installer technology: winget's choice (the other technologies could not be checked: ...)` | The check could not reach GitHub. The checks after the download still run. |

When you choose a technology at the question, the toolkit pins it. A **Keep** answer adds no new pin: the earlier
version still decides.

### Pin it on the command line

Add `-InstallerType` to pin the technology. This example pins the WiX MSI of Notepad++.

```powershell
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -TemplateName 'Contoso' -InstallerType wix
```

The values are `msi`, `wix`, `nullsoft`, `inno`, `burn`, `exe` and `msix`. The pin covers the whole [installer family](glossary.md#installer-family): the types that register the same way in Windows. If the version
does not offer the exact type, the toolkit tries the other types of the family. It never changes to another family.

| Family | winget installer types | Can be packaged |
|---|---|---|
| MSI | `msi`, `wix` | Yes |
| EXE | `burn` (EXE bundle), `nullsoft` (NSIS), `inno` (Inno Setup), `exe` | Yes |
| MSIX | `msix`, `appx`, `msstore` (Microsoft Store) | `msix` and `appx`: Yes. `msstore`: No. |
| Portable | `portable` | No, because there is no installer. |

To pin an APPX package, use `msix`. For each missing type, winget prints `No applicable installer found`. This is
normal: the next line names the type the toolkit tries next.

### When a new version no longer ships it

Sometimes a vendor drops a technology for one release. If the version does not ship the kept or pinned technology,
the toolkit downloads nothing and stops. The error ID `W32T.InstallerVariantUnavailable` means that this technology is
not available. The message lists the types the toolkit tried and gives two options.

1. Skip this version. Package the next version that ships your technology again. This is the recommended option.
2. Switch on purpose with `-InstallerType` and another type. Devices that have the old technology then get a second
   registration.

If you passed `-InstallerType` in this command, the message gives other options. Run the command without
`-InstallerType`, or package a version that ships your technology.

After this error, the project folder of this version stays. **Browse projects** shows it with `(not configured)`. If
you skip this version, delete that folder. Packaging the version again with the same technology stops with the same
error.

In the menu, the wizard warns you in yellow before the build. It offers **Skip this version** (recommended), **Switch
to** another technology, or **Keep**. Skip builds nothing, and Keep stops the build.

### When a test reports a technology switch

In step 4 you can [test an update from an older version](testing.md#test-an-update-from-an-older-version). The console
calls the old version the baseline. If the old version has another technology, the test can report a technology
switch.

The message starts with `Technology switch:` and names this page. In the menu, it is a red **TECHNOLOGY SWITCH**
panel.

It means that the old install was still registered after your package installed. Devices with that old install would
get two registrations over one folder. Do not publish this package to them. Choose one of these options instead.

- Re-create the project with the technology your devices have, for example `-InstallerType nullsoft` for the NSIS
  setup of Notepad++. See [Re-create a project](projects.md#re-create-a-project).
- Add a [prior-install rule](glossary.md#prior-install-rule): a rule in the package that blocks or
  removes the other install. See [Devices that already have the app](prior-installs.md).

## Warnings after the download

After the download, the toolkit compares the installer with the other technologies winget ships and with your earlier
versions. These checks never stop the build. You see their warnings again when you build and publish the package.

Two warnings use special words. The [install tattoo](glossary.md#install-tattoo) is a registry value
that the package writes on the device. Intune reads it to see which version is installed. The [SYSTEM account](glossary.md#system-account) is the built-in Windows account that Intune uses to install apps.

| Warning starts with | What it means | What to do |
|---|---|---|
| `winget also ships` | winget ships another technology for this version. Devices that have it would get two registrations. | Keep one technology. See [Devices that already have the app](prior-installs.md). |
| `winget chose` | The app ships more than one technology, and no earlier version was published or pinned. Nothing keeps the technology stable. | Pin it now with the `-InstallerType` value in the message, or choose it in the menu. |
| `The installer technology changed` | The earlier version you published or pinned has another technology. | Re-create the project with the `-InstallerType` value in the message. |
| `The detection key changed` | The path of the install tattoo changed. Devices with the earlier version keep the old one. | Check the app script author of your org template, and the publisher and name of the app. |
| `The winget manifest labels this installer user-scope` | Intune installs as SYSTEM. Users never see a per-user install made by SYSTEM. | Check the install capture. Look for another installer. |
| `Could not check which installer technologies` | The check on GitHub failed. Apps from a private winget source always fail it. | If the app ships an EXE and an MSI, pin one with `-InstallerType`. |
| `Several winget ids in this template look like the same product` | More than one winget ID in this org template seems to be this app. The toolkit compares with one earlier version only. | Check that the message names the right earlier version. Check that this package uses the winget ID your devices already have. |

`The installer technology changed` and `The detection key changed` compare only with an earlier version that you
published or pinned. A `winget also ships` line that says `cannot package it` is only information.

## Which version is packaged

The toolkit always packages the newest version that winget lists. There is no option to choose another version. To
package an older version, get its installer yourself and follow [Package an app that is not in winget](manual-apps.md).
Older winget versions are only used as the old version in an update test.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `Package ID '...' not found in winget` | Check the exact winget ID with `winget search git`. |
| `Download FAILED for` | After a network problem, package the app again. Otherwise package your own installer: see [Package an app that is not in winget](manual-apps.md). |
| `winget reported success for ... but wrote no installer` | This is a portable, zip or Store app without an installer. Package a real installer as an app that is not in winget. |
| `... is marked not configured` | The build stopped halfway. Package the app again: this replaces the folder. |
| `The capture recorded NO changes` | The installer did nothing, often because of wrong silent switches. Fix them, then run the install capture again. |
| `Another Windows Sandbox is still running` | Only one Windows Sandbox can run at a time. Close the other one, then run the install capture again. |

More messages and fixes are in [Packaging from winget](troubleshooting.md#packaging-from-winget),
[The install capture](troubleshooting.md#the-install-capture) and
[Recover from a stopped build](projects.md#recover-from-a-stopped-build).

## Next step

Test the package in a clean test machine before you build and publish it.

[Next: test the package](testing.md){ .md-button .md-button--primary }
