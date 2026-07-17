# Manual apps (not in winget)

Plenty of apps never make it into winget: a vendor MSI, an in-house installer, a legacy EXE. For those,
[New-Win32ToolkitManualApp](reference/New-Win32ToolkitManualApp.md) replaces the winget search/download step:
**you supply the installer, and everything after that is identical to the winget flow**. That means Sandbox/Hyper-V
install capture, auto-generated uninstall logic, detection rule, `.intunewin` packaging, Intune publish, and
the same test scenarios.

Input is hybrid: pass what you know as parameters, and the command prompts for any missing required field
(name, version, architecture, installer path).

## Easy vs Advanced: one decision

The only question is whether the toolkit can install your app **silently and unattended** on its own:

| Mode | When it applies | What you do |
|---|---|---|
| **Easy** | An **MSI** (installed via PSADT Zero-Config), an **MSIX/APPX** (installed via `Add-AppxPackage`/provisioning), or an **EXE where you know the silent switches** (`-SilentArgs`) | Nothing to author. The install is data-driven and the flow can run end to end |
| **Advanced** | An **EXE with no known silent switches**, or you pass `-Advanced` explicitly | You author the Install region of the deploy script yourself, then finalise with [Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md) |

The **uninstall stays automated in both modes**, never from anything you write. Where it comes from
depends on the installer: an **MSI** is removed by PSADT Zero-Config from the MSI itself, an
**MSIX/APPX** by its package identity, and an **EXE** from what the install capture observed. Only the
EXE case needs the capture to have worked.

"Easy" means there is no install *script* for you to write. For an **MSIX/APPX** there is still one
prerequisite outside the toolkit: the package must be **signed and the certificate trusted on your
devices**, or Windows refuses to install it. See
[Installer types](concepts.md#installer-types-msi-exe-msix-appx). A package you got from winget is
already signed; your own LOB package is not.

## SourcePath: file or folder

`-SourcePath` accepts either:

| You pass | What happens |
|---|---|
| A **file** (`.msi`, `.exe`, `.msix`, `.appx`) | Copied into the project's `Files\` folder; its type decides Easy vs Advanced |
| A **folder** | Copied **wholesale** into `Files\`. Use this for installers that need their payload beside them (config files, MST transforms, prerequisite DLLs). The installer inside the folder is auto-detected |

If no installer file (msi/exe/msix/appx) is found after the copy, the command stops with an error.

## Easy mode, end to end

To package an MSI, test it, and build the `.intunewin` in one command:

```powershell
New-Win32ToolkitManualApp -Name 'Qastor' -Version '3.16.0' -Architecture x64 `
    -SourcePath 'C:\src\qastor.msi' -TemplateName 'Contoso' `
    -RunTest InstallUninstall -PackageIntune
```

An EXE works the same way as long as you supply its silent switches:

```powershell
New-Win32ToolkitManualApp -Name 'Acme Reader' -Version '7.1' -Architecture x64 `
    -SourcePath 'C:\src\acme-setup.exe' -SilentArgs '/S /norestart' -TemplateName 'Contoso'
```

Without `-Continue` (or `-RunTest` / `-PackageIntune` / `-PublishIntune`, which imply it), the second
example only **scaffolds** the project. It prints the exact `Complete-Win32ToolkitManualApp` line to run
when you are ready to capture, test, and package.

The project lands under `Projects\<Template>\<Name>_<arch>_<version>`, the same tier layout as winget
projects (see [concepts.md](concepts.md)).

## Advanced mode: you write the install

To package an EXE with no silent switches (or anything the data-driven install can't handle):

```powershell
# 1. Scaffold: the Install region is left for you
New-Win32ToolkitManualApp -Name 'Legacy CAD' -Version '12.0' -Architecture x64 `
    -SourcePath 'C:\src\LegacyCAD\' -Advanced -TemplateName 'Contoso'

# 2. Edit the Install region (Pre-Install / Install / Post-Install) in:
#    <BasePath>\Projects\Contoso\Legacy_CAD_x64_12.0\Invoke-AppDeployToolkit.ps1

# 3. Finalise: capture → uninstall logic → test → package
Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Legacy_CAD_x64_12.0' `
    -RunTest InstallUninstall -PackageIntune
```

Two things to know about the script you edit:

- It runs on target devices under **Windows PowerShell 5.1**, so avoid PowerShell 7-only syntax.
- Only touch the **Install** region. The Uninstall region is filled in automatically during finalise,
  from the changes the capture observed.

`Complete-Win32ToolkitManualApp` also works on **any** existing project (manual or winget), so you can
re-finalise a project after hand edits at any time.

## It rejoins the same pipeline

Manual apps are not a lesser path. From the capture onward, the flow is byte-for-byte the winget flow:

```mermaid
flowchart LR
    A[Your installer] --> B[PSADT scaffold + org template]
    B --> C[Sandbox / Hyper-V install capture]
    C --> D[Uninstall logic + detection rule]
    D --> E[Tests]
    E --> F[.intunewin]
    F --> G[Intune publish]
```

- **Dependencies**: `-DependsOn 'winget:Microsoft.VCRedist.2015+.x64'` (or `project:` / `intune:`
  references) works exactly as in the winget flow, including being installed in the test guest **before**
  your app, the same order Intune uses on a real device. See [dependencies.md](dependencies.md).
- **Tests, packaging, publishing**: [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md),
  [Export-Win32ToolkitIntuneWin](reference/Export-Win32ToolkitIntuneWin.md) and
  [Publish-Win32ToolkitIntuneApp](reference/Publish-Win32ToolkitIntuneApp.md) treat the project like any other.
- **Branding and icon**: the org template applies as usual; an operator-supplied `-IconPath` is kept even
  when the capture extracts an icon from the installed app.

## The Update-test caveat

The `Update` test scenario normally pulls an **older winget version** to upgrade from, which a manual app
does not have. Instead, point the test at a **locally packaged older project** as the baseline:

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Legacy_CAD_x64_12.0' `
    -Scenario Update -BaselineProject 'Contoso\Legacy_CAD_x64_11.0'
```

(`-BaselineProjectPath` takes a full path instead.) Details in [testing.md](testing.md). In the TUI, the
Update flow prompts for the baseline automatically.

## The TUI path

In [Show-Win32Toolkit](reference/Show-Win32Toolkit.md), choose **"Package a manual app"**. It asks the same
questions (name, version, architecture, installer path, silent switches, template, dependencies) and shows
the same review panel as the winget flow, then follows the Easy or Advanced path described above.

<!-- SCREENSHOT: the TUI "Package a manual app" wizard with the review panel visible -->
