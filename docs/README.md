# win32-toolkit documentation

Everything you need to package Win32 apps for Microsoft Intune with win32-toolkit — from
first run to publishing. Start with **Getting started** if this is your first time; use
**Concepts** when you want to understand what the pipeline is actually doing.

## Learn

| Page | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | Tutorial: package Git for Windows end-to-end with the interactive menu — no PowerShell fluency needed. |
| [Concepts](concepts.md) | How the pipeline works, where every file lands on disk, and how detection/uninstall logic is generated. |

## Guides

| Page | What it covers |
| --- | --- |
| [Org templates](org-templates.md) | Per-customer branding and PSADT dialog defaults, and how templates group your output folders. |
| [Manual apps](manual-apps.md) | Packaging apps that are not in winget — you supply the installer, the rest of the flow is identical. |
| [Testing packages](testing.md) | Proving install/uninstall/update work in a disposable Windows guest with real pass/fail assertions. |
| [Hyper-V test VM](hyperv-vm.md) | The opt-in, faster alternative to Windows Sandbox: one persistent VM reverted to a warm checkpoint. |
| [App dependencies](dependencies.md) | Declaring "install X first" so Intune enforces it and local tests replicate it. |
| [Packaging](packaging.md) | Turning a finished project into an `.intunewin` file, and what the staging optimizer does. |
| [Publishing](publishing.md) | Uploading the packaged app to Intune via Microsoft Graph — auth, detection rules, assignments. |

## Reference

| Page | What it covers |
| --- | --- |
| [Configuration](configuration.md) | Every persistent setting: BasePath, registry keys, folder tiers, and environment prerequisites. |
| [Command reference](reference/README.md) | Generated pages for every exported command, with all parameters and examples. |

## Offline help

The command reference is generated from the module's built-in help, so the same content is
always available in your console without internet access:

```powershell
Get-Help Invoke-Win32Toolkit -Full
```
