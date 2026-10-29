---
description: "Sign in to the right Intune tenant on purpose, check the tenant banner, and keep customers apart with a tenant pin."
---

# Connect to Intune

This step signs you in to the right Microsoft Intune [tenant](glossary.md#tenant): one organization's
own space in Microsoft 365 and Intune. You choose the tenant on purpose and check it before win32-toolkit writes
anything.

## Before you start

Step 6 of 7.

- You need an account that can create apps in Intune. See [What your account needs](#what-your-account-needs).
- You need an [org template](glossary.md#org-template), the settings file of one customer. See
  [Create your org template](org-templates.md).
- The org template holds the customer's [tenant ID](glossary.md#tenant-id). This is the fixed ID of a
  tenant, a long code like `11111111-2222-3333-4444-555555555555`.
- Time: a few minutes (longer if an admin must give consent first).

## What your account needs

The toolkit talks to Intune through [Microsoft Graph](glossary.md#microsoft-graph), Microsoft's web
service for Intune data. It signs in as you and acts only in your name.

[Admin consent](glossary.md#admin-consent) is a one-time approval by a tenant administrator that lets
an app use a permission. An **Intune role** is the set of Intune rights your account has.

| You need | Why |
|---|---|
| The Graph permission `DeviceManagementApps.ReadWrite.All` | The toolkit creates the app and uploads the package with it. It asks for no other permission. |
| Admin consent for "Microsoft Graph Command Line Tools" | The Graph module signs in through this Microsoft app. |
| An Intune role that may create and upload apps | The Graph permission alone is not enough. |
| The Relate permission in your Intune role | Only if your apps have [dependencies](dependencies.md). It lets the toolkit link an app to the app it needs. |
| Network access to Microsoft Graph, Microsoft sign-in and Azure Storage | The toolkit uploads the package to Azure Storage. |

Consent and Intune roles are general Microsoft facts. Without consent, your first sign-in stops at a Microsoft page
called "Need admin approval".

## Connect

Publishing signs you in by itself, but connect first. You then see the tenant before the toolkit writes anything to
Intune.

=== "Menu"

    1. Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)).
    2. In the main menu, choose **Microsoft Intune connection**. The top of the screen shows your current connection.
    3. Choose **Connect using an org template's tenant**.
    4. At **Which customer?**, choose the line that starts with `Contoso`.
    5. If a Microsoft sign-in window opens, sign in with your account.
    6. Read the banner, then press any key.

    Each line of **Which customer?** shows the tenant ID of the org template, or `not pinned`.

    To connect without an org template, choose **Connect to a tenant by id or domain**. At **Tenant id or domain**,
    type the tenant ID. A domain name does not work here, because the toolkit compares tenant IDs.

=== "Command line"

    [`Connect-Win32ToolkitIntune`](reference/Connect-Win32ToolkitIntune.md) connects to the tenant that the
    `Contoso` org template pins.

    ```powershell
    Connect-Win32ToolkitIntune -Template 'Contoso'
    ```

    To connect without an org template, give the tenant ID.

    ```powershell
    Connect-Win32ToolkitIntune -TenantId '11111111-2222-3333-4444-555555555555'
    ```

    On a PC without a browser, add `-UseDeviceAuthentication`. This starts a [device code sign-in](glossary.md#device-code-sign-in). PowerShell shows a code and a web address. Open the address on
    any device and enter the code.

    For every option, see [Connect-Win32ToolkitIntune](reference/Connect-Win32ToolkitIntune.md).

### Install the Graph module once

The first time, the toolkit needs the [module](glossary.md#module) `Microsoft.Graph.Authentication`, a
package of PowerShell commands. If it is missing, you see this question:

```text title="What you see"
WARNING: Microsoft.Graph.Authentication module not found.
Install it now from PSGallery? (Y/N):
```

Type `Y` and press <kbd>Enter</kbd>. The default is No, and then the connect stops. The toolkit installs the module
for your Windows account from the [PowerShell Gallery](glossary.md#powershell-gallery), Microsoft's
public store of PowerShell modules.

## Check the tenant banner

After the sign-in, the toolkit shows a panel titled **Microsoft Intune connection**:

```text title="The tenant banner"
Tenant    : Contoso
Domain    : contoso.onmicrosoft.com
Tenant ID : 11111111-2222-3333-4444-555555555555
Account   : admin@contoso.onmicrosoft.com
Template  : Contoso (matches)
Scopes    : DeviceManagementApps.ReadWrite.All
Session   : Process / Delegated
```

<!-- SCREENSHOT: the Microsoft Intune connection banner after connecting with the Contoso org template, showing "Template  : Contoso (matches)" -->

Read the Tenant line first. It names the customer whose Intune gets your apps. The Account line cannot tell you that,
because a consultant's account looks the same in every customer tenant. The Template line appears only when you
connect with an org template.

| What you see | What it means |
|---|---|
| `Contoso (matches)` on the Template line | Your sign-in is in the tenant saved on the org template. |
| `Contoso (not pinned)` on the Template line | The org template has no tenant ID. Nothing can check that this is the right customer. |
| A red panel with `MISMATCH - template expects` | You are in another tenant than the org template expects. Connect again. |
| `(name unavailable)` on the Tenant line | Your sign-in may not have the right to read the tenant name. This is harmless: every check still works. |

## Pin the tenant on your org template

A [tenant pin](glossary.md#pin) is the tenant ID saved on an org template. With a pin, the toolkit
refuses to publish to any other tenant.

!!! warning "Use the tenant ID"

    Use the tenant ID, not a domain name. The template wizard and the menu also offer a domain such as
    `contoso.onmicrosoft.com`. But the toolkit compares tenant IDs. A domain never matches, so connect and publish
    are refused.

You find the tenant ID in the Microsoft Entra admin center, on the Overview page (a general Microsoft fact). To pin
the tenant on an existing org template:

1. In the main menu, choose **Org templates** > **Edit a template**, then choose `Contoso`.
2. Press <kbd>Enter</kbd> to keep each answer until the question **Intune tenant**.
3. Type the tenant ID and press <kbd>Enter</kbd>. To remove a pin, type `-` instead.
4. Press <kbd>Enter</kbd> for the other questions. The wizard then saves the template.

To set the pin in a new template, see
[Answer the questions that matter](org-templates.md#answer-the-questions-that-matter).

Suppose you publish a pinned project while you are signed in to another tenant. The console shows `Switching tenant`
and a new sign-in starts. If the tenant still differs from the pin, the toolkit refuses the publish before it creates
anything in Intune.

### What the pin does not cover

A [project](glossary.md#project) is the folder of one app version. To [re-create](glossary.md#re-create) a project means to make it again from the start. See
[Re-create a project](projects.md#re-create-a-project).

- The toolkit copies the pin into a winget project when it creates it. Changes to an org template reach new projects
  only. Re-create a project to apply them.
- [Apps that are not in winget](manual-apps.md) do not store the pin. The toolkit checks the tenant only when you
  publish in the same run that creates them. Later, connect with the org template first and read the banner.
- Without a pin, a publish only warns: `This project's template does not pin a tenant`. It then uses the tenant you
  are signed in to.

## Work for several customers

Do this for every customer:

1. Pin every org template with the customer's tenant ID.
2. Connect with the customer's org template, in the menu or with `Connect-Win32ToolkitIntune -Template`.
3. Read the Tenant line of the banner.
4. Publish.
5. Sign out when you finish with this customer.

Always connect first. By default, `Connect-Win32ToolkitIntune` keeps the sign-in in this PowerShell window only. A
publish that signs you in by itself saves the sign-in on disk. Another PowerShell window can then use it too.

Take care if you are a consultant and your customers added your own company account to their tenants. Suppose an org
template has no pin and you publish without connecting first. Microsoft then usually signs you in to your own company's tenant (a general
Microsoft fact). The app goes to your own tenant, with only a warning.

Signing out is a convenience. The tenant pin is the safety control.

## Sign out

=== "Menu"

    Choose **Microsoft Intune connection** > **Sign out**. The menu shows **Sign out** only when you are connected.

=== "Command line"

    [`Disconnect-Win32ToolkitIntune`](reference/Disconnect-Win32ToolkitIntune.md) ends the sign-in.

    ```powershell
    Disconnect-Win32ToolkitIntune
    ```

    For every option, see [Disconnect-Win32ToolkitIntune](reference/Disconnect-Win32ToolkitIntune.md).

```text title="What you see"
✓ Signed out of Contoso.
  This cleared the toolkit's token. Your browser is still signed in to Entra, so the next connect may not prompt.
```

The toolkit forgets its [token](glossary.md#token), the proof of your sign-in. Your browser stays
signed in to [Microsoft Entra ID](glossary.md#microsoft-entra-id), Microsoft's sign-in service. So the
next connect may finish without a question, on the same tenant.

## What you have now

- A sign-in to the Contoso tenant, kept in this PowerShell window only. It ends when you sign out or close the window.
- If you pinned the tenant: the tenant ID in the org template `Contoso`.
- Nothing in Intune. No app was created or changed.

## If something goes wrong

When you connect, the toolkit puts `Connect failed:` in front of each error. Read the words after it.

| Message starts with | What to do |
|---|---|
| "Need admin approval" (a Microsoft page) | Ask a Global Administrator to give admin consent once for Microsoft Graph Command Line Tools. |
| `Connected to tenant '...' but '...' was requested` | You signed in to another tenant, so the toolkit signed you out again. Use the right account, or add `-UseDeviceAuthentication`. Pin the tenant ID, not a domain. |
| `Microsoft.Graph.Authentication is required but this session is non-interactive` | Install the module first, or add `-Force` to `Connect-Win32ToolkitIntune` to install it without a question. |
| `Template 'Contoso' not found. Creating it now...` | No org template has this name in your [base folder](glossary.md#base-folder). Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to stop the template wizard, then check the name. |
| `Template 'Contoso' does not pin a tenant` | [Pin the tenant on your org template](#pin-the-tenant-on-your-org-template). |

In a script, a connect error does not stop the script: add `-ErrorAction Stop` to `Connect-Win32ToolkitIntune`.

For more messages, see [Troubleshooting: sign-in and tenant](troubleshooting.md#sign-in-and-tenant).

## Next step

Publish the package to the tenant you checked.

[Next: publish to Intune](publishing.md){ .md-button .md-button--primary }
