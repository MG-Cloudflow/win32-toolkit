---
description: "Create and apply org templates to brand every packaged app consistently across your Intune Win32 deployments."
---

# Org templates

An **org template** captures everything that should be the same across every app you package for a
customer: branding, PSADT dialog behaviour, deploy-time scripts, Intune publish defaults, and more.
Every project you build gets the template applied automatically, so all of a customer's apps look
and behave consistently with no per-app work.

A template is two things on disk:

| Part | Path under BasePath | Holds |
|---|---|---|
| Definition | `Templates\<name>.json` | All the settings (created/edited by the wizard) |
| Sidecar folder *(optional)* | `Templates\<name>\` | Files the template ships: `Hooks\`, `Assets\`, `PSAppDeployToolkit.<Org>\` |

Templates also **group your output**. The template name (sanitized) becomes a folder segment in
every tier, so work for different customers stays separated:

| Tier | Path under BasePath |
|---|---|
| Projects | `Projects\<Template>\<App>` |
| Staging | `Staging\<Template>\<App>` |
| IntuneWin | `IntuneWin\<Template>\<App>.intunewin` |

## Creating a template

To create a template without packaging anything:

```powershell
Invoke-Win32Toolkit -NewTemplate
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

This opens the wizard, saves the JSON, and exits. If you never create one, the toolkit prompts you
the first time you run the pipeline. You cannot package without a template.

To **edit** an existing template, use the TUI (`Show-Win32Toolkit` → Org templates → Edit): the
wizard is pre-filled with the current values, so Enter keeps each one, and typing `-` clears an
optional value (the prompts that offer it say so). `Invoke-Win32Toolkit -NewTemplate` with the name
of an existing template starts from the built-in defaults instead and overwrites the saved file.

<!-- SCREENSHOT: the wizard running in a terminal, showing the Identity and Branding sections with bracketed defaults -->

## The wizard, section by section

Every prompt shows a default in brackets. Press **Enter** to accept it.

