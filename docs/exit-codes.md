---
description: "What each exit code means in Intune, on devices and in tests, and where to find the logs."
---

# Exit codes and logs

An [exit code](glossary.md#exit-code) is the number a program returns when it ends. This page
explains the exit codes of win32-toolkit packages and where to find the logs.

## Where to find logs

### On your PC

The [install capture](glossary.md#install-capture) records what the installer changes while you package
the app. Every package runs on [PSAppDeployToolkit (PSADT)](glossary.md#psadt), the install engine
inside the package.

The paths below start in the project folder, `<base folder>\Projects\<template>\<project>`.

| What | Where |
|---|---|
| Install capture: the changes and its log | `Documentation\InstallationChanges_<time>.json` and `Documentation\Targeted_Documentation_Log_<time>.txt` |
| PSADT and MSI logs of the install capture | `Sandbox\Logs\Runs\<time>_Capture\` |
| All logs of one test run | `Sandbox\Logs\Runs\<time>_<scenario>\` |
| Exit codes of the last test command | `Sandbox\Logs\PsadtExitCodes.log` |
| Results of your tests, newest last | `Documentation\TestResults.json` |

The console prints each run folder after `Run logs` or `Capture logs`. Hyper-V tests use the same `Sandbox\Logs`
folder.

A run folder holds the check log (`InstallAssertions.log` or `UpdateAssertions.log`), the PSADT and MSI logs, and the
exit codes of that run. Read it first, because the files directly in `Sandbox\Logs\` mix several runs.

### On a device

The [Intune Management Extension](glossary.md#intune-management-extension) is the Intune agent that
installs Win32 apps.

| What | Where |
|---|---|
| PSADT log | The **Log path** of your [org template](org-templates.md#all-questions-and-their-defaults). The default is `$envWinDir\Logs\Software`, that is `C:\Windows\Logs\Software`. |
| Intune Management Extension logs | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs`, for example `AppWorkload.log` (a general Microsoft fact) |

## Codes Intune treats as success or retry

Each app the toolkit publishes has a list of [return codes](glossary.md#return-code): the exit
codes that Intune knows. The meanings below are general Windows facts.

| Code | Intune result | What it means |
|---|---|---|
| 0 | Success | It worked. |
| 1707 | Success | Windows Installer finished the install. |
| 3010 | Soft reboot | It worked, but the device needs a restart. |
| 1641 | Hard reboot | It worked, and the installer started a restart. |
| 1618 | Retry | Another install was busy. Intune tries again later. |

Intune reports every other code as failed. You can change the list in the Intune admin center.

## PSAppDeployToolkit codes

The [deploy script](glossary.md#deploy-script) `Invoke-AppDeployToolkit.ps1` installs and uninstalls
the app. If it stops with a problem, Intune reports one of these codes as failed.

| Code | What happened | What to do |
|---|---|---|
| 60001 | An error in the deploy script. For example, the installer failed, or your own code from the org template failed. | Read the PSADT log on the device. It names the error. |
| 60008 | PSADT could not start. Often the app was published by win32-toolkit 1.1.6 or older. | See [Fix apps that are already in Intune](maintain-toolkit.md#fix-apps-that-are-already-in-intune). |
| 1602 | The user postponed the install. | Nothing, if you allow deferrals. Intune reports it as failed. |
| 69113 | During an uninstall, the package stopped the app's EXE uninstaller after 30 minutes. Intune still reports the app as installed. | Check why the uninstaller does not finish. The PSADT log names the uninstaller. |
| 69114 | The deploy script and `SupportFiles\AppConfig.json` name different kinds of installer, for example after a hand edit. Nothing was installed. | Undo the edit, or [re-create](glossary.md#re-create) the project. |

The toolkit refuses org template text that would cause 60001 or 60008, for example a `$` sign before a letter. See
[Text rules](org-templates.md#text-rules).

A [deferral](glossary.md#deferral) lets the user postpone the install. By default, a new org template
allows 3 deferrals. Never add `-DeployMode Interactive` to the install command in Intune. With nobody signed in, PSADT
then exits with 1602.

The [maximum run time](glossary.md#maximum-run-time) is how long Intune lets the install or uninstall
run. Keep it above 30 minutes, or Intune stops the uninstall first and reports a timeout instead of 69113. The default
is 60 minutes.

## Prior-install codes

A [prior install](glossary.md#prior-install) is the same app, installed on a device by another kind of
installer. A [prior-install rule](glossary.md#prior-install-rule) tells the package what to do with it:
Block stops the install, and Enforce removes the prior install first.

Every app that the toolkit publishes lists these codes as failed, even an app without rules. This does no harm. A
package without rules never returns them.

| Code | What happened | What to do |
|---|---|---|
| 69101 | A Block rule found the prior install. | Keep blocking, or change the rule to Enforce and [prove it](prior-installs-enforce.md#prove-the-rule). |
| 69102 | The prior install is newer than the rule covers. | Package the newer version. Check if the app's own updater installed it. |
| 69105 | The rule cannot be used safely, for example the prior install is in another folder. | Fix the rule or the folder permissions, or use Block. |
| 69106 | This package's own product is already installed next to the prior install. | Clean up the device by hand. |
| 69107 | A restart is pending, or the removal needs one. | Nothing. The install runs after the restart. |
| 69108 | The prior install's uninstaller failed, or ran longer than 30 minutes. | Read the PSADT log. |
| 69109 | The prior install is still there after its uninstaller. | Read the PSADT log. |
| 69110 | The prior install came back after this package removed it. | See [Clear a 69110](prior-installs-devices.md#clear-a-69110). |
| 69111 | The [kill switch](prior-installs-devices.md#stop-all-removals-with-the-kill-switch) is on. | Nothing, if you turned it on for an incident. |
| 69112 | The package's installer is missing or cannot be opened. | Build the package again. |

With an Enforce rule, 1618 (retry) can also mean that the old app was still open after PSADT asked to close it.

The code 69103 is not an exit code. A PSADT log line with it ends with `(code 69103; the install goes on)`. The
code means that the registry key of a rule belongs to another install. The package does not touch that install.

Refusal lines in the PSADT log start with `win32-toolkit prior-check` or `win32-toolkit remove-prior`. For the registry
values on the device and the incident runbook, see [Prior installs on devices](prior-installs-devices.md).

## Codes you see only in tests

Some of these codes come from the [Hyper-V test VM](glossary.md#hyper-v-test-vm), a virtual machine
(VM) that the toolkit resets before each test. There, the console prints the code in a warning that starts with
`Guest phase` (a step of the test inside the VM).

| Code | What happened | What to do |
|---|---|---|
| 1460 | The toolkit's test runner stopped the package at its time limit. Often a PSADT dialog was waiting for a user. | Run the test again and watch it. See [Interactive or unattended](testing.md#interactive-or-unattended). |
| 267009 | A step on the test VM was still running at its time limit and was stopped. | Run the test again. |
| 267011 | A step on the test VM never started. | [Check that the VM is ready](hyperv-vm.md#check-that-the-vm-is-ready). |

After 267009 or 267011, the test usually gives no result: it is [Inconclusive](glossary.md#inconclusive).

On the Hyper-V test VM, 69113 shows in a `Guest phase` warning. See
[PSAppDeployToolkit codes](exit-codes.md#psappdeploytoolkit-codes).

## Read the exit-code log

`Sandbox\Logs\PsadtExitCodes.log` has one line for each install or uninstall in a test. After each run, the console
prints the lines of that run in green (`Success`, `SoftReboot`, `HardReboot`) or red. The toolkit starts a new file each
time a test command starts.

```text title="A line in PsadtExitCodes.log"
[2026-10-16 10:12:03Z] app Install parent=x86-cmd exit=0 result=Success
```

An [update test](glossary.md#update-test) installs an old version first and then your package over it.
The console calls the old version the baseline. A [dependency](glossary.md#dependency) is another app
that must be installed first.

| Field | Example | What it means |
|---|---|---|
| Time | `[2026-10-16 10:12:03Z]` | When the step ended, in UTC. Run folder names use the time of your PC. |
| Label | `app` | `app` is your package, `baseline` the old version, `update` your package over it, `dep:<name>` a dependency. |
| Action | `Install` | `Install` or `Uninstall`. |
| Parent | `parent=x86-cmd` | `x86-cmd` as Intune does, `x64-direct` directly, `vendor` or `direct` an installer without PSADT, `native-cmd` not exactly as Intune does. |
| Exit code | `exit=0` | The exit code. |
| Result | `result=Success` | `Success`, `SoftReboot`, `HardReboot`, `Retry`, `Timeout` (1460) or `Failed` (any other code). |

Each test run starts with a line that ends with `-- test run <run folder> --`.
