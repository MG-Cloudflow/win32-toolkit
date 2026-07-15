# win32-toolkit

A PowerShell module that automates the end-to-end process of packaging Win32 applications for Microsoft Intune deployment using the **PSAppDeployToolkit (PSADT) v4** framework.

The module exposes an interactive UI plus a set of commands that cover the full packaging pipeline:

| Command | Purpose |
|---|---|
| `Show-Win32Toolkit` | **Launch the interactive, menu-driven UI over the whole pipeline** |
| `Invoke-Win32Toolkit` | Search, download, scaffold, document, and optionally test, package, and publish a winget app |
| `New-Win32ToolkitManualApp` | Package an app that is **not** in winget (you supply the installer) |
| `Complete-Win32ToolkitManualApp` | Finalise a scaffolded project (sandbox capture → uninstall → test/package/upload) |
| `Test-Win32ToolkitProject` | Run test scenarios (Windows Sandbox or a Hyper-V VM) against any existing PSADT project |
| `Export-Win32ToolkitIntuneWin` | Clean up and compile a project into a ready-to-upload `.intunewin` file |
| `Publish-Win32ToolkitIntuneApp` | Upload a `.intunewin` file directly to Microsoft Intune via the Graph API |
| `Set-Win32ToolkitAppDependency` | Declare apps that Intune must install **before** this one (e.g. a VC++ redistributable) |
| `Export-Win32ToolkitDocumentation` | Write a clean, customer-facing `Documentation.md` for a packaged project (app info, deployment, tests) |

---

## Interactive UI (recommended)

Prefer not to remember parameters? Launch the guided, menu-driven UI:

```powershell
Import-Module C:\path\to\win32-toolkit\win32-toolkit.psd1
Show-Win32Toolkit
```

…or **double-click `Launch-Win32Toolkit.cmd`** — it opens straight into the menu, no PowerShell knowledge needed.

