---
description: "Automatically drive and validate a package's PSAppDeployToolkit dialogs in the Hyper-V test VM — screenshot every prompt and check the org branding, deferral, countdown, progress and completion dialogs against your template."
---

# Validating the installer UI

[Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md) proves a package **installs and
detects** correctly. This command proves the **dialogs a device user actually sees** are right:
the org branding, the deferral offer, the close-processes countdown, the progress text, and the
completion prompt — all checked against the org template the app was branded from.

[Test-Win32ToolkitProjectUI](reference/Test-Win32ToolkitProjectUI.md) runs the deploy in the Hyper-V
test VM, drives every PSAppDeployToolkit dialog automatically with UI Automation, screenshots each one,
and validates a structured log of what it saw against your template. No operator is needed — it clicks
the buttons itself.

```powershell
Test-Win32ToolkitProjectUI -ProjectPath 'C:\Win32Apps\Projects\Contoso\Firefox_x64_130.0'
```

## What it does

1. Reverts the VM to its clean checkpoint and copies the project in.
2. Launches the PSADT deploy **in the interactive user session** (a GUI needs a real desktop — the same
   reason the Hyper-V golden image auto-logs-on).
3. For each dialog it: anchors on the Fluent window, takes a screenshot, records what the dialog shows
   (title, subtitle, buttons, deferrals, countdown), and clicks the intended button — **Install** by
   default.
4. Copies the screenshots and the state log back under the project's `Sandbox\` folder.
5. Compares what it saw to the org template and prints a **PASS / WARN / FAIL / GAP** report.

Results land in the project:

- `Sandbox\Shots\` — one PNG per dialog, named in order (`01_Welcome_…png`, `02_Progress_…png`, …).
- `Sandbox\Logs\uidriver-state.log` — the structured record the checks are made from.

## Hyper-V only

This is a **Hyper-V-only** feature and needs the same setup as an unattended Hyper-V test:
a built [test VM](hyperv-vm.md) that auto-logs-on, an elevated host, and a saved guest credential.
Windows Sandbox has no persistent interactive session to drive, so the command refuses any other backend
rather than falling back. If Hyper-V isn't ready, build the VM first with `New-Win32ToolkitTestVM`.

## Reading the report

| Result | Meaning |
|---|---|
| **PASS** | The dialog was reached and matched the template (e.g. the subtitle shows your company name; the Defer button is present with the configured count; the completion prompt used your button label). |
| **WARN** | Expected, but legitimately skippable — for example the Welcome dialog is skipped when nothing needs closing, or the countdown wasn't shown because no target app was running. |
| **FAIL** | A real mismatch — e.g. the completion prompt is enabled in the template but never appeared, or deferral is enabled but no Defer button was offered. |
| **GAP** | A **visual** property UI Automation can't read from a window — the accent color, the org logo image, the rendered language, and the Windows toast. Open the screenshots in `Sandbox\Shots\` and confirm these by eye. |

The `GAP` checks are deliberate: some branding can only be judged by looking. That's what the captured
PNGs are for.

## Options

| Option | Effect |
|---|---|
| `-IncludeDefer` | Also run a pass that clicks **Defer** and confirms the deferral path is offered. |
| `-IncludeUninstall` | Also run an **Uninstall** pass and validate the uninstall Welcome dialog. |
| `-CaptureHostConsole` | Additionally capture the VM console from the host on a cadence into `Sandbox\HostShots\` (a fallback view; the in-guest screenshots are primary). |
| `-TemplateName` | Validate against a specific org template. By default it's resolved from the project's template folder. |

Each requested pass is an **independent** run that reverts to the clean checkpoint first, so Install,
Defer, and Uninstall never contaminate one another.

## When to use which test

- **Does it install and detect?** → [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md)
  (`InstallUninstall` / `Update`).
- **Do the prompts look and read right?** → this command.

They're complementary: one validates the install *result*, the other validates the install *experience*.
