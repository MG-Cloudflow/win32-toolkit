# win32-toolkit documentation

<div class="tk-hero" markdown>

## Stop hand-building Intune packages

**win32-toolkit turns an app into a tested, branded, published Intune Win32 app.** It writes the
PSADT script, works out the detection rule and the uninstall by watching a real install, proves the
package in a throwaway VM, and uploads it. From a winget ID, or from your own installer.

[Get started](getting-started.md){ .md-button .md-button--primary }
[How it works](concepts.md){ .md-button }

</div>

## The job you do today

Packaging one app by hand is an afternoon. Find the silent switches. Write the PSADT script. Install
it somewhere to see what it registered. Hand-write a detection rule. Hope the uninstall works. Build
the `.intunewin`. Fill in the Intune form. Then do it again for the next app, and again next version.

The tedious parts are exactly the parts a machine is better at:

<div class="grid cards" markdown>

- :material-radar: **Detection rules you didn't have to guess**

    The toolkit installs the app in a disposable guest, diffs the machine before and after, and builds
    the rule from what actually happened, not from what a vendor's docs claim.

- :material-delete-sweep-outline: **An uninstall that actually uninstalls**

    Derived the same way, from the real install. MSI and MSIX get theirs without needing a capture
    at all.

- :material-flask-outline: **Proof before you ship**

    Install, uninstall, and upgrade-from-the-previous-version, replayed in a clean guest with real
    pass/fail assertions. Not "it worked on my machine".

- :material-palette-swatch-outline: **Consistent branding, configured once**

    An org template carries your company name, dialogs, logo, language, deploy-time scripts, and
    Intune defaults into every app you package for that customer.

</div>

## Prove it works before Intune ever sees it

This is the part that turns packaging from hopeful into repeatable. Every test runs in a **disposable
guest** that has never seen your app: Windows Sandbox (zero setup), or a Hyper-V VM that reverts to a
clean checkpoint between runs.

| Scenario | What it proves |
|---|---|
| **Install / Uninstall** | The app installs silently, your detection rule fires, and the uninstall removes it. Real assertions, a real verdict. |
| **Update** | The **previous** version is installed first, then yours upgrades over it. This is the scenario that catches the upgrade which only works on a clean machine. |
| **With dependencies** | Declared dependencies install first in the guest, in the same order Intune uses on a real device. |

The same guest run also produces the customer documentation and the app's icon, so it pays for itself
twice.

[Testing packages](testing.md){ .md-button }
[The Hyper-V test VM](hyperv-vm.md){ .md-button }

## Your apps, not just winget's

Most of what you deploy is not on winget: a vendor MSI, an in-house EXE, an MSIX from a supplier, an
installer that needs its payload folder beside it. **Those are first-class here, not a workaround.**

You supply the installer. From that point the flow is byte-for-byte the winget flow: capture,
uninstall logic, detection rule, tests, packaging, publish.

<div class="grid cards" markdown>

- :material-package-variant-closed: **Easy mode**

    An MSI, an MSIX, or an EXE whose silent switches you know. Nothing to author, the install is
    data-driven, and one command can take it all the way to Intune.

- :material-pencil-ruler: **Advanced mode**

    The EXE nobody has switches for. You write **only** the install region. The uninstall, detection,
    tests, and packaging all stay automated.

- :material-folder-open-outline: **Whole-folder installers**

    Point `-SourcePath` at a folder and it ships intact: transforms, configs, prerequisites, all of it.

- :material-tune-variant: **Yours to shape**

    Deploy-phase hook scripts, a shared org PowerShell module, custom dialogs and language, custom
    Intune defaults. Set once per template, applied to everything built from it.

</div>

[Manual apps](manual-apps.md){ .md-button }
[Org templates](org-templates.md){ .md-button }

## What one command does

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -RunTest InstallUninstall -PublishIntune
```

Downloads it, scaffolds PSADT v4, applies your branding, captures a real install in a disposable
guest, writes the detection rule and uninstall logic, proves both in a clean guest, packages the
`.intunewin`, and uploads it to Intune with the tile icon attached.

Prefer to click? `Show-Win32Toolkit` is the same pipeline behind a menu.

## Learn

<div class="grid cards" markdown>

- :material-rocket-launch: **[Getting started](getting-started.md)**

    Package Git for Windows end to end with the interactive menu. No PowerShell fluency needed.

- :material-lightbulb-on-outline: **[Concepts](concepts.md)**

    The pipeline, the folder tiers, the installer types, and how detection and uninstall get written.

</div>

## Guides

<div class="grid cards" markdown>

- :material-palette-outline: **[Org templates](org-templates.md)**

    Branding, dialogs, language, hook scripts, and Intune defaults, per customer.

- :material-package-variant: **[Manual apps](manual-apps.md)**

    Everything that is not on winget.

- :material-test-tube: **[Testing packages](testing.md)**

    Install/uninstall and update scenarios with real pass/fail assertions.

- :material-server: **[Hyper-V test VM](hyperv-vm.md)**

    The faster, opt-in alternative to Windows Sandbox.

- :material-graph-outline: **[App dependencies](dependencies.md)**

    "Install X first", enforced by Intune and replicated in your tests.

- :material-zip-box: **[Packaging](packaging.md)**

    Turning a project into an `.intunewin`, and what the staging optimizer strips.

- :material-cloud-upload: **[Publishing](publishing.md)**

    Uploading through Microsoft Graph: auth, detection rules, assignments.

</div>

## Reference

<div class="grid cards" markdown>

- :material-cog-outline: **[Configuration](configuration.md)**

    BasePath, the registry keys, folder tiers, and prerequisites.

- :material-console: **[Command reference](reference/README.md)**

    Every exported command, with all parameters and examples.

</div>

## Offline help

The command reference is generated from the module's built-in help, so the same content is always in
your console with no internet required:

```powershell
Get-Help Invoke-Win32Toolkit -Full
```
