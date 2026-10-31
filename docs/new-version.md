---
description: "Package, test and publish a newer version of an app that is already in Intune, then replace the old app."
---

# Ship a new version

Use this page for a newer version of an app that you published with win32-toolkit. You package, test and publish it
as a new project, then replace the old app in Intune. The examples update Git from `2.52.0` to `2.53.0`.
Your versions will differ.

## Before you start

- The earlier version is a [project](glossary.md#project), the folder of one app version. Here it
  is `Git_x64_2.52.0`.
- You use the same [org template](glossary.md#org-template) as before, for example `Contoso`.
- You published the earlier version, or you chose its [installer technology](glossary.md#installer-technology) on purpose. The installer technology is the kind of setup program,
  for example an MSI or a vendor EXE.
- You can [connect to Intune](intune-connection.md).
- Time: as for steps 3 to 7 of the guide. The update test adds a few minutes.

## The steps at a glance

1. [Package the new version](#package-the-new-version) with the same org template.
2. [Run an install and uninstall test](testing.md#run-an-install-and-uninstall-test).
3. [Test the update](#test-the-update-from-the-previous-version) from the version that your devices have now.
4. [Build the package](build-intunewin.md). In the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)),
   **Publish to Intune** builds it for you.
5. [Publish the install app](#install-app-update-app-or-both), and an update app if you want one.
6. [Replace the old app](#replace-the-old-app-in-intune) in the Intune admin center.

Does the earlier version block or remove another install? Then read
[With prior-install rules](#with-prior-install-rules) first.

## Package the new version

Package the new version as you packaged the earlier one. The toolkit always packages the newest version that winget
offers.

=== "Menu"

    1. In the main menu, choose **Package an app from winget**.
    2. At **Search winget for**, type the name of the app.
    3. At **Select the application**, choose the same app.
    4. If the wizard asks for the **Target architecture**, choose the same one.
    5. At **Choose an org template**, choose the same org template.
    6. If the wizard asks about the installer technology, choose the **Keep** entry that says recommended.
    7. If the earlier version had dependencies, answer `y` at **Does this app need another app installed FIRST**.
       Choose them again.
    8. Answer the other questions as in [Run the wizard](packaging.md#run-the-wizard).
    9. At **Build this now?**, type `y` and press <kbd>Enter</kbd>. (The default is No.)

    If the wizard offers **Skip this version (recommended)** instead, choose it and package a later version.

    If the technology question has no **Keep** entry, choose the technology that your devices already have. There is
    no **Keep** entry if you did not publish an earlier version or choose its technology on purpose.

=== "Command line"

    Run [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md) again with the same app, architecture and org
    template.

    ```powershell
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso'
    ```

    The line `Installer technology:` names the earlier version when the toolkit keeps its technology. If the earlier
    version had dependencies, give them again with `-DependsOn`. For every option, see
    [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

The new project gets its own folder, for example `Git_x64_2.53.0` next to `Git_x64_2.52.0`. Keep the earlier folder:
the toolkit reads it.

The new version keeps the installer technology of an earlier version that you published or chose on purpose. A version
that you only built does not count. The new version also takes the [prior-install rules](glossary.md#prior-install-rule) of the highest earlier version. These rules handle devices that have the
app from another installer technology.

The new project does not get your changes by hand, such as a new icon.
[Make them again](projects.md#change-a-project-by-hand) in the new project.

The new project does not get the dependencies either. Give them again while you package. To add them later, see
[Change the dependencies of a project](dependencies.md#change-the-dependencies-of-a-project).

### Warnings to expect

Two warnings compare the new package with that earlier version. They do not stop packaging.

- `The installer technology changed:` Devices with the earlier version would get two installs of the app. Package
  this version again with the `-InstallerType` that the message names.
- `The detection key changed from` The [install tattoo](glossary.md#install-tattoo) moved. This
  registry value tells Intune which version is installed. Its key
  `HKLM\SOFTWARE\<app script author>\<publisher>\<app name>` changed, so the
  [update app](#install-app-update-app-or-both) misses devices with the earlier version.

### Apps that are not in winget

In the main menu, choose **Package a manual app** and give the new installer. Use the same app name, architecture and
org template. See [Package an app that is not in winget](manual-apps.md).

## Test the update from the previous version

An [update test](glossary.md#update-test) installs an older version first, then your new package over
it. This guide calls that version the [old version](glossary.md#baseline). The console calls it the
baseline. The test shows two things: devices with the old version get the new one, and the update app finds them.

=== "Menu"

    In the main menu, choose **Work with an existing project** > choose `Git_x64_2.53.0` > **Run a test**. At
    **Test scenario**, choose **Update from an older version**. At **Baseline version**, choose `2.52.0`, the version
    that your devices have now. The menu also asks a few other questions.

=== "Command line"

    Run [`Test-Win32ToolkitProject`](reference/Test-Win32ToolkitProject.md) with the old version.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -SpecificVersion '2.52.0'
    ```

    For every option, see [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

!!! tip "Test from your own earlier package"

    Devices that got the app from Intune have your earlier package. To start from it, choose
    **Use a local packaged project** in the menu. On the command line, use
    `-BaselineProject 'Contoso\Git_x64_2.52.0'` instead of `-SpecificVersion`.

If some devices have the app from another installer technology, test from that technology too. See
[Installer technology](packaging.md#installer-technology).

A failed test only warns. It does not stop packaging or publishing.
[Test an update from an older version](testing.md#test-an-update-from-an-older-version) explains the questions and
the checks.

## Install app, update app, or both

The [install app](glossary.md#install-app) is the normal app that you assign. The [update app](glossary.md#update-app) is a second app with the same package. Its name ends in `(Update)`.

The update app has a [requirement rule](glossary.md#requirement-rule), a check that Intune runs before
it installs an app. Only devices that already have the app meet this rule. So the update app updates old installs
and installs nothing new. The rule looks for exact matches only, for example the install tattoo, the MSI upgrade code
or an installed app with exactly the same name.

| Choice in the menu | Command line | Use it when |
|---|---|---|
| **Install app** | `-PublishIntune` | You replace the old app with [supersedence](#replace-the-old-app-in-intune) or by hand. |
| **Install app + Update app** | `-PublishIntune -PublishUpdate` | New devices get the app, and old installs are updated. |
| **Update app only** | `-PublishUpdate` | The install app of this version is already in Intune. |

=== "Menu"

    In the main menu, choose **Work with an existing project** > choose `Git_x64_2.53.0` > **Publish to Intune**. At
    **Publish which app?**, choose an entry from the table. At **Package and upload now?**, type `y` and press
    <kbd>Enter</kbd>. (The default is No.)

=== "Command line"

    [`Export-Win32ToolkitIntuneWin`](reference/Export-Win32ToolkitIntuneWin.md) builds the package and publishes both
    apps.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune -PublishUpdate
    ```

    For a package that you already built, `-AsUpdate` on
    [`Publish-Win32ToolkitIntuneApp`](reference/Publish-Win32ToolkitIntuneApp.md) publishes the update app. For every
    option, see [Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md).

### What to know about the update app

- With both apps, the install app comes first. The update app is a second upload of the package, with no
  dependencies.
- The update app needs the install tattoo. Without the install tattoo, Intune checks only that the app is there, not
  its version. Old versions can then count as up to date.
- Without an install tattoo, an MSI upgrade code or an app name, there is no requirement rule. The menu and
  `Export-Win32ToolkitIntuneWin` then skip the update app with a warning. `-AsUpdate` refuses.
- The rule does not see an install from the vendor's other installer technology. The exception is an install that a
  prior-install rule of this package removes.

## Replace the old app in Intune

Every publish creates a new app in Intune. Publishing again does not change the old app.

win32-toolkit never assigns an app. You assign it in the Intune admin center. The toolkit also never sets supersedence
or deletes an app.

With the install tattoo, Intune detects your app by its exact version. A device with `2.52.0` gets `2.53.0` when you
assign the new app to it.

To move devices to the new version, use the update app or [supersedence](glossary.md#supersedence).
This Intune setting says that a new app replaces or updates an older app.

| Point | Update app | Supersedence |
|---|---|---|
| Who sets it up | The toolkit, when you publish | You, in the Intune admin center |
| Devices it reaches | Only devices that already have the app | The groups that you assign the new app to |
| The old app | Stays as it is. You unassign it. | Intune updates it, or uninstalls it first. |
| Extra work | A second app and upload for each version | One setting by hand for each version |

The supersedence column is general Microsoft behavior. See
[Win32 app supersedence](https://learn.microsoft.com/intune/intune-service/apps/apps-win32-supersedence) on Microsoft
Learn.

Without supersedence, unassign the old app and its update app before you assign the new ones. Their detection rules
look for the old version, so a Required assignment could install it again.

Delete the old app only when no device needs it. Intune does not delete an app while a dependency links it to another
app (a general Microsoft fact). See
[Change the dependencies of an app in Intune](dependencies.md#change-the-dependencies-of-an-app-in-intune).

## With prior-install rules

The new version gets the rules of the highest earlier version of the same app and architecture. The console prints
a line that starts with `Carried`.

### What the new version gets

- For rules that you typed or took from an update test, the toolkit raises the highest version they cover.
- Rules from a [sibling capture](glossary.md#sibling-capture), a capture of the app's other installer
  technologies, stay as they were. Only a new sibling capture changes them.
- The new version does not get your [acknowledgements](glossary.md#acknowledgement), your recorded
  acceptance of a known risk. Give them again, for example `DATA-LOSS` for each new Notepad++ version.
- The new version does not get your [waivers](glossary.md#waiver) either. A waiver is your recorded
  exception to a check.
- If the new version lacks a rule that the earlier version has, packaging refuses the project. Declare the rule
  again, or accept the removal with `ID-PRIOR-DROPPED`.

### Prove Enforce rules again

An [Enforce](glossary.md#enforce) rule removes the other install before your package installs.
Enforce removes another install as SYSTEM. Assign the package to a pilot group first.

Every Enforce rule needs a new [proof](glossary.md#proof). That is an unattended update test of this
exact package on the [Hyper-V test VM](glossary.md#hyper-v-test-vm). The test VM is a virtual machine
(VM) that the toolkit resets for each test.

Build the new version with `-RunTest Update` while the test VM is ready. Run it in PowerShell 7 as administrator.

```powershell
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -TemplateName 'Contoso' -RunTest Update
```

Rules that you typed or took from an update test stay Enforce without a proof. Packaging refuses them until they are
proven or waived.

For a project with rules, the toolkit refuses an [interactive test](glossary.md#interactive-test) in
Windows Sandbox, also inside a build. An interactive test is a test that you watch, with pauses. Test on the test VM,
or see [Interactive or unattended](testing.md#interactive-or-unattended).

### When rules become proposals

Enforce rules from a sibling capture become [proposals](glossary.md#proposal) again without a proof.
This happens after a build without `-RunTest Update`, with a test VM that is not ready, or with a failed proof. A
proposal does nothing until you approve it, so the package does not remove that install.

Without `-RunTest Update`, the warning starts with `Captured Enforce prior-install rules are proven by an Update test`.
The menu cannot run the update test while it builds, so after a menu build these rules always become proposals.
Packaging then refuses the project until you approve and prove the rule again, or acknowledge `ID-PRIOR-DROPPED`. See
[Keep Enforce rules on the next version](prior-installs-enforce.md#keep-enforce-rules-on-the-next-version).

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `winget offers no` (error ID `W32T.InstallerVariantUnavailable`) | This version lacks the earlier technology. Skip it and package the next one. See [When a new version no longer ships it](packaging.md#when-a-new-version-no-longer-ships-it). |
| `ASSERT Requirement-PreUpdate = FAIL` | The update app would miss devices with this old install. Publish the install app and use supersedence. |
| `ASSERT OldArpGone-PostUpdate = FAIL` | The old version is still installed after the update. Often it is another installer technology. |
| `Technology switch:` | Devices with the other technology would get two installs. See [When a test reports a technology switch](packaging.md#when-a-test-reports-a-technology-switch). |
| `No winget PackageIdentifier found in:` | The app is not in winget. Use your earlier project as the old version. See [Test an update of a manual app](manual-apps.md#test-an-update-of-a-manual-app). |
| `Skipped the update app:` | The project has no sure sign that the app is installed. Publish the install app and use supersedence. |

More messages: [Troubleshooting, tests](troubleshooting.md#tests) and
[Troubleshooting, publishing](troubleshooting.md#publishing).

## Next steps

- [Change or re-create a project](projects.md)
- [Devices that already have the app](prior-installs.md)
- [Exit codes and logs](exit-codes.md)
