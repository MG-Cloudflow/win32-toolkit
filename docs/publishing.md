---
description: "Publish your Win32 app to Microsoft Intune through the Graph beta API, with detection rules, requirements, and assignments."
---

# Publishing to Intune

This page covers getting a packaged `.intunewin` into your tenant with
[Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md), whether you call it
directly, or let `-PublishIntune` on [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md) or
[Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md) call it for you. For
producing the `.intunewin` itself, see [Packaging](packaging.md).

## Authentication

The toolkit signs in to Microsoft Graph with the **Microsoft.Graph.Authentication** module. If the
module is missing, the publisher offers to install it from the PowerShell Gallery (answer `Y` at
the prompt); in a non-interactive session it stops with the exact `Install-Module` command to run.

Only one delegated scope is requested: **`DeviceManagementApps.ReadWrite.All`**. Sign-in is
interactive: a browser window opens for you to pick an account.

**Admin-consent reality:** in most tenants this scope requires admin consent for the *Microsoft
Graph Command Line Tools* app. The first sign-in either shows a consent prompt you can accept
(if you are allowed to consent) or fails with a "need admin approval" error. In that case a Global
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
| Install command line | `Invoke-AppDeployToolkit.exe -DeploymentType Install` |
| Uninstall command line | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall` |
| Install behavior | **System** context, restart suppressed, 60-minute max run time (keep it above 30 minutes, see below) |
| Return codes | 0 and 1707 success · 3010 soft reboot · 1641 hard reboot · 1618 retry |
| Minimum OS | Windows 10 1607 |

Everything above can be adjusted in the Intune portal after upload. The org template can change the
restart behavior, the maximum run time and the minimum OS for every app it publishes (see
[Org templates](org-templates.md#intune-publish-defaults)). Keep the maximum run time above 30 minutes
(default 60): the uninstall stops an EXE uninstaller at 30 minutes, and a lower Intune limit would stop it
first, without the toolkit's exit code. Publish, and its `-WhatIf` dry run, warns when the maximum run time
is 30 minutes or less; it never stops the publish.

**Why `Invoke-AppDeployToolkit.exe`.** The Intune Management Extension is a 32-bit process, so a bare
`powershell.exe` in the command line starts the **32-bit** Windows PowerShell on a 64-bit device.
PSAppDeployToolkit 4.2 refuses to run there and exits **60008** before anything installs; 4.1 runs,
but writes the install tattoo to the 32-bit registry view (`HKLM\SOFTWARE\WOW6432Node\...`), where
the 64-bit detection rule never finds it. PSADT's own launcher, `Invoke-AppDeployToolkit.exe`, is in
every package (PSADT's project template ships it next to `Invoke-AppDeployToolkit.ps1`) and always
starts the **64-bit** Windows PowerShell. No `-DeployMode` is passed, so PSADT picks the mode itself
(Auto): dialogs appear only when the user has to close one of the app's processes, otherwise the
deployment runs silently (on PSADT 4.1 an app with an empty processes-to-close list still shows them;
see [When dialogs appear](org-templates.md#when-dialogs-appear)). Never add `-DeployMode Interactive`
to the command line: with nobody signed in, PSADT then exits 1602.

**Codes Intune reports as failed.** Any exit code not in the return-code list is a failure in Intune.
The ones you will meet from a win32-toolkit package:

| Exit code | Meaning |
|---|---|
| 60001 | An error inside the deploy script (for example the installer failed, or an org hook threw). The PSADT log on the device names it. |
| 60008 | PSADT could not start its session: a 32-bit launch of a PSADT 4.2 package (the old command line, see below), or a config value PSADT refuses (see the [text rules](org-templates.md#text-rules)). |
| 69113 | Uninstall only: an EXE uninstaller the package runs was still running after 30 minutes and was stopped, together with the processes it started. The detection tattoo stays, so Intune keeps reporting the app as installed. The PSADT log on the device names the uninstaller. (When only a process the uninstaller started is still running at 30 minutes, that process is stopped and the uninstaller's own exit code counts.) See [how the uninstall is guarded on the device](concepts.md#how-detection-uninstall-are-generated). |
| 1602 | The user deferred the installation (org template deferral), or a forced interactive mode found nobody signed in. Deliberately not mapped, so Intune reports it as failed. |

With PSAppDeployToolkit 4.2 the generated deploy script also sets `ExitWithMsiCodes`, so any restart
request is returned as 3010 (soft reboot); 4.1 ignores that setting.

**Detection rule:** one rule is created, by priority:

1. **Install tattoo (preferred):** the generated deploy script writes
   `HKLM\SOFTWARE\<Author>\<Vendor>\<App>\Version` at install time (64-bit registry view), so the
   rule checks that registry value **equals the packaged version**, so Intune confirms both presence
   *and* version.
2. **Capture fallback:** projects without a tattoo fall back to the **newest**
   `InstallationChanges_*.json` sandbox capture: a registry key (Uninstall keys preferred) or a
   machine-wide file path (`Program Files` locations ranked first; per-user profile paths are
   never used, since Intune detects as SYSTEM). The newest capture is used even when its install
   failed, so after a failed capture re-run it successfully (or remove the failed file from the
   project's `Documentation\` folder) before publishing.
3. **None:** the publish **stops** with a `W32T.NoDetectionRule` error before you are asked to sign
   in and before anything uploads: an app Intune cannot detect reports a failure on every device, or
   reinstalls forever. Re-create the project with an org template (for the tattoo) or run the install
   capture, then publish again. For an app nothing can describe (a per-user install, some MSIX
   packages), pass `-AllowNoDetectionRule` to create it without a rule, then add one in the portal
   before you assign it.

**App icon:** `Assets\AppIcon.png` (from winget, a manual `-IconPath`, or captured during the
install run) is normalized to a genuine PNG and attached as the app tile icon (`largeIcon`).
When none of those sources produced an icon, the file still contains the **PSADT default logo**
from the project scaffold, and that is what appears as the Intune tile. To use your own, drop a
PNG at `Assets\AppIcon.png` before publishing.

<!-- SCREENSHOT: the published app in the Intune portal showing tile icon, detection rule, and shell defaults -->

## What happens during upload

The app shell is created first, then the encrypted content is uploaded to Azure Storage in chunks,
committed, and linked to the app. The two waits (storage URI, commit) poll with exponential
back-off up to the timeout. When it finishes you get the app id and a direct portal link.
The wire protocol is deliberately not documented here: it is an implementation detail.

## Publishing updates

To publish the same package a second time as an **update app** (one that only applies to devices
that already have the app installed), pass `-AsUpdate` to `Publish-Win32ToolkitIntuneApp`, or
`-PublishUpdate` to `Invoke-Win32Toolkit` / `Export-Win32ToolkitIntuneWin`. The update app gets
`(Update)` appended to its display name (configurable) and a **requirement rule** (a PowerShell
presence check) that gates it to machines where the app already exists. Detection stays the
version-aware tattoo rule, so older installs get updated and detect once they reach this version.
If no requirement rule can be built, the publish fails fast rather than creating an app that would
apply to every device.
For a package with Enforce prior-install rules, the update app also applies to devices that have a prior install
one of those rules would remove (see [Packages that remove a prior install](#packages-that-remove-a-prior-install)).

**Re-publish behavior:** every publish creates a **new** app. Intune has no overwrite. To retire
an old version, delete it or configure supersedence in the portal.

The update app's requirement rule checks the install tattoo in **both** registry views (the native
64-bit key and `HKLM\SOFTWARE\WOW6432Node\...`), so devices installed by a package published before
this version (see below) still count as "already installed".

## Warnings before you publish

Packaging and publishing look at the project's test results and identity checks once more and
**warn**. They never stop a package or a publish, so read them before you assign the app. Each warning is
a sentence that starts with the project folder's name (`Publishing '<app>':` when you publish); the codes
below name the kinds of warning in these docs, and the warning text does not print them:

| Warning | Meaning | What to do |
|---|---|---|
| `INSTALL-FAILED` | The latest install/uninstall test failed (for example the app's own uninstall entry stayed: `AppArpGone-PostUninstall`). The warning names the failed checks. | Read the `InstallAssertions.log` it names, fix the package, run the test again. |
| `INSTALL-INCONCLUSIVE` | The latest install/uninstall test gave no verdict (closed early, timed out). | Run it again. |
| `UPDATE-FAILED` | The latest Update test from that installer technology failed. The warning names the failed assertions (for example `OldArpGone-PostUpdate`) and, when the update itself failed, its exit code and what it means. After the refusal of a Block prior-install rule (69101) it is a note: that outcome is intended (its `Requirement-PreUpdate` failure is by design: the update app's requirement detects only installs an Enforce rule names). A retry code (1618, 69107) means the run judged nothing; the warning names that code's causes. | Read the `UpdateAssertions.log` the warning names (in the failed run's own folder, `Sandbox\Logs\Runs\<run>\`, or `Sandbox\Logs\` for a run recorded before those folders existed) before you assign the app. |
| `ID-TECH-SWITCH` | An Update test saw the vendor's other installer technology (for example its NSIS EXE) stay registered after this package installed. | **Do not publish this package to devices that have the other technology:** they would get two registrations over one folder. Package the technology your devices already have (see [Installer technology](packaging.md#installer-technology)). |
| `ID-SIBLING-UNTESTED` | winget also ships another installer technology for this app, and the latest Update test from it did not pass (or none ran). | Run `Test-Win32ToolkitProject -Scenario Update -BaselineInstallerType Both`. Once the latest test from that technology passes, the warning goes away. The advice follows the failed run: after a Block rule's refusal (69101) it is a note (make the rule Enforce and prove it to remove that install); after a retry code, run it again; after 69102, widen the rule's version window (the warning prints the command, which keeps the rule's mode and lowest version) or test from an old version inside it; after 69111, remove what switches removal off on the test VM; when the rule's identity did not match the install on the test VM, replace the rule from that test's candidate (the warning prints the command); with a Report rule, that install stays next to the package by design (make it Enforce); when the run left a prior-install candidate, declare it (Block first), or, in a project created by an earlier win32-toolkit version, re-create the project and run the Update test again first. |
| `UNSAFE-CLEANUP` (publish only) | The project's uninstall cleanup paths fail the check that packaging enforces, so a package exported before this check deletes folders outside the app's own install folder. | Re-run the install capture, re-export, then publish. |
| `PRIOR-BLOCK-FLEET` | A **Block** prior-install rule: devices with that other installer technology fail this install (69101) until the rule is Enforce. | Assign the app to a pilot group first. |
| `PRIOR-NO-WELCOME` | An Enforce rule, but the org template turns the welcome dialog off: nothing closes the prior app before its removal, so devices where it runs retry (1618). | Turn the welcome dialog on in the org template, or accept the retries. |
| `PRIOR-PREDECESSOR-PUBLISHED` | An Enforce rule, and an earlier version of the app is published from this template. | Unassign the earlier app before you assign this one. |
| `PRIOR-ENFORCE-PILOT` | The package removes another install of the app as SYSTEM. | Pilot first; the warning names the kill switch (see [Packages that remove a prior install](#packages-that-remove-a-prior-install)). |
| `ID-PRIOR-OWN`, `PRIOR-CLASS-E` | A rule of the previous version was dropped because it names this package's own uninstall key; or the app belongs to a family whose versions install side by side (Python, .NET, ...). | Check that the right install is removed. |
| Other `ID-...` codes | The identity checks from packaging time (another technology, an earlier version of another technology, a changed detection key, a user-scope installer, ...), shown again. | See [Installer technology](packaging.md#installer-technology). |

They are shown **once per action**: `Export-Win32ToolkitIntuneWin -PublishIntune -PublishUpdate` prints
them once, not once per app, and a dry run (`-WhatIf`) prints them too. In the TUI, **Publish to
Intune** shows them in a panel before you pick which app to publish: red when an install/uninstall test
failed or gave no verdict, an Update test failed, a technology switch was seen, the cleanup paths are
unsafe or a prior-install rule fails, retries or reinstalls on devices (`PRIOR-BLOCK-FLEET`, `PRIOR-NO-WELCOME`,
`PRIOR-PREDECESSOR-PUBLISHED`), yellow for the other warnings.
When the cleanup paths are unsafe, the menu stops before asking which app to publish: packaging refuses
such a project until Finalize / refresh re-runs the capture (or, when `SupportFiles\AppConfig.json` cannot be
read, until you fix the file or re-create the project).
**Package and upload now?** still defaults to No.

**Packages exported before this version:** re-export them before you publish. Packaging now refuses a
project whose uninstall cleanup paths reach outside the app's own install folder, but an older
`.intunewin` still carries them. Publish warns `UNSAFE-CLEANUP` when the project's cleanup paths fail
the check, or cannot be checked because `SupportFiles\AppConfig.json` cannot be read (Windows
PowerShell 5.1 on the device may still read it). It reads the project, not the package: a package
exported before the project was re-captured is not detected, so re-export it anyway.

## Packages that remove a prior install

A package with **prior-install rules** ([Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md),
see [Prior installs](packaging.md#prior-installs-remove-another-installer-technology-before-installing)) refuses
(**Block**) or removes (**Enforce**) another installer technology of the app on the device before it installs.
Publishing such a package adds a few steps.

**The package must carry the rules that were checked.** Packaging refuses an Enforce rule that no Hyper-V Unattended
Update test proved, and every invalid rule. If you change a rule after packaging (a mode, a window, a re-run install
capture), publishing refuses the old `.intunewin` with `W32T.PackageNotReady` ("the prior-install rules changed after
Export"): package it again, then publish. A dry run (`-WhatIf`) checks this too, without signing in.

**Pilot first.** win32-toolkit never assigns an app. Assign a package with Enforce rules to a **pilot group** first,
watch the results, then widen it. Publishing reminds you of this and names the kill switch. Keep the app's maximum run
time at **60 minutes or more** (the default): one prior uninstaller may run up to 30 minutes before the install starts.

**Apps that would fight the removal.** After the sign-in, for a package with Enforce rules, publishing reads the
tenant's Win32 apps once and warns (it never stops) about:

- an app assigned **Required** whose detection rule looks for the prior install's uninstall key: that app reinstalls
  what this package removes, and devices end in exit code 69110. Unassign or retire it first;
- an earlier version of this app (recorded in the project folder of that version) that is still assigned
  **Required**: unassign it before you assign this one, or the old app reinstalls.

Only detection rules count: an app whose *requirement* rule looks for that key does not reinstall anything. If the
tenant cannot be read, you get one "could not check" warning, and if the list of apps comes back without the detection
rules of some Required apps, one "could not read the detection rules of N Required Win32 app(s)" warning that names
them (display name and app id, the first 10, then "and N more"): check those apps by hand. The publish goes on either
way.

**Vendor updaters.** Some apps update themselves with their own updater (Notepad++ ships one, `GUP.exe` in its
`updater` folder). If that updater installs the vendor's other installer technology again on a device where an Enforce
package removed it, every later install there ends in 69110 (or 69102 when it installed a newer version). For an
Enforce package, switch the app's own updater off on the devices that get it (the vendor documents how), keep the app
updated by publishing new packages, and clear the `Removed` marker on the affected devices (see the
[incident runbook](#incident-runbook)).

### Exit codes

The app is published with these return codes. All of them are **failed**, except 1618, which Intune retries:

| Code | Meaning | What to do |
|---|---|---|
| 69101 | The prior install is present and its rule is **Block**. | Decide: prove it and set the rule to Enforce, or keep blocking. |
| 69102 | A **newer** version of the prior install is present than the rule covers. | Package the next version (the rules are carried forward with a raised window). If the vendor's own updater keeps installing the prior technology, disable that updater for devices that get this package. |
| 69105 | A rule cannot be applied safely on this device: invalid data, the prior installed in another folder than the rule names, an uninstaller or folder that accounts other than SYSTEM, Administrators or TrustedInstaller can change, a device marker that cannot be written, or a 32-bit host. | Fix the data and package again, fix the folder's permissions, or set the rule to Block. |
| 69106 | This package's own product is already registered next to the prior install. | Clean the device up by hand: remove the other install (its own uninstaller, for example from Settings > Apps), then repair or reinstall this app. The next version of this package handles such a device itself when its MSI has a new ProductCode (a major upgrade, as Notepad++ ships): its own older product is no refusal there, so it removes the prior and upgrades. |
| 69107 | A restart is pending, or the removal needs one. | Nothing: the install runs after the restart. |
| 69108 | The prior's uninstaller failed, or ran longer than 30 minutes. | Check that uninstaller in the PSAppDeployToolkit log. |
| 69109 | The prior's uninstall key or main program file is still there after its uninstaller. | As 69108. |
| 69110 | The prior came back after this package removed it on this device. | Find what reinstalls it (a Required app, see above, or the vendor's updater), then clear the `Removed` marker (below). |
| 69111 | Removal is switched off on this device (`RemovePriorDisabled`). | Intended during an incident. |
| 69112 | The package's installer is missing or cannot be opened. | Package it again. |
| 1618 | The prior app is still running after the close-apps dialog, Windows Installer is busy, or the prior install changed while the dialog was open. | Nothing: Intune retries. |

A device whose prior install is not exactly the one a rule declares (another publisher, name or version) is left as it
is: the install goes on and the device gets a `LastSeen` marker.

### Device markers

Each device records what happened under `HKLM\SOFTWARE\<ScriptAuthor>\win32-toolkit` (`<ScriptAuthor>` is your org
template's script author):

| Value | Meaning |
|---|---|
| `LastRefusal` | `yyyy-MM-dd <code> <package version>` of the last refusal. |
| `PriorInstalls\<View>\<Key>\LastSeen` | The prior install was seen but not removed (not the declared one, a Report rule, or a planned removal). |
| `PriorInstalls\<View>\<Key>\Removed` (and `Version`) | This package removed that prior install on this date. |
| `RemovePriorDisabled` | The kill switch (you set it, below). |

Read them with an inventory or Remediations script for fleet visibility. **Run every such script as 64-bit**
("Run script in 64-bit PowerShell" = Yes, or `reg.exe ... /reg:64`): a 32-bit script reads
`HKLM\SOFTWARE\WOW6432Node\...` and does not see these values.

### Incident runbook

If removals go wrong on devices:

1. **Unassign the app, or exclude the affected group.** This is the fastest stop.
2. **Switch removal off** where the app stays assigned: a Remediations script that sets the DWORD
   `RemovePriorDisabled = 1` under `HKLM\SOFTWARE\<ScriptAuthor>\win32-toolkit`. Devices then refuse with 69111 instead
   of removing anything. The switch is read from both registry views, so a 32-bit script also works for this one value,
   but prefer 64-bit.
3. **Read** `LastRefusal`, the Intune Management Extension log and the PSAppDeployToolkit log of an affected device.
4. **Fix** the rule, package again, run the Hyper-V proof again, then publish the new package (pilot first).

To clear a `Removed` marker once the cause of a 69110 is fixed, delete the value
`HKLM\SOFTWARE\<ScriptAuthor>\win32-toolkit\PriorInstalls\<View>\<Key>\Removed` with a **64-bit** remediation
(`<View>` is `Native` or `Wow6432`, `<Key>` the prior's uninstall key name).

If the cause was the vendor's own updater installing the prior again **over this package's own MSI install** (Notepad++'s
updater does), clearing the marker is not enough for the same package version: the device then refuses with 69106 (its own
product is registered next to the prior install). Clean that device up by hand (see 69106 above), or wait for the next
version of the package.

## Apps published before this version

win32-toolkit 1.1.6 and older published every app with the command line
`powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install`
(and `Uninstall`). Under the 32-bit Intune Management Extension that starts a 32-bit PowerShell: a
PSAppDeployToolkit 4.2 package exits 60008 on every 64-bit device, and a 4.1 package writes its
install tattoo to `HKLM\SOFTWARE\WOW6432Node\<Author>\<Vendor>\<App>`, where the detection rule does
not look, so Intune reports "not detected" after a successful install. Publishing never edits an app
that is already in Intune, so those apps keep the old command line until you act.

**Recommended: rebuild, then republish.** Re-create the project with this version
([Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md), or
[New-Win32ToolkitManualApp](reference/New-Win32ToolkitManualApp.md) for a manual app: copy your
Install code out of `Invoke-AppDeployToolkit.ps1` first, because re-creating a project deletes its
folder), then publish it and retire the old app. Only a rebuilt project gets the new uninstall that
also removes the legacy `WOW6432Node` tattoo written by the old 32-bit launch.

**Stopgap: republish the existing project, or edit the command lines in the Intune portal.** Set the
install and uninstall command lines to `Invoke-AppDeployToolkit.exe -DeploymentType Install` and
`Invoke-AppDeployToolkit.exe -DeploymentType Uninstall` (the exe already ships in every `.intunewin`),
or package and publish the existing project again. This fixes install and detection (Required
assignments heal on their own), **not** the uninstall cleanup: the existing project's deploy script
is packaged unchanged (it shows as `legacy` in **Browse projects**, and packaging prints one warning
about it).

!!! warning "Stopgap caveat: the stale WOW6432Node key"

    After an uninstall by an existing (not rebuilt) project, the stale
    `HKLM\SOFTWARE\WOW6432Node\<Author>\<Vendor>\<App>` key remains on devices the old 32-bit launch
    installed. The update requirement checks both registry views, so it still matches there, and an
    **Update** app for that title can reinstall it on devices where it was removed. Use the stopgap
    only for titles without an Update app, or remove the key with a remediation script.

## Dependencies at publish time

Dependencies declared on the project (see [Dependencies](dependencies.md)) are resolved to real
Intune app **ids** before anything uploads, so a missing dependency is reported up front, not after
a 200 MB upload. Unresolvable ones are warned about and skipped; nothing is ever auto-published as
a side effect. The relationship is attached **after** the upload completes (Intune only allows it
then), and only to the install app, never to the `(Update)` app.

## Customer-facing documentation

To produce a one-page hand-over sheet (`Documentation.md`) for the packaged app, covering deployment
settings, detection method in plain English, captured-change summary and test history, run
[Export-Win32ToolkitDocumentation](reference/Export-Win32ToolkitDocumentation.md). The output is
customer-safe by default: no tenant id, no Intune app id, no raw host paths. Pass
`-IncludeIntuneIds` only for an **internal copy** (or when the customer owns the tenant) to add
the app id and a portal deep-link. In the test history, each Update test names the installer
technology and version it upgraded from (for example `Update (baseline: nullsoft exe, v8.8.9)`), and a
failed one lists its failed assertions.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| **403 when attaching a dependency** (app itself uploaded fine) | Your Intune RBAC role lacks the **Relate** permission on Mobile apps. A correct Graph scope is not enough. Ask an Intune admin to add Relate to your role, then re-attach in the portal. |
| **"Need admin approval" at sign-in** | The `DeviceManagementApps.ReadWrite.All` scope needs tenant admin consent, see [Authentication](#authentication). |
| **Timeout waiting for storage URI or commit** | Large packages take longer to server-side validate. Raise the wait: `-TimeoutSeconds` on the publisher, or `-PublishTimeoutSeconds 900` on `Export-Win32ToolkitIntuneWin` (default 300 s). |
| **An older app fails with 60008 everywhere, or installs but is "not detected"** | It still has the `powershell.exe -File` command line of win32-toolkit 1.1.6 or older. See [Apps published before this version](#apps-published-before-this-version). |
| **`W32T.NoDetectionRule`** | No install tattoo and no usable install capture. See the detection rule list in [What gets created](#what-gets-created). |
| **`W32T.PackageNotReady`** while packaging | The deploy script failed the packaging check (every problem and its fix is listed in the message). See [Packaging](packaging.md#the-package-check). |
| **`W32T.ProjectNotConfigured`** while packaging or publishing | The project's build stopped after its folder was created (a refused configuration, a failed download, no installer found), so it has no org template or installer configuration. There is no override: package the app again (`Invoke-Win32Toolkit` or `New-Win32ToolkitManualApp`, or the menu's Package an app), which replaces the folder. See [Packaging](packaging.md#the-package-check). |
| **`UNSAFE-CLEANUP` warning** while publishing | The package was exported before the cleanup-path check. See [Warnings before you publish](#warnings-before-you-publish). |
| **`W32T.PackageNotReady` "Prior install: the prior-install rules changed after Export"** while publishing | A prior-install rule (or the install capture) changed after the package was built. Package it again, then publish. See [Packages that remove a prior install](#packages-that-remove-a-prior-install). |
| **Exit codes 69101-69112** on devices | See [Exit codes](#exit-codes). |
