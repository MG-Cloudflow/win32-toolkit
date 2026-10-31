---
description: "Install and uninstall the package in a clean test machine, read the result, and test an update from an older version."
---

# Test the package

A test installs your package in a clean [test machine](glossary.md#test-machine): a copy of
Windows with nothing else installed. win32-toolkit then runs automatic [checks](glossary.md#check)
and records a [result](glossary.md#result): Passed, Failed or Inconclusive.

A failed test only warns. It does not stop packaging or publishing. So read every result.

## Before you start

Step 4 of 7.

- You packaged an app in [step 3](packaging.md). This page tests the [project](glossary.md#project)
  `C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0`: the folder of one app version. Your version will differ.
- [Windows Sandbox](glossary.md#windows-sandbox) is turned on. It is a clean, temporary copy of
  Windows that comes with Windows. See [Turn on Windows Sandbox](install.md#turn-on-windows-sandbox).
- Or you have a ready [Hyper-V test VM](glossary.md#hyper-v-test-vm): a virtual machine (VM) that goes
  back to a clean state before each test. See [Set up the Hyper-V test VM](hyperv-vm.md).
- Time: less than a minute to start a test, then about 2 minutes of waiting in Windows Sandbox. A test you watch adds
  a 2-minute pause. Testing an update takes longer, because it downloads and installs the old version first.

## Run an install and uninstall test

This test checks that the package installs, that Intune would detect the app, and that the package uninstalls it. Run
it for every app.

=== "Menu"

    Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)).

    1. In the main menu, choose **Work with an existing project**.
    2. At **Select a project**, choose `Contoso / Git_x64_2.53.0`. You can type to filter the list.
    3. Choose **Run a test**.
    4. At **Which test backend?**, choose **Windows Sandbox**. The menu asks this every time.
    5. At **Test scenario**, choose **Install then uninstall**.

=== "Command line"

    Run [`Test-Win32ToolkitProject`](reference/Test-Win32ToolkitProject.md) with your project folder and the scenario.

    ```powershell
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario InstallUninstall
    ```

    Without options, the command asks for the scenario, then for the project.

    For every option, see [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

## What happens during the test

1. The test installs the app's [dependencies](glossary.md#dependency) first: other apps that your app
   needs.
2. The package installs the app.
3. The test checks that the app is installed, the way Intune checks it.
4. An [interactive test](glossary.md#interactive-test) is a test you watch. It pauses here, so you can
   try the app.
5. The package uninstalls the app.
6. The test checks that the app is gone.
7. The toolkit copies the logs of the test into the project.

To find the app, the test reads the [install tattoo](glossary.md#install-tattoo): a registry value that
the package writes after a good install. Intune uses the same value.

If a dependency does not install, the test stops and the result is Failed (see
[Dependencies in tests](dependencies.md#dependencies-in-tests)).

In Windows Sandbox, the pause is a 2-minute countdown window. Choose **Skip Wait** to end it sooner. The first line of
the window shows the real install result: `INSTALLATION COMPLETED SUCCESSFULLY!` in green, or
`INSTALLATION FAILED (exit ...)` in red. The uninstall still runs after a failed install.

<!-- SCREENSHOT: Windows Sandbox during an InstallUninstall run, with the 2-minute countdown dialog visible over the freshly installed app -->

On the Hyper-V test VM, the VM window opens instead. The console waits with
`Test the app in the VM window - press Enter to continue`. Press <kbd>Enter</kbd> when you are done.

## Interactive or unattended

An interactive test lets you watch the install and try the app. An [unattended test](glossary.md#unattended-test) runs from start to end without a person and without a pause.

| Question | Interactive test | Unattended test |
|---|---|---|
| What you see | The install and the pause. Windows Sandbox stays open after the test. | Nothing. Windows Sandbox closes itself. |
| How long | Adds a 2-minute pause in Windows Sandbox. On the test VM, it waits until you press <kbd>Enter</kbd>. | About 2 minutes in Windows Sandbox. About 4 to 5 minutes on the test VM (depends on your PC). |
| When to use it | To try the app, or to see a dialog that stops the install. | Scripts, several tests in a row, and tests as Intune runs them. |

Interactive is the default. Choose the mode like this:

- **For one test:** add `-TestMode Unattended` (short form `-Unattended`) or `-TestMode Interactive`. Do not combine
  `-Unattended` with `-TestMode Interactive`.
- **As your default:** set `SandboxTestMode` or `HyperVTestMode` to `Unattended`, see [Tests](settings.md#tests).
- **In the menu:** a test in Windows Sandbox follows `SandboxTestMode`. A test on the test VM asks
  **Hyper-V run mode**: choose **Interactive** or **Unattended**. Your default is first, so <kbd>Enter</kbd> keeps it.

!!! warning "Do not close Windows Sandbox early"
    If you close an interactive Windows Sandbox before the test ends, the test does not stop. The toolkit waits up to
    10 minutes (30 when you test an update), then records Inconclusive. If Windows Sandbox does not start by itself,
    an install and uninstall test is Inconclusive, even when you start it by hand.

## Read the result

### In the menu and the console

In the menu, the result is a panel:

- **INSTALL/UNINSTALL TEST PASSED** (green): all install and uninstall checks passed.
- **INSTALL/UNINSTALL TEST FAILED** (red): each failed check with its reason, and the path of the log.
- **Inconclusive** (yellow): no clear result. Read the messages above the panel.

<!-- SCREENSHOT: The green INSTALL/UNINSTALL TEST PASSED panel in the menu after a Windows Sandbox test of Git_x64_2.53.0 -->

Above the panel, and on the command line, the console prints each check and the result.

```text title="What you see at the end of the test"
...
  ASSERT InstallDetected-PostInstall = PASS
  ASSERT UninstallClean-PostUninstall = PASS
  ASSERT AppArpGone-PostUninstall = PASS

✓ INSTALL/UNINSTALL TEST PASSED - 3 assertion(s) passed.
PSADT exit codes (Sandbox\Logs\PsadtExitCodes.log):
  [2026-10-29 10:16:03Z] app Install parent=x64-direct exit=0 result=Success
  [2026-10-29 10:18:41Z] app Uninstall parent=x64-direct exit=0 result=Success
Run logs         : C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0\Sandbox\Logs\Runs\20261029-111500_InstallUninstall
```

### What the checks mean

The logs call the checks assertions. Each check ends with `PASS`, `FAIL` or `SKIP` (nothing to check). Apps with an
[MSI](glossary.md#msi) installer get two extra checks.

| Check as printed | What it means |
|---|---|
| `InstallDetected-PostInstall` | After the install, the install tattoo holds the app version. Intune would detect the app. |
| `MsiProductInstalled-PostInstall` | MSI apps only. Windows Installer lists the app after the install. |
| `UninstallClean-PostUninstall` | After the uninstall, the install tattoo is gone. |
| `MsiProductRemoved-PostUninstall` | MSI apps only. Windows Installer no longer lists the app. |
| `AppArpGone-PostUninstall` | The app's own entries in the list of installed apps are gone. Older projects do not get this check. |
| `DependenciesInstalled` | Printed only when a dependency did not install. The app was then not installed. |

### Passed, Failed, Inconclusive

| Result | What it means | What to do |
|---|---|---|
| Passed | Every check passed. Some checks can be skipped. | Build the package. |
| Failed | At least one check failed, even if the test stopped early. | Read the log that the result names. Fix the project and test again. |
| Inconclusive | No clear result. | Read the warnings above the result. Fix the cause and test again. |

A test is Inconclusive in these cases:

- Windows Sandbox was closed early or did not start.
- The test stopped early, ran out of time or lost lines of its log.
- Every check was skipped. [Re-create the project](projects.md#re-create-a-project).
- The toolkit did not start the test, see [When a test is not started](#when-a-test-is-not-started).

Some errors stop a test before it starts. Then the toolkit records no result, for example when another Windows
Sandbox is still open.

### Where the results are kept

Each test adds one record to `Documentation\TestResults.json` in the project: scenario, test machine, mode, time,
result and every check. Each test also keeps its logs in a run folder of its own, for example
`Sandbox\Logs\Runs\20261029-111500_InstallUninstall\` (local start time and scenario).

The file `Sandbox\Logs\PsadtExitCodes.log` has one line for each install and uninstall. Each line shows the [exit code](glossary.md#exit-code): the number that a program returns when it ends. `parent=x86-cmd` instead
of `parent=x64-direct` means that the test started the package the way Intune does. Times in this file are UTC, see
[Exit codes and logs](exit-codes.md#where-to-find-logs).

When you build or publish the package, the toolkit shows a Failed or Inconclusive result again. It does not stop
you.

## Test an update from an older version

Run an [update test](glossary.md#update-test) before you publish a new version or an [update app](glossary.md#update-app). An update app is a second Intune app that reaches only devices with an older
version. The test installs an [old version](glossary.md#baseline) first, then your package over it.
The console calls the old version the baseline.

=== "Menu"

    1. In the main menu, choose **Work with an existing project** > your project > **Run a test**.
    2. At **Which test backend?**, choose **Windows Sandbox**.
    3. At **Test scenario**, choose **Update from an older version**.
    4. At **Old-version baseline source**, choose **Download an older version from winget**.
    5. If the menu asks **Baseline installer technology**, choose **Auto** (see below).
    6. At **Baseline version**, choose the version to update from. The newest is first.
    7. At **Also verify the update-app requirement rule during the test?**, answer `y`. (The default is Yes.)

    The packaging wizards do not offer this test.

=== "Command line"

    Add `-Scenario Update`. `-VersionsBack 1` takes the version before the packaged one.

    ```powershell
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario Update -VersionsBack 1
    ```

    Use `-SpecificVersion '2.52.0'` for an exact version. Without either option, the command shows a list. An
    unattended test cannot ask, so it takes the version before the packaged one.

    For every option, see [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

These are the main checks of the update test:

- Before the update, the requirement rule of the update app finds the old install (`Requirement-PreUpdate`). This
  rule decides which devices get the update app.
- After the update, the install tattoo shows the new version (`Tattoo-PostUpdate`).
- The old version is no longer in the list of installed apps (`OldArpGone-PostUpdate`).
- The files of the new version are in place (`NewAppIntact-PostUpdate`).
- The update itself ended with a success exit code (`UpdateExitCode-PostUpdate`).

The console lists these checks at the end of the test. In the menu, the result is the **UPDATE TEST PASSED** or
**UPDATE TEST FAILED** panel, or **Inconclusive**.

<!-- SCREENSHOT: Host console showing the Update test verdict block (PASS with the requirement and tattoo assertions listed) -->

In an interactive Windows Sandbox test, the countdown says that the uninstallation begins in 2 minutes. In fact the
update comes next. The first line shows the install result of the old version.

### Choose the installer technology of the old version

Many apps ship more than one [installer technology](glossary.md#installer-technology), for example an
MSI and a vendor EXE. An MSI never removes an EXE install. So a device with the EXE gets two installs of the app in
one folder.

| Menu choice | Command line | The old version is installed as |
|---|---|---|
| **Auto** | `-BaselineInstallerType Auto` (the default) | The other technology that winget ships for this app, else the technology of your package. |
| **Test both technologies** | `-BaselineInstallerType Both` | Each technology, in one update test each. |
| **Only the packaged technology** | `-BaselineInstallerType Packaged` | The technology of your package. |
| Not in the menu | `-BaselineInstallerType nullsoft`, or `msi`, `wix`, `burn`, `inno`, `exe`, `msix` | That installer type, else another type of the same technology. |

The menu asks only when winget ships another technology. If the chosen version does not ship it, **Auto** warns you
and uses the technology of your package.

With **Only the packaged technology** or an installer type, the test never uses another technology. If the old
version does not ship it, the console prints `Update test: NO VERDICT` and the test records Inconclusive.

If the old install of the other technology is still there after the update, the test fails. The console prints a
warning that starts with `Technology switch:`, and the menu shows a red **TECHNOLOGY SWITCH** panel. Read
[Installer technology](packaging.md#installer-technology) before you publish.

### Apps that are not in winget

These apps have no older versions to download. Package the older version as a project first, for example
`Contoso_Reader_x64_3.1.0`. In the menu, **Baseline project** then lists your other projects: choose the older one.
On the command line, use `-BaselineProject`:

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0' -Scenario Update -BaselineProject 'Contoso\Contoso_Reader_x64_3.1.0'
```

`-RunTest Update` on [New-Win32ToolkitManualApp](reference/New-Win32ToolkitManualApp.md) or
[Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md) gives no result for these apps. See
[Test an update of a manual app](manual-apps.md#test-an-update-of-a-manual-app).

## Choose where the test runs

Windows Sandbox is the default test machine. It needs no extra setup. The Hyper-V test VM needs a one-time setup (see
[Set up the Hyper-V test VM](hyperv-vm.md)), but it can test the package as Intune runs it.

- **For one test:** answer **Which test backend?** in the menu, or add `-Backend HyperV` on the command line.
- **As your default:** in the main menu, choose **Settings** > **Hyper-V test VM** >
  **Set the default test backend**. See [Make the test VM your default](hyperv-vm.md#make-the-test-vm-your-default).
  The default applies to the commands and to tests while you build. **Run a test** still asks every time.

The toolkit uses the test VM only when it is ready. If it is not, the test runs in Windows Sandbox. A warning gives the
reason, for example that PowerShell does not run as administrator.

Results can differ. In Windows Sandbox, the package runs as the Windows Sandbox user. On the test VM, it runs as the
[SYSTEM account](glossary.md#system-account): the Windows account that Intune uses to install apps. So
a package can pass in Windows Sandbox and still behave differently on devices.

## Test as Intune does

On the Hyper-V test VM, an unattended test runs the package the way Intune does on a device:

- It runs as the SYSTEM account.
- It uses the same command line as Intune: `Invoke-AppDeployToolkit.exe -DeploymentType Install` (or `Uninstall`).
- A 32-bit program starts it, like the Intune program on devices.
- The exit codes 0, 1707, 3010 and 1641 count as success.

It takes about 4 to 5 minutes (depends on your PC). Start PowerShell 7 as administrator first.

=== "Menu"

    After **Run a test**, choose **Hyper-V VM** at **Which test backend?** and **Install then uninstall** at
    **Test scenario**. At **Hyper-V run mode**, choose **Unattended**.

=== "Command line"

    Add `-Backend HyperV` and `-TestMode Unattended` to the test command.

    ```powershell
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario InstallUninstall -Backend HyperV -TestMode Unattended
    ```

    For every option, see [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

### When a test is not started

Before an unattended test on the test VM, the toolkit runs the [Intune-parity pre-check](glossary.md#intune-parity-pre-check). It finds a test that would only wait for a dialog nobody answers.
The first Intune-parity pre-check on the test VM can take a few minutes. A test waits for such a dialog when all of
these are true:

- The package uses [PSAppDeployToolkit (PSADT)](glossary.md#psadt) 4.1, not 4.2. PSADT is the free
  PowerShell tool inside every package.
- Its list of [processes to close](glossary.md#processes-to-close) is empty. These are the programs
  that PSADT asks people to close before the install. For an MSI, PSADT also adds the programs inside the MSI to this
  list.
- Its welcome dialog lets the signed-in person postpone the install.
- A user is signed in to the test VM. The toolkit's test VM always has one.

PSADT 4.1 then shows its welcome dialog. The test would wait 25 minutes and fail with exit code 1460. So the toolkit
does not start it. A warning explains why, and the console prints this line:

```text
Install/uninstall test: NOT RUN (Intune-parity pre-check).
```

The toolkit records the result as Inconclusive and changes nothing else in the project. Devices with a signed-in user
show the same dialog. To test such a package, do one of these:

- Run an interactive test and answer the dialog in the VM window. Use `-TestMode Interactive`, or **Interactive** at
  **Hyper-V run mode**.
- Add the app's program to the processes to close, see [Change a project by hand](projects.md#change-a-project-by-hand).
  PSADT 4.1 then asks only while the app runs, on devices too.

## Test while you build

You can run tests as part of packaging.

=== "Menu"

    In the winget wizard, at **After building, also…**, tick **Run an install/uninstall test in Windows Sandbox**
    with <kbd>Space</kbd>. The wizard for apps that are not in winget has the same choice.

=== "Command line"

    Add `-RunTest InstallUninstall` to [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md). `-RunTest Update`
    also works.

    ```powershell
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso' -RunTest InstallUninstall
    ```

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

The toolkit first runs the [install capture](glossary.md#install-capture): it installs the app once to
learn how to detect and remove it. Then come your tests, then the package if you asked for it. The tests use your
default test machine and test mode. After a failed test, packaging continues with a warning.

!!! tip "Chain tests as unattended tests"
    Run several tests in a row only as unattended tests. An interactive Windows Sandbox stays open after the first
    test. The second test waits 90 seconds for it to close, then gives no result. Set `SandboxTestMode` to
    `Unattended` for such runs, see [Tests](settings.md#tests).

## What you have now

- A new record in `Documentation\TestResults.json` and the logs in `Sandbox\Logs\Runs\` in your project.
- The app is not installed on your PC. It was installed only in the test machine.
- After an interactive test, Windows Sandbox is still open. Close it when you are done. The next test or install
  capture cannot start while it is open.
- Nothing in Intune. The `Sandbox\` and `Documentation\` folders never go into the package.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `Another Windows Sandbox is still running after waiting 90 s` | Close the other Windows Sandbox, for example from an interactive test. Also close a window that still shows `The remote environment is shutting down`. Test again. |
| `The sandbox did NOT auto-launch` | The result is Inconclusive. Check that Windows Sandbox opens, then test again. |
| `ASSERT InstallDetected-PostInstall = FAIL` | The install wrote no install tattoo with this version. Read the install log in the run folder. |
| `ASSERT DependenciesInstalled = FAIL` | A dependency did not install, so the app was not installed. Fix or remove the dependency. |
| `Hyper-V test backend requested but not ready` | The test ran in Windows Sandbox. Fix the reason in the brackets. |
| `Guest phase '...' exited with code 1460` | A step in the test VM reached its time limit, often at a dialog. Run an interactive test to see it. |
| `This project has prior-install rules or sibling-capture records` | Your project has rules or captures for other installs. Use the test VM or an unattended test. See [Devices that already have the app](prior-installs.md). |

More messages and fixes are in [Tests](troubleshooting.md#tests).

## Next step

Build the `.intunewin` package from your tested project.

[Next: build the package](build-intunewin.md){ .md-button .md-button--primary }
