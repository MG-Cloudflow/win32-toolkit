---
description: "Upload the package to Intune as a new Win32 app, check what was created, and finish in the Intune admin center."
---

# Publish to Intune

In this step, win32-toolkit uploads your [package](glossary.md#package), the `.intunewin` file, to
Microsoft Intune. Intune then has a new [Win32 app](glossary.md#win32-app), the Intune app type for
classic Windows programs.

Every publish creates a new app in Intune. Publishing again does not change the old app. win32-toolkit never assigns an
app. You assign it in the Intune admin center.

## Before you start

Step 7 of 7.

- You have a [project](glossary.md#project): the folder of one app version. This page uses the project
  `Git_x64_2.53.0` of the [org template](glossary.md#org-template) `Contoso`. An org template holds your
  settings for one customer. Your version will differ.
- You tested the package in [step 4](testing.md) and read the result. You built it in [step 5](build-intunewin.md).
- You connected to your [tenant](glossary.md#tenant), the space of your organization in Intune, in
  [step 6](intune-connection.md). Your account has the rights in
  [What your account needs](intune-connection.md#what-your-account-needs).
- Time: usually a few minutes, longer for big packages.

## Publish your app

You publish the [install app](glossary.md#install-app): the normal app that you assign to devices.

=== "Menu"

    Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)). The menu builds the package again before
    the upload, so the package always matches the project.

    1. In the main menu, choose **Work with an existing project**.
    2. At **Select a project**, choose `Contoso / Git_x64_2.53.0`. You can type a few letters to filter the list.
    3. Choose **Publish to Intune**.
    4. Read the yellow **About to PUBLISH to Intune** panel. Check the application, the version and the publisher.
    5. If a warnings panel appears, read every line.
    6. At **Publish which app?**, choose **Install app**.
        <!-- SCREENSHOT: The Publish which app? choice for Git_x64_2.53.0, with Install app highlighted -->
    7. At **Package and upload now?**, type `y` and press <kbd>Enter</kbd>. (The default is No.)
    8. If a browser window opens, sign in with your Intune account.
    9. Wait for the green **Done** panel, then press any key.

    The red **Review before you publish** panel shows serious warnings, for example a failed test. The yellow
    **Check before you publish** panel shows other warnings. If a red line says `Packaging refuses this project`, the
    publish stops. Do what the line says, then publish again.

    Two other choices at **Publish which app?** publish an [update app](glossary.md#update-app), a
    second app for devices that already have the app. See
    [Install app, update app, or both](new-version.md#install-app-update-app-or-both).

=== "Command line"

    [`Export-Win32ToolkitIntuneWin`](reference/Export-Win32ToolkitIntuneWin.md) builds the package again and
    publishes the install app. So the package always matches the project.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune
    ```

    To publish a package that you built earlier, use
    [`Publish-Win32ToolkitIntuneApp`](reference/Publish-Win32ToolkitIntuneApp.md) with both paths. `-ProjectPath` is
    the project under `Projects\`, never the copy under `Staging\`. The command does not check that the package was
    built from this project.

    ```powershell
    $package = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $package -ProjectPath $project
    ```

    Without `-PublishIntune`, `Export-Win32ToolkitIntuneWin` asks `Upload to Microsoft Intune now? (Y/N)`. The answer
    `Y` publishes the install app.

    For every option, see [Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md) and
    [Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md).

## What you see during the upload

In the menu, the messages of the package build come first.

```text title="What you see"
Intune App Upload
=================
  App name     : Git
  Publisher    : The Git Development Community
  Architecture : x64
  Tenant       : Contoso (11111111-2222-3333-4444-555555555555)
  ✓ Unencrypted : <size> MB
  ✓ Encrypted  : <size> MB
  Icon         : Assets\AppIcon.png (<size> KB)
  ✓ App created: <app ID>
...
  ✓ Upload complete.
  ✓ Commit successful.

✓ App published successfully!
  App ID : <app ID>
  Name   : Git

  View in Intune portal:
  https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/<app ID>
```

Read the `Tenant` line. It names the tenant that gets the app.

A project can carry the tenant ID of its org template. Then the toolkit refuses any other tenant before it creates the
app. Without a tenant ID, it only warns. See
[Pin the tenant on your org template](intune-connection.md#pin-the-tenant-on-your-org-template).

A [prior-install rule](glossary.md#prior-install-rule) tells the package what to do with another
install of the app on a device. A package with such rules shows more warnings. See
[Build and publish a project with rules](prior-installs.md#build-and-publish-a-project-with-rules).

## Try it first with a dry run

A [dry run](glossary.md#dry-run) runs the same checks as a real publish up to the sign-in, then stops. It
shows the same warnings. It also refuses what a real publish refuses before sign-in, for example an app that Intune
could not detect. It does not sign in, and it writes nothing to Intune.

The menu has no dry run. Use [`Publish-Win32ToolkitIntuneApp`](reference/Publish-Win32ToolkitIntuneApp.md) with
`-WhatIf`. The package file must exist already.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
$package = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
Publish-Win32ToolkitIntuneApp -IntuneWinPath $package -ProjectPath $project -WhatIf
```

```text title="What you see at the end"
...
What if: Performing the operation "Publish Win32 app to Intune (version 2.53.0)" on target "Git".
WhatIf: would connect to Microsoft Graph and publish 'Git' v2.53.0 to Intune (create app shell, upload content, commit).
```

`Export-Win32ToolkitIntuneWin -PublishIntune -WhatIf` checks less. It does not run the checks of the publish. For the
publish, it only prints a line that starts with `WhatIf: would publish to Intune after packaging`.

## What the app looks like in Intune

The table shows the fields of the new app. [Return codes](glossary.md#return-code) tell Intune what each exit code of the install means. A [detection rule](glossary.md#detection-rule) tells Intune how to check that the app is on a device. [Supersedence](glossary.md#supersedence) is the Intune setting that says a new app replaces an older app.

| Field in Intune | Value | Where it comes from |
|---|---|---|
| Name | The app name, for example `Git` | The project or the winget manifest |
| Publisher | The vendor, or `Unknown` | The project or the winget manifest |
| App version | The packaged version, for example `2.53.0` | The project or the winget manifest |
| Description | The app description, then the standard text of your org template | The project, the winget manifest and the org template |
| Information URL | The web page of the app | The project or the winget manifest |
| Privacy URL | Your privacy page, or empty | The org template |
| Notes | `win32-toolkit; Git.Git` | The toolkit |
| Install and uninstall commands | `Invoke-AppDeployToolkit.exe` with `-DeploymentType Install` or `-DeploymentType Uninstall` | Always the same |
| Install behavior | System | Always the same |
| Device restart behavior | No specific action (`suppress`) by default | The org template |
| Maximum run time | 60 minutes by default | The org template |
| Architecture | x86, x64 or arm64 | The project |
| Minimum operating system | Windows 10 1607 by default. MSIX and APPX packages get at least 1809. | The org template |
| Return codes | 0 and 1707 Success, 3010 Soft reboot, 1641 Hard reboot, 1618 Retry. 69101, 69102 and 69105 to 69112 Failed. | The toolkit |
| Detection rule | One rule | See [How Intune detects the app](#how-intune-detects-the-app) |
| Logo | `Assets\AppIcon.png` of the project, else the generic Intune tile | See [Where the app icon comes from](org-template-files.md#where-the-app-icon-comes-from) |
| Assignments, supersedence, categories, scope tags | None | You set them in the Intune admin center |

<!-- SCREENSHOT: the published app in the Intune portal showing tile icon, detection rule, and shell defaults -->

The toolkit copies the org template values into the project when you create it. Changes to an org template reach new
projects only. Re-create a project to apply them.

Every app gets the prior-install codes, even without prior-install rules. See
[Prior-install codes](exit-codes.md#prior-install-codes).

Keep the maximum run time above 30 minutes. The uninstall stops an EXE uninstaller after 30 minutes. With a limit of
30 minutes or less, Intune stops first and reports a timeout instead. The publish warns you about it.

## How Intune detects the app

The toolkit adds exactly one detection rule. It uses the first source that works:

1. The [install tattoo](glossary.md#install-tattoo): a registry value that the package writes when it
   installs. The rule checks the value `Version` under
   `HKEY_LOCAL_MACHINE\SOFTWARE\<app script author>\<publisher>\<app name>`, so Intune sees the exact version.
2. The newest [install capture](glossary.md#install-capture), the record of what the installer changed
   on a clean copy of Windows. The rule checks that one registry key or one file exists. It does not check the version.
3. None. The publish stops with `No detection rule for`. Nothing is published.

The install tattoo is the normal case. It needs an org template. The org template gives the [app script author](glossary.md#app-script-author), the name at the start of the key.

!!! warning "Capture again after a failed install"

    A detection rule from the install capture uses the newest capture, even when that install failed. After a failed
    capture, run the install capture again before you publish. In the menu, choose **Finalize / refresh**. See
    [Run the install capture again](projects.md#run-the-install-capture-again).

### Apps that cannot be detected automatically

Some apps leave nothing that the toolkit can use for a rule, for example per-user apps and some MSIX packages. First
try a better fix: re-create the project with an org template, or run the install capture.

If that does not help, publish the app without a detection rule. Only `Publish-Win32ToolkitIntuneApp` can do this.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
$package = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
Publish-Win32ToolkitIntuneApp -IntuneWinPath $package -ProjectPath $project -AllowNoDetectionRule
```

The warning starts with `No detection rule could be built`. Add a detection rule in the Intune admin center before you
assign the app. Without a rule, the app fails on every device, or it installs again and again.

## Why the install command is Invoke-AppDeployToolkit.exe

Every app gets the same two commands. Intune runs them through the [Intune Management Extension](glossary.md#intune-management-extension), the Intune agent on the device.

```text title="Install and uninstall commands"
Invoke-AppDeployToolkit.exe -DeploymentType Install
Invoke-AppDeployToolkit.exe -DeploymentType Uninstall
```

Never change them to `powershell.exe`. Never add `-DeployMode` either. [PSAppDeployToolkit (PSADT)](glossary.md#psadt), the free PowerShell tool in every package, chooses by itself when to show dialogs.
With `-DeployMode Interactive` and nobody signed in, PSADT stops with exit code 1602.

??? note "Why?"

    The Intune Management Extension is a 32-bit program. If it starts `powershell.exe`, a 64-bit device runs the
    32-bit Windows PowerShell. There, PSADT 4.2 refuses to run (exit code 60008), and PSADT 4.1 writes the install
    tattoo where the detection rule never looks. `Invoke-AppDeployToolkit.exe` is part of every package and always
    starts the 64-bit Windows PowerShell.

Apps published by win32-toolkit 1.1.6 or older use `powershell.exe` until you fix them. See
[Fix apps that are already in Intune](maintain-toolkit.md#fix-apps-that-are-already-in-intune).

## Finish in the Intune admin center

The toolkit stops after the upload. A [pilot group](glossary.md#pilot-group) is a small group of test devices or users that gets a new app first.

1. Open the link that the toolkit printed under `View in Intune portal:`.
2. Check the detection rule, the return codes, the maximum run time and the icon.
3. If you published without a detection rule, add one now.
4. Assign the app to a pilot group.
5. Watch the results on the pilot devices.
6. Assign the app to all devices or users that need it.
7. If the app replaces an older app, set supersedence or retire the old app. See
   [Replace the old app in Intune](new-version.md#replace-the-old-app-in-intune).

Remediation or inventory scripts that read the registry values of the toolkit must run in 64-bit PowerShell. A 32-bit
script reads another part of the registry.

## Give your customer a one-page summary

A [customer document](glossary.md#customer-document) is a one-page summary of the app, for a customer or
for change control. The toolkit writes it to `Documentation.md` in the project folder.

=== "Menu"

    1. In the main menu, choose **Work with an existing project**.
    2. At **Select a project**, choose `Contoso / Git_x64_2.53.0`.
    3. Choose **Generate customer documentation**.
    4. At **Include the Intune app id + portal link?**, press <kbd>Enter</kbd>. (The default is No.)
    5. Read the path of the file in the green **Done** panel.

    Answer `y` at step 4 only when the customer owns the tenant.

=== "Command line"

    [`Export-Win32ToolkitDocumentation`](reference/Export-Win32ToolkitDocumentation.md) writes the document.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Export-Win32ToolkitDocumentation -ProjectPath $project
    ```

    Add `-IncludeIntuneIds` only when the customer owns the tenant. It adds the Intune app ID and a link to the app.
    For every option, see [Export-Win32ToolkitDocumentation](reference/Export-Win32ToolkitDocumentation.md).

The customer document describes the app, the install and uninstall commands and how Intune detects the app. It counts
the files, registry keys and services that the app installs. It also lists the tests that ran and how to uninstall the
app. It ends with the footer of your org template, if it has one.

By default, the document has no tenant ID and no Intune app ID. It never goes into the package. It takes seconds and
needs no network.

## Next time do it all in one run

For an app you know well, you can build, test, package and publish in one run.

=== "Menu"

    In **Package an app from winget** or **Package a manual app**, the wizard asks **After building, also…**. Tick
    the test, **Package to .intunewin** and **Publish to Intune** with <kbd>Space</kbd>, then press <kbd>Enter</kbd>.

    After you confirm the build, the wizard asks **Publishing UPLOADS to your Intune tenant**. Type `y` and press
    <kbd>Enter</kbd>. (The default is No.) The wizards publish the install app only.

=== "Command line"

    [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md) builds, tests, packages and publishes Git in one run.

    ```powershell
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso' -RunTest InstallUninstall -PublishIntune
    ```

    `-PublishIntune` also builds the package. [`New-Win32ToolkitManualApp`](reference/New-Win32ToolkitManualApp.md)
    and [`Complete-Win32ToolkitManualApp`](reference/Complete-Win32ToolkitManualApp.md) have the same switch. For
    every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

!!! warning "A failed test does not stop this"

    A failed test only warns. It does not stop packaging or publishing. The run prints
    `The InstallUninstall test FAILED its assertions` and then publishes. For production apps, test first, read the
    result, then publish in a separate step.

## If the publish fails

Where the publish stopped decides what you do.

- **Before** `✓ App created`: nothing was written to Intune. Fix the cause and publish again.
- **After** `✓ App created`: an incomplete app stays in Intune. The toolkit does not remove it. Delete it in the Intune
  admin center, fix the cause, then publish again.

One case is different. If the message says `Intune refused the relationship write` or `Failed to attach dependencies`,
the app is complete but has no dependency. Do not publish again. See
[Publish an app with dependencies](dependencies.md#publish-an-app-with-dependencies).

The toolkit writes `Intune\Publications.json` only after a successful upload. So a failed publish leaves no record.

**The upload timed out.** The toolkit waits up to 300 seconds for each of two Intune steps, then stops with
`Timed out after`. Delete the incomplete app. Then publish again with a longer wait.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune -PublishTimeoutSeconds 900
```

`Publish-Win32ToolkitIntuneApp` has `-TimeoutSeconds` instead. The menu and `Invoke-Win32Toolkit` cannot change the
wait.

**A Graph API error with 403.** [Microsoft Graph](glossary.md#microsoft-graph) is the Microsoft web
service that the toolkit talks to. A 403 usually means that your Intune role is missing a permission. Ask your Intune
administrator to check your role.

## What you have now

- One new Win32 app in Intune, in the tenant of the `Tenant` line. It is not assigned.
- The file `Intune\Publications.json` in the project folder. It keeps the app ID for each tenant and never goes into a
  package.
- The package in `IntuneWin\Contoso` under your [base folder](glossary.md#base-folder), the main
  folder of the toolkit.
- Your earlier apps in Intune, unchanged.

## If something goes wrong

Some messages start with `Publish-Win32ToolkitIntuneApp failed:` or `Export-Win32ToolkitIntuneWin failed:`. Read the
text after it.

| Message starts with | What to do |
|---|---|
| `REFUSING publish: this project is pinned to tenant` | Nothing was created. Connect to the pinned tenant as in [Connect](intune-connection.md#connect), then publish again. |
| `'<project>' is marked not configured and cannot be` | The build of the project stopped halfway. Package the app again. This replaces the folder. |
| `No detection rule for` | See [How Intune detects the app](#how-intune-detects-the-app). |
| `Prior install: the prior-install rules changed after Export` | Build the package again, then publish the new file. |
| `Graph API error` | Read the error that follows. See [If the publish fails](#if-the-publish-fails). |
| `Timed out after` | Delete the incomplete app, then publish again with a longer wait. See [If the publish fails](#if-the-publish-fails). |

More messages and fixes are in [Troubleshooting: Publishing](troubleshooting.md#publishing).

## Next step

You finished the journey. For apps that are not in winget, dependencies and devices that already have the app, see the
**Special cases** tab. The next page shows how to ship a new version.

[Next: ship a new version](new-version.md){ .md-button .md-button--primary }
