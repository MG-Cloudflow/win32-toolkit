---
description: "Turn an installer from winget or your own files into a tested Intune Win32 app, and keep it up to date."
---

# win32-toolkit

<div class="tk-hero" markdown>

![win32-toolkit](assets/win32-toolkit-logo.svg#only-light){ .tk-logo .tk-logo-wide }
![win32-toolkit](assets/win32-toolkit-stacked.svg#only-light){ .tk-logo .tk-logo-stacked }
![win32-toolkit](assets/win32-toolkit-logo-dark.svg#only-dark){ .tk-logo }

## Package Intune apps you can trust

win32-toolkit turns an installer into a tested Intune Win32 app and helps you keep it up to date. It works with
your own installers and with apps from [winget](glossary.md#winget), the Windows Package Manager.

[Start here](how-it-works.md){ .md-button .md-button--primary }
[Install](install.md){ .md-button }

</div>

## What do you want to do

<div class="grid cards" markdown>

- :material-package-variant: **Is your app in winget**?

    Search for it by name, and the toolkit downloads the newest version for you.

    [Package an app from winget](packaging.md)

- :material-folder-open-outline: **Do you have your own installer**?

    Package an MSI, MSIX or EXE file that is not in winget, or an older version of an app.

    [Package an app that is not in winget](manual-apps.md)

- :material-pencil-ruler: **What if your EXE cannot install silently**?

    Write the install code yourself, and the toolkit still creates the uninstall for you.

    [Package an Advanced app](manual-apps.md#package-an-advanced-app)

- :material-update: **Is there a new version of your app**?

    Package, test and publish the new version, then replace the old app in Intune.

    [Ship a new version](new-version.md)

- :material-flask-outline: **Do you want to test before you publish**?

    Let the toolkit install and uninstall the package in a clean copy of Windows, then read the result.

    [Test the package](testing.md)

- :material-graph-outline: **Does the app need the Visual C++ runtime first**?

    Make Intune and your tests install the runtime before your app.

    [Apps that need another app first](dependencies.md)

- :material-account-group-outline: **Do you work for several customers**?

    Save each customer's tenant ID once, so the toolkit can refuse a publish to the wrong tenant.

    [Work for several customers](intune-connection.md#work-for-several-customers)

- :material-swap-horizontal: **Do devices already have the app from another installer technology**?

    A rule can stop the install on those devices, report the other install, or in some cases remove it first.

    [Devices that already have the app](prior-installs.md)

</div>

Not here? See [Find a task](tasks.md).

## The journey

Your first app takes seven steps and about 1 to 1.5 hours, much of it waiting. All times on this page are estimates.

```mermaid
flowchart LR
    A[Install the toolkit] --> B[Create an org template]
    B --> C[Package an app]
    C --> D[Test the package]
    D --> E[Build the package]
    E --> F[Connect to Intune]
    F --> G[Publish to Intune]
```

1. [Install the toolkit](install.md): about 15 minutes, plus one restart.
2. [Create your org template](org-templates.md): about 2 to 5 minutes, once per customer.
3. [Package an app from winget](packaging.md): 2 to 5 minutes of your input, then usually 5 to 20 minutes of waiting.
4. [Test the package](testing.md): about 2 minutes, plus a 2-minute pause to look at the app.
5. [Build the package](build-intunewin.md): seconds to a few minutes.
6. [Connect to Intune](intune-connection.md): a few minutes, longer if an admin must give consent first.
7. [Publish to Intune](publishing.md): usually a few minutes, longer for big packages.

Your PC needs Windows 10 or 11 Pro, Enterprise or Education (not Home). [Check your PC](install.md#check-your-pc)
lists everything else you need.

Most steps work in the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) and on the command line. The step
pages show the menu first. For the ideas behind the steps, read [How win32-toolkit works](how-it-works.md).

## What the toolkit does for you

<div class="grid cards" markdown>

- :material-radar: **Exact-version detection**

    Intune finds the app with a [detection rule](glossary.md#detection-rule) that checks the exact
    version the package wrote to the registry. If that is not possible, the toolkit builds the rule from a real install
    in a clean copy of Windows.

- :material-delete-sweep-outline: **An uninstall that works**

    The toolkit installs the app in a clean copy of Windows and records what changed. This [install capture](glossary.md#install-capture) gives an EXE an uninstall that matches the real install.

- :material-test-tube: **Tests before Intune sees the app**

    A test installs and uninstalls the package in a clean copy of Windows and runs automatic checks. Another test
    installs an older version first and checks that your package updates it.

- :material-palette-swatch-outline: **Your branding, once per customer**

    An [org template](glossary.md#org-template) holds a customer's company name, dialog style, logo,
    tenant ID and Intune defaults. Every app you package for that customer uses it.

</div>

## What it never does

Keep these four facts in mind.

- win32-toolkit never assigns an app. You assign it in the Intune admin center.
- Every publish creates a new app in Intune. Publishing again does not change the old app.
- win32-toolkit never turns on Windows features. You turn them on once.
- A failed test only warns. It does not stop packaging or publishing.

The full list is in [What the toolkit never does](how-it-works.md#what-the-toolkit-never-does).

## Help

<div class="grid cards" markdown>

- :material-magnify: **[Find a task](tasks.md)**

    Every task as a question, with a link to the answer.

- :material-lifebuoy: **[Troubleshooting](troubleshooting.md)**

    Look up a message by its first words and learn what to do.

- :material-book-open-variant: **[Glossary](glossary.md)**

    Plain explanations of the words in this guide.

- :material-console: **[Commands](reference/README.md)**

    All 17 commands, with their options and examples.

</div>

In PowerShell, `Get-Help <command> -Full` shows the same command help. It works without internet.
