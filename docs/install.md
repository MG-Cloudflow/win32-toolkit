---
description: "Check your PC, turn on Windows Sandbox, install PowerShell 7 and win32-toolkit, and start the menu for the first time."
---

# Install the toolkit

This step gets your PC ready for win32-toolkit. You check your PC, install what the toolkit needs and start it for
the first time.

## Before you start

Step 1 of 7.

- If you are new to the toolkit, read [How win32-toolkit works](how-it-works.md) first.
- You need a PC with Windows 10 or 11 Pro, Enterprise or Education, and internet access.
- You need admin rights on this PC for two steps: turning on a Windows feature and installing PowerShell 7.
- Time: about 15 minutes, plus one restart.

## Check your PC

Check these points before you install anything. Three words in the table may be new to you:

- [PowerShell 7](glossary.md#powershell-7-and-windows-powershell-51) is the newer version of
  PowerShell. It installs next to the built-in Windows PowerShell 5.1.
- [Windows Sandbox](glossary.md#windows-sandbox) is a clean, temporary copy of Windows. It opens in a
  window and forgets everything when it closes.
- [winget](glossary.md#winget) is Microsoft's command-line app store. The toolkit uses it to find and
  download installers.

| You need | Why |
|---|---|
| Windows 10 or 11 Pro, Enterprise or Education | Windows Sandbox and Hyper-V do not exist on Windows Home. |
| PowerShell 7.4 or later | The toolkit does not load in older versions of PowerShell. |
| Windows Sandbox, turned on | The toolkit installs and tests your apps in it. |
| winget | Only for apps from winget, and for apps that need an app from winget first ([dependencies](dependencies.md)). Other apps work without it. |
| Internet access | For downloads from Microsoft, GitHub and app vendors, and to publish to Intune. |
| Admin rights | Only to turn on Windows features, to install PowerShell 7 and for the optional [Hyper-V test VM](hyperv-vm.md). Normal packaging runs as a standard user. |
| Hardware virtualization | Windows Sandbox and Hyper-V need it. If it is off, turn it on in the firmware settings of your PC. |

The toolkit does not check the Windows edition or the firmware for you.

## Turn on Windows Sandbox

Windows Sandbox is a Windows feature, and it is off by default. win32-toolkit never turns on Windows features. You
turn them on once.

1. In the Start menu, right-click **Windows PowerShell** and choose **Run as administrator**.
2. Turn on the feature with this command:

    ```powershell
    Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All
    ```

3. Restart the PC. Windows Sandbox works only after the restart.

You can also use **Control Panel** > **Programs** > **Turn Windows features on or off**. Tick **Windows Sandbox**,
choose **OK** and restart the PC.

After the restart, the toolkit shows Windows Sandbox as `available` when it starts. For the optional Hyper-V test
VM, see [Set up the Hyper-V test VM](hyperv-vm.md).

## Install PowerShell 7

Install PowerShell 7 with winget, from any PowerShell or Command Prompt window.

```powershell
winget install Microsoft.PowerShell
```

Windows asks for admin rights during the install. If winget is not on your PC, see
[Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
on Microsoft Learn (general Microsoft information).

Your PC now has two PowerShell apps. In the Start menu, always choose **PowerShell 7**, not **Windows PowerShell**.
The command name of PowerShell 7 is `pwsh`.

Install the toolkit from PowerShell 7 too. If you install it from Windows PowerShell, it goes to another folder
and PowerShell 7 does not find its commands.

To check your version, run this command in PowerShell 7. The version must be 7.4 or later.

```powershell
$PSVersionTable.PSVersion
```

## Install win32-toolkit

The toolkit is a PowerShell [module](glossary.md#module): a package of commands that you install
once and then use by name. Choose one of three ways to install it. Most people use the [PowerShell Gallery](glossary.md#powershell-gallery), Microsoft's public online store for PowerShell modules.

=== "PowerShell Gallery (recommended)"

    Run this command in PowerShell 7. It installs the toolkit for your Windows account only.

    ```powershell
    Install-Module win32-toolkit -Scope CurrentUser
    ```

    PowerShell may ask if you trust the PowerShell Gallery, under the title **Untrusted repository**. Type `Y` and
    press <kbd>Enter</kbd> to install. (The default is No.)

    !!! warning "Install for your account only"
        Always add `-Scope CurrentUser`. The toolkit later downloads [IntuneWinAppUtil.exe](glossary.md#intunewinapputil) into its own folder. This Microsoft tool makes the `.intunewin`
        file for Intune. In an all-users install, a standard user cannot write to that folder, so your first package
        fails.

    The double-click file `Launch-Win32Toolkit.cmd` is not part of this install. It comes only with a Git clone or a
    ZIP download.

=== "Git clone"

    Use this way if you want the double-click file `Launch-Win32Toolkit.cmd`. You need Git on your PC.

    These commands copy the toolkit to your PC and load it.

    ```powershell
    git clone https://github.com/MG-Cloudflow/win32-toolkit.git
    Import-Module .\win32-toolkit\win32-toolkit.psd1
    ```

    Load the toolkit again in each new PowerShell 7 window. Or double-click `Launch-Win32Toolkit.cmd` in the
    folder. It opens PowerShell 7 and starts the toolkit.

    The clone already contains `IntuneWinAppUtil.exe`, the Microsoft tool that makes the `.intunewin` file for
    Intune.

=== "ZIP download"

    Use this way if you want the double-click file but do not use Git.

    1. Open the GitHub page of the toolkit, `https://github.com/MG-Cloudflow/win32-toolkit`.
    2. Choose **Code** > **Download ZIP**.
    3. Right-click the ZIP file, choose **Properties** and tick **Unblock**. Or run
       `Unblock-File .\win32-toolkit-main.zip` in PowerShell.
    4. Extract the ZIP to a folder of your choice.
    5. In that folder, double-click `Launch-Win32Toolkit.cmd`.

    You can also load the toolkit in PowerShell 7 with `Import-Module <folder>\win32-toolkit.psd1`. The ZIP
    already contains `IntuneWinAppUtil.exe`, the Microsoft tool that makes the `.intunewin` file for Intune.

    If you forgot to unblock the ZIP, `Import-Module` can stop with an error that the file is not digitally
    signed. Run `Get-ChildItem <folder> -Recurse | Unblock-File` in PowerShell 7, then import again.

### Check the install

This command checks that PowerShell 7 finds the commands of the toolkit.

```powershell
Get-Command -Module win32-toolkit
```

The list shows 17 commands. The help of each command also works offline. For example, this command shows the
full help of [`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md).

```powershell
Get-Help Show-Win32Toolkit -Full
```

## Start the menu for the first time

The [menu](glossary.md#menu) is the guided way to use the toolkit inside a PowerShell 7 window. To
start it, type `Show-Win32Toolkit` in PowerShell 7 and press <kbd>Enter</kbd>.

```powershell
Show-Win32Toolkit
```

The menu needs [PwshSpectreConsole](glossary.md#pwshspectreconsole). This free module draws the
colors, tables and lists of the menu. If it is not on your PC yet, you see this question:

```text title="What you see"
The text UI needs the PwshSpectreConsole module (a one-time install).
Install it now for your user account? (Y/N):
```

Type `Y` and press <kbd>Enter</kbd>. It installs for your Windows account only. If you answer `N`, the menu does not
start, but the commands still work.

Then a large blue win32-toolkit banner appears, and the menu asks for your base folder.

The menu needs an interactive console window, so start it in a normal PowerShell 7 window. It does not start when
its input or output goes to a file or another program instead of the window.

These keys work everywhere in the menu:

- Use the arrow keys and <kbd>Enter</kbd> to choose an item.
- In long lists, type a few letters to filter the list.
- In lists with boxes, press <kbd>Space</kbd> to tick an item and <kbd>Enter</kbd> to accept.
- Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to end the menu.

For all keys and screens, see [Move around the menu](menu.md#move-around-the-menu).

## Choose your base folder

The [base folder](glossary.md#base-folder) is the one folder on your PC where the toolkit keeps all
its work. On the first start, a blue panel titled **First-run setup** asks for it:

```text title="What you see"
Welcome! Choose the base folder where all output lives (Templates, Projects, Staging, IntuneWin).
This is saved to the registry so you only pick it once.
```

<!-- SCREENSHOT: The First-run setup panel asking for the base folder, with the default C:\Win32Apps -->

Under the panel, the **Base folder** question shows the default, `C:\Win32Apps`. Press <kbd>Enter</kbd> to accept
it, or type another folder and press <kbd>Enter</kbd>. The menu prints `Saved base folder:` with the path, then
opens the main screen.

Follow these rules when you type a folder:

- Use a short local path, like `C:\Win32Apps`. A long path can hit the Windows limit on path length when the toolkit
  creates a project.
- Type a full path that starts with a drive letter.
- Type the path without quotes. The question keeps the quotes that **Copy as path** in File Explorer adds, and later
  steps then fail.

The toolkit saves the base folder in the registry, for your Windows account only. It does not create any folder
now: each one appears when the toolkit first needs it.

To change the folder later, choose **Settings** > **Change the base folder**. The toolkit does not move your files
when you change it. See [Move or change the base folder](maintain-toolkit.md#move-or-change-the-base-folder).

## Read the system check

The [system check](glossary.md#system-check) is the table on the main screen, under the banner. It
lists each part the toolkit needs, with a status. You see it every time you come back to the main menu.

<!-- SCREENSHOT: The TUI health/system-check table showing OK and missing rows -->

One row is [PSAppDeployToolkit (PSADT)](glossary.md#psadt). This free PowerShell module installs
apps on devices in a standard way. Every package you build uses it.

Green `OK` means ready and a red `X` means missing. A yellow `!` means the part works but needs your attention,
for example a test version of PSADT (`prerelease - testing only`).

| Row | What OK looks like | What fixes a red X |
|---|---|---|
| PowerShell 7.4+ | Your version, for example `7.4.6` | Never red: the toolkit does not load in older PowerShell. |
| PwshSpectreConsole (UI) | A version, for example `v2.6.3` | Answer `Y` when the menu offers it. |
| Base folder configured | Your base folder | **Settings** > **Change the base folder**. |
| winget | `available` | Install or update App Installer from the Microsoft Store. |
| PSAppDeployToolkit (4.1.x and 4.2.x) | A version, for example `v4.1.8` | Nothing. The toolkit installs it when you create your first project. |
| Windows Sandbox | `available` | [Turn on Windows Sandbox](#turn-on-windows-sandbox), then restart the PC. |
| Hyper-V test backend (only when the test VM is your default) | `ready` | See [Check that the VM is ready](hyperv-vm.md#check-that-the-vm-is-ready). |
| Microsoft.Graph.Authentication | A version number | Nothing. The toolkit offers it when you first connect to Intune or publish. |
| IntuneWinAppUtil.exe | `present` | Nothing. The toolkit downloads it when you build your first package. |

!!! note "Three red rows are normal"
    On a new PC after a PowerShell Gallery install, three rows show a red `X`: PSAppDeployToolkit,
    Microsoft.Graph.Authentication and IntuneWinAppUtil.exe. Nothing is wrong. Each one arrives the first time you
    need it. After a Git clone or a ZIP download, IntuneWinAppUtil.exe is already there.

Below the table, a line may start with `Tip: fixable items can be resolved from Settings`. Only the base folder
can be fixed in **Settings**. The other items arrive the first time you need them.

To run the check again, choose **Settings** > **Re-run the system check**.

## What the toolkit installs later

The toolkit installs some parts only when a feature needs them.

| What | When | Asks first? |
|---|---|---|
| PwshSpectreConsole | The first time you start the menu | Yes |
| PSAppDeployToolkit | The first time you create a project | No |
| Microsoft.Graph.Authentication, for the Intune sign-in | The first time you connect to Intune or publish | Yes |
| IntuneWinAppUtil.exe | The first time you build a package, after a PowerShell Gallery install | No |

All of them install for your Windows account only, so you need no admin rights. For PSADT, the toolkit takes the
newest stable 4.1.x or 4.2.x version from the PowerShell Gallery. It never installs a test version of PSADT for you.
To choose the version yourself, see
[Choose the PSADT version for new projects](maintain-toolkit.md#choose-the-psadt-version-for-new-projects).

The toolkit checks the Microsoft signature of IntuneWinAppUtil.exe every time it uses the file. If the signature is
not valid, the toolkit deletes the file and stops.

On every winget download, the toolkit accepts the agreements of the winget source and of the package for you.

## What you have now

- The toolkit is installed, and PowerShell 7 finds its 17 commands.
- The menu starts, and PwshSpectreConsole is installed.
- Your base folder is saved. The folder itself may not exist yet.
- You have no [org template](glossary.md#org-template) yet. An org template holds the settings of
  one company or customer.
- You have no project yet, and nothing changed in Intune.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `PowerShell 7.4 or later (pwsh) is required` | The double-click file did not find PowerShell 7. [Install PowerShell 7](#install-powershell-7), then try again. |
| An error about a minimum PowerShell version of 7.4 | You started an older PowerShell. Start PowerShell 7 and check `$PSVersionTable.PSVersion`. |
| `Show-Win32Toolkit needs an interactive console window` | Start the menu in a normal PowerShell 7 window. |
| `Install failed:` | PwshSpectreConsole did not install. Check that your PC can reach the PowerShell Gallery, then start the menu again. |
| `winget is not available on this PC` | Install or update App Installer from the Microsoft Store. Or package an [app that is not in winget](manual-apps.md). |
| `feature not enabled` on the Windows Sandbox row | [Turn on Windows Sandbox](#turn-on-windows-sandbox) and restart the PC. |

For more messages, see [Troubleshooting: install and start](troubleshooting.md#install-and-start).

## Next step

Create the org template that holds the settings of your company or customer.

[Next: create your org template](org-templates.md){ .md-button .md-button--primary }
