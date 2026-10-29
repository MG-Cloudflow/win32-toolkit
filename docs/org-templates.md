---
description: "Create the org template that holds one customer's branding, dialogs, tenant and Intune defaults."
---

# Create your org template

An [org template](glossary.md#org-template) holds what all apps of one customer share: company name,
dialog style, logo, Intune defaults and tenant. win32-toolkit needs one before your first app. Creating it changes
nothing in Intune.

## Before you start

Step 2 of 7.

- Step 1 is done: see [Install the toolkit](install.md).
- You know the company name that users should see in dialogs.
- You know the customer's [tenant ID](glossary.md#tenant-id). It is the ID of the customer's [tenant](glossary.md#tenant): its own organization in the Microsoft cloud. You find it in the Microsoft Entra admin
  center, on the **Overview** page (a general Microsoft fact).
- Time: about 2 to 5 minutes.

## Create the template

=== "Menu"

    1. Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)).
    2. Choose **Org templates** > **Create a new template**.
    3. Answer the questions. Press <kbd>Enter</kbd> to keep the default in brackets.

    While you package an app, you can also choose **+ Create a new template…** at **Choose an org template**.

=== "Command line"

    This command starts the wizard, saves the template and stops. It packages nothing.

    ```powershell
    Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
    ```

    Without a template, [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md) also starts the wizard by itself.

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

The wizard asks plain questions in six sections, A to F.

```text title="What you see"
=== Organisation Template Wizard ===
Press Enter on any prompt to keep the default value.

--- A: Identity ---
Template name [Default] :
```

<!-- SCREENSHOT: the wizard running in a terminal, showing the Identity and Branding sections with bracketed defaults -->

