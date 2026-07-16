# Publishing to Intune

This page covers getting a packaged `.intunewin` into your tenant with
[Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md) — whether you call it
directly, or let `-PublishIntune` on [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md) or
[Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md) call it for you. For
producing the `.intunewin` itself, see [Packaging](packaging.md).

## Authentication

The toolkit signs in to Microsoft Graph with the **Microsoft.Graph.Authentication** module. If the
module is missing, the publisher offers to install it from the PowerShell Gallery (answer `Y` at
the prompt); in a non-interactive session it stops with the exact `Install-Module` command to run.

Only one delegated scope is requested: **`DeviceManagementApps.ReadWrite.All`**. Sign-in is
interactive — a browser window opens for you to pick an account.

**Admin-consent reality:** in most tenants this scope requires admin consent for the *Microsoft
Graph Command Line Tools* app. The first sign-in either shows a consent prompt you can accept
(if you are allowed to consent) or fails with a "need admin approval" error — in that case a Global
Administrator must grant consent once, and every later sign-in works silently.

**Pre-connect pattern:** if a Graph session with the right scope already exists, the publisher
reuses it and does not prompt again. Connect first when you want to control which account is used:

```powershell
# Sign in once with the account you want
Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All'

# The uploader detects the existing connection and skips re-auth
Publish-Win32ToolkitIntuneApp `
    -IntuneWinPath 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin' `
    -ProjectPath   'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

## What gets created

One Win32 app, with metadata (name, publisher, version, description, info URL) read from the
project's `AppConfig.json` (winget manifest as fallback). Shell defaults:

| Property | Value |
|---|---|
| Install command line | `powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install` |
| Uninstall command line | same, with `-DeploymentType Uninstall` |
| Install behavior | **System** context, restart suppressed, 60-minute max run time |
| Return codes | 0 and 1707 success · 3010 soft reboot · 1641 hard reboot · 1618 retry |
| Minimum OS | Windows 10 1607 |

Everything above can be adjusted in the Intune portal after upload.

**Detection rule** — one rule is created, by priority:

1. **Install tattoo (preferred):** the generated deploy script writes
   `HKLM\SOFTWARE\<Author>\<Vendor>\<App>\Version` at install time, so the rule checks that
   registry value **equals the packaged version** — Intune confirms both presence *and* version.
2. **Capture fallback:** projects without a tattoo fall back to the **newest**
   `InstallationChanges_*.json` sandbox capture — a registry key (Uninstall keys preferred) or a
   `Program Files` path.
3. **None:** the app is still created, with a warning — add a detection rule in the portal.

**App icon** — `Assets\AppIcon.png` (from winget, a manual `-IconPath`, or captured during the
install run) is normalized to a genuine PNG and attached as the app tile icon (`largeIcon`). No
usable icon means Intune shows the generic tile.

<!-- SCREENSHOT: the published app in the Intune portal showing tile icon, detection rule, and shell defaults -->

## What happens during upload

The app shell is created first, then the encrypted content is uploaded to Azure Storage in chunks,
committed, and linked to the app. The two waits (storage URI, commit) poll with exponential
back-off up to the timeout. When it finishes you get the app id and a direct portal link.
The wire protocol is deliberately not documented here — it is an implementation detail.

## Publishing updates

To publish the same package a second time as an **update app** — one that only applies to devices
that already have the app installed — pass `-AsUpdate` to `Publish-Win32ToolkitIntuneApp`, or
`-PublishUpdate` to `Invoke-Win32Toolkit` / `Export-Win32ToolkitIntuneWin`. The update app gets
`(Update)` appended to its display name (configurable) and a **requirement rule** (a PowerShell
presence check) that gates it to machines where the app already exists. Detection stays the
version-aware tattoo rule, so older installs get updated and detect once they reach this version.
If no requirement rule can be built, the publish fails fast rather than creating an app that would
apply to every device.

**Re-publish behavior:** every publish creates a **new** app — Intune has no overwrite. To retire
an old version, delete it or configure supersedence in the portal.

## Dependencies at publish time

Dependencies declared on the project (see [Dependencies](dependencies.md)) are resolved to real
Intune app **ids** before anything uploads — a missing dependency is reported up front, not after
a 200 MB upload. Unresolvable ones are warned about and skipped; nothing is ever auto-published as
a side effect. The relationship is attached **after** the upload completes (Intune only allows it
then), and only to the install app — never to the `(Update)` app.

## Customer-facing documentation

To produce a one-page hand-over sheet (`Documentation.md`) for the packaged app — deployment
settings, detection method in plain English, captured-change summary, test history — run
[Export-Win32ToolkitDocumentation](reference/Export-Win32ToolkitDocumentation.md). The output is
customer-safe by default: no tenant id, no Intune app id, no raw host paths. Pass
`-IncludeIntuneIds` only for an **internal copy** (or when the customer owns the tenant) to add
the app id and a portal deep-link.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| **403 when attaching a dependency** (app itself uploaded fine) | Your Intune RBAC role lacks the **Relate** permission on Mobile apps. A correct Graph scope is not enough — ask an Intune admin to add Relate to your role, then re-attach in the portal. |
| **"Need admin approval" at sign-in** | The `DeviceManagementApps.ReadWrite.All` scope needs tenant admin consent — see [Authentication](#authentication). |
| **Timeout waiting for storage URI or commit** | Large packages take longer to server-side validate. Raise the wait: `-TimeoutSeconds` on the publisher, or `-PublishTimeoutSeconds 900` on `Export-Win32ToolkitIntuneWin` (default 300 s). |
