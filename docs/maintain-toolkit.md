---
description: "Update win32-toolkit, choose the PSAppDeployToolkit version for new projects, move the base folder, fix apps from older versions, or remove the toolkit."
---

# Update, move or remove the toolkit

Use this page to look after win32-toolkit itself: update it, move your work, or remove it. It also shows how to
choose the version of [PSAppDeployToolkit (PSADT)](glossary.md#psadt). PSADT is the free PowerShell
tool inside every app the toolkit builds.

## Update win32-toolkit

The menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) checks GitHub for a new version at most once a day.
If one exists, a grey line appears above the menu:

```text title="What you see"
Update available: v<installed> -> v<latest>  (Update-Module win32-toolkit, or https://github.com/MG-Cloudflow/win32-toolkit/releases)
```

Only the menu checks, never the commands. The check sends one request to GitHub, with no account data. If it fails,
the menu tries again after 24 hours.

Update the toolkit in the same way you installed it.

=== "PowerShell Gallery (recommended)"

    Close the menu. Then update the module in PowerShell 7:

    ```powershell
    Update-Module win32-toolkit
    ```

    Close the window and open a new one. An open window keeps using the old version.

=== "Git clone"

    Close the menu and run `git pull` in the folder of your clone. Then open a new PowerShell window.

=== "ZIP download"

    1. Close every PowerShell window that uses the toolkit.
    2. Download the new ZIP from the releases page on GitHub.
    3. Right-click the ZIP, choose **Properties**, tick **Unblock** and choose **OK**.
    4. Extract the ZIP and replace your old toolkit folder with the new one.