Many answers decide how the [PSAppDeployToolkit (PSADT)](glossary.md#psadt) dialogs look on devices.
PSADT is the free PowerShell tool that installs the app on each device. If an answer breaks a text rule, the wizard
shows the rule and asks again. At the end, it prints `✓ Template 'Contoso' saved:` and the file path.

## Answer the questions that matter

Six questions need a real answer:

| Question (as shown) | Default | What to enter |
|---|---|---|
| `Template name` | `Default` | The customer's short name, such as `Contoso`. Also the folder name. |
| `Company name (shown in dialog subtitles)` | `Your Organisation IT` | The name users see, such as `Contoso IT`. |
| `App script author` | `IT Packaging Team` | Your team name. Choose it once and never change it. |
| `Intune tenant (blank = unpinned)` | empty | The tenant ID, such as `11111111-2222-3333-4444-555555555555`. |
| `Dialog style - Fluent or Classic` | `Fluent` | [Fluent](glossary.md#fluent-and-classic) is the modern look, **Classic** the older one. |
| `Max run time (minutes)` | `60` | Keep `60`, never 30 or less. |

Press <kbd>Enter</kbd> for all other questions now. The full list is in
[All questions and their defaults](#all-questions-and-their-defaults).

### Choose the app script author once

The [app script author](glossary.md#app-script-author) is your team name. It is part of the [install tattoo](glossary.md#install-tattoo): a registry value that tells Intune which version is installed. Its key is
`HKLM\SOFTWARE\<app script author>\<publisher>\<app name>`. If you change the author, later updates miss the devices with
the old key. See [The detection key](settings.md#the-detection-key).

### Enter the tenant ID

With a tenant in the template, the toolkit refuses to publish this customer's apps to any other tenant. Without one, it
only warns. Each project of a winget app gets a copy of the tenant. See
[Pin the tenant on your org template](intune-connection.md#pin-the-tenant-on-your-org-template).

!!! warning "A domain name never matches"
    Use the tenant ID, not a domain name. The wizard also accepts a domain, such as `contoso.onmicrosoft.com`. But a
    domain never matches your sign-in, so the publish stops.

### Keep the maximum run time above 30 minutes

Intune stops an install that runs longer than the maximum run time. At 30 minutes or less, Intune can stop the
install before the package reports its own exit code, so the wizard warns. Keep 60 or more for apps with [prior-install rules](glossary.md#prior-install-rule): rules for another install of the app on the device. Removing the other
install first can take up to 30 minutes.

## When dialogs appear on devices

Intune does not tell PSADT whether to show dialogs. So PSADT shows them only when one of the app's programs is
running, because that program must be closed first. Otherwise the install runs silently.

These programs are the [processes to close](glossary.md#processes-to-close). The toolkit usually finds
them when it packages the app. When the list is empty, PSADT 4.2 stays silent. If the template allows a deferral,
PSADT 4.1 can still show the welcome dialog to a signed-in user.

A [deferral](glossary.md#deferral) lets users postpone the install, by default 3 times. The install
then ends with exit code 1602. Intune reports it as failed and tries again later (a general Microsoft fact).

Balloon texts, the short notices near the clock on the taskbar, show only with the Classic dialog style. The wizard
does not say this. To see the dialogs before you publish, run an [interactive test](glossary.md#interactive-test), a test that you watch. See
[Interactive or unattended](testing.md#interactive-or-unattended).

## Text rules

PSADT reads some template text as PowerShell code on the device. A `$` or a backtick there can fail every deployment
(exit code 60001 or 60008). It can also change the text without an error. So the toolkit refuses such text.

| Rule | Example of what is refused |
|---|---|
| Dollar sign: no `$` before a letter, a digit or one of `_ { ( : ? $ ^` | `Contoso $Team` or `Save $5`. Allowed: `US$ 5`, or a `$` at the end. |
| Backtick: none anywhere, also not in the log path | ``Contoso`IT`` |
| Spaces only: no text made only of spaces | Three spaces (leave the field empty instead). |
| Log path: only `$envName`, `$env:Name` or `${env:Name}` as variables | `$(Get-Date)\Logs`. Allowed: `$envWinDir\Logs\Software`. |
| Countdown: whole seconds from 0 to 86400 | `90000` or `1.5` |
| Language: a language name such as `nl`, `fr-FR` or `zh-Hans` | `Dutch` |

The wizard checks each answer as you type it. The toolkit checks a saved template again each time it loads it. So a
template from an older toolkit, or one changed by hand, can stop packaging before anything is created.

```text title="What you see"
Org template text rejected (template 'Contoso'): 1 problem(s) would make PSAppDeployToolkit fail every deployment that uses this template.
  - CompanyName: 'Contoso $Team' contains '$Team', which PSAppDeployToolkit expands as a variable or expression - the deployment fails or the text changes.
...
```

To fix it, choose **Org templates** > **Edit a template**. Correct each value it names.

!!! note "Curly quotes are not checked"
    Curly double quotes, such as “ and ”, can cut the text on the device. The toolkit does not check them yet, so type
    straight quotes (`"`) instead.

## View, edit, copy or delete a template

=== "Menu"

    Choose **Org templates**, then an action, then the template at **Choose a template**.

    | Action | What it does |
    |---|---|
    | **View a template's settings** | Shows the main settings. |
    | **Edit a template** | Opens the wizard with your current values. |
    | **Duplicate a template** | Asks for a new name, then copies the file and the template's folder. |
    | **Delete a template** | Asks `Delete template 'Contoso'?` (the default is No), then deletes it. |

    In the edit wizard, <kbd>Enter</kbd> keeps the current value. Type `-` to clear an optional value, for example at
    `Intune tenant (Enter = keep, '-' = unpinned)`.

=== "Command line"

    There is no edit command. With two or more templates, `Invoke-Win32Toolkit` without `-TemplateName` shows a
    numbered list. Type the number of `[Edit existing template]`, then the number of the template.

    After the wizard saves, the command continues and asks which app to package. To stop there, press
    <kbd>Ctrl</kbd>+<kbd>C</kbd>.

    For every option, see [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md).

!!! warning "Edits reach new projects only"
    Changes to an org template reach new projects only. Re-create a project to apply them.

To [re-create](glossary.md#re-create) a project is to make it again from the start. See
[Re-create a project](projects.md#re-create-a-project). Also know these points:

- `Invoke-Win32Toolkit -NewTemplate` with an existing name does not edit the template. It starts from the built-in
  defaults and overwrites the file. You must enter the tenant and every other value again.
- A new name in the edit wizard saves a new file and keeps the old one. New projects go to a new folder. There, new
  versions do not find the [installer technology](packaging.md#installer-technology) of earlier versions.
- A copy keeps the tenant of the original. Change it before you publish.
- Deleting a template also deletes its folder with your logo and scripts. Projects and packages stay.

## When the toolkit asks to update a template

A template from an older toolkit lacks the newest questions. When the toolkit loads it, it asks:

```text title="What you see"
  Template 'Contoso' uses schema v3.0, current is v4.0.
  New options are available. Would you like to update the template now?
  Update template? (y/n) [y]:
```

The schema is the version of the template file format.

- Press <kbd>Enter</kbd> or answer `y` (the default). The wizard opens with your values filled in. Answer the new
  questions.
- Answer `n` to use the defaults for the new questions in this run only. The file does not change, so the toolkit asks
  again next time.

A script cannot answer, so the toolkit takes the `n` path and prints a warning.

## Work for several customers

Create one org template per customer. Each one has its own tenant and its own folders. So the same app can exist for
several customers side by side, for example `Projects\Contoso\Git_x64_2.53.0` and `Projects\Fabrikam\Git_x64_2.53.0`.
Your version will differ.

With two or more templates, the toolkit asks which one to use. In a script, pass `-TemplateName`. Projects of apps that
are not in winget do not keep the tenant. Read [Work for several customers](intune-connection.md#work-for-several-customers)
before you publish them.

## All questions and their defaults

Questions with a yes or no answer show `(y/n)`, then the default in brackets.

### Identity questions

| Question | Default |
|---|---|
| `Template name` | `Default` |
| `Company name (shown in dialog subtitles)` | `Your Organisation IT` |
| `App script author` | `IT Packaging Team` |
| `Intune tenant (blank = unpinned)` | empty |

### Branding and dialog style

| Question | Default | Note |
|---|---|---|
| `Dialog style - Fluent or Classic` | `Fluent` | Another answer becomes `Fluent`. |
| `Fluent accent hex e.g. 0xFF0078D7 (blank=default)` | empty | Highlight color: `0xAARRGGBB`, `#RRGGBB` or `RRGGBB`. |
| `Log path` | `$envWinDir\Logs\Software` | The PSADT log folder on the device. |
| `Force dialog language e.g. nl / fr-FR (blank=auto-detect)` | empty | Empty: the language of the signed-in user. |

### Progress and balloon texts

| Question | Default |
|---|---|
| `Progress message - Install`, `- Repair`, `- Uninstall` | `Installation in progress. Please wait...` and similar |
| `Progress detail - Install`, `- Repair`, `- Uninstall` | `This window will close automatically when the installation is complete.` and similar |
| `Balloon complete - Install`, `- Repair`, `- Uninstall` | `Installation complete.` and similar (Classic style only) |

### Dialog questions

| Dialog | Question | Default |
|---|---|---|
| Install | `Show Welcome dialog on install`, `Allow deferral`, `Persist prompt (user cannot ignore)`, `Block app re-launch during install` | Yes |
| Install | `Max deferrals` | `3` |
| Install | `Check disk space`, `Show custom text from strings.psd1` | No |
| Install | `Auto-close countdown seconds (0=off, max 86400)` | `180` |
| Uninstall | `Show Welcome dialog on uninstall` | Yes |
| Uninstall | `Auto-close countdown seconds (0=off, max 86400)` | `60` |
| Uninstall | `Persist prompt`, `Block app re-launch during uninstall` | No |
| Progress | `Show Progress dialog` | Yes |
| Progress | `Override status message (blank = use strings.psd1)`, `Override detail text, Fluent only (blank = use strings.psd1)` | empty |
| Completion | `Show completion prompt after install` | No |
| Completion | `Completion message`, `Button label` | `The installation has completed successfully.`, `OK` |

### Org scripts and extension module

Section E asks about hook scripts, an extension module and your logo. Its yes or no questions are all No by default. See
[Add a logo, hook scripts or an extension module](org-template-files.md).

### Intune publish defaults

| Question | Default | Note |
|---|---|---|
| `Minimum Windows release (e.g. 1607, 22H2)` | `1607` | Accepted values are below. |
| `Device restart behavior (suppress/allow/force/basedOnReturnCode)` | `suppress` | Another answer becomes `suppress`. |
| `Max run time (minutes)` | `60` | Keep it above 30. |
| `Description boilerplate appended to every app (blank=none)` | empty | Added to every app description. |
| `Privacy information URL (blank=none)` | empty | Set on every app. |
| `Customer-doc footer line (blank=default)` | empty | A line at the end of the customer document (`Documentation.md`). |

The minimum Windows release takes `1607`, `1703`, `1709`, `1803`, `1809`, `1903`, `1909`, `2004`, `20H2`, `21H1`,
`21H2`, `22H2`, `Windows11_21H2`, `Windows11_22H2`, `Windows11_23H2` or `Windows11_24H2`. When the toolkit creates a
project, it changes any other value to `1607` and shows a warning. For MSIX and APPX packages, publishing raises the
minimum Windows release to at least `1809`.

Each new project gets a copy of these values. To change them later, change the template and re-create the project, or
change the app in the Intune admin center.

## What you have now

- `C:\Win32Apps\Templates\Contoso.json`: your org template, named as you typed the name.
- `C:\Win32Apps\Templates\Contoso\`: only if you turned on files in section E. Put your files there.
- No project yet. Your first project goes to `C:\Win32Apps\Projects\Contoso\`.
- Nothing in Intune.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `Org template text rejected` | Choose **Org templates** > **Edit a template** and fix each value it lists. |
| `Update template? (y/n)` | Not an error. Press <kbd>Enter</kbd> to add the new questions. |
| `W32T.OrgTemplateChoiceNeeded` (in a script) | The script cannot ask which template to use. Pass `-TemplateName` with the name of an existing template. |
| `A maximum run time of` | Edit the template and enter `60` or more. Re-create the projects you made with the low value. |
| `Connected to tenant` | If it names a domain, enter the tenant ID in the template and re-create the project. |

For more messages, see [Org templates in Troubleshooting](troubleshooting.md#org-templates).

## Next step

Your org template is ready. Now package your first app with it.

[Next: package an app from winget](packaging.md){ .md-button .md-button--primary }