Built on [PwshSpectreConsole](https://pwshspectreconsole.com/) (offered for a one-time install on first launch), the UI covers the whole pipeline with validated prompts, confirmations, and a prerequisite health check:

- **Package an app** — from winget (search) or a **manual** installer (easy, or advanced where you write the install logic)
- **Work with an existing project** — test / package / publish (publishing is gated behind a confirmation)
- **Browse projects**, **manage org templates**, and **Settings** (base folder)

Requires PowerShell 7.2+ and an interactive console window.

---

## Requirements

| Requirement | Details |
|---|---|
| **PowerShell** | **7.2 or later** (PowerShell 7). Windows PowerShell 5.1 is not supported for running the module. |
| **Winget** | Windows Package Manager must be installed and in `$PATH`. Included in Windows 10 21H1+ and Windows 11. |
| **PSAppDeployToolkit** | v4.x from the PowerShell Gallery. Prompted to install automatically on first run if absent. |
| **Test/capture backend** | Documentation capture and test scenarios run in a **backend**. Default: **Windows Sandbox** — enable via *Windows Features → Windows Sandbox* (Windows 10/11 Pro/Enterprise/Education). Opt-in alternative: a provisioned **Hyper-V VM** (faster; `New-Win32ToolkitTestVM` to provision, then `-Backend HyperV` or the TUI's *Hyper-V test VM* screen). The backend is resolved per run, falling back to Sandbox if the VM isn't ready. Pick the VM's CPU/memory at provision time, or change them later on the existing VM with **`Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB`** (or the TUI's *Change VM resources* option) — it reconfigures the hardware and re-freezes the clean-base checkpoint in minutes, without rebuilding from ISO; requests above the host's CPU/RAM are refused. |
| **Internet access** | Required to search Winget, download packages, check PSGallery, and download IntuneWinAppUtil.exe. |
| **Administrator rights** | Recommended. Required if `BasePath` is under a system-protected location. |
| **Microsoft.Graph.Authentication** | Required only for `Publish-Win32ToolkitIntuneApp` / `-PublishIntune`. Installed automatically on first use when you agree to the prompt. Install manually with `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser`. |

---

## Installation

### Option A — Import by path

```powershell
Import-Module C:\path\to\win32-toolkit\win32-toolkit.psd1
```

### Option B — Add to PSModulePath

```powershell
$dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\win32-toolkit'
Copy-Item -Path C:\path\to\win32-toolkit -Destination $dest -Recurse
Import-Module win32-toolkit
```

> **Downloaded as a ZIP?** Extracted files carry the Mark-of-the-Web, so under `RemoteSigned` the very
> first `Import-Module` may show a single "Do you want to run?" prompt — answer **[R] Run once** and the
> module unblocks all of its own files; every later file and session loads silently. (Using
> `Launch-Win32Toolkit.cmd` or `git clone` never prompts.)

### Verify

```powershell
Get-Command -Module win32-toolkit

# CommandType  Name
# -----------  ----
# Function     Complete-Win32ToolkitManualApp
# Function     Export-Win32ToolkitIntuneWin
# Function     Invoke-Win32Toolkit
# Function     New-Win32ToolkitManualApp
# Function     New-Win32ToolkitTestVM
# Function     Publish-Win32ToolkitIntuneApp
# Function     Remove-Win32ToolkitTestVM
# Function     Reset-Win32ToolkitTestVM
# Function     Set-Win32ToolkitAppDependency
# Function     Set-Win32ToolkitTestVMResource
# Function     Show-Win32Toolkit
# Function     Sync-Win32ToolkitAppDependency
# Function     Test-Win32ToolkitProject
```

---

## Folder layout

All output lives under a single **BasePath**. On first run the toolkit prompts for this folder and saves it to the registry (`HKCU:\Software\CloudFlow\win32-toolkit`); pass `-BasePath` to override per-call, or `-Reconfigure` to re-prompt. Output is grouped **by org template**, so the same app can be packaged for multiple clients side by side:

```
C:\Win32Apps\                            BasePath (saved in the registry)
  Templates\
    Contoso.json                         org template — branding + PSADT dialog prefs
  Projects\
    Contoso\                             template the project was built with
      Git_x64_2.53.0\                    raw project — never modified after creation
        Files\
          Git_x64_2.53.0.exe
          installer.yaml
        SupportFiles\
          AppConfig.json                 data-driven install/uninstall values
          RequirementScript.ps1
        Sandbox\                         test artifacts: WSB configs, Countdown.ps1, Logs\, OldVersion\
        Documentation\                   sandbox capture JSON and log
        Config\
        Strings\
        Assets\
          AppIcon.png
        Invoke-AppDeployToolkit.ps1
  Staging\
    Contoso\
      Git_x64_2.53.0\                    cleaned copy produced during .intunewin packaging
  IntuneWin\
    Contoso\
      Git_x64_2.53.0.intunewin           ready-to-upload Intune package
```

The `Projects\` tier is **never touched** after creation — the optimizer only runs against the `Staging\` copy.

---

## Org Templates

Before packaging apps, create an **org template** — a JSON file that stores your company branding and PSADT dialog preferences. Once created, it is applied automatically to every project.

Templates are stored under **BasePath** in `Templates\` (e.g. `C:\Win32Apps\Templates\`). The BasePath is chosen on first run and saved to the registry.

### Create a new template

```powershell
Invoke-Win32Toolkit -NewTemplate
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

The wizard prompts for:
- Company name, script author, Fluent accent colour, log path
- Progress and balloon notification messages (Install / Repair / Uninstall)
- Welcome dialog settings — deferral count, disk space check, persist, block execution, countdown
- Uninstall welcome dialog settings
- Progress dialog — enable/disable, optional status message
- Completion prompt — optional post-install message

If a template with a lower schema version already exists, the wizard offers to upgrade it.

---

## Invoke-Win32Toolkit

The main entry point. Covers the full pipeline in a single command.

### Syntax

```powershell
Invoke-Win32Toolkit
    [-SearchTerm <string>]
    [-Id <string>]
    [-TemplateName <string>]
    [-NewTemplate]
    [-Architecture <string>]
    [-Force]
    [-BasePath <string>]
    [-RunTest <string[]>]
    [-UpdateVersionsBack <int>]
    [-UpdateSpecificVersion <string>]
    [-PackageIntune]
    [-PublishIntune]
    [-DependsOn <string[]>]
    [-DependencyType <autoInstall|detect>]
```

### Parameters

#### `-SearchTerm <string>`

Searches Winget and presents an interactive numbered selection list.

```powershell
Invoke-Win32Toolkit -SearchTerm 'visual studio code'
```

If neither `-SearchTerm` nor `-Id` is provided, the command prompts interactively.

---

#### `-Id <string>`

Resolves the package directly by Winget ID, skipping the search step entirely.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git'
Invoke-Win32Toolkit -Id 'Microsoft.VisualStudioCode'
Invoke-Win32Toolkit -Id '7zip.7zip'
```

---

#### `-TemplateName <string>`

Loads a specific org template by name instead of showing the interactive picker. If the named template does not yet exist, the wizard opens pre-filled with that name.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -TemplateName 'Contoso'
```

---

#### `-NewTemplate`

Runs the org template wizard and exits without packaging anything.

```powershell
Invoke-Win32Toolkit -NewTemplate
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Fabrikam'
```

---

#### `-Architecture <string>`

Specifies the target architecture (`x64`, `x86`, `arm64`) and skips the interactive menu. If omitted, an interactive list is shown with detected architectures highlighted.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64
```

---

#### `-Force`

Suppresses two interactive prompts:
- PSGallery update check for PSAppDeployToolkit (uses the installed version)
- Project overwrite confirmation if a folder with the same name already exists

```powershell
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force
```

---

#### `-BasePath <string>`

Root directory for all output tiers (`Projects\`, `Staging\`, `IntuneWin\`). Defaults to `C:\Win32Apps`.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -BasePath 'D:\Packaging'
```

---

#### `-RunTest <string[]>`

Runs one or more sandbox test scenarios immediately after the project is built and documented. Accepts an array to chain multiple scenarios.

Valid values: `InstallUninstall`, `Update`

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -RunTest InstallUninstall, Update
```

Calls `Test-Win32ToolkitProject -ProjectPath $projectFullPath -Scenario $_` for each value.

---

#### `-UpdateVersionsBack <int>` / `-UpdateSpecificVersion <string>`

Pre-select the `Update` test's baseline (Nth-older release, or an exact version) so a scripted
`-RunTest Update` pipeline never blocks on the interactive version picker mid-run. Omit both to keep
the picker. `-UpdateSpecificVersion` wins when both are supplied.

```powershell
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -RunTest InstallUninstall, Update -UpdateVersionsBack 1 -PackageIntune
```

---

#### `-PackageIntune`

After building (and optionally testing), calls `Export-Win32ToolkitIntuneWin` to produce the `.intunewin` file. Downloads `IntuneWinAppUtil.exe` automatically on first use.

```powershell
# Build, test, and package in one command
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune

# Package without testing
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -PackageIntune
```

---

#### `-PublishIntune`

After packaging, calls `Publish-Win32ToolkitIntuneApp` to upload the `.intunewin` file directly to Microsoft Intune via the Graph API. **Implies `-PackageIntune`** — you do not need to specify both.

On first use you are prompted to install the `Microsoft.Graph.Authentication` module (if absent) and to sign in interactively. The credential is cached for the session.

```powershell
# Full pipeline: build → package → publish
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PublishIntune

# Full pipeline including test
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PublishIntune
```

---

### Pipeline steps

```
 1.  Winget check              Confirms winget is installed and available
 2.  Template load             Loads or creates an org template
 3.  App resolution            Resolves the package via search or direct ID
 4.  Architecture selection    Interactive menu or -Architecture parameter
 5.  PSADT project creation    Scaffolds a v4 project under Projects\
 6.  Download                  winget download → Projects\<Name>\Files\
 7.  File rename               Normalises installer filename to AppName_arch_version.ext
 8.  PSADT configuration       Detects MSI / EXE / MSIX, configures Invoke-AppDeployToolkit.ps1
 9.  Org template application  Updates config.psd1, strings.psd1, and Invoke-AppDeployToolkit.ps1
10.  Icon download             Fetches IconUrl from Winget YAML → Assets\AppIcon.png (winget-primary)
11.  Sandbox documentation     Writes TargetedDocumentationScript.ps1 and a .wsb, launches sandbox
12.  Result processing         Monitors for InstallationChanges JSON from the sandbox, then:
       a. Generates SupportFiles\RequirementScript.ps1 (Intune requirement rule)
       b. Populates uninstall logic in Invoke-AppDeployToolkit.ps1 (EXE only)
       c. Sets AppProcessesToClose from App Paths registry entries
       d. Promotes the icon extracted from the install run to Assets\AppIcon.png when
          winget had none (this is how manual / iconless apps get a real tile)
13.  -RunTest (optional)       Launches sandbox test scenarios (InstallUninstall / Update)
14.  -PackageIntune /           Copies to Staging\, cleans, runs IntuneWinAppUtil.exe → IntuneWin\
     -PublishIntune (optional)
15.  -PublishIntune (optional)  Uploads .intunewin to Intune via Graph API (see below)
```

---

### Output files (under `Projects\<Name>\`)

| File | Purpose |
|---|---|
| `Invoke-AppDeployToolkit.ps1` | Main PSADT deployment script, pre-configured for your installer |
| `Files\<installer>` | Downloaded installer |
| `Files\installer.yaml` | Winget manifest — metadata used during configuration |
| `Assets\AppIcon.png` | Application icon — winget IconUrl if present, else extracted from the install run |
| `Config\config.psd1` | PSADT configuration — branding from org template |
| `Strings\strings.psd1` | PSADT localisation strings — messages from org template |
| `SupportFiles\RequirementScript.ps1` | Ready-to-paste Intune Win32 requirement script |
| `<ProjectName>_TargetedDocumentation.wsb` | Sandbox config — double-click to re-run documentation |

---

### Examples

```powershell
# Interactive — prompts for search term, then lists results
Invoke-Win32Toolkit

# Direct ID, specific architecture
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64

# Fully automated
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -Force -BasePath 'C:\Packaging'

# With org template
Invoke-Win32Toolkit -Id 'Google.Chrome' -Architecture x64 -TemplateName 'Contoso' -Force

# Build and test
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall

# Full pipeline: build → test → package
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune

# Full pipeline: build → package → publish to Intune
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PublishIntune

# Full pipeline: build → test → package → publish to Intune
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PublishIntune

# Create org template only
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

---

## Manual apps (not in winget)

Plenty of apps aren't in winget — a vendor MSI, an in-house installer, a legacy EXE. `New-Win32ToolkitManualApp`
packages those: **you supply the installer, and everything after that is identical to the winget flow** —
capture, auto-generated uninstall logic, detection rule, `.intunewin`, publish, dependencies, and the same
Sandbox/Hyper-V test scenarios.

### Easy vs Advanced

The only question is whether the toolkit can install your app **silently and unattended**:

| | When | What you do |
|---|---|---|
| **Easy** | An **MSI** (Zero-Config), an **MSIX/APPX**, or an **EXE with `-SilentArgs`** | Nothing — it runs end to end |
| **Advanced** | An **EXE with no known silent switches**, or you pass `-Advanced` | The Install region is left for **you** to author, then you finalise |

The **uninstall stays automated in both cases** — it's derived from the capture, not from you.

```powershell
# Easy — an MSI, end to end (capture → uninstall logic → package → publish)
New-Win32ToolkitManualApp -Name 'Qastor' -Version '3.16.0' -Architecture x64 `
    -SourcePath 'C:\src\qastor.msi' -TemplateName 'Arxus' -PackageIntune

# Easy — an EXE, because you know its silent switches
New-Win32ToolkitManualApp -Name 'Acme Reader' -Version '7.1' -Architecture x64 `
    -SourcePath 'C:\src\acme-setup.exe' -SilentArgs '/S /norestart' -TemplateName 'Contoso'

# Advanced — you write the install logic
New-Win32ToolkitManualApp -Name 'Legacy CAD' -Version '12.0' -Architecture x64 `
    -SourcePath 'C:\src\LegacyCAD\' -Advanced -TemplateName 'Contoso'
#   → edit the Install region of <project>\Invoke-AppDeployToolkit.ps1, then:
Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Legacy_CAD_x64_12.0' `
    -RunTest InstallUninstall -PackageIntune
```

`-SourcePath` takes a **file or a folder** (a folder is copied wholesale into `Files\`, for installers that
need their payload beside them).

### It's the same pipeline

Manual apps are not a lesser path — they get everything the winget flow gets:

- **Dependencies** — `-DependsOn 'winget:Microsoft.VCRedist.2015+.x64'` works exactly the same, including
  being installed in the guest before your app during the capture and test runs.
- **Test scenarios** — `Test-Win32ToolkitProject` (`InstallUninstall`; `Update` needs a local baseline —
  `-BaselineProject 'Contoso\App_x64_1.0'` (or `-BaselineProjectPath`) — since there's no winget version
  history to pull an older build from. The TUI's Update flow prompts for the baseline automatically).
- **Org templates**, detection rules, the install tattoo, `.intunewin`, Intune publish, the update app.

In the TUI this is **"Package a manual app"**, which asks the same questions and shows the same review panel.

---

## Test-Win32ToolkitProject

Runs test scenarios against a PSADT project in the configured backend — **Windows Sandbox** by default, or a **Hyper-V VM** via `-Backend HyperV` (opt-in; falls back to Sandbox if the VM isn't ready). Documentation capture follows the same backend. Can be called standalone, chained via `-RunTest` on `Invoke-Win32Toolkit`, or run at any time against any existing project.

**Watched vs unattended.** Both backends default to **Interactive** (watched): PSADT shows its GUI and a countdown/pause gives you a verification window. Pass `-Unattended` (or set the `SandboxTestMode` / `HyperVTestMode` config value to `Unattended`) for silent back-to-back automation — no GUI, no countdown, and a Sandbox run shuts its guest down afterwards so **chained runs proceed on their own**. A non-interactive host (CI, redirected stdin) auto-selects Unattended with a warning. Note: Sandbox-unattended runs as the WDAG admin user while HyperV-unattended runs as SYSTEM (Intune parity) — their verdicts are not equivalent evidence. Back-to-back runs no longer fail on "another sandbox is already running": the guard now waits up to 90 s for the previous sandbox to close.

### Syntax

```powershell
Test-Win32ToolkitProject
    [-ProjectPath <string>]
    [-BasePath <string>]
    [-Scenario <string>]
    [-VersionsBack <int>]
    [-SpecificVersion <string>]
```

### Parameters

#### `-ProjectPath <string>`

Full path to a PSADT project folder (must contain `Invoke-AppDeployToolkit.ps1`). If omitted, an interactive numbered picker scans `BasePath\Projects\`.

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0'
```

---

#### `-BasePath <string>`

Root folder to scan when `-ProjectPath` is not provided. Defaults to `C:\Win32Apps`.

```powershell
Test-Win32ToolkitProject -BasePath 'D:\Packaging'
```

---

#### `-Scenario <string>`

The test scenario to run. If omitted, an interactive menu is shown.

| Value | Description |
|---|---|
| `InstallUninstall` | Install → 2-minute countdown (skippable) → Uninstall. Sandbox stays open for verification. |
| `Update` | Silently install an older baseline → 2-minute countdown → run the PSADT package to perform the update. |

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario InstallUninstall
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario Update
```

---

#### `-VersionsBack <int>`

*(Update scenario only)* Auto-selects the version *N* positions older than the packaged version. `1` = the immediately previous release. Overridden by `-SpecificVersion` if both are supplied.

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario Update -VersionsBack 1
```

---

#### `-SpecificVersion <string>`

*(Update scenario only)* Uses this exact version string as the baseline, bypassing the version list menu and `-VersionsBack`.

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario Update -SpecificVersion '2.47.0'
```

---

#### `-BaselineProject <Template\Name>` / `-BaselineProjectPath <path>`

*(Update scenario only)* Use a **local, already-packaged toolkit project** as the old-version baseline instead of
downloading the old build from winget — the same way a `project:` dependency is referenced. This is the way to test
an upgrade for a **manual (non-winget) app** (which has no winget version history), and it exercises the real
tattoo-overwrite path (old install tattoo → new). The baseline package is delivered read-only (`C:\PSADTOld`) and
installed via **its own** PSADT before the new version. Both forms are mutually exclusive with `-VersionsBack` /
`-SpecificVersion`.

- `-BaselineProject 'Contoso\Git_x64_2.53.0'` — friendly reference, resolved to
  `<BasePath>\Projects\Contoso\Git_x64_2.53.0` (also accepts `project:Contoso\Git_x64_2.53.0`).
- `-BaselineProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'` — an explicit full path.

```powershell
# Test upgrading 2.55.0 over a locally-packaged 2.53.0, by friendly reference
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.55.0' -Scenario Update -BaselineProject 'Contoso\Git_x64_2.53.0'
```

In the **TUI**, choosing the `Update` scenario prompts for the baseline source — *download from winget* or *use a
local packaged project* (which lists your packaged projects, newest to pick as the baseline). For a manual app the
local project is used automatically.

---

### How `InstallUninstall` works

1. Creates `Sandbox\Countdown.ps1` — a WinForms dialog with a 2-minute timer and a Skip button
2. Writes `Sandbox\FinalDemo.wsb` — maps the project folder to `C:\PSADT` inside the sandbox
3. Launches the sandbox; the logon command automatically:
   - Installs via `Invoke-AppDeployToolkit.ps1`
   - Shows the countdown
   - Uninstalls via `Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall`
   - Keeps the sandbox open for manual verification

```
Sandbox\
  Countdown.ps1    WinForms 2-min countdown with Skip button
  CollectLogs.ps1  Copies PSADT/MSI logs into Sandbox\Logs after the run
  FinalDemo.wsb    Sandbox config — double-click to re-run
  Logs\            PSADT + MSI logs copied back from the sandbox (for troubleshooting)
```

---

### How `Update` works

> With a **local baseline** (`-BaselineProject` / `-BaselineProjectPath`), steps 1–5 below are skipped: that
> packaged project is installed via its own PSADT (read-only at `C:\PSADTOld`) as the old version, then the
> project under test performs the update. This is also the only path for manual (non-winget) apps.

1. Reads `PackageIdentifier` and current version from the YAML in `Files\`
2. Calls `winget show <id> --versions` and filters to versions older than the packaged one
3. Resolves the target baseline via `-SpecificVersion`, `-VersionsBack`, or an interactive numbered menu
4. Downloads the old installer to `Sandbox\OldVersion\` via `winget download`
5. Resolves silent install switches from the downloaded YAML (falls back to installer-type defaults: Inno `/VERYSILENT /NORESTART /SP-`, NSIS `/S`, MSI `/qn /norestart`, WiX/Burn `/quiet /norestart`)
6. Creates `Countdown.ps1`
7. Writes `Sandbox\UpdateDemo.wsb` with a logon command that:
   - Silently installs the old baseline
   - Shows the countdown — verify the old version works
   - Runs `Invoke-AppDeployToolkit.ps1` to perform the update
   - Keeps the sandbox open for final verification

```
Sandbox\
  OldVersion\      Downloaded old-version installer
  Countdown.ps1    WinForms 2-min countdown with Skip button
  CollectLogs.ps1  Copies PSADT/MSI logs into Sandbox\Logs after the run
  UpdateDemo.wsb   Sandbox config — double-click to re-run
  Logs\            PSADT + MSI logs copied back from the sandbox (for troubleshooting)
```

---

### Examples

```powershell
# Interactive scenario + project picker
Test-Win32ToolkitProject

# Direct path, interactive scenario picker
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0'

# InstallUninstall
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario InstallUninstall

# Update — interactive version picker
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario Update

# Update — 1 version back
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario Update -VersionsBack 1

# Update — pin to specific version
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -Scenario Update -SpecificVersion '2.47.0'

# Custom base folder
Test-Win32ToolkitProject -BasePath 'D:\Packaging'

# Chained from Invoke-Win32Toolkit
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall, Update
```

> **Test outcomes are recorded.** Every test run (both scenarios, both backends) now asserts a real
> pass/fail — after install the app must be **detected** (the same registry tattoo Intune detects on); after
> uninstall it must be **gone** — and appends the result to `Documentation\TestResults.json`. That history is
> what `Export-Win32ToolkitDocumentation` turns into the customer doc's Testing table.

---

## Export-Win32ToolkitDocumentation

Writes a clean, **customer-facing one-page `Documentation.md`** for a packaged project — the kind of hand-over
sheet you can send to a customer signing off a deployment. It gathers the facts already in the project and
renders them as a skimmable Markdown page:

- **Header & overview** — app name, version, publisher, architecture, packaged date, prepared-by, description.
- **Deployment** — installer type; that it runs silently as SYSTEM; the exact Intune install/uninstall command
  lines; the detection method in plain English; minimum Windows; and any dependencies installed first.
- **What it installs** — a sanitised summary of the captured changes (counts of files/registry keys/services and
  the Add/Remove Programs name) — never raw host paths.
- **Testing** — a table of every recorded test run (scenario · backend · date · result), pulled from
  `Documentation\TestResults.json`.
- **Uninstall** — whether uninstall is supported/verified.

**Customer-safe by default:** no tenant id, no Intune app id, no raw paths. Pass `-IncludeIntuneIds` (only when
the customer owns the tenant) to add the app id and a portal deep-link. The output is ASCII-only so it can't
mojibake when forwarded.

```powershell
# Write Documentation.md next to the project
Export-Win32ToolkitDocumentation -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.55.0'

# An internal copy that also lists the Intune app id + portal link
Export-Win32ToolkitDocumentation -ProjectPath $proj -OutputPath 'C:\temp\Git.md' -IncludeIntuneIds
```

In the **TUI**, this is the *"Generate customer documentation (Documentation.md)"* action in the
"Work with an existing project" menu.

---

## Export-Win32ToolkitIntuneWin

Compiles a PSADT project into a `.intunewin` file ready for Intune upload. The original raw project is never modified — a `Staging\` copy is used for cleanup and packaging.

`IntuneWinAppUtil.exe` is downloaded automatically from the official Microsoft GitHub repository if not already present in the module's `Tools\` folder.

### Syntax

```powershell
Export-Win32ToolkitIntuneWin
    [-ProjectPath <string>]
    [-BasePath <string>]
    [-PublishIntune]
```

### Parameters

#### `-ProjectPath <string>`

Full path to the raw project folder under `Projects\`. If omitted, an interactive numbered picker scans `BasePath\Projects\`.

```powershell
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0'
```

---

#### `-BasePath <string>`

Root folder containing the tier structure when `-ProjectPath` is not provided. Defaults to `C:\Win32Apps`.

```powershell
Export-Win32ToolkitIntuneWin -BasePath 'D:\Packaging'
```

---

#### `-PublishIntune`

After packaging completes, immediately calls `Publish-Win32ToolkitIntuneApp` to upload the resulting `.intunewin` to Microsoft Intune. On first use you are prompted to install `Microsoft.Graph.Authentication` (if absent) and to authenticate interactively.

```powershell
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -PublishIntune
Export-Win32ToolkitIntuneWin -PublishIntune   # interactive picker + publish
```

---

### What it does

1. Resolves the target project (interactive picker if `-ProjectPath` is omitted)
2. Locates or downloads `IntuneWinAppUtil.exe` into `<ModuleRoot>\Tools\` — tries the GitHub Releases API first, falls back to the raw repository file
3. Copies `Projects\<Name>` → `Staging\<Name>`, refreshing a previous copy if present so Staging always reflects the latest raw project state
4. Runs the optimizer against the **Staging copy** — removes:
   - `Docs\`, `Examples\` folders
   - `Sandbox\` folder (WSB configs, Countdown scripts, OldVersion downloads, **dependency installers**)
   - `Intune\` folder (`Publications.json` — the project→app-id cache; tenant and app ids never travel to a device)
   - `Documentation\` folder (sandbox capture JSON and logs)
   - `SupportFiles\TargetedDocumentationScript.ps1` and documentation log files (`SupportFiles\RequirementScript.ps1` is kept)
   - `*.md` and `*.wsb` files in the project root
   - Any empty subdirectories
5. Runs `IntuneWinAppUtil.exe -c <StagingPath> -s Invoke-AppDeployToolkit.ps1 -o <IntuneWin\> -q`
6. Renames the output from `Invoke-AppDeployToolkit.intunewin` → `<ProjectName>.intunewin`

### Output

```
C:\Win32Apps\
  Projects\
    Git_x64_2.53.0\              raw project — Sandbox\, Documentation\ still intact
  Staging\
    Git_x64_2.53.0\              lean copy — kept for fast re-packaging
      Files\
      SupportFiles\
        RequirementScript.ps1
      Config\
      Strings\
      Assets\
      Invoke-AppDeployToolkit.ps1
  IntuneWin\
    Git_x64_2.53.0.intunewin     ready-to-upload Intune package
```

### Examples

```powershell
# Interactive project picker
Export-Win32ToolkitIntuneWin

# Custom base folder
Export-Win32ToolkitIntuneWin -BasePath 'D:\Packaging'

# Direct project path
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0'

# Package and publish to Intune in one step
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -PublishIntune

# Chained from Invoke-Win32Toolkit
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune
```

---

## App dependencies

Some apps need something else installed **first** — most commonly a **Visual C++ redistributable**, or
another in-house app. Declare it, and the toolkit does two things:

1. **In Intune** — creates a real `mobileAppDependency` relationship, so the Intune Management Extension
   installs the dependency **before** your app on the device.
2. **In your test runs** — installs the dependency **inside the Sandbox / Hyper-V guest before the app**, so
   your app is never captured or tested on a machine that is missing its runtime.

That second part matters more than it sounds. The **documentation capture** installs your app on a clean
machine to discover what it changes. Without the dependency present, the install can fail or half-succeed —
and the detection rule, uninstall logic and processes-to-close would all be generated from a **broken
install**, then shipped to every device.

### Declaring

```powershell
# winget flow
Invoke-Win32Toolkit -Id 'Contoso.App' -Architecture x64 -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'

# custom (non-winget) app
New-Win32ToolkitManualApp -Name 'Qastor' -Version '10.0' -Architecture x64 -SourcePath 'C:\src\qastor.msi' `
    -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'

# an existing project (add or change dependencies at any time)
Set-Win32ToolkitAppDependency -ProjectPath 'C:\Win32Apps\Projects\Arxus\Qastor_x64_10.0' `
    -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'
```

Or in the **TUI**: both wizards ask *"Does this app need another app installed FIRST?"*, and every project
has a **Dependencies** action.

### Three sources

| Reference | Meaning | Installed in the test run? |
|---|---|---|
| `winget:Microsoft.VCRedist.2015+.x64` | a winget package | ✅ downloaded and installed in the guest |
| `project:Contoso\VCRedist_x64_14.38` | a project you already packaged | ✅ installed via its own PSADT |
| `intune:<app id>` | an app already published in Intune (pick it from the TUI) | ❌ no local package to install |

`-DependencyType` defaults to `autoInstall` (install it first). `detect` **only detects** it — and if it is
absent, Intune will not even attempt your app. Use it deliberately.

### What happens at publish

The dependency must already exist in Intune as a published Win32 app. The toolkit resolves it (from its
publication cache, or by searching the tenant), then attaches the relationship after the upload.

**So publish the dependency FIRST, then the app that needs it.**

**If the dependency isn't in your tenant yet, your app still publishes — with a warning.** Nothing is ever
auto-published on your behalf.

> ⚠️ **Do NOT "just re-publish" the app to fix its dependencies.** `Publish-Win32ToolkitIntuneApp` always
> creates a **new** app — it has no update path — so re-publishing produces a *duplicate* and leaves the
> original (the one actually assigned to your users) still without its dependency.
>
> To change the dependencies of an app that is **already live**, declare them and then run:
> ```powershell
> Sync-Win32ToolkitAppDependency -ProjectPath 'C:\Win32Apps\Projects\Arxus\Qastor_x64_10.0'
> ```
> It updates the existing app in place (its id comes from the project's publication cache), replacing its
> dependency set — so removing a declaration really does remove the relationship. Supersedence is left
> untouched.

If a reference matches **more than one** app in the tenant, it is skipped with a warning (never guessed) and
the app publishes without it — declare `intune:<app id>` to disambiguate.

You do **not** need a "skip if already installed" setting: Intune honours the *dependency app's own
detection rule*, so a machine that already has the redistributable simply doesn't reinstall it.

> **Prerequisite:** your admin account needs the Intune RBAC **Relate** permission (Mobile apps). A correct
> Graph scope is *not* enough — without it the relationship write fails with a 403 *after* the app uploads.

Uninstalling your app leaves the dependency in place (it is shared). Design notes:
[knowledge-base/designs/intune-dependencies.md](knowledge-base/designs/intune-dependencies.md).

---

## Publish-Win32ToolkitIntuneApp

Uploads a `.intunewin` file to Microsoft Intune using the Microsoft Graph `/beta` endpoint. Can be called standalone (useful if the file was produced by a different tool), or is invoked automatically when `-PublishIntune` is passed to `Export-Win32ToolkitIntuneWin` or `Invoke-Win32Toolkit`.

### Syntax

```powershell
Publish-Win32ToolkitIntuneApp
    -IntuneWinPath <string>
    -ProjectPath   <string>
```

### Parameters

#### `-IntuneWinPath <string>` *(required)*

Full path to the `.intunewin` file to upload.

```powershell
Publish-Win32ToolkitIntuneApp \
    -IntuneWinPath 'C:\Win32Apps\IntuneWin\Git_x64_2.53.0.intunewin' \
    -ProjectPath   'C:\Win32Apps\Projects\Git_x64_2.53.0'
```

---

#### `-ProjectPath <string>` *(required)*

Full path to the raw PSADT project folder. Used to read the Winget YAML manifest for app metadata (display name, publisher, description, information URL) and to locate `Documentation\InstallationChanges_*.json` for detection rule generation.

---

### What it does

| Step | Action |
|------|--------|
| 1 | Reads `Files\*.yaml` for display name, publisher, description, and information URL |
| 2 | Parses architecture from the project folder name (`_x64_`, `_x86_`, `_arm64_`) |
| 3 | Authenticates to Microsoft Graph — installs `Microsoft.Graph.Authentication` on prompt, skips if already connected with the right scope |
| 4 | Opens the `.intunewin` ZIP and reads `IntuneWinPackage/metadata.xml` for all encryption fields |
| 5 | Builds 1 detection rule from `Documentation\InstallationChanges_*.json` — registry key preferred (Uninstall key first), file system path as fallback |
| 6 | `POST /beta/deviceAppManagement/mobileApps` — creates the Win32 app shell |
| 7 | `POST .../contentVersions` — creates a content version |
| 8 | `POST .../files` — registers the file entry with encrypted and unencrypted sizes |
| 9 | Polls until the Azure Storage SAS URI is ready |
| 10 | Extracts the inner encrypted content file from the `.intunewin` ZIP to a temp location |
| 11 | Uploads the encrypted file to Azure Blob Storage using chunked Put Block (4 MB chunks) + Put Block List commit |
| 12 | `POST .../files/{id}/commit` — sends all `fileEncryptionInfo` fields |
| 13 | Polls until the commit is confirmed |
| 14 | `PATCH /mobileApps/{appId}` — links the committed content version to the app |
| 15 | Deletes the temp file; prints the app ID and a direct Intune portal URL |

### App shell defaults

| Property | Value |
|---|---|
| `installCommandLine` | `powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install -DeployMode Silent` |
| `uninstallCommandLine` | same with `-DeploymentType Uninstall` |
| `runAsAccount` | `system` |
| `deviceRestartBehavior` | `suppress` |
| Return codes | 0 success, 1707 success, 3010 soft reboot, 1641 hard reboot, 1618 retry |
| Minimum OS | Windows 10 1607 |

All of these can be adjusted in the Intune portal after upload.

### Authentication

The module requests only the `DeviceManagementApps.ReadWrite.All` scope. Authentication is interactive (browser pop-up via `Connect-MgGraph`). Once the token is cached for the session, subsequent calls in the same PowerShell session do not re-prompt.

```powershell
# If you want to pre-connect with a specific account
Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All'

# Then call the uploader — it detects the existing connection and skips re-auth
Publish-Win32ToolkitIntuneApp \
    -IntuneWinPath 'C:\Win32Apps\IntuneWin\Git_x64_2.53.0.intunewin' \
    -ProjectPath   'C:\Win32Apps\Projects\Git_x64_2.53.0'
```

### Detection rule logic

The function reads `Documentation\InstallationChanges_*.json` produced by the sandbox documentation run and applies this priority:

1. **Registry** — look in `NewRegistryKeys`; prefer any entry whose path contains `Uninstall` (reliable app-presence indicator); fall back to the first `HKEY_LOCAL_MACHINE\SOFTWARE` entry
2. **File system** — if no registry candidates, look in `NewFiles` for a path under `C:\Program Files`
3. **None** — the app is created with an empty detection rule list; a warning is shown. Add a rule manually in the Intune portal.

Only 1 detection rule is created. Additional rules can be added in the portal.

### Examples

```powershell
# Standalone upload
Publish-Win32ToolkitIntuneApp `
    -IntuneWinPath 'C:\Win32Apps\IntuneWin\Git_x64_2.53.0.intunewin' `
    -ProjectPath   'C:\Win32Apps\Projects\Git_x64_2.53.0'

# Via Export-Win32ToolkitIntuneWin
Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -PublishIntune

# Via Invoke-Win32Toolkit (full pipeline)
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PublishIntune
```

---

## Pipeline performance & config switches

The test/capture pipeline is tuned for wall-clock: blind waits are event-driven **with their old
durations kept as hard ceilings** (worst case per site is exactly the previous behavior), each Hyper-V
run reverts once instead of twice, results copy back as a single archive, and repeated downloads are
cached. Registry config values (`HKCU:\Software\CloudFlow\win32-toolkit`):

| Value | Default | Effect |
|---|---|---|
| `TestBackend` | `Sandbox` | `HyperV` opts test/capture runs into the Hyper-V VM (falls back to Sandbox when not ready). |
| `HyperVTestMode` / `SandboxTestMode` | `Interactive` | `Unattended` makes that backend's tests run silent + back-to-back (no GUI, no countdown; Sandbox shuts its guest down afterwards). `-Unattended` overrides per call; non-interactive hosts auto-select it. |
| `PipelineCache` | `On` | Caches update-baseline downloads under `<BasePath>\Cache\winget\` (SHA256-validated against the winget manifest on every reuse — a tampered/torn entry re-downloads) and reuses dependency staging within 6 h (every staged file re-hashed before reuse). `Off` restores the old always-download behavior. |
| `HyperVDepsCheckpoint` | `Off` | `On`: after a project's dependencies install once in the VM, a `clean-base+deps-<hash>` checkpoint is taken and later runs of that project restore it instead of re-installing the dependencies. The hash covers the dependency set, every staged installer byte, and the parent checkpoint identity — any change falls back to `clean-base` + a live install. VM maintenance (resource changes, re-checkpointing) deletes it; it is simply recreated on the next run. |

---

## Notes

- **MSI installers** use PSADT's Zero-Config MSI feature — `AppName` is left empty so PSADT reads the product name directly from the MSI database. No manual uninstall logic is needed.
- **EXE installers** have install and uninstall logic generated and inserted automatically from the sandbox documentation run.
- The **Windows Sandbox** documentation session maps the project folder to `C:\PSADT` inside the sandbox. All output is written back to the host via the mapped folder.
- **App icon** — the tile icon is sourced winget-first: the Winget `IconUrl` wins when present; otherwise the
  installed app's real icon is extracted during the documentation/capture run (from the Add/Remove-Programs
  `DisplayIcon`, else the largest install-dir `.exe`) and promoted to `Assets\AppIcon.png`. A manual app's
  `-IconPath` always wins. Low-resolution frames (≤48px from `.ico`/image sources) are skipped rather than
  upscaled. The icon is uploaded to Intune as the app tile (`largeIcon`) at publish time — before this,
  `Assets\AppIcon.png` only fed PSADT's on-device dialogs and the Intune tile stayed blank. If nothing usable
  is found, the default PSADT icon is kept and the app publishes without a tile icon.
- The PSAppDeployToolkit PSGallery update check can be suppressed with `-Force` on `Invoke-Win32Toolkit`.
- `IntuneWinAppUtil.exe` is stored in `<ModuleRoot>\Tools\` and downloaded once — subsequent packaging runs reuse it.