| Section | Field | What it controls |
|---|---|---|
| Identity | Template name / Company name / App script author | File+folder name, dialog subtitle, deploy-script author |
| | **Intune tenant** | Pins this customer's tenant. Publishing then **refuses** to write to any other one. See [Connecting to Intune](intune-connection.md) |
| Branding & dialog style | **Dialog style** | `Fluent` (modern) or `Classic` (v3-style, uses the Classic banner) |
| | Fluent accent hex | Accent colour, e.g. `0xFF0078D7` (blank = PSADT default) |
| | Log path | Where deploy scripts write logs (default `$envWinDir\Logs\Software`). Only the variables `$envName` (PSADT), `$env:Name` and `${env:Name}` are allowed |
| | **Force dialog language** | Pin all dialogs to one language, e.g. `nl`, `fr-FR` (blank = auto-detect). Must be a language name |
| Progress / Balloon | per-deployment-type text | Progress-dialog wording, and the completion balloon (shown only with the **Classic** dialog style, on PSADT 4.1 and 4.2) |
| Welcome / Uninstall / Progress / Completion dialogs | enable, deferral, countdown (0 to 86400 s), persist, block, messages | PSADT dialog behaviour per phase (see [when dialogs appear](#when-dialogs-appear)) |
| Org scripts & extension module | **Enable org hook scripts** + on-error policy | Runs your `.ps1` files in each deploy phase (see below) |
| | **Ship an org PSADT extension module** | Copies `PSAppDeployToolkit.<Org>\` into every project |
| | **Ship org branding assets** | Copies your logo/banner into every project |
| Intune publish defaults | **Minimum Windows release / restart behavior / max run time** | The Intune install experience |
| | **Description boilerplate / privacy URL** | Appended to every published app |
| | **Customer-doc footer line** | Footer on the generated customer documentation |

The wizard also records the schema version and, for information only, the PSADT version new projects
would use when the template was saved (you are not prompted for these). Each project's real PSADT
version is the one bundled in the project.

Text the wizard cannot accept (see [Text rules](#text-rules)) is explained and asked again.

## When dialogs appear

The Intune command line passes no deploy mode, so PSADT runs in **Auto** mode: the welcome
(close apps, deferral), progress and completion dialogs appear only when the user has to close one of
the app's processes. When none of them is running, the deployment runs silently on PSADT 4.1 and 4.2
alike. One difference: an app with an **empty** processes-to-close list runs silently on PSADT 4.2,
where 4.1 still showed the dialogs. The dialog *policy* (what is shown when a dialog does appear) is
stored as data in each project's `SupportFiles\AppConfig.json` and read on the device.

A deferral ends the deployment with exit code 1602, which Intune reports as failed (see
[Publishing](publishing.md#what-gets-created)).

## Text rules

PSADT expands the company name, the log path and the language as PowerShell strings when a
deployment starts, and PSADT 4.2 also expands the dialog texts (progress, balloon, completion) every
time a dialog command runs, even in a silent deployment. Text that looks like a variable or an expression would
then fail every deployment built from the template (exit code 60001 or 60008). So the toolkit
**rejects** such text instead of trying to escape it:

| Rule | Applies to | Rejected |
|---|---|---|
| Dollar | Company name and every dialog text | a `$` followed by a letter, digit, `_`, `{`, `(`, `:`, `?`, `$` or `^` (`$$` and `$^` silently become empty text) (`US$ 5` and a trailing `$` are fine) |
| Backtick | the same fields and the log path | any backtick |
| Whitespace | company name and every dialog text | a value made of spaces only (leave the field empty instead) |
| Log path | log path | any `$` that is not part of `$envName`, `$env:Name` or `${env:Name}` |
| Countdown | the two close-apps countdowns | anything but a whole number from 0 (off) to 86400 seconds |
| Language | dialog language | anything but a language name such as `nl`, `fr-FR` or `zh-Hans` (blank = auto-detect) |

The wizard checks each answer as you type it. A template saved by an older toolkit version, or
edited by hand, is checked every time it is loaded: if it breaks a rule, packaging stops with a
`W32T.OrgTemplateInvalid` error that lists every problem and how to fix it (edit the template in
the TUI). Signing in with `Connect-Win32ToolkitIntune -Template` is not blocked by it.

## Branding: dialog style, language, logos

- **Dialog style**: `Fluent` is the modern v4 look; `Classic` renders the older v3-style dialogs and
  uses `Banner.Classic.png`. Some estates (kiosks, servers) prefer Classic.
- **Language**: leave the language override blank and PSADT shows dialogs in the signed-in user's
  language (this works correctly even though the package runs as SYSTEM). Set it (e.g. `nl`) to pin
  every dialog to one of PSADT's 27 shipped languages.
- **Logos & banner**: enable *Ship org branding assets*, then drop files in
  `Templates\<name>\Assets\`:
  - `AppIcon.png` brands PSADT dialogs/toasts **and** becomes the Intune tile when the app has no
    icon of its own (see precedence below).
  - `Banner.Classic.png` is the banner shown by Classic dialogs.

  You don't touch any config: the project's `Config\config.psd1` always points the dialog logo and
  banner at the project's `Assets\AppIcon.png` and `Assets\Banner.Classic.png` (on PSADT 4.2 the
  built-in defaults are embedded images, so the files alone would not be used). The same
  `AppIcon.png` serves light and dark mode.

### App-icon precedence

`AppIcon.png` serves both the on-device dialogs and the Intune tile. The toolkit picks the best
available source, in this order:

1. **winget** icon (downloaded from the package's manifest)
2. **manual** icon (a `-IconPath` you passed for a manual app)
3. **captured** icon (extracted from the app during the sandbox install run)
4. **org template** logo (your `Assets\AppIcon.png`), the fallback
5. PSADT's default logo (only if you ship none of the above)

So your org logo is the floor: every app-specific icon wins over it, but when an app has no icon of
its own, the tile shows **your** logo instead of the generic PSADT one.

## Org hook scripts

Enable *org hook scripts* and drop any of these in `Templates\<name>\Hooks\`:

```
PreInstall.ps1   PostInstall.ps1
PreUninstall.ps1 PostUninstall.ps1
PreRepair.ps1    PostRepair.ps1
```

Each file runs in the matching PSADT deploy phase of **every** app built from the template: map a
drive, drop a shortcut, remove a legacy agent, write a tattoo key, once per customer instead of
per app. Inside a hook you have the full `$adtSession` and every PSADT function available.

Where a hook runs inside its phase (the same on PSADT 4.1 and 4.2):

| Hook | Runs |
|---|---|
| `PreInstall.ps1`, `PreUninstall.ps1`, `PreRepair.ps1` | **last** in the phase, after the org welcome and progress dialogs |
| `PostInstall.ps1`, `PostUninstall.ps1`, `PostRepair.ps1` | **first** in the phase, before the detection tattoo is written (or removed) and before the completion prompt |

Important:

- **They run on the device under Windows PowerShell 5.1** (Intune runs PSADT there). Keep them
  5.1-safe: no `?:` ternary, `??`, `?.`, or `&&`/`||`. The toolkit parse-checks each hook under real
  5.1 when applying the template and warns about PS7-only syntax.
- **Hooks are dot-sourced** into the phase. To fail, `throw`; never `return` (a `return` only ends
  the hook early and the deployment carries on as if it succeeded). Never assign PSADT's own variable
  names (`$Culture`, `$envTemp`, ...): they are read-only on PSADT 4.2 and the deployment fails.
- **On error** you choose `Fail` (a throwing hook fails the deployment; this is the default, and the
  safe choice for a setup step that must succeed) or `Continue` (log and carry on).
- Because a post-install hook runs **before** the detection tattoo is written, a failing hook
  correctly prevents the app being detected as installed.

Your scripts are **copied** into the package (`SupportFiles\OrgHooks\`) and dot-sourced at runtime.
Their contents are never spliced into generated code: the deploy script only gets a small, fixed
block per phase that calls the file. Removing a hook file and building again removes its block. If
the toolkit cannot place a hook block, building the project fails rather than shipping a package
whose hook silently never runs.

## Org PSADT extension module

For functions shared across your hooks (or manual deploy-script edits), enable the extension module
and place a module folder at `Templates\<name>\PSAppDeployToolkit.<YourOrg>\`. It's copied into every
project's root, where PSADT v4 auto-imports it, so `Set-ContosoTattoo`, `Remove-ContosoLegacyAgent`,
etc. are available everywhere. Use exit codes in the 70000-79999 range per PSADT guidance. The module
runs on-device as 5.1 too, so the same syntax rule applies (the toolkit parse-checks it).

The folder must have this layout, because PSADT 4.2 imports the extension through its manifest:

```
Templates\Contoso\PSAppDeployToolkit.Contoso\
    PSAppDeployToolkit.Contoso.psd1    manifest, named exactly like the folder
    PSAppDeployToolkit.Contoso.psm1    the manifest's RootModule, in the same folder
```

A `.psm1`-only folder, or a `Save-Module` layout with a version subfolder (`1.0.0\`), fails every
deployment on PSADT 4.2 (exit code 60001). The toolkit therefore checks the layout: the wizard warns
when you enable the module, and applying the template **stops** with a `W32T.OrgExtensionInvalid`
error that names the fix. If the manifest declares `RequiredModules` for `PSAppDeployToolkit`, the
PSADT bundled in each project must satisfy it, and win32-toolkit builds 4.1.x and 4.2.x projects side
by side. So declare a minimum of `ModuleVersion = '4.1.0'` or leave the version out. Don't use
`RequiredVersion` (an exact pin) or `MaximumVersion` (an upper bound): they fail every deployment of a
project that bundles a different PSADT version. Applying the template stops with
`W32T.OrgExtensionInvalid`, before it changes the project, when the bundled PSADT does not satisfy the
entry or when the entry is not valid for Windows PowerShell 5.1 (for example a prerelease version such
as `4.2.0-rc2`).

## Intune publish defaults

The template can set the Intune install experience and metadata for every app it publishes:

| Setting | Default | Notes |
|---|---|---|
| Minimum Windows release | `1607` | e.g. `22H2`; also shown in the customer documentation |
| Device restart behavior | `suppress` | `suppress` / `allow` / `force` / `basedOnReturnCode` |
| Max run time (minutes) | `60` | Keep it above your dialog timeout |
| Description boilerplate | *(none)* | Appended to every app's Intune description |
| Privacy URL | *(none)* | Published as the app's privacy information URL |

These are stored in the project at configure time and read back when you publish, so
`Publish-Win32ToolkitIntuneApp` honours them even when run on its own. A project built without a
template publishes exactly as before.

## Documentation branding

`Export-Win32ToolkitDocumentation` picks up your **company name** and an optional **footer line** from
the template, adding a *"Prepared by &lt;company&gt;"* credit and your footer to the generated customer
docs. The doc's "Minimum OS" line reflects the template's minimum Windows release, so it always
matches what you actually published.

## Managing templates

The Templates screen (`Show-Win32Toolkit` → Org templates) lists your templates and offers:

- **Create / Edit** opens the wizard (edit is pre-filled).
- **View** shows the current settings at a glance.
- **Duplicate** clones the JSON *and* the whole sidecar folder (hooks, module, assets) under a new
  name. This is the natural way to spin up `Customer-B` from `Customer-A`.
- **Delete** removes the template definition and its sidecar folder. It first checks whether the
  template's segment still holds projects and, if so, warns you and asks for confirmation. But it
  **never** deletes anything in `Projects\`, `Staging\`, or `IntuneWin\`; only the template itself.

## Under the hood: data-driven config

Template settings that map to PSADT's `config.psd1` (company name, dialog style, accent, language,
log path) are written as a **sparse** `config.psd1` containing only your overrides, plus the two asset
paths (logo and banner) described under [Branding](#branding-dialog-style-language-logos). PSADT merges
it over its own signed defaults, so anything you don't set keeps the PSADT default. There's no
find-and-replace against the full config file, which means template application no longer breaks when
a PSADT update reshuffles that file.

The dialog behaviour (welcome, deferral, countdowns, progress and completion) is not code either: it is
written as data to each project's `SupportFiles\AppConfig.json`, and fixed toolkit blocks in the deploy
script read it on the device. PSADT's own default dialog calls are removed from the deploy script, so
only your template's dialogs appear.

## Schema upgrades

Each template records a schema version. Loading a template from an older toolkit offers an upgrade:
accept and the wizard reopens **pre-filled with your values** so you only answer the new prompts;
decline and the toolkit fills the missing fields with safe defaults for that run (your JSON keeps
working, and the offer repeats next time).

## Advanced: the PSADT policy layer

Independently of templates, PSADT reads machine policy from
`HKLM\SOFTWARE\Policies\PSAppDeployToolkit\Config` on the device and **overrides** the packaged
`config.psd1` with any values it finds there. You can deploy this key by GPO or an Intune settings
policy to force a setting across the whole estate (for example, silencing balloon notifications
everywhere) without repackaging anything.

PSADT 4.2 adds **version-specific** keys, such as `HKLM\SOFTWARE\Policies\PSAppDeployToolkit\4.2\Config`.
Precedence on a 4.2 package, lowest to highest: the packaged `config.psd1`, then the shared key, then
each versioned key up to the package's PSADT version. A 4.1 package reads only the shared key.

Things to know:

- It applies to `config.psd1` values only. Dialog **strings** are deliberately excluded.
- It **silently wins over your template values.** If a device behaves differently from what a
  template specifies, check for this policy key first; it's the usual culprit.
- **Put Base64 image values (logo, banner) only in the `4.2` key.** win32-toolkit builds 4.1.x and
  4.2.x packages side by side, and PSADT 4.1 treats a Base64 value in the shared key as a file path
  that does not exist and throws.

## Next steps

- Run the full pipeline with your template: [Packaging an app](packaging.md)
- Command details: [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md)
