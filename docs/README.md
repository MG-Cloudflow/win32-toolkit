# win32-toolkit documentation

<div class="tk-hero" markdown>

**Package Win32 apps for Microsoft Intune — end to end.** From a winget ID or your own
installer to a tested, branded, published Intune app: capture, detection, uninstall logic,
`.intunewin`, and Graph upload, all automated.

[Get started](getting-started.md){ .md-button .md-button--primary }
[How it works](concepts.md){ .md-button }

</div>

## Learn

<div class="grid cards" markdown>

- :material-rocket-launch: **[Getting started](getting-started.md)**

    Tutorial: package Git for Windows end-to-end with the interactive menu — no PowerShell fluency needed.

- :material-lightbulb-on-outline: **[Concepts](concepts.md)**

    How the pipeline works, where every file lands on disk, and how detection/uninstall logic is generated.

</div>

## Guides

<div class="grid cards" markdown>

- :material-palette-outline: **[Org templates](org-templates.md)**

    Per-customer branding and PSADT dialog defaults, and how templates group your output folders.

- :material-package-variant: **[Manual apps](manual-apps.md)**

    Packaging apps that are not in winget — you supply the installer, the rest of the flow is identical.

- :material-test-tube: **[Testing packages](testing.md)**

    Proving install/uninstall/update work in a disposable Windows guest with real pass/fail assertions.

- :material-server: **[Hyper-V test VM](hyperv-vm.md)**

    The opt-in, faster alternative to Windows Sandbox: one persistent VM reverted to a warm checkpoint.

- :material-graph-outline: **[App dependencies](dependencies.md)**

    Declaring "install X first" so Intune enforces it and local tests replicate it.

- :material-zip-box: **[Packaging](packaging.md)**

    Turning a finished project into an `.intunewin` file, and what the staging optimizer does.

- :material-cloud-upload: **[Publishing](publishing.md)**

    Uploading the packaged app to Intune via Microsoft Graph — auth, detection rules, assignments.

</div>

## Reference

<div class="grid cards" markdown>

- :material-cog-outline: **[Configuration](configuration.md)**

    Every persistent setting: BasePath, registry keys, folder tiers, and environment prerequisites.

- :material-console: **[Command reference](reference/README.md)**

    Generated pages for every exported command, with all parameters and examples.

</div>

## Offline help

The command reference is generated from the module's built-in help, so the same content is
always available in your console without internet access:

```powershell
Get-Help Invoke-Win32Toolkit -Full
```
