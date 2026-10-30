---
description: "Ship your logo, your own scripts that run at fixed moments of every install, or a shared PowerShell module, in every package of a customer."
---

# Add a logo, hook scripts or an extension module

An [org template](glossary.md#org-template) can ship files with every package of a customer: your logo,
your own scripts and a shared PowerShell module. win32-toolkit copies them into each new [project](glossary.md#project), the folder of one app version.

## When you need this

Every package runs the install on the device with [PSAppDeployToolkit (PSADT)](glossary.md#psadt), a
free tool that adds dialogs and logs to an installer. Use template files for things that every app of a customer
needs.

- Your logo in the PSADT dialogs, and as the Intune tile of apps without an icon.
- Extra steps in every install or uninstall, such as mapping a drive. You write them as [hook scripts](glossary.md#hook-script): PowerShell files that run at fixed moments.
- Shared functions for your hook scripts, in an [extension module](glossary.md#extension-module) that
  PSADT loads in every package.

For a change in one app only, change that project instead. See
[Change a project by hand](projects.md#change-a-project-by-hand). You need an org template first. If you have none,
see [Create your org template](org-templates.md).

## Turn on the files in the template

Each kind of file has a question in the template wizard. All three are off by default.

=== "Menu"

    1. In the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)), choose **Org templates** >
       **Edit a template**, then your template.
    2. Press <kbd>Enter</kbd> to keep each value until section **E: Org scripts & extension module**.
    3. At **Enable org hook scripts**, answer `y` for hook scripts.
    4. At **On hook error**, type `Fail` or `Continue`. The default is `Fail`. This question comes only after a `y`.
    5. At **Ship an org PSADT extension module**, answer `y` for an extension module.
    6. At **Ship org branding assets**, answer `y` for your logo and banner.
    7. Press <kbd>Enter</kbd> to the end. The wizard saves the template.

=== "Command line"

    Edit an existing template in the menu. To create a new template, run
    [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md) with `-NewTemplate`, and answer `y` in section E.

    ```powershell
    Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
    ```

    Use a name that no template has yet. With the name of an existing template, the wizard starts from the defaults
    and overwrites that template.

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

After section E, the wizard creates the template folder in your [base folder](glossary.md#base-folder),
where the toolkit keeps its files.

```text title="What you see"
  ✓ Prepared C:\Win32Apps\Templates\Contoso - add your files there, then re-run the pipeline.
```

It also creates `Assets\` and `Hooks\` for the files you turned on. You create the extension module folder yourself.

```text title="The template folder"
<base folder>\Templates\
    Contoso.json                     the template settings
    Contoso\                         the files of the template
        Assets\                      your logo and banner
        Hooks\                       your hook scripts
        PSAppDeployToolkit.Contoso\  your extension module
```

**Duplicate a template** copies this folder too. If you rename a template in the wizard, the wizard saves it as
a new template. The toolkit then looks for its files in a folder with the new name, so copy your files there yourself.

!!! warning "Delete removes your files"
    **Delete a template** also deletes this folder, with your scripts, module and logo. Keep a copy of your files
    somewhere else.

## Add your logo and banner

Put your images in `<base folder>\Templates\Contoso\Assets\`, with exactly these names.

| File | Where it shows |
|---|---|
| `AppIcon.png` | The logo in the PSADT dialogs. Also the Intune tile of apps without an icon of their own. |
| `Banner.Classic.png` | The banner of [Classic](glossary.md#fluent-and-classic) dialogs, the older PSADT dialog style. |

Each new project gets a copy, and its dialogs use that copy. You change no PSADT setting. The toolkit skips a file
that is not a real image, and warns you.

### Where the app icon comes from

In a project, `Assets\AppIcon.png` is both the dialog logo and the Intune tile. The toolkit uses the first of these
sources that has an icon.

1. The icon of the app in [winget](glossary.md#winget), the Windows Package Manager.
2. Your own icon, for an app that is not in winget.
3. The icon found during the [install capture](glossary.md#install-capture), the test install that
   records what the installer changes.
4. Your template logo.
5. The PSADT default logo.

The warning `No WinGet IconUrl found in YAML - keeping default PSADT icon` only means that winget has no icon. The
captured icon or your logo still replaces the default. To change the tile of one app, replace `Assets\AppIcon.png` in
its project after the last install capture. Then build the package and publish it.

## Add hook scripts

Put your scripts in `<base folder>\Templates\Contoso\Hooks\`. Use only these file names, and add only the hooks you
need. The [install tattoo](glossary.md#install-tattoo) is the registry value that tells Intune the app
is installed.

| File | Runs |
|---|---|
| `PreInstall.ps1` | Before the install, after the template's dialogs. Before the package removes a [prior install](glossary.md#prior-install): the same app from another kind of installer. |
| `PostInstall.ps1` | Right after the install, before the install tattoo is written and before the completion prompt. |
| `PreUninstall.ps1` | Before the uninstall, after the template's dialogs. |
| `PostUninstall.ps1` | Right after the uninstall, before the install tattoo is removed. |
| `PreRepair.ps1` | Before a repair, after the template's dialogs. |
| `PostRepair.ps1` | Right after a repair. |

Intune starts only installs and uninstalls, so the repair hooks run only when someone starts a repair by hand. Each
project gets a copy of your hooks in `SupportFiles\OrgHooks\`, and the package runs them on the device. A hook can use
every PSADT command and the `$adtSession` object, which holds the data of the running deployment.

### Rules for hook scripts

- Write for [Windows PowerShell 5.1](glossary.md#powershell-7-and-windows-powershell-51), because
  devices run your hooks with it. Do not use `?:`, `??`, `?.`, `&&` or `||`.
- Stop with `throw`, never with `return`. A `return` ends only the hook, and the deployment continues.
- Never assign a value to a PSADT variable such as `$envTemp`. On PSADT 4.2 this fails the deployment.

The toolkit checks each hook when it creates a project, and warns about syntax problems. With the default `Fail`, this
hook stops the install when a file is missing.

```powershell
# PostInstall.ps1: check a file the app needs
$file = 'C:\ProgramData\Contoso\settings.ini'
if (-not (Test-Path -LiteralPath $file)) {
    throw "Contoso settings file not found: $file"
}
Write-ADTLogEntry -Message 'Contoso settings file found.'
```

### When a hook fails

Your answer at **On hook error** decides what happens when a hook throws an error. With `Fail`, the deployment stops
with exit code 60001. With `Continue`, the package writes the error to its log and continues.

A post-install hook runs before the install tattoo is written. So with `Fail`, a failing post-install hook means that
Intune does not detect the app.

## Add an extension module

Use an extension module for functions that several hooks share. Create this folder and these files in your template
folder.

```text title="Extension module layout"
<base folder>\Templates\Contoso\PSAppDeployToolkit.Contoso\
    PSAppDeployToolkit.Contoso.psd1    the manifest
    PSAppDeployToolkit.Contoso.psm1    your functions
```

The folder name starts with `PSAppDeployToolkit.`. The manifest is the `.psd1` file that describes the module, and
its name is exactly the folder name. In the manifest, set `RootModule = 'PSAppDeployToolkit.Contoso.psm1'`.

The toolkit refuses a version subfolder such as `1.0.0\`, which `Save-Module` creates. It also refuses a folder with
only a `.psm1` file, because PSADT 4.2 loads the module through its manifest.

The toolkit keeps some names for its own extension module, `PSAppDeployToolkit.Win32Toolkit`:

- Your folder name must not start with `PSAppDeployToolkit.Win32Toolkit`.
- Your module must not define or export a command with `W32T` right after the dash, such as `Install-W32TApp`.

The wizard warns about these names, and packaging an app stops on them.

### Which PSADT version to declare

The toolkit builds projects with PSADT 4.1 and 4.2 side by side, so your module must work with both. If the manifest
has a `RequiredModules` entry for PSAppDeployToolkit, declare `ModuleVersion = '4.1.0'`. This is a minimum, so it fits
both versions.

```powershell
RequiredModules = @(
    @{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0' }
)
```

Never use `RequiredVersion` or `MaximumVersion`. The toolkit also refuses an entry without a version. A module made
from PSADT's own Extensions template declares the version of that template, such as 4.2.0. Change it to 4.1.0, or the
toolkit refuses the module in PSADT 4.1 projects.

The module also runs under Windows PowerShell 5.1, so the hook syntax rules apply. PSADT recommends exit codes 70000 to
79999 for errors from your module. The wizard checks an existing module folder when you answer `y`. Packaging an app
checks it again and stops on a problem.

## PSADT machine policy

If devices show dialog settings that differ from your template, look for a PSADT machine policy. It can come from Group
Policy or an Intune settings policy.

??? note "How PSADT machine policy works"
    PSADT reads `HKLM\SOFTWARE\Policies\PSAppDeployToolkit\Config` on the device. Its values replace the values of
    your template, without a warning. PSADT 4.2 also reads versioned keys, such as
    `HKLM\SOFTWARE\Policies\PSAppDeployToolkit\4.2\Config`. Put Base64 logo or banner images only in the `4.2` key,
    because PSADT 4.1 fails on them.

## Give projects the new files

Changes to an org template reach new projects only. Re-create a project to apply them.

This also applies to the files in the template folder. The next version you package gets them anyway, because it is
a new project. To [re-create](glossary.md#re-create) a project, package the same app again with the
same template.

=== "Menu"

    Choose **Package an app from winget**, then the same app and template. The menu replaces the project of the same
    version without asking.

=== "Command line"

    ```powershell
    Invoke-Win32Toolkit -Id 'Git.Git' -TemplateName 'Contoso'
    ```

    At **Do you want to overwrite it?**, answer `y`. Any other answer keeps the old project.

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

The toolkit always takes the newest version from winget. If a newer version exists, you get a new project instead. For
an app that is not in winget, see [Re-create a project](projects.md#re-create-a-project).

!!! warning "Copy your own code first"
    Re-creating a project deletes its folder. Copy your own code out first.

Then [test the project](testing.md) again, build the package and publish it.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `Org extension module '...' cannot be used` | The message says which rule the folder breaks and how to fix it. Fix the folder, then package the app again. |
| `Org extension module '...' pins PSAppDeployToolkit` or `Org extension module '...' requires PSAppDeployToolkit` | In the manifest, declare `ModuleVersion = '4.1.0'` in the `RequiredModules` entry. |
| `Org hook '...' has Windows PowerShell 5.1 syntax issue(s)` | Windows PowerShell 5.1 cannot read the hook, often because of PowerShell 7 syntax. Fix the file in `Hooks\`, then re-create the project. |
| `Template asset '...' is not a valid image - skipped.` | Replace the file in `Assets\` with a real image, then re-create the project. |
| `Org hook ... failed (continuing)` in the device log | A hook failed, and **On hook error** is `Continue`. The rest of the line shows the error. |
| Intune reports exit code 60001 after you added hooks | The package stopped on an error, for example in a hook. Read the log on the device: see [Where to find logs](exit-codes.md#where-to-find-logs). |

More messages: [Troubleshooting](troubleshooting.md#org-templates).

## Next steps

- [Create your org template](org-templates.md): every template question and its default.
- [Change or re-create a project](projects.md): change one app, or give a project the new template files.
