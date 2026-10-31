---
description: "Find the first words of a win32-toolkit message and learn what it means and what to do."
---

# Troubleshooting

Search this page for the first words of a win32-toolkit message: press <kbd>Ctrl</kbd>+<kbd>F</kbd> or use the site
search. Also read the yellow warning lines above a red error, because they often name the cause.

## First checks

- Look at the [system check](glossary.md#system-check): the table on the main screen of the menu
  ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)). It shows what is missing. To see it again, choose
  **Settings** > **Re-run the system check**.
- Open a new PowerShell 7 window. Some problems disappear in a new window, for example a [PSAppDeployToolkit (PSADT)](glossary.md#psadt) version that is already loaded. Every package uses PSADT to install the app.
- Read the warning above the error. In the menu, the red **Something went wrong** panel can also show an `Error id:`
  line.
- Look at the logs. [Where to find logs](exit-codes.md#where-to-find-logs) lists every log folder.
- Run the step again. After a network error or a busy [Windows Sandbox](glossary.md#windows-sandbox),
  the second try often works. Windows Sandbox is a clean, temporary Windows that opens in a window.

## Install and start

| Message starts with | What it means | What to do |
|---|---|---|
| `PowerShell 7.4 or later (pwsh) is required` ... | The double-click file `Launch-Win32Toolkit.cmd` found no PowerShell 7 on your PC. | [Install PowerShell 7](install.md#install-powershell-7). |
| `Show-Win32Toolkit needs an interactive console window` ... | This window cannot show the menu, for example an editor console. | Start the menu in a normal PowerShell 7 window. |
| `Cannot start the UI without it.` ... | You refused to install PwshSpectreConsole, the module that draws the menu. | Start the menu again and answer `Y`. The commands work without it. |
| `Winget is not installed or not available in PATH` | [winget](glossary.md#winget), the Windows Package Manager, is missing. The menu says `winget is not available on this PC.` | Install App Installer from the Microsoft Store, or [package a manual app](manual-apps.md). |
| `Windows Sandbox feature is not enabled.` ... | Windows Sandbox is off. win32-toolkit never turns on Windows features. You turn them on once. | [Turn on Windows Sandbox](install.md#turn-on-windows-sandbox), restart, and run the step again. |
| `PSAppDeployToolkit <version> is already loaded` ... | One window can load only one PSADT version. | Open a new PowerShell window and run the step again. |
| `PreferredPsadtVersion '<version>'` ... | The PSADT version you pinned is not installed or not supported. | Choose another version in **Settings** > **PSAppDeployToolkit version**, or remove the pin. See [Choose the PSADT version](maintain-toolkit.md#choose-the-psadt-version-for-new-projects). |

!!! note "Red rows on a new PC"
    On a new PC, the system check shows PSAppDeployToolkit, Microsoft.Graph.Authentication and IntuneWinAppUtil.exe in
    red. This is normal: the toolkit gets them when you first need them. The tip under the table names Settings, but
    only the base folder (where the toolkit keeps your files) can be fixed in **Settings**.

## Org templates

An [org template](glossary.md#org-template) holds the settings of one customer.

| Message starts with | What it means | What to do |
|---|---|---|
| `Org template text rejected` ... | A text would make PSADT fail every deployment (`W32T.OrgTemplateInvalid`). | Choose **Org templates** > **Edit a template**. See [Text rules](org-templates.md#text-rules). |
| `<Field>: '<value>' contains` ... | The wizard refuses a `$` before a letter, and any backtick. PSADT would fail or change the text. | Remove the character. See [Text rules](org-templates.md#text-rules). |
| `Template '<name>' uses schema v` ... | An older toolkit version saved the template. | Answer `y` (the default), then answer the new questions. |
| `Several org templates exist under` ... | A script cannot choose the template (`W32T.OrgTemplateChoiceNeeded`). | Add `-TemplateName` with the name of your template. |
| `Org extension module '<folder>' cannot be used:` ... | The extension module has a wrong layout, asks for another PSADT version, or uses a name the toolkit keeps for its own extension module (`W32T.OrgExtensionInvalid`). | See [Add an extension module](org-template-files.md#add-an-extension-module). |
| `A maximum run time of <n> minutes is 30 minutes or less` ... | Intune would stop a slow uninstall first and report a timeout. | Keep the value above 30 minutes. The default is 60. |

Changes to an org template reach new projects only. Re-create a project to apply them.

## Packaging from winget

The [installer technology](glossary.md#installer-technology) is the kind of setup the vendor uses, for
example an MSI or an NSIS `.exe`.

| Message starts with | What it means | What to do |
|---|---|---|
| `Package ID '<id>' not found in winget.` ... | No winget source knows this exact ID. | Check the ID with `winget search <name>`. |
| `winget offers no <family> installer for <id>` ... | The pinned installer technology is not offered for this version (`W32T.InstallerVariantUnavailable`). | Skip this version, or [switch on purpose](packaging.md#when-a-new-version-no-longer-ships-it). |
| `winget download exited with code` ... | The download failed, so the run stops with `W32T.DownloadFailed`. | Run again after a network error. See [Recover from a stopped build](projects.md#recover-from-a-stopped-build). |
| `winget could not download <app>: a configured winget source failed to authenticate` ... | A warning: a private winget source needs a sign-in. The toolkit tries the download once more, from the public `winget` source only. | If the app is in the public `winget` source, do nothing. Otherwise, sign in to your private source and run again. |
| `winget reported success for <app> but wrote no installer` ... | A ZIP, portable or Store app, without an installer. | Get the installer from the vendor and [package a manual app](manual-apps.md). |
| `Project directory already exists:` ... | This version already has a project. | Answer `y` to replace it. The menu replaces it without asking. |
| `Failed to create the PSADT project` ... | No new project was made (`W32T.ProjectCreationFailed`). You also see this message after you answer `n` to the replace question. | Read the warning above it, then run again. |
| `PSADT configuration failed` ... | The project was not set up (`W32T.PipelineAborted`). | Fix the cause in the warnings. Then [package the app again](projects.md#recover-from-a-stopped-build). |
| `winget also ships <technology>` ... | A warning: devices with the other technology would get two installs. | See [Warnings after the download](packaging.md#warnings-after-the-download). |
| `Several winget ids in this template look like the same product` ... | A warning: more than one winget ID in this org template seems to be this app. | See [Warnings after the download](packaging.md#warnings-after-the-download). |

## The install capture

The [install capture](glossary.md#install-capture) installs the app in Windows Sandbox or on the
[Hyper-V test VM](glossary.md#hyper-v-test-vm), a virtual machine (VM) for tests. It records what
changes. To run it again, choose **Work with an existing project** > choose your project > **Finalize / refresh**.

| Message starts with | What it means | What to do |
|---|---|---|
| `Another Windows Sandbox is still running after waiting 90 s` ... | Only one Windows Sandbox can run. The capture or the test did not start. | Close the other Windows Sandbox. Then run **Finalize / refresh** again for a capture, or **Run a test** again for a test. |
| `The sandbox did NOT auto-launch` ... | Windows Sandbox did not start by itself. | Double-click the `.wsb` file it names. The toolkit stops waiting after 30 minutes. |
| `Documentation JSON file not found after 30 minutes.` ... | The capture never finished. | Close Windows Sandbox and [run the capture again](projects.md#run-the-install-capture-again). |
| `ProcessesToClose: no user-launchable processes detected` ... | The capture found no program of the app to close. | If needed, add program names to `ProcessesToClose` in `SupportFiles\AppConfig.json`. See [Change a project by hand](projects.md#change-a-project-by-hand). |
| `Uninstaller(s) <list> have no silent switch in the capture` ... | The uninstall would show windows that nobody sees. | Set `Uninstall.Uninstallers[].Args` in `SupportFiles\AppConfig.json`, again after each capture. |

### The installer failed or did nothing

```text title="What you see"
The PSADT install in the capture run failed with exit code <n> ...
The capture recorded NO changes (no new files, registry keys, services or programs) ...
```

Why: the installer did not install the app. For an `.exe`, the cause is often wrong [silent switches](glossary.md#silent-switches), the options that install an app without windows.

Fix:

1. Open `SupportFiles\AppConfig.json` in the project.
2. Correct `Installer.SilentArgs`. For example, Inno Setup needs `/VERYSILENT`.
3. Choose **Work with an existing project** > choose your project > **Finalize / refresh**.

Run a good capture before you publish. For some apps, Intune detects the app with data from the newest capture, even a
failed one.

## Tests

A test runs on a [test machine](glossary.md#test-machine): Windows Sandbox or the Hyper-V test VM. It
ends **Passed**, **Failed** or [Inconclusive](glossary.md#inconclusive). Inconclusive means no clear
result.

A failed test only warns. It does not stop packaging or publishing.

| Message starts with | What it means | What to do |
|---|---|---|
| `Hyper-V test backend requested but not ready` ... | The test runs in Windows Sandbox instead. | Fix the reasons in brackets. See [Check that the VM is ready](hyperv-vm.md#check-that-the-vm-is-ready). |
| `No assertion results appeared within` ... | No results came back, often because Windows Sandbox was closed early. | Run the test again. Leave Windows Sandbox open until the result shows. |
| `INSTALL/UNINSTALL TEST FAILED` or `UPDATE TEST FAILED` | A check failed. The console calls checks assertions. | Read the log that the panel names. See [What the checks mean](testing.md#what-the-checks-mean). |
| `The update exited with code` ... | The update itself failed, so the [update test](glossary.md#update-test) is Failed. This test installs an old version first. | Read the PSADT log of the run. See [Where to find logs](exit-codes.md#where-to-find-logs). |
| `Update test: NO VERDICT` ... | The old version has no installer of the chosen technology. | Choose [another old version or technology](testing.md#choose-the-installer-technology-of-the-old-version). |
| `Technology switch: the vendor` ... | Devices with the other technology would get two installs. | See [When a test reports a technology switch](packaging.md#when-a-test-reports-a-technology-switch). |
| `Intune-parity pre-check: the unattended Hyper-V` ... | Not started: a PSADT 4.1 dialog would wait for an answer. | See [When a test is not started](testing.md#when-a-test-is-not-started). |
| `The <scenario> test of <path> cannot be trusted:` ... | The test machine changed your project (`W32T.GuestTamper`). | [Re-create the project](projects.md#re-create-a-project). |

## Building the package

Before the toolkit builds the package, it runs the [package check](glossary.md#package-check). The check
refuses a project that the toolkit cannot trust, for example because of its [deploy script](glossary.md#deploy-script), `Invoke-AppDeployToolkit.ps1`.

| Message starts with | What it means | What to do |
|---|---|---|
| `win32-toolkit cannot vouch for the deploy script of` ... | The package check failed (`W32T.PackageNotReady`). One line per problem follows. | Fix each problem. See [The package check](build-intunewin.md#the-package-check). |
| `'<name>' is marked not configured and cannot be packaged` ... | The build of the project stopped halfway (`W32T.ProjectNotConfigured`). | Package the app again. See [Recover from a stopped build](projects.md#recover-from-a-stopped-build). |
| `Unsupported PSADT template shape:` ... | The toolkit does not know the layout of the deploy script (`W32T.UnsupportedTemplateShape`, or one line of the package check). If the message says a newer win32-toolkit generated the script, a newer toolkit made the project. | [Re-create the project](projects.md#re-create-a-project), or update the toolkit. |
| `Deploy extension (` ... | One line of the package check. The [toolkit extension](glossary.md#toolkit-extension) in the project is missing or changed, the deploy script lacks a block that the project needs, or a folder that PSADT would load is not an extension module. | Delete a folder that the message calls stray. Otherwise, [re-create the project](projects.md#re-create-a-project). |
| `win32-toolkit has no deploy-script blocks for the installer type` ... | `SupportFiles\AppConfig.json` names a kind of installer that the toolkit cannot package (`W32T.UnsupportedInstallerType`). | Package an MSI, EXE, MSIX or APPX installer of the app. |
| `win32-toolkit's own PSADT extension module at` ... | The toolkit's own files on your PC were changed or are incomplete (`W32T.DeployExtensionInvalid`). | [Update or reinstall](maintain-toolkit.md) win32-toolkit. |
| `Unsafe uninstall cleanup path:` ... | The uninstall would delete a folder outside the app. This check has no override. | Remove the path from `SupportFiles\AppConfig.json`, run the install capture again, or re-create the project. |
| `Failed to download IntuneWinAppUtil.exe:` ... | The toolkit could not reach GitHub. | Download the file by hand and put it in the folder the message names. |
| `Skipped the update app: this project has no reliable` ... | This project cannot get an [update app](glossary.md#update-app): an app only for devices with an older version. | Publish the install app only. |

!!! warning "Re-creating deletes the folder"
    Re-creating a project deletes its folder. Copy your own code out first. See
    [Re-create a project](projects.md#re-create-a-project).

## Sign-in and tenant

Your [tenant](glossary.md#tenant) is the Intune space of one organization. A tenant [pin](glossary.md#pin) on the org template makes the toolkit refuse any other tenant.

| Message starts with | What it means | What to do |
|---|---|---|
| `Microsoft.Graph.Authentication module not found.` | The sign-in module is missing. | Answer `Y` at `Install it now from PSGallery? (Y/N)`. |
| `Microsoft.Graph.Authentication is required but this session is non-interactive.` ... | A script cannot answer the install question. | First run `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser`. |
| `Need admin approval` | A Microsoft sign-in page. Nobody gave [admin consent](glossary.md#admin-consent) yet: an administrator's one-time yes for the sign-in app. | Ask an administrator to consent once. See [What your account needs](intune-connection.md#what-your-account-needs). |
| `Connected to tenant '<ID>' but '<pin>' was requested.` ... | The browser signed you in to another tenant. | Sign the browser out of it, or use device code sign-in. See [Connect](intune-connection.md#connect). |
| `REFUSING publish: this project is pinned to tenant` ... | You are signed in to another tenant. Nothing was created. | Run the [`Connect-Win32ToolkitIntune`](reference/Connect-Win32ToolkitIntune.md) command it shows. |
| `This project's template does not pin a tenant` ... | A warning: nothing checks the tenant. | Read the tenant name now. [Pin the tenant ID](intune-connection.md#pin-the-tenant-on-your-org-template) on the org template. |
| `Connect failed:` ... | The connection failed, but a script continues. | In scripts, add `-ErrorAction Stop`. |

Use the tenant ID, not a domain name. A domain such as `contoso.onmicrosoft.com` never matches the pin.

## Publishing

Every publish creates a new app in Intune. Publishing again does not change the old app. Intune finds the app with a
[detection rule](glossary.md#detection-rule). Usually this rule checks the [install tattoo](glossary.md#install-tattoo), a registry value that the package writes.

| Message starts with | What it means | What to do |
|---|---|---|
| `No detection rule for '<name>'` ... | No install tattoo and no usable install capture (`W32T.NoDetectionRule`). | Run the install capture. See [Apps that cannot be detected automatically](publishing.md#apps-that-cannot-be-detected-automatically). |
| `Prior install: the prior-install rules changed after Export` ... | The package is older than its rules (`W32T.PackageNotReady`). | Build the package again, then publish. |
| `Update app requested, but no requirement rule could be built` ... | This update app would reach every device. | Publish the install app only. |
| `Timed out after <n> s waiting for` ... | Intune was slower than the wait time. | Delete the incomplete app. Publish again with a longer wait. See [If the publish fails](publishing.md#if-the-publish-fails). |
| `Intune reported a failure while waiting for` ... | Intune refused the upload. | Delete the incomplete app, build the package again, and publish. |
| `Publish-Win32ToolkitIntuneApp failed:` ... | A request to Intune failed. The line `Graph API error:` says why. | A 403 means your account has no Intune role for apps. See [What your account needs](intune-connection.md#what-your-account-needs). |
| `The latest install/uninstall test` ... | A warning: the last test Failed or was Inconclusive. | Test again before you assign the app. |
| `UNSAFE-CLEANUP:` ... | The uninstall would delete folders outside the app. | Run the install capture again, build the package, then publish. |

!!! warning "Delete an incomplete app"
    If a publish fails after the line `App created`, an incomplete app stays in Intune. Delete it in the Intune admin
    center before you publish again.

## Dependencies

A [dependency](glossary.md#dependency) is another app that Intune installs before your app.

| Message starts with | What it means | What to do |
|---|---|---|
| `Dependency reference '<ref>' has no value after the` ... | The reference is incomplete (`W32T.InvalidDependencyReference`). | See [Three kinds of reference](dependencies.md#three-kinds-of-reference). |
| `Dependency '<source>:<ref>' could not be staged:` ... | The test machine cannot get it (`W32T.DependencyNotStaged`). Nothing ran. | Fix or remove the dependency, then run again. See [Dependencies in tests](dependencies.md#dependencies-in-tests). |
| `Dependency 'intune:<id>' is an app id in the tenant` ... | Tests run without an `intune:` dependency. | To test with it, declare it as `winget:` or `project:`. |
| `ASSERT DependenciesInstalled = FAIL` ... | A dependency failed to install, so the test is Failed. | Its exit code is in `Sandbox\Logs\PsadtExitCodes.log`. See [Read the exit-code log](exit-codes.md#read-the-exit-code-log). |
| `Dependency '<source>:<ref>' is NOT published` ... | The app was published without it. | Publish the dependency, then run [`Sync-Win32ToolkitAppDependency`](reference/Sync-Win32ToolkitAppDependency.md). |
| `Dependency 'winget:<id>' matched <n> apps in the tenant` ... | The toolkit does not guess which app is right, so it skips the dependency. | Declare it as `intune:<app id>`. |
| `Intune refused the relationship write (403).` ... | Your account lacks the Intune permission Relate. | Get Relate, then run `Sync-Win32ToolkitAppDependency`. See [Change the dependencies of an app in Intune](dependencies.md#change-the-dependencies-of-an-app-in-intune). |

!!! warning "Do not publish again for dependencies"
    The menu says `re-publish to attach the Intune relationships`. For an app that is already in Intune, run
    `Sync-Win32ToolkitAppDependency` instead. Publishing again creates a second app.

## Manual apps

A manual app is an app that is not in winget. You give the installer yourself. For an [Advanced app](glossary.md#advanced-app), you also write the install code.

| Message starts with | What it means | What to do |
|---|---|---|
| `No installer (msi/exe/msix/appx) detected in:` ... | No installer is at the top level of the folder. | Move it there and package the app again. See [Installer files and folders](manual-apps.md#installer-files-and-folders). |
| `Files\ contains <n> .msi files` ... | The toolkit uses the first file by name. | Remove the extra files if that is wrong. |
| `The org template could not be applied` ... | The project is marked not configured (`W32T.PipelineAborted`). | Fix the template, then package the app again. |
| `Tattoo/version detection unavailable` ... | Often `App.Vendor`: no publisher, so no install tattoo. | See [Always give a publisher](manual-apps.md#always-give-a-publisher). |
| `ASSERT InstallDetected-PostInstall = FAIL` ... | Often a `return` in Advanced install code: the install tattoo was not written. | Use `throw`, never `return`. See [Write the install code](manual-apps.md#write-the-install-code). |
| `No winget PackageIdentifier found in:` ... | The update test gets the old version from winget, and a manual app has no winget ID. | See [Test an update of a manual app](manual-apps.md#test-an-update-of-a-manual-app). |

!!! note "Manual apps keep no tenant pin"
    A manual app does not keep the tenant pin of its org template. When you publish it later, read the tenant name in
    the warning.

## Hyper-V test VM

The Hyper-V test VM returns to its [checkpoint](glossary.md#checkpoint), a saved clean state, before
every test. "Guest" in a message means the Windows inside the VM.

| Message starts with | What it means | What to do |
|---|---|---|
| `New-Win32ToolkitTestVM requires an elevated (Administrator) session` ... | Hyper-V needs administrator rights. | Open PowerShell 7 with **Run as administrator**. |
| `No preferred edition` ... | The build uses the first Windows edition, often Home. | Run [`New-Win32ToolkitTestVM`](reference/New-Win32ToolkitTestVM.md) again with `-Edition` or `-ImageIndex`. |
| `VHDX already exists:` ... | An earlier build left its virtual disk. | See [Repair a broken VM](hyperv-vm-care.md#repair-a-broken-vm). |
| `PowerShell Direct did not become ready within 900 s` ... | The toolkit cannot reach Windows in the VM. Often the password is wrong. | See [Fix a wrong VM password](hyperv-vm-care.md#fix-a-wrong-vm-password). |
| `The test VM pinned by W32T_HYPERV_VM` ... | The VM of this window is not ready (`W32T.HyperVTargetNotReady`). | Fix it, or [remove the pin](hyperv-vm-care.md#use-another-vm-in-one-powershell-window). |
| `Another process kept` ... | Only one window can use the VM (`W32T.HyperVLeaseTimeout`). | Wait for the other run. See [When another window is using the VM](hyperv-vm-care.md#when-another-window-is-using-the-vm). |
| `The <task> was not started: the lock folder` ... or `the lease file` ... | The folder `%ProgramData%\win32-toolkit\locks` or a lock file in it is missing or not safe (`W32T.HyperVLeaseUnsafe`). A lease file is such a lock file. | Open PowerShell 7 with **Run as administrator**. If the message says `Remove it from an elevated session`, delete what it names there. Then run the step again. |
| `The test VM's checkpoint '<checkpoint>' is <n> days old` ... | Every run first installs Windows updates. | [Re-take the checkpoint](hyperv-vm.md#re-take-the-checkpoint). |
| `No interactive desktop detected (login screen?)` ... | Each [interactive test](glossary.md#interactive-test), a test you watch, loses 1 to 3 minutes. | [Re-take the checkpoint](hyperv-vm.md#re-take-the-checkpoint) at a signed-in desktop. |
| `Guest phase '<label>' exited with code 1460` ... | The test time ran out. Often a PSADT dialog waited for an answer. | Run an interactive test to see the dialog. See [Test as Intune does](testing.md#test-as-intune-does). |

## Prior installs

A [prior install](glossary.md#prior-install) is the same app from another installer technology. A
[prior-install rule](glossary.md#prior-install-rule) tells the package what to do with it: stop the
install (Block), remove it first (Enforce) or only report it (Report). A [sibling capture](glossary.md#sibling-capture) installs the other technologies of the app on a test machine and records them.

| Message starts with | What it means | What to do |
|---|---|---|
| `This project has prior-install rules or sibling-capture records:` ... | An interactive test in Windows Sandbox could change the project (`W32T.PriorInstallRefused`). | Run an unattended test, which nobody watches, or use the Hyper-V test VM. |
| `No prior-install rule can be written into` ... | The deploy script has no place for rules (`W32T.PriorInstallSlotsMissing`). | [Re-create the project](projects.md#re-create-a-project). |
| `The other installer technologies of '<name>' cannot be captured:` ... | For example a manual app, or no install capture yet (`W32T.SiblingCaptureUnsupported`). | See [What you need first](prior-installs.md#what-you-need-first). |
| `The other installer technologies of '<name>' were not captured: the Hyper-V test VM is not ready` ... | After a capture in Windows Sandbox, no rule could ever remove the installs named in the message. | Make the test VM ready and capture again. |
| `The other installer technologies of '<name>' were not captured: another Windows Sandbox` ... | Only one Windows Sandbox can run (`W32T.SandboxBusy`). | Close it and capture again. |
| `The other installer technologies were not captured:` ... | A warning: the build continued without the sibling capture. The reason follows the colon, for example an install capture that did not finish. | Fix the reason, then capture again. See [What you need first](prior-installs.md#what-you-need-first). |
| `Nothing was captured: the winget manifest of` ... | Often GitHub limits requests from your PC for a while. | Wait until the time in the message, then capture again. |
| `Prior install: the Enforce rule '<id>' is not proven` ... | No test proved the removal yet. | See [Prove the rule](prior-installs-enforce.md#prove-the-rule). |
| `Prior install: the captured Enforce rule '<id>' has no current approval` ... | The rule changed, or it was never approved. | See [Approve a proposal as Enforce](prior-installs-enforce.md#approve-a-proposal-as-enforce). |
| `Prior install: the rule '<id>' (<key> [<view>]) of <project> is missing` ... | The previous version had a rule that this package does not have. | Declare it again, or see [Acknowledgements and waivers](prior-installs-enforce.md#acknowledgements-and-waivers). |

Enforce removes another install as SYSTEM. Assign the package to a pilot group first.

## Symptoms in Intune or on devices

| Symptom | Likely cause | What to do |
|---|---|---|
| "Not detected" after a good install | An app from win32-toolkit 1.1.6 or older, a rule from a failed capture, or `return` in Advanced code. | Check the detection rule. See [Fix apps that are already in Intune](maintain-toolkit.md#fix-apps-that-are-already-in-intune). |
| Exit code 60008 | PSADT could not start: often a PSADT 4.2 package started by the old `powershell.exe` command line. | Use [the published command line](publishing.md#why-the-install-command-is-invoke-appdeploytoolkitexe). |
| Exit code 60001 | An error in the deploy script: the installer, a hook script or your install code failed. | Read the PSADT log on the device. See [Where to find logs](exit-codes.md#where-to-find-logs). |
| Exit code 1602 | Someone deferred the install, or a deploy mode was added to the command line and nobody was signed in. | Nothing for a deferral. Never change the published command line. |
| The app installs again and again | Intune does not detect it, or an older app of the same title is still assigned. | Check the detection rule. See [Replace the old app in Intune](new-version.md#replace-the-old-app-in-intune). |
| Two entries in Installed apps | The device already had the app from another installer technology. | Keep one technology. See [Devices that already have the app](prior-installs.md). |
| The app is in the wrong tenant | The org template had no tenant pin. | Delete the app there. [Pin the tenant ID](intune-connection.md#pin-the-tenant-on-your-org-template), then re-create the project. |
| Intune shows the folder name as the app name | A manual MSI app, such as `Contoso_Reader_x64_3.2.0`. | Rename it in the Intune admin center. See [Known limits](manual-apps.md#known-limits). |
| The publisher is "Unknown" | A manual app without a publisher. It also has no version detection. | See [Always give a publisher](manual-apps.md#always-give-a-publisher). |
| A generic tile icon | No app icon in the project, or `Assets\AppIcon.png` is not an image. | Add a logo in the Intune admin center. See [Where the app icon comes from](org-template-files.md#where-the-app-icon-comes-from). |

For exit codes 69101 to 69112, see [Prior-install codes](exit-codes.md#prior-install-codes).

## Error IDs

A [W32T error](glossary.md#w32t-error) stops a command on purpose. In a script, the ID is the
`FullyQualifiedErrorId` of the error.

In the menu, the red **Something went wrong** panel can show its ID on an `Error id:` line. A red **Error** panel shows
the message only, without an `Error id:` line. Search this page for its first words.

| Error ID | What it means | Section |
|---|---|---|
| `W32T.DependencyNotStaged` | A test could not get a dependency. | [Dependencies](#dependencies) |
| `W32T.DeployExtensionInvalid` | The toolkit's own extension files on your PC were changed. | [Building the package](#building-the-package) |
| `W32T.DownloadFailed` | winget downloaded no installer. | [Packaging from winget](#packaging-from-winget) |
| `W32T.GeneratedScriptInvalid` | The deploy script failed the toolkit's own check. | [Ask for help](#ask-for-help) |
| `W32T.GuestTamper` | The test machine changed the project. | [Tests](#tests) |
| `W32T.HyperVLeaseTimeout` | Another window used the test VM too long. | [Hyper-V test VM](#hyper-v-test-vm) |
| `W32T.HyperVLeaseUnsafe` | The lock folder or a lock file is not safe. Often you must run PowerShell as administrator. | [Hyper-V test VM](#hyper-v-test-vm) |
| `W32T.HyperVTargetNotReady` | The VM pinned for this window is not ready. | [Hyper-V test VM](#hyper-v-test-vm) |
| `W32T.InstallerVariantUnavailable` | winget lacks the pinned installer technology. | [Packaging from winget](#packaging-from-winget) |
| `W32T.InvalidDependencyReference` | A dependency reference is not valid. | [Dependencies](#dependencies) |
| `W32T.NoDetectionRule` | No detection rule can be built. | [Publishing](#publishing) |
| `W32T.OrgExtensionInvalid` | The extension module has a wrong layout, a wrong PSADT version, or a name the toolkit keeps. | [Org templates](#org-templates) |
| `W32T.OrgTemplateChoiceNeeded` | A script must pass `-TemplateName`. | [Org templates](#org-templates) |
| `W32T.OrgTemplateInvalid` | An org template text would make PSADT fail. | [Org templates](#org-templates) |
| `W32T.PackageNotReady` | The package check failed. | [Building the package](#building-the-package) |
| `W32T.PipelineAborted` | The project could not be set up. | [Packaging from winget](#packaging-from-winget) |
| `W32T.PriorInstallInvalid` | A prior-install rule is not valid. | [Type a rule by hand](prior-installs-enforce.md#type-a-rule-by-hand) |
| `W32T.PriorInstallRefused` | A prior-install step is not allowed now. | [Prior installs](#prior-installs) |
| `W32T.PriorInstallSlotsMissing` | The project has no place for rules. | [Prior installs](#prior-installs) |
| `W32T.ProjectCreationFailed` | The project could not be created. | [Packaging from winget](#packaging-from-winget) |
| `W32T.ProjectLeaseTimeout` | Another window tested the same project too long (setting `TestProjectLease`). | [Tests settings](settings.md#tests) |
| `W32T.ProjectNotConfigured` | The project build stopped halfway. | [Building the package](#building-the-package) |
| `W32T.SandboxBusy` | Another Windows Sandbox was open. | [Prior installs](#prior-installs) |
| `W32T.SiblingCaptureUnsupported` | The sibling capture cannot run now. | [Prior installs](#prior-installs) |
| `W32T.UnsupportedInstallerType` | The toolkit cannot package this kind of installer. | [Building the package](#building-the-package) |
| `W32T.UnsupportedTemplateShape` | The deploy script layout is unknown. | [Building the package](#building-the-package) |

Other IDs, such as `W32T.OrgTemplateDrift` or `W32T.PhaseAnchorMissing`, point to a problem inside the toolkit. If
one appears again in a new PowerShell window, ask for help.

## Ask for help

Open an issue on [GitHub](https://github.com/MG-Cloudflow/win32-toolkit/issues). Include these facts:

- The full message, with the warning lines above it.
- The menu path or the command you used.
- Your PowerShell version, from `$PSVersionTable.PSVersion`.
- The PSADT version from the system check.
- The logs of the run. See [Where to find logs](exit-codes.md#where-to-find-logs).

Remove tenant IDs, user names and app IDs before you post. Use sample values such as
`11111111-2222-3333-4444-555555555555` instead.
