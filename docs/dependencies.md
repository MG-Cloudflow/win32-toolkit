---
description: "Make Intune and your tests install another app first, publish the dependency link, and change it later without a second app."
---

# Apps that need another app first

Some apps work only when another app is already on the device, for example the Visual C++ runtime. In
win32-toolkit you declare that other app as a [dependency](glossary.md#dependency): an app that
Intune installs before your app. The toolkit also installs it first in your tests, and it links the two apps in
Intune when you publish.

## When you need this

Declare a dependency when your app needs a runtime, such as Visual C++ or .NET, or your own base app.

Intune checks the dependency with its own [detection rule](glossary.md#detection-rule): the check
that tells Intune whether an app is installed. A device that already has the dependency does not install it again.

To publish the links, your account needs one extra Intune permission (see
[Publish an app with dependencies](#publish-an-app-with-dependencies)).

## Three kinds of reference

You name each dependency with a reference: a prefix, a colon and a value. Always write the prefix. Without it, the
toolkit guesses the kind from the value.

| Reference | Use it for | Installed in tests? | Found in Intune by |
|---|---|---|---|
| `winget:<winget ID>`, for example `winget:Microsoft.VCRedist.2015+.x64` | A public runtime or tool in [winget](glossary.md#winget), the Microsoft command-line app store | Yes, the newest version | An app that the toolkit published from winget with this winget ID |
| `project:<template>\<project>`, for example `project:Contoso\Contoso_Reader_x64_3.2.0` | Your own app: another [project](glossary.md#project) that you packaged with the toolkit | Yes | The app this PC published from that project, else an app with exactly its name |
| `intune:<app ID>` | An app that exists only in Intune | No | The app ID itself |

In a `project:` reference, write the Template and Application names that the menu
([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) shows in **Browse projects**, with a backslash between them.
Never write a full path. An [app ID](glossary.md#app-id) is the code that Intune gives every app.
Copy it from the Intune admin center.

## Add a dependency when you create the app

=== "Menu"

    1. In the main menu, choose **Package an app from winget** or **Package a manual app**.
    2. Answer the questions of the wizard until it asks about another app.
    3. At **Does this app need another app installed FIRST**, answer `y`. (The default is No.)
    4. Choose a source (see below). Repeat this for each dependency.
    5. Choose **Done**.

    - **Add a dependency from winget**: search by name, for example `VCRedist`.
    - **Add a dependency from an already-packaged project**: choose one of your other projects.
    - **Pick an app already published in Intune**: sign in and choose the app. It cannot be installed in tests.

=== "Command line"

    Add `-DependsOn` to [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md) or to
    [`New-Win32ToolkitManualApp`](reference/New-Win32ToolkitManualApp.md). For several references, put each one in
    quotes and separate them with commas.

    ```powershell
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'
    ```

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

The toolkit checks every reference before it downloads or creates anything. A wrong reference stops the command.
The toolkit saves the list in the project, in `SupportFiles\AppConfig.json`.

## Change the dependencies of a project

Changing the list changes only the project, not Intune.

=== "Menu"

    1. In the main menu, choose **Work with an existing project** and choose your project.
    2. Choose **Dependencies**.
        <!-- SCREENSHOT: the TUI project actions menu showing the Dependencies action -->
    3. Add or remove dependencies. You get the same sources, plus **Remove a dependency**.
    4. Choose **Done**. The **Done** panel starts with `Dependencies saved:`.

    Ignore the panel's advice to "re-publish". See
    [Change the dependencies of an app in Intune](#change-the-dependencies-of-an-app-in-intune).

=== "Command line"

    [`Set-Win32ToolkitAppDependency`](reference/Set-Win32ToolkitAppDependency.md) adds references to the list
    that the project already has.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Set-Win32ToolkitAppDependency -ProjectPath $project -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'
    ```

    - `-Clear` with references replaces the whole list.
    - `-Clear` alone removes all dependencies.
    - There is no option to remove only one. Use `-Clear` and give the references you want to keep.

    For every option, see [Set-Win32ToolkitAppDependency](reference/Set-Win32ToolkitAppDependency.md).

After a change, run the [install capture](glossary.md#install-capture) again: the test install
that records what your app changes. It must run with the new list. See
[Run the install capture again](projects.md#run-the-install-capture-again).

## Install it first or only check for it

The type of a dependency tells Intune what to do when the device does not have it.

| Type | What Intune does |
|---|---|
| `autoInstall` (the default) | Installs the dependency first, then your app. |
| `detect` | Only checks for the dependency. If it is missing, Intune does not install your app at all. |

`detect` is rarely the right choice, and the menu never offers it. Set it on the command line with
`-DependencyType`:

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Set-Win32ToolkitAppDependency -ProjectPath $project -DependsOn 'winget:Microsoft.VCRedist.2015+.x64' -DependencyType detect
```

The type applies to every reference in the command. For mixed types, run the command once per type.

!!! warning "The menu resets the type"
    When you save in the **Dependencies** action of the menu, every dependency becomes `autoInstall` again. Set
    `detect` again on the command line afterwards.

## Dependencies in tests

### What the test machine installs

The [test machine](glossary.md#test-machine) is Windows Sandbox or the Hyper-V test VM. In the
install capture and in every test, the toolkit installs your dependencies there first, in the order you declared.
The toolkit installs them before it records the "before" state, so they are never part of your app's capture results.

- `winget:` gets the newest version in winget. It may differ from the build on devices.
- `project:` installs the app from a copy of that project.
- `intune:` cannot be installed in a test. The message starts with `Dependency 'intune:...' is an app id in the
  tenant`. If your app needs it during tests, use `winget:` or `project:`.
- The toolkit does not follow chains of dependencies in tests. If app A needs B and B needs C, declare C and then B
  on A.

The toolkit reuses a dependency download for up to 6 hours while the list stays the same. It does this only when
the setting `PipelineCache` is `On` (the default, see [General settings](settings.md#general)). Dependency installers
never go into your package.

### When a dependency fails

Every installer ends with an [exit code](glossary.md#exit-code): a number that says how the install
went. A dependency install succeeds with exit code 0, 1707, 3010 or 1641. Any other code stops the dependency step.

If a dependency install runs longer than 25 minutes, the toolkit stops it. The exit code is then 1460.

- **In a test**, your app is not installed, because Intune would not install it either. The result is **Failed**,
  with the check `DependenciesInstalled = FAIL (exit <code>)`.
- **In the install capture**, the toolkit warns with `The declared dependencies in the capture run failed`. It
  takes no uninstall or other data from that capture. Fix the dependency and run the capture again before you
  publish.
- **If a dependency cannot be staged** (prepared for the test machine), the test or capture does not start. A
  failed winget download is one cause. The whole run stops: nothing is tested, packaged or published.

## Publish an app with dependencies

Package and publish the dependency first, as its own app (see [Package an app from winget](packaging.md)). Then
publish your app. Intune can only link to an app that already exists in your tenant.

Before the upload, the toolkit looks up each dependency in your tenant, as the table in
[Three kinds of reference](#three-kinds-of-reference) shows. Any version counts.

A `winget:` reference never finds an app that the toolkit did not publish from winget, such as an app you added by
hand. Use `intune:<app ID>` for such an app.

If a dependency is not found, or several apps match, you get a warning. Your app still publishes without that
link. The toolkit never publishes the dependency for you.

After the upload, the toolkit links the dependencies to the [install app](glossary.md#install-app),
the app for new installs. The [update app](glossary.md#update-app) is the optional second app for
devices with an older version. It never gets links, and a `winget:` or `project:` reference never finds it.

Your account needs the **Relate** permission in the **Mobile apps** category of its Intune role. Without it, Intune
refuses the links with a 403 error after the upload. The publish then ends with an error, but your app is in Intune
without its dependencies. Get the permission, then run
[`Sync-Win32ToolkitAppDependency`](reference/Sync-Win32ToolkitAppDependency.md) as shown in the next section.

## Change the dependencies of an app in Intune

!!! warning "Never publish again for this"
    Every publish creates a new app in Intune. Publishing again does not change the old app. Your users would keep
    the app without the links. Ignore the menu hint that says "re-publish".

The menu has no action for this. Use the command line.

1. Change the list of the project, as shown in [Change the dependencies of a project](#change-the-dependencies-of-a-project).
2. Run `Sync-Win32ToolkitAppDependency` (Sync, for short) on the same project.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Sync-Win32ToolkitAppDependency -ProjectPath $project
```

Sync signs you in, checks the tenant and shows the app as `Target app:`. Then it replaces the dependencies of that
app with the list of the project. It keeps any [supersedence](glossary.md#supersedence): the Intune
setting that says one app replaces another.

```text title="What you see"
✓ Attached 1 dependency(ies): winget:Microsoft.VCRedist.2015+.x64
```

- Sync changes the app that this PC published from the project. If there are two, it changes the newest one.
- Add `-AppId` with the app ID if you published from another PC or want an older copy. You also need it after you
  re-create the project of an app that is not in winget.
- Sync uses only the dependencies it can find now. For every other dependency, it warns and removes the link from
  the app, if there is one. Fix the cause and run Sync again.
- With `-WhatIf`, Sync still signs in and looks up the dependencies, but it changes nothing.

## Remove all dependencies

Clear the list of the project, then run Sync.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Set-Win32ToolkitAppDependency -ProjectPath $project -Clear
Sync-Win32ToolkitAppDependency -ProjectPath $project
```

The console then shows `✓ App now has no dependencies (existing supersedence was preserved).`

Do this before you delete either app in Intune. Intune does not let you delete an app while a dependency link
connects it to another app. When a device uninstalls your app, the dependency stays on the device. Other apps may
still need it.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `Dependency reference '...' has no value` | Write a value after the prefix. |
| `Dependency '...' could not be staged` | Fix the reason that the message names, or remove the dependency with `-Clear`. |
| `Dependency '...' is NOT published in this Intune tenant` | Publish the dependency, then run `Sync-Win32ToolkitAppDependency` on your project. |
| `Dependency '...' matched ... refusing to guess` | Declare the right app as `intune:<app ID>`. |
| `Intune refused the relationship write (403)` | Your app is in Intune. Get the **Relate** permission, then run `Sync-Win32ToolkitAppDependency`. |
| `This project has no recorded Intune publication` | Publish the project first, or run Sync with `-AppId`. |

For more messages, see [Troubleshooting](troubleshooting.md#dependencies).

## Next steps

- [Test the package](testing.md)
- [Publish to Intune](publishing.md)
