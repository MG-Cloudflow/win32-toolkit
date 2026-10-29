---
description: "Turn a tested project into the .intunewin file that Intune needs, and understand the package check."
---

# Build the package

This step turns your tested app into a [package](glossary.md#package): the `.intunewin` file that
Intune needs. Before it builds anything, win32-toolkit checks that the app is safe to send to devices.

## Before you start

Step 5 of 7.

- You have a [project](glossary.md#project): the folder of one app version. You made it in
  [Package an app from winget](packaging.md) or [Package an app that is not in winget](manual-apps.md).
- You tested it in [Test the package](testing.md). A failed test only warns. It does not stop packaging or publishing.
- Time: one menu choice or one command, then seconds to a few minutes. After you install or update the toolkit, the
  first build may also download Microsoft's packaging tool.

!!! note "Publishing builds it again"
    When you publish from the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) in step 7, the toolkit
    builds the package again for you. Do this step to get the file, for example to upload it by hand. It also shows
    problems in the project before you sign in.

## Build the package

If you ticked **Package to .intunewin** in a packaging wizard, the package already exists. Build it again after you
change the project.

=== "Menu"

    1. Start the menu (`Show-Win32Toolkit`).
    2. Choose **Work with an existing project**.
    3. At **Select a project (type to filter)**, type part of the name, for example `Git`.
    4. Choose your project.
    5. Choose **Package to .intunewin**.
    6. Wait for the **Done** panel. It says "Package created. See the messages above for the .intunewin path."

    The menu never asks to upload the package here.

=== "Command line"

    [Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md) checks one project and builds its
    package:

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Export-Win32ToolkitIntuneWin -ProjectPath $project
    ```

    At the end, the command asks `Upload to Microsoft Intune now? (Y/N)`. Type `N` and press <kbd>Enter</kbd>, because
    you connect to Intune in step 6. Any answer that does not start with `Y` means No.

    If you type `Y`, the toolkit publishes the [install app](glossary.md#install-app) at once, and only
    that app.

    - Add `-NoPublishPrompt` to skip the question, for example in a script.
    - Add `-WhatIf` for a [dry run](glossary.md#dry-run). The toolkit checks the project and shows the
      warnings, but it builds nothing.
    - Leave out `-ProjectPath` to choose from a numbered list of your projects.

    For every option, see [Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md).

## What happens when you build

A build uses [IntuneWinAppUtil.exe](glossary.md#intunewinapputil), Microsoft's free tool that makes
`.intunewin` files. The tool works on a [Staging copy](glossary.md#staging-copy): a clean copy of your
project, made only for the build. The toolkit runs these steps in order:

1. The [package check](glossary.md#package-check) looks for problems in the project. Any error stops
   the build.
2. The toolkit downloads IntuneWinAppUtil.exe if it is missing. It checks the tool's Microsoft signature every time.
3. It deletes the old Staging copy. Then it copies the project again, without test folders and private data.
4. It removes the test files that are left in the copy, such as the capture script.
5. IntuneWinAppUtil.exe builds the package from the Staging copy.
6. The toolkit names the package after the project, for example `Git_x64_2.53.0.intunewin`.
7. It shows warnings about your tests and the installer. They never stop the build.

```text title="What you see"
✓ Using IntuneWinAppUtil.exe from: <toolkit folder>\Tools (Authenticode verified)
✓ Staging copy     : C:\Win32Apps\Staging\Contoso\Git_x64_2.53.0
...
✓ Package created  : C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin  (<size> MB)
```

## What goes into the package

The package holds the [deploy script](glossary.md#deploy-script), `Invoke-AppDeployToolkit.ps1`. It
installs and removes the app on each device. It uses [PSAppDeployToolkit (PSADT)](glossary.md#psadt),
a free PowerShell tool for install scripts, with dialogs and logs.

| In the package | Never in the package |
|---|---|
| `Invoke-AppDeployToolkit.ps1`, and `Invoke-AppDeployToolkit.exe` (the program that Intune starts) | `Sandbox\`: test files, logs and old-version installers |
| `Files\`: the installer | `Documentation\`: install changes, test results, prior-install decisions |
| `SupportFiles\`: `AppConfig.json` with the app settings, your hook scripts, `RequirementScript.ps1` (for reference only) | `Intune\`: the IDs of your tenant and your published apps |
| The PSADT folders (`PSAppDeployToolkit\`, `Assets\`, `Config\`, `Strings\`) and your org extension module, if you have one | `*.md` and `*.wsb` files in the project folder, the capture script and its logs |

The `Intune\` folder never goes into the package, so the IDs of your published apps never reach a device. If the
toolkit cannot remove the `Intune\` or `Documentation\` folder from the Staging copy, it refuses to build.

`AppConfig.json` does go into the package. If your org template had a [tenant ID](glossary.md#tenant-id) when the project was made, the file holds it. A tenant ID is the ID of your
Intune tenant.

## The package check

The toolkit builds only a project it can trust. The package check looks at the deploy script and the project settings.
It lists every problem at once, each with its fix.

The [install tattoo](glossary.md#install-tattoo) is a registry value that the package writes. Intune
reads it to see which version is installed. Without it, Intune can only check that the app is there.

A [prior-install rule](glossary.md#prior-install-rule) tells the package what to do when a device
already has the app from another [installer technology](glossary.md#installer-technology). The
installer technology is how the vendor built the setup program, for example as an MSI or as an EXE.

Problems with prior-install rules start with `Prior install:`. See
[Build and publish a project with rules](prior-installs.md#build-and-publish-a-project-with-rules).

| Check | Stops the build? |
|---|---|
| `Invoke-AppDeployToolkit.ps1` is missing or is not valid PowerShell | Yes |
| The toolkit did not prepare the deploy script | Yes, unless you use `-AllowLegacyScript` |
| The PSADT layout or version is not supported (supported: 4.1 and 4.2) | Yes, unless you use `-AllowLegacyScript` |
| The deploy script uses PowerShell 7 syntax (devices run Windows PowerShell 5.1) | Yes |
| `Invoke-AppDeployToolkit.exe` is missing | Yes |
| The uninstall would delete a folder outside the app's install folder, or `AppConfig.json` cannot be read | Yes, with no override |
| A prior-install rule cannot be applied | Yes (the message says how to clear it) |
| The project was made by win32-toolkit 1.1.6 or older | No, it warns |
| The deploy script writes no install tattoo | No, it warns |
| The project contains a test version (prerelease) of PSADT | No, it warns |
| The project has an older, less strict uninstall | No, it warns |

The last row is about the uninstall on a device. The current uninstall waits up to 30 minutes for an EXE uninstaller
and for the programs that it starts. If the uninstaller still runs after that, the package stops it, and the
uninstall ends with exit code 69113.

When the uninstaller succeeds, the uninstall deletes the app's leftover folders, but it checks each folder again
first. It leaves a folder in place when the folder is outside the app's install folders. It also leaves shared and
system folders, and links to other folders. The PSADT log names each folder that it leaves, and the uninstall does not
fail because of it.

### Projects made by win32-toolkit 1.1.6 or older

The toolkit still builds these projects, unchanged. It shows one warning that contains
`Deploy script generated by an older win32-toolkit`. Their uninstall does not remove an old install tattoo in the
32-bit part of the registry.

To fix this, [re-create](glossary.md#re-create) the project: package the app again, which replaces the
project folder. Re-creating a project deletes its folder. Copy your own code out first. For apps that are already in
Intune, see [Coming from win32-toolkit 1.1.6 or older](maintain-toolkit.md#coming-from-win32-toolkit-116-or-older).

### The AllowLegacyScript option

Use `-AllowLegacyScript` only for a deploy script that the toolkit never prepared, for example one you keep by hand.
It turns two errors into warnings: an unprepared deploy script, and a PSADT layout or version that is not supported.

The option exists only on the command line, on `Export-Win32ToolkitIntuneWin` and
[Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md). The menu does not offer it. Projects
from older win32-toolkit versions do not need it.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Export-Win32ToolkitIntuneWin -ProjectPath $project -AllowLegacyScript
```

All other errors still stop the build, for example an unsafe uninstall folder or a prior-install problem. The option
also cannot build a project that is marked not configured.

## Read the warnings after the build

After the build, the toolkit reads your latest test results and its installer checks. Each warning starts with
`WARNING:` and the project folder name, for example `WARNING: Git_x64_2.53.0:`. You may see a warning when:

- The latest install and uninstall test failed, or was [Inconclusive](glossary.md#inconclusive): it
  gave no clear result.
- The latest test of an update from an older version failed.
- An update test found the old version still installed after the update, because the old version used another
  installer technology. For example, an EXE install stayed next to your MSI.
- This version differs from an earlier version you published or pinned.
- winget also ships another technology of the app, and no test covered it.
- The project has prior-install rules that need care.

These warnings never stop the build. Many of them say `This only warns`. Only the latest test counts, so a new test
that passes removes its warning.

The warnings come back when you publish. In the menu, they appear in a panel named **Review before you publish** or
**Check before you publish**. Publishing also warns about a [maximum run time](glossary.md#maximum-run-time) of 30 minutes or less. That is how long Intune lets the install run.

## Build again at any time

Building again is always safe. Each build makes a new Staging copy from the project. The new package replaces the old
`.intunewin` file. A change to the project reaches the package only through a new build.

If a program has a file open in the Staging folder, the build stops with `Could not clear the previous Staging copy`.
Close that program, for example an editor or a PowerShell window in that folder. Then build again.

## What you have now

The paths use the [examples of this guide](how-it-works.md#about-the-examples-in-this-guide).

- The package: `C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin`.
- The Staging copy: `C:\Win32Apps\Staging\Contoso\Git_x64_2.53.0\`. Open it to see exactly what goes into the
  package.
- Your project in `C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0\` did not change. A build never changes it.
- Nothing changed in Intune, unless you answered `Y` to the upload question.

## If something goes wrong

Some messages start with `Export-Win32ToolkitIntuneWin failed:`. Read the words after it.

| Message starts with | What to do |
|---|---|
| `'<project>' is marked not configured and cannot be packaged` | The project was never finished, for example after a failed download. The menu marks it `(not configured)`. Fix the cause, then package the app again. |
| `win32-toolkit cannot vouch for the deploy script` | The package check found errors. The message lists each one with its fix. Fix them and build again. |
| `Cannot derive the BasePath` | The project is not in `<base folder>\Projects\<template>\`. Move it there, or add `-BasePath` to the command. |
| `Failed to download IntuneWinAppUtil.exe` or `Refusing to use` | Download the tool by hand from Microsoft's GitHub, into the folder that the message names. A copy with no valid Microsoft signature is deleted. |
| `Could not clear the previous Staging copy` or `Refusing to package` | A program has a file open in the Staging folder. Close it and build again. |
| `IntuneWinAppUtil.exe exited with code` | Read the tool's output above the message, fix the cause and build again. |

For more messages, see [Troubleshooting](troubleshooting.md#building-the-package).

## Next step

Next, connect the toolkit to your Intune tenant.

[Next: connect to Intune](intune-connection.md){ .md-button .md-button--primary }
