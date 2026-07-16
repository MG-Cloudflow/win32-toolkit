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

Templates also **group your output** — the template name (sanitized) becomes a folder segment in
every tier, so work for different customers stays separated:

| Tier | Path under BasePath |
|---|---|
| Projects | `Projects\<Template>\<App>` |
| Staging | `Staging\<Template>\<App>` |
| IntuneWin | `IntuneWin\<Template>\<App>.intunewin` |

## Creating a template

To create (or edit) a template without packaging anything:

```powershell
Invoke-Win32Toolkit -NewTemplate
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

This opens the wizard, saves the JSON, and exits. If you never create one, the toolkit prompts you
the first time you run the pipeline — you cannot package without a template.

<!-- SCREENSHOT: the wizard running in a terminal, showing the Identity and Branding sections with bracketed defaults -->

## The wizard, section by section

Every prompt shows a default in brackets — press **Enter** to accept it.

| Section | Field | What it controls |
|---|---|---|
| Identity | Template name / Company name / App script author | File+folder name, dialog subtitle, deploy-script author |
| Branding & dialog style | **Dialog style** | `Fluent` (modern) or `Classic` (v3-style, uses the Classic banner) |
| | Fluent accent hex | Accent colour, e.g. `0xFF0078D7` (blank = PSADT default) |
| | Log path | Where deploy scripts write logs (default `$envWinDir\Logs\Software`) |
| | **Force dialog language** | Pin all dialogs to one language, e.g. `nl`, `fr-FR` (blank = auto-detect) |
| Progress / Balloon | per-deployment-type text | Progress-dialog and completion-toast wording |
| Welcome / Uninstall / Progress / Completion dialogs | enable, deferral, countdown, persist, block, messages | PSADT dialog behaviour per phase |
| Org scripts & extension module | **Enable org hook scripts** + on-error policy | Runs your `.ps1` files in each deploy phase (see below) |
| | **Ship an org PSADT extension module** | Copies `PSAppDeployToolkit.<Org>\` into every project |
| | **Ship org branding assets** | Copies your logo/banner into every project |
| Intune publish defaults | **Minimum Windows release / restart behavior / max run time** | The Intune install experience |
| | **Description boilerplate / privacy URL** | Appended to every published app |
| | **Customer-doc footer line** | Footer on the generated customer documentation |

The wizard also records the schema version and the installed PSADT version (you are not prompted for
these).

## Branding: dialog style, language, logos

- **Dialog style** — `Fluent` is the modern v4 look; `Classic` renders the older v3-style dialogs and
  uses `Banner.Classic.png`. Some estates (kiosks, servers) prefer Classic.
- **Language** — leave the language override blank and PSADT shows dialogs in the signed-in user's
  language (this works correctly even though the package runs as SYSTEM). Set it (e.g. `nl`) to pin
  every dialog to one of PSADT's 27 shipped languages.
- **Logos & banner** — enable *Ship org branding assets*, then drop files in
  `Templates\<name>\Assets\`:
  - `AppIcon.png` — brands PSADT dialogs/toasts **and** becomes the Intune tile when the app has no
    icon of its own (see precedence below).
  - `Banner.Classic.png` — the banner shown by Classic dialogs.

  You don't touch any config — PSADT's defaults already point at these filenames.

### App-icon precedence

`AppIcon.png` serves both the on-device dialogs and the Intune tile. The toolkit picks the best
available source, in this order:

1. **winget** icon (downloaded from the package's manifest)
2. **manual** icon (a `-IconPath` you passed for a manual app)
3. **captured** icon (extracted from the app during the sandbox install run)
4. **org template** logo (your `Assets\AppIcon.png`) — the fallback
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

Each file runs in the matching PSADT deploy phase of **every** app built from the template — map a
drive, drop a shortcut, remove a legacy agent, write a tattoo key, once per customer instead of
per app. Inside a hook you have the full `$adtSession` and every PSADT function available.

Important:

- **They run on the device under Windows PowerShell 5.1** (Intune's `powershell.exe`). Keep them
  5.1-safe — no `?:` ternary, `??`, `?.`, or `&&`/`||`. The toolkit parse-checks each hook under real
  5.1 when applying the template and warns about PS7-only syntax.
- **On error** you choose `Fail` (a throwing hook fails the deployment — the default, and the safe
  choice for a setup step that must succeed) or `Continue` (log and carry on).
- Post-install / post-uninstall hooks run **before** the detection tattoo is written, so a failing
  hook correctly prevents the app being detected as installed.

Your scripts are **copied** into the package (`SupportFiles\OrgHooks\`) and dot-sourced at runtime —
their contents are never spliced into generated code.

## Org PSADT extension module

For functions shared across your hooks (or manual deploy-script edits), enable the extension module
and place a module folder at `Templates\<name>\PSAppDeployToolkit.<YourOrg>\` (a `.psd1` + `.psm1`).
It's copied into every project's root, where PSADT v4 auto-imports it — so `Set-ContosoTattoo`,
`Remove-ContosoLegacyAgent`, etc. are available everywhere. Use exit codes in the 70000–79999 range
per PSADT guidance. The module runs on-device as 5.1 too, so the same syntax rule applies (the
toolkit parse-checks it).

## Intune publish defaults

The template can set the Intune install experience and metadata for every app it publishes:

| Setting | Default | Notes |
|---|---|---|
| Minimum Windows release | `1607` | e.g. `22H2`; also shown in the customer documentation |
| Device restart behavior | `suppress` | `suppress` / `allow` / `force` / `basedOnReturnCode` |
| Max run time (minutes) | `60` | Keep it above your dialog timeout |
| Description boilerplate | *(none)* | Appended to every app's Intune description |
| Privacy URL | *(none)* | Published as the app's privacy information URL |

These are stored in the project at configure time and read back when you publish — so
`Publish-Win32ToolkitIntuneApp` honours them even when run on its own. A project built without a
template publishes exactly as before.

## Documentation branding

`Export-Win32ToolkitDocumentation` picks up your **company name** and an optional **footer line** from
the template, adding a *"Prepared by &lt;company&gt;"* credit and your footer to the generated customer
docs. The doc's "Minimum OS" line reflects the template's minimum Windows release, so it always
matches what you actually published.

## Managing templates

The Templates screen (`Show-Win32Toolkit` → Org templates) lists your templates and offers:

- **Create / Edit** — the wizard (edit is pre-filled).
- **View** — the current settings at a glance.
- **Duplicate** — clones the JSON *and* the whole sidecar folder (hooks, module, assets) under a new
  name. This is the natural way to spin up `Customer-B` from `Customer-A`.
- **Delete** — removes the template definition and its sidecar folder. It first checks whether the
  template's segment still holds projects and, if so, warns you and asks for confirmation — but it
  **never** deletes anything in `Projects\`, `Staging\`, or `IntuneWin\`; only the template itself.

## Under the hood: data-driven config

Template settings that map to PSADT's `config.psd1` (company name, dialog style, accent, language,
log path) are written as a **sparse** `config.psd1` containing only your overrides. PSADT merges it
over its own signed defaults, so anything you don't set keeps the PSADT default. There's no
find-and-replace against the full config file, which means template application no longer breaks when
a PSADT update reshuffles that file.

## Schema upgrades

Each template records a schema version. Loading a template from an older toolkit offers an upgrade:
accept and the wizard reopens **pre-filled with your values** so you only answer the new prompts;
decline and the toolkit fills the missing fields with safe defaults for that run (your JSON keeps
working, and the offer repeats next time).

## Advanced: the PSADT policy layer

Independently of templates, PSADT reads machine policy from
`HKLM\SOFTWARE\Policies\PSAppDeployToolkit\config` on the device and **overrides** the packaged
`config.psd1` with any values it finds there. You can deploy this key by GPO or an Intune settings
policy to force a setting across the whole estate — for example, silencing balloon notifications
everywhere — without repackaging anything.

Two things to know:

- It applies to `config.psd1` values only. Dialog **strings** are deliberately excluded.
- It **silently wins over your template values.** If a device behaves differently from what a
  template specifies, check for this policy key first — it's the usual culprit.

## Next steps

- Run the full pipeline with your template: [Packaging an app](packaging.md)
- Command details: [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md)