An update keeps your settings and your [base folder](glossary.md#base-folder), the folder with all
your work. It also keeps the PSADT versions you installed, and it does not update PSADT.

After `Update-Module`, the toolkit downloads `IntuneWinAppUtil.exe` again the next time it builds a [package](glossary.md#package). A package is the `.intunewin` file that you upload to Intune.

The [Changelog](changelog.md) lists the changes of every release.

## Turn off the update check

In the main menu, choose **Settings** > **Update check**. Each choice switches the setting between `On` and `Off`,
and the label shows the current state. The toolkit saves your choice for your Windows account.

When you switch it to `On`, the menu checks at once and shows the result. There is no separate "check now": to check
again while it is `On`, choose it twice.

An [environment variable](glossary.md#environment-variable) is a named value that programs can read.
The check is also off when `WIN32TOOLKIT_NO_UPDATE_CHECK`, `DO_NOT_TRACK` or `NO_UPDATE_NOTIFIER` has any value, or
when `CI` is set. To turn the check off in this PowerShell window only:

```powershell
$env:WIN32TOOLKIT_NO_UPDATE_CHECK = '1'
```

For every variable the toolkit reads, see [Environment variables](settings.md#environment-variables).

## Choose the PSADT version for new projects

The toolkit supports PSADT 4.1.x and 4.2.x side by side. On a new PC, you do not need to do anything.

Each time the toolkit creates a [project](glossary.md#project), the folder of one app version, it
needs a supported PSADT. If none is installed, it installs the newest stable 4.1.x or 4.2.x for your Windows account.
It does not ask first. You see a line that starts with `Installing PSAppDeployToolkit`.

### Which version a new project gets

The toolkit uses the first of these that applies:

1. `$env:W32T_PSADT_VERSION`, for this PowerShell window only.
2. The registry value `PreferredPsadtVersion`, for your Windows account.
3. The newest supported version that is installed. A stable version wins over a test version of the same number.

Choosing a version with one of the first two is called a [pin](glossary.md#pin).

Each project keeps the PSADT copy it was built with, so a new version or pin reaches new projects only. To change the
version of a project, [re-create](glossary.md#re-create) it: make it again from the start. See
[Re-create a project](projects.md#re-create-a-project). **Browse projects** in the menu shows the PSADT version of
each project.

### Pin a version

A pin is an exact version, such as `4.1.8`, or a major and minor number: `4.1` means the newest installed 4.1.x. Set
or remove a pin with these commands:

```powershell
$key = 'HKCU:\Software\CloudFlow\win32-toolkit'
# every new project you create: the newest installed 4.1.x
Set-ItemProperty -Path $key -Name 'PreferredPsadtVersion' -Value '4.1'
# this PowerShell window only
$env:W32T_PSADT_VERSION = '4.1.8'
# remove the registry pin
Remove-ItemProperty -Path $key -Name 'PreferredPsadtVersion'
```

The toolkit never installs a pinned version for you. If it is missing, project creation stops with a warning that
starts `PreferredPsadtVersion '<pin>'`. The [system check](glossary.md#system-check), the table on the
main screen of the menu, shows an active pin on its PSADT row. A pin set with `$env:W32T_PSADT_VERSION` lasts until
you close the window.

### Install PSADT by hand

To add a supported version yourself, install it next to the others:

```powershell
Install-Module PSAppDeployToolkit -RequiredVersion 4.1.8 -Scope CurrentUser
```

!!! warning "Do not use Update-Module for PSADT"

    `Update-Module PSAppDeployToolkit` can install a version outside 4.1 and 4.2, for example 4.3. The toolkit
    ignores it, and the system check shows a yellow `!` on the PSADT row.

A [prerelease](glossary.md#prerelease) is a test version. The toolkit never installs one for you.

If you install one and it is the newest supported version, new projects use it. A warning then starts with
`Using PSAppDeployToolkit <version> - a PRERELEASE`. Do not use a prerelease in production.

A command that creates a project can also offer a newer PSADT version. It asks
`Install PSAppDeployToolkit <version> now? (y/n)`. It never asks when a pin is set, and the menu never asks.

Add `-Force` to skip the question. But `-Force` also replaces a project of the same version without asking.

### One PSADT version per window

One PowerShell window can load only one PSADT version. After you change a pin or install a version, choose **Exit**
in the menu and open a new PowerShell window. If you do not, project creation can stop with a warning that starts
`PSAppDeployToolkit <version> is already loaded`.

## Move or change the base folder

The default base folder is `C:\Win32Apps`. You can choose another one, for example on a bigger disk. Rules for the
new path:

- Use a short, local path. A long path can hit the Windows limit on path length.
- Type a full path that starts with a drive letter.
- Remove the quotes that **Copy as path** in File Explorer adds. The toolkit keeps them, and later steps fail.

=== "Menu"

    1. In the main menu, choose **Settings** > **Change the base folder**.
    2. At **Enter the base folder for all output**, type the full path and press <kbd>Enter</kbd>. The default is
       your current base folder.

    The menu shows `Saved:` with the path and uses the new folder at once.

=== "Command line"

    Add `-Reconfigure` to your next [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md) or
    [`New-Win32ToolkitManualApp`](reference/New-Win32ToolkitManualApp.md) command. It asks
    `Base folder [C:\Win32Apps]` and saves your answer. The default is `C:\Win32Apps`, not your current base folder.

    To use a folder for one command only, add `-BasePath` instead. The toolkit does not save that folder.

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

!!! warning "Nothing is moved for you"

    The toolkit does not move or copy your files. After a change, it looks only in the new folder. Your work in
    the old folder no longer appears in the menu.

The [Hyper-V test VM](glossary.md#hyper-v-test-vm) is a virtual machine (VM) that can run your tests.
Its files are in `<base folder>\HyperV`. Hyper-V does not follow these files when you move them.

To move your work:

1. If you have the test VM, [remove it](hyperv-vm-care.md#remove-the-vm) first.
2. Close the menu and every PowerShell window that uses the toolkit.
3. Move the whole base folder, with everything inside it, in File Explorer.
4. Start the menu and set the new path in **Settings** > **Change the base folder**.
5. If you removed the test VM, [rebuild it](hyperv-vm-care.md#rebuild-the-vm).

The download cache and the test VM folders always use the saved base folder, even when you add `-BasePath`.

## Coming from win32-toolkit 1.1.6 or older

The toolkit now needs PowerShell 7.4 or later. Check your version with `$PSVersionTable.PSVersion`, and
[install PowerShell 7](install.md#install-powershell-7) if it is older.

Projects from these versions show "(legacy)" next to their PSADT version in **Browse projects**. The toolkit still
builds their package unchanged, with one warning. But their uninstall leaves an old [install tattoo](glossary.md#install-tattoo) on devices. An install tattoo is a registry value that tells Intune which
version is installed.

So re-create these projects. Re-creating a project deletes its folder. Copy your own code out first.

### Fix apps that are already in Intune

These versions published apps with this command line, and the same with `Uninstall`:

```text
powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install
```

The [Intune Management Extension](glossary.md#intune-management-extension) is the Intune agent on
devices. It is a 32-bit program, so this command line starts the 32-bit Windows PowerShell on 64-bit devices. A
PSADT 4.2 package then stops with exit code 60008. A PSADT 4.1 package installs, but Intune reports it as not
detected.

Publishing never changes an app that is already in Intune. So these apps keep the old command line until you act.

**Recommended fix.** Only a re-created project also removes the old install tattoo when it uninstalls.

1. Re-create the project with this version of the toolkit.
2. Build the package and publish it.
3. Assign the new app in the [Intune admin center](glossary.md#intune-admin-center), then
   [retire the old one](new-version.md#replace-the-old-app-in-intune).

Every publish creates a new app in Intune. Publishing again does not change the old app.

**Quick fix.** In the Intune admin center, change the two command lines of the old app to these:

```text
Invoke-AppDeployToolkit.exe -DeploymentType Install
Invoke-AppDeployToolkit.exe -DeploymentType Uninstall
```

Every package already contains `Invoke-AppDeployToolkit.exe`. Install and detection then work, and devices with a
Required assignment recover by themselves. The uninstall does not change.

!!! warning "Quick fix and update apps"

    After an uninstall by the old package, the old install tattoo stays on the device. An [update app](glossary.md#update-app) installs only where it finds an older version, and it finds that tattoo.
    So it can install the app again. Use the quick fix only for apps that have no update app, or remove that tattoo
    with a remediation script.

## Remove the toolkit

Follow these steps in order.

1. If you built the test VM, remove it. In PowerShell 7 as administrator, run
   [`Remove-Win32ToolkitTestVM -RemoveVhdx`](reference/Remove-Win32ToolkitTestVM.md).

    In the menu: **Settings** > **Hyper-V test VM** > **Remove the test VM**. At **Remove the test VM and delete its
    VHDX?** answer `y` (the default is No). The VHDX is the virtual disk file of the test VM.

2. Sign out of Intune with [`Disconnect-Win32ToolkitIntune`](reference/Disconnect-Win32ToolkitIntune.md), or choose
   **Microsoft Intune connection** > **Sign out** in the menu.
3. In a new PowerShell 7 window, run `Uninstall-Module win32-toolkit -AllVersions`. For a Git clone or a ZIP, delete
   its folder.
4. Optional: remove the modules the toolkit installed, if nothing else uses them.

    ```powershell
    Uninstall-Module PwshSpectreConsole -AllVersions
    Uninstall-Module PSAppDeployToolkit -AllVersions
    Uninstall-Module Microsoft.Graph.Authentication -AllVersions
    ```

5. Optional: delete the settings and the small cache folder of the toolkit.

    ```powershell
    Remove-Item -Path 'HKCU:\Software\CloudFlow\win32-toolkit' -Recurse
    Remove-Item -Path "$env:LOCALAPPDATA\CloudFlow\win32-toolkit" -Recurse
    ```

    The test VM can also leave a `%ProgramData%\win32-toolkit` folder. If it exists, delete it as administrator.

6. Keep or delete your base folder. It holds all your work, and nothing above deletes it.

## Next steps

- [Settings and folders](settings.md): every setting and the layout of the base folder.
- [Set up the Hyper-V test VM](hyperv-vm.md): tests that run the package as Intune does.
