# Org templates

An **org template** is a JSON file that stores per-customer branding and PSADT dialog defaults — company name, accent colour, progress/balloon messages, welcome-dialog behaviour, and so on. Every project you package gets the template applied automatically, so all apps for a given customer look and behave the same without any per-app work.

Templates also **group your output**: the template name (sanitized) becomes a folder segment in every output tier, so work for different customers stays separated:

| Tier | Path under BasePath |
|---|---|
| Templates | `Templates\<name>.json` |
| Projects | `Projects\<Template>\<App>` |
| Staging | `Staging\<Template>\<App>` |
| IntuneWin | `IntuneWin\<Template>\<App>.intunewin` |

## Creating a template

To create (or edit) a template without packaging anything:

```powershell
Invoke-Win32Toolkit -NewTemplate
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

This opens the wizard, saves the JSON, and exits. See [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md) for the full parameter reference.

If you never create one, the toolkit prompts you to create a template the first time you run the pipeline — you cannot package without one.

## The wizard, field by field

Every prompt shows a default in brackets — press **Enter** to accept it. Only the Fluent dialog style is supported.

| Section | Field | What it controls |
|---|---|---|
| Identity | Template name | File name and the folder segment used in the output tiers |
| Identity | Company name | Shown in PSADT dialog subtitles |
| Identity | App script author | Recorded as the author in generated deploy scripts |
| Branding | Fluent accent hex | Accent colour, e.g. `0xFF0078D7` (blank = PSADT default) |
| Branding | Log path | Where deploy scripts write logs (default `$envWinDir\Logs\Software`) |
| Progress messages | Install / Repair / Uninstall message + detail | Text shown in the progress dialog per deployment type |
| Balloon notifications | Install / Repair / Uninstall | Toast/balloon text shown on completion |
| Install welcome dialog | Show Welcome dialog | Whether users see a prompt before install |
| | Allow deferral + max deferrals | Lets users postpone the install, and how many times |
| | Check disk space | Verify free space before installing |
| | Persist prompt | Keep re-showing the dialog so users cannot ignore it |
| | Block app re-launch | Prevent the app being reopened mid-install |
| | Auto-close countdown seconds | Force-close blocking apps after this many seconds (0 = off) |
| | Show custom text | Display extra text from `strings.psd1` |
| Uninstall welcome dialog | Enabled / countdown / persist / block | Same options for uninstall; only shown when processes must close first |
| Progress dialog | Show Progress dialog | Whether the progress window appears at all |
| | Override status message / detail text | Custom text (blank = PSADT `strings.psd1` defaults) |
| Completion prompt | Show completion prompt | Optional message box after a successful install |
| | Completion message + button label | Its text and button caption |

The wizard also records metadata you are not prompted for: the schema version and the PSADT version installed when the template was created.

<!-- SCREENSHOT: the wizard running in a terminal, showing the Identity and Branding sections with bracketed defaults -->

## Where the JSON lives

Templates are saved as `Templates\<name>.json` under your **BasePath** (chosen on first run and stored in the registry — see [Getting started](getting-started.md)). The file is plain JSON: you can inspect it, copy it to another machine, or check it into source control. Editing by hand works, but re-running the wizard is safer — it validates input and keeps the schema current.

## Picking a template per run

When the pipeline starts, it loads a template like this:

- **`-TemplateName 'Contoso'` given** — loads `Templates\Contoso.json` directly, skipping any picker. If it does not exist, the wizard opens to create it under that name.
- **No name, one template on disk** — loaded automatically.
- **No name, several templates** — an interactive picker lists them, plus options to create a new template or edit an existing one (the wizard opens pre-filled with its current values).
- **No templates at all** — the wizard opens to create the first one.

## Schema upgrades

Each template records a schema version. When you load a template created by an older toolkit version, you are offered an upgrade: accepting reopens the wizard **pre-filled with your existing values** so you only answer the new prompts. If you decline, the toolkit silently fills the missing fields with safe defaults for that run — your JSON file keeps working, and the offer repeats next time.

## Next steps

- Run the full pipeline with your template: [Packaging an app](packaging.md)
- Command details: [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md)
