# Changelog

## [1.1.5](https://github.com/MG-Cloudflow/win32-toolkit/compare/v1.1.4...v1.1.5) (2026-09-07)


### Bug Fixes

* **winget:** parse the search table by header column offsets so versions resolve ([662731c](https://github.com/MG-Cloudflow/win32-toolkit/commit/662731c7a8be40da0154cd1ff9822034549846a5))

## [1.1.4](https://github.com/MG-Cloudflow/win32-toolkit/compare/v1.1.3...v1.1.4) (2026-09-07)


### Bug Fixes

* **tui:** stop capturing TUI screen output so Settings cannot corrupt the base path ([14508b1](https://github.com/MG-Cloudflow/win32-toolkit/commit/14508b1dbc5e462fa277ac866f35a64ddbbd25be))
* **tui:** stop capturing TUI screen output so Settings cannot corrupt the base path ([ccafdc1](https://github.com/MG-Cloudflow/win32-toolkit/commit/ccafdc1672d07478d458cfdf4e86d69ca4686975)), closes [#67](https://github.com/MG-Cloudflow/win32-toolkit/issues/67)

## [1.1.3](https://github.com/MG-Cloudflow/win32-toolkit/compare/v1.1.2...v1.1.3) (2026-08-31)


### Bug Fixes

* **hyperv:** make the AutoLogon re-checkpoint action repair a half-provisioned VM ([0e3fe7e](https://github.com/MG-Cloudflow/win32-toolkit/commit/0e3fe7ef59603bcb521654e4ae19701fbff8ed93))
* **hyperv:** make the AutoLogon re-checkpoint action repair a half-provisioned VM ([60107a0](https://github.com/MG-Cloudflow/win32-toolkit/commit/60107a00e357b379eef4dda930efa562087a074e))

## [1.1.2](https://github.com/MG-Cloudflow/win32-toolkit/compare/v1.1.1...v1.1.2) (2026-08-04)


### Bug Fixes

* **winget:** resolve package Ids locale-independently (closes [#60](https://github.com/MG-Cloudflow/win32-toolkit/issues/60)) ([7fdb3f6](https://github.com/MG-Cloudflow/win32-toolkit/commit/7fdb3f628542c0fdf3e80aac68eb312a0305f65e))
* **winget:** resolve package Ids locale-independently (issue [#60](https://github.com/MG-Cloudflow/win32-toolkit/issues/60)) ([7edba46](https://github.com/MG-Cloudflow/win32-toolkit/commit/7edba46e750f9a9dbd73faa95cb302de3e043e7f))

## [1.1.1](https://github.com/MG-Cloudflow/win32-toolkit/compare/v1.1.0...v1.1.1) (2026-07-25)


### Bug Fixes

* **tui:** UTF-8 rendering, wrap long health cells, stop Spectre output leaking ([5ae604e](https://github.com/MG-Cloudflow/win32-toolkit/commit/5ae604e6a040bec1b55e3e6d656c5e98d89473c4))
* **tui:** UTF-8 rendering, wrap long health cells, stop Spectre output leaking ([27126de](https://github.com/MG-Cloudflow/win32-toolkit/commit/27126de2d2f08a45eea6278987112a270508d1af))

## [1.1.0](https://github.com/MG-Cloudflow/win32-toolkit/compare/v1.0.1...v1.1.0) (2026-07-25)


### Features

* in-app update check + automated PowerShell Gallery publishing ([8e2b676](https://github.com/MG-Cloudflow/win32-toolkit/commit/8e2b676239b4e4b2832940304421f8c1c1353d46))
* in-app update check + automated PowerShell Gallery publishing ([83ef36a](https://github.com/MG-Cloudflow/win32-toolkit/commit/83ef36a31d58b2ba2fe611831d79c95f0540a0fd))
* show the installed version under the TUI banner ([58ed996](https://github.com/MG-Cloudflow/win32-toolkit/commit/58ed996aaa825806583a7e52c34d5dbdaf6b3abc))

## 1.0.1 (2026-07-24)

### Bug Fixes

* **org-template:** the Organisation Template wizard no longer crashes with "You cannot call a method on a null-valued expression" on a machine where PSAppDeployToolkit is not installed yet. This blocked first-run and new-template creation for every new user ([#49](https://github.com/MG-Cloudflow/win32-toolkit/issues/49)).

This release also introduces the automated release process and this changelog page. From here on, versions are bumped and published automatically from [Conventional Commits](https://www.conventionalcommits.org).

## 1.0.0 (2026-07-24)

The first release of win32-toolkit: end-to-end Win32 app packaging for Microsoft Intune, driven by a guided console UI or fully scriptable from PowerShell.

### Features

* **winget packaging.** Discover an app, download its installer, and build a ready-to-ship package in a single command.
* **Manual (non-winget) apps.** Package any `.exe`, `.msi`, or `.msix`/`.appx` installer, including advanced hand-authored installs.
* **PSAppDeployToolkit v4 projects** scaffolded for every app and branded from reusable org templates: dialog style, accent, language, progress and balloon text, welcome and completion prompts, hook scripts, and logos.
* **Real install capture and testing** in a disposable Windows Sandbox or a reusable Hyper-V VM, so the detection rule, uninstall logic, and processes-to-close all come from what the installer actually did on a clean machine.
* **MSIX and APPX support**, including bundles and per-architecture handling.
* **Intune packaging** into the `.intunewin` format and **publishing** through Microsoft Graph, with app dependencies, requirement rules, minimum-OS and restart defaults, and icons.
* **Tenant-pinned publishing.** Connect and disconnect to Microsoft Intune from the UI, and refuse to publish into the wrong customer's tenant.
* **Customer-facing documentation** generated for each packaged app.
