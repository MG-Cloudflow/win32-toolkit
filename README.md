# win32-toolkit

A PowerShell module that automates the end-to-end process of packaging Win32 applications for Microsoft Intune deployment using the **PSAppDeployToolkit (PSADT) v4** framework.

The module exposes three public commands that cover the full packaging pipeline:

| Command | Purpose |
|---|---|
| `Invoke-Win32Toolkit` | Search, download, scaffold, document, and optionally test and package an app |
| `Test-Win32ToolkitProject` | Run sandbox-based test scenarios against any existing PSADT project |
| `Export-Win32ToolkitIntuneWin` | Clean up and compile a project into a ready-to-upload `.intunewin` file |

---

## Requirements

| Requirement | Details |
|---|---|
| **PowerShell** | 5.1 or later (Windows PowerShell or PowerShell 7+) |
| **Winget** | Windows Package Manager must be installed and in `$PATH`. Included in Windows 10 21H1+ and Windows 11. |
| **PSAppDeployToolkit** | v4.x from the PowerShell Gallery. Prompted to install automatically on first run if absent. |
| **Windows Sandbox** | Required for documentation and test scenarios. Enable via *Windows Features → Windows Sandbox*. Available on Windows 10/11 Pro, Enterprise, and Education only. |
| **Internet access** | Required to search Winget, download packages, check PSGallery, and download IntuneWinAppUtil.exe. |
| **Administrator rights** | Recommended. Required if `BasePath` is under a system-protected location. |

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

### Verify

```powershell
Get-Command -Module win32-toolkit

# CommandType  Name
# -----------  ----
# Function     Export-Win32ToolkitIntuneWin
# Function     Invoke-Win32Toolkit
# Function     Test-Win32ToolkitProject
```

---

## Folder layout

All output lives under a single `BasePath` (default `C:\Win32Apps`) organised into three tiers:

```
C:\Win32Apps\
  Projects\
    Git_x64_2.53.0\          raw project — never modified after creation
      Files\
        Git_x64_2.53.0.exe
        installer.yaml
      SupportFiles\
        RequirementScript.ps1
      Sandbox\               test artifacts: WSB configs, Countdown.ps1, OldVersion\
      Documentation\         sandbox capture JSON and log
      Config\
      Strings\
      Assets\
        AppIcon.png
      Invoke-AppDeployToolkit.ps1
  Staging\
    Git_x64_2.53.0\          cleaned copy produced during .intunewin packaging
  IntuneWin\
    Git_x64_2.53.0.intunewin ready-to-upload Intune package
```

The `Projects\` tier is **never touched** after creation — the optimizer only runs against the `Staging\` copy.

---

## Org Templates

Before packaging apps, create an **org template** — a JSON file that stores your company branding and PSADT dialog preferences. Once created, it is applied automatically to every project.

Templates are stored in `$env:APPDATA\IntuneToolkit\`.

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
    [-PackageIntune]
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

#### `-PackageIntune`

After building (and optionally testing), calls `Export-Win32ToolkitIntuneWin` to produce the `.intunewin` file. Downloads `IntuneWinAppUtil.exe` automatically on first use.

```powershell
# Build, test, and package in one command
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune

# Package without testing
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -PackageIntune
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
10.  Icon download             Fetches IconUrl from Winget YAML → Assets\AppIcon.png
11.  Sandbox documentation     Writes TargetedDocumentationScript.ps1 and a .wsb, launches sandbox
12.  Result processing         Monitors for InstallationChanges JSON from the sandbox, then:
       a. Generates SupportFiles\RequirementScript.ps1 (Intune requirement rule)
       b. Populates uninstall logic in Invoke-AppDeployToolkit.ps1 (EXE only)
       c. Sets AppProcessesToClose from App Paths registry entries
13.  -RunTest (optional)       Launches sandbox test scenarios (InstallUninstall / Update)
14.  -PackageIntune (optional) Copies to Staging\, cleans, runs IntuneWinAppUtil.exe → IntuneWin\
```

---

### Output files (under `Projects\<Name>\`)

| File | Purpose |
|---|---|
| `Invoke-AppDeployToolkit.ps1` | Main PSADT deployment script, pre-configured for your installer |
| `Files\<installer>` | Downloaded installer |
| `Files\installer.yaml` | Winget manifest — metadata used during configuration |
| `Assets\AppIcon.png` | Application icon from the Winget manifest |
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

# Create org template only
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

---

## Test-Win32ToolkitProject

Runs sandbox-based test scenarios against a PSADT project. Can be called standalone, chained via `-RunTest` on `Invoke-Win32Toolkit`, or run at any time against any existing project.

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
  FinalDemo.wsb    Sandbox config — double-click to re-run
```

---

### How `Update` works

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
  UpdateDemo.wsb   Sandbox config — double-click to re-run
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

---

## Export-Win32ToolkitIntuneWin

Compiles a PSADT project into a `.intunewin` file ready for Intune upload. The original raw project is never modified — a `Staging\` copy is used for cleanup and packaging.

`IntuneWinAppUtil.exe` is downloaded automatically from the official Microsoft GitHub repository if not already present in the module's `Tools\` folder.

### Syntax

```powershell
Export-Win32ToolkitIntuneWin
    [-ProjectPath <string>]
    [-BasePath <string>]
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

### What it does

1. Resolves the target project (interactive picker if `-ProjectPath` is omitted)
2. Locates or downloads `IntuneWinAppUtil.exe` into `<ModuleRoot>\Tools\` — tries the GitHub Releases API first, falls back to the raw repository file
3. Copies `Projects\<Name>` → `Staging\<Name>`, refreshing a previous copy if present so Staging always reflects the latest raw project state
4. Runs the optimizer against the **Staging copy** — removes:
   - `Docs\`, `Examples\` folders
   - `Sandbox\` folder (WSB configs, Countdown scripts, OldVersion downloads)
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

# Chained from Invoke-Win32Toolkit
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune
```

---

## Notes

- **MSI installers** use PSADT's Zero-Config MSI feature — `AppName` is left empty so PSADT reads the product name directly from the MSI database. No manual uninstall logic is needed.
- **EXE installers** have install and uninstall logic generated and inserted automatically from the sandbox documentation run.
- The **Windows Sandbox** documentation session maps the project folder to `C:\PSADT` inside the sandbox. All output is written back to the host via the mapped folder.
- If no `IconUrl` is present in the Winget YAML manifest, the default PSADT icon is kept unchanged.
- The PSAppDeployToolkit PSGallery update check can be suppressed with `-Force` on `Invoke-Win32Toolkit`.
- `IntuneWinAppUtil.exe` is stored in `<ModuleRoot>\Tools\` and downloaded once — subsequent packaging runs reuse it.
