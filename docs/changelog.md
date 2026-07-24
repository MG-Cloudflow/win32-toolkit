# Changelog

## 1.0.0 (2026-07-24)

The first release of win32-toolkit: end-to-end Win32 app packaging for Microsoft Intune, driven by a guided console UI or fully scriptable from PowerShell. From here on, every release and version bump on this page is generated automatically from [Conventional Commits](https://www.conventionalcommits.org).

### Features

* **winget packaging.** Discover an app, download its installer, and build a ready-to-ship package in a single command.
* **Manual (non-winget) apps.** Package any `.exe`, `.msi`, or `.msix`/`.appx` installer, including advanced hand-authored installs.
* **PSAppDeployToolkit v4 projects** scaffolded for every app and branded from reusable org templates: dialog style, accent, language, progress and balloon text, welcome and completion prompts, hook scripts, and logos.
* **Real install capture and testing** in a disposable Windows Sandbox or a reusable Hyper-V VM, so the detection rule, uninstall logic, and processes-to-close all come from what the installer actually did on a clean machine.
* **MSIX and APPX support**, including bundles and per-architecture handling.
* **Intune packaging** into the `.intunewin` format and **publishing** through Microsoft Graph, with app dependencies, requirement rules, minimum-OS and restart defaults, and icons.
* **Tenant-pinned publishing.** Connect and disconnect to Microsoft Intune from the UI, and refuse to publish into the wrong customer's tenant.
* **Customer-facing documentation** generated for each packaged app.
