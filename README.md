# win32-toolkit

A PowerShell module that automates the end-to-end process of packaging Win32 applications for Microsoft Intune deployment using the **PSAppDeployToolkit (PSADT) v4** framework.

From a single command, `Invoke-Win32Toolkit` will:

1. Search the **Winget** repository for an application (or resolve a known package ID directly)
2. Select and download the installer for a chosen architecture
3. Scaffold a **PSADT v4** project and configure it for the detected installer type (MSI / EXE / MSIX)
4. Apply your **org template** — company branding, dialog settings, log paths — across the project
5. Download the application icon from the Winget manifest and embed it in the project
6. Generate a **Windows Sandbox** configuration and documentation script that captures before/after snapshots of the registry, file system, services, and programs during a real installation
7. Process the sandbox output JSON to automatically produce an **Intune requirement script**, populate uninstall logic (EXE), and set `AppProcessesToClose`

---

## Requirements

| Requirement | Details |
|---|---|
| **PowerShell** | 5.1 or later (Windows PowerShell or PowerShell 7+) |
| **Winget** | Windows Package Manager (`winget`) must be installed and available in `$PATH`. Included in Windows 10 21H1+ and Windows 11. |
| **PSAppDeployToolkit** | v4.x (`PSAppDeployToolkit` module from the PowerShell Gallery). The toolkit will prompt to install it automatically on first run if not present. |
| **Windows Sandbox** | Required for the automated documentation phase. Enable via *Windows Features → Windows Sandbox*. Only available on Windows 10/11 Pro, Enterprise, and Education. |
| **Internet access** | Required to search Winget, download packages, and check PSGallery for PSADT updates. |
| **Administrator rights** | Recommended. Required if your `BasePath` is under a system-protected location or if PSADT installs to `Program Files`. |

---

## Installation

### Option A — Import directly from the local path

```powershell
Import-Module C:\path\to\win32-toolkit\win32-toolkit.psd1
```

### Option B — Add to your PSModulePath so it auto-loads

```powershell
# Copy the module folder to your user modules directory
$dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\win32-toolkit'
Copy-Item -Path C:\path\to\win32-toolkit -Destination $dest -Recurse

# Import (or just use the command — it will auto-import if PSModulePath is correct)
Import-Module win32-toolkit
```

### Verify installation

```powershell
Get-Command -Module win32-toolkit
# Expected output:
# Name                       CommandType
# ----                       -----------
# Invoke-Win32Toolkit        Function
# Test-Win32ToolkitProject   Function
```

---

## Org Templates

Before packaging apps, it is recommended to create an **org template** — a saved JSON file that stores your company's branding and dialog preferences. The template is applied to every PSADT project automatically.

Templates are stored in `$env:APPDATA\IntuneToolkit\`.

### Create a new template

```powershell
Invoke-Win32Toolkit -NewTemplate
```

### Create a template with a pre-filled name

```powershell
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

The wizard will prompt for:

- **Company name** — shown in PSADT dialog subtitles
- **Script author** — written into `AppScriptAuthor` in every project
- **Fluent accent colour** — hex value e.g. `0xFF0078D7` (leave blank for default)
- **Log path** — override for `Toolkit.LogPath` in `config.psd1`
- **Progress messages** — Install, Repair, Uninstall
- **Progress detail text** — secondary line shown in the Fluent progress bar
- **Balloon notification text** — Install, Repair, Uninstall completion messages
- **Welcome dialog** settings — deferral count, disk space check, persist prompt, block execution, countdown
- **Uninstall welcome dialog** settings
- **Progress dialog** — enable/disable, optional status message override
- **Completion prompt** — optional post-install message shown to the user

If a template already exists with a lower schema version, the wizard will offer to upgrade it with any new fields.

---

## Usage

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
```

```powershell
Test-Win32ToolkitProject
    [-ProjectPath <string>]
    [-BasePath <string>]
    [-Scenario <string>]
```

---

### Parameters

#### `-SearchTerm <string>`

Searches the Winget repository for matching applications and presents an interactive selection list. Mutually exclusive with `-Id`.

```powershell
Invoke-Win32Toolkit -SearchTerm 'visual studio code'
```

If neither `-SearchTerm` nor `-Id` is provided, the command will prompt interactively.

---

#### `-Id <string>`

Skips the search entirely and resolves the package directly by its Winget package ID. Faster and unambiguous for automation.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git'
Invoke-Win32Toolkit -Id 'Microsoft.VisualStudioCode'
Invoke-Win32Toolkit -Id '7zip.7zip'
```

---

#### `-TemplateName <string>`

Loads a specific org template by name instead of showing the interactive template picker. If a template with that name does not exist yet, the wizard opens pre-filled with the name ready to save.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -TemplateName 'Contoso'
```

---

#### `-NewTemplate`

Runs the org template wizard and exits **without** packaging any application. Use this to create or update your branding template independently of any packaging run.

```powershell
# Create a new template
Invoke-Win32Toolkit -NewTemplate

# Create a template with a specific name
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Fabrikam'

# Update (edit) an existing template — wizard pre-fills existing values
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

---

#### `-Architecture <string>`

Specifies the target architecture and skips the interactive architecture selection menu. Accepted values: `x64`, `x86`, `arm64`.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64
Invoke-Win32Toolkit -SearchTerm 'chrome' -Architecture x86
```

If omitted, an interactive menu is shown listing detected architectures (marked with `*`) plus the three common options. Architectures not detected in the Winget manifest are still offered as choices.

---

#### `-Force`

Suppresses two interactive prompts:
- The **PSGallery update prompt** for PSAppDeployToolkit (skips the update, uses the installed version)
- The **project overwrite prompt** if a project folder with the same name already exists (silently overwrites)

Useful for scripted or unattended runs.

```powershell
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force
```

---

#### `-BasePath <string>`

The root directory where all PSADT project folders are created. Each project gets its own subfolder named `AppName_Architecture_Version`.

Defaults to `C:\Win32Apps`.

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -BasePath 'D:\Packaging\Projects'
```

---

#### `-RunTest <string[]>`

Runs one or more sandbox test scenarios immediately after the project is built and documented. Accepts an array, so multiple scenarios can be chained in a single call.

Valid values: `InstallUninstall`, `Update`

```powershell
# Run a full install/uninstall test right after packaging
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall

# Chain multiple scenarios
Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -RunTest InstallUninstall, Update
```

Internally this calls `Test-Win32ToolkitProject -ProjectPath $projectFullPath -Scenario $_` for each value supplied, so the same project is tested sequentially without any extra input required.

**Example output structure:**

```
D:\Packaging\Projects\
  Git_x64_2.53.0\
    Files\
      Git_x64_2.53.0.exe
      installer.yaml
    SupportFiles\
      TargetedDocumentationScript.ps1
      RequirementScript.ps1
    Config\
    Strings\
    Assets\
    Invoke-AppDeployToolkit.ps1
    Git_x64_2.53.0_TargetedDocumentation.wsb
```

---

### Common Examples

#### Interactive — search and select

```powershell
Import-Module win32-toolkit
Invoke-Win32Toolkit
# Prompts for search term, then presents a numbered list of results
```

#### Search by keyword, auto-select architecture

```powershell
Invoke-Win32Toolkit -SearchTerm '7-zip' -Architecture x64
```

#### Direct package ID, fully automated

```powershell
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -Force -BasePath 'C:\Packaging'
```

#### Use a specific org template

```powershell
Invoke-Win32Toolkit -Id 'Google.Chrome' -Architecture x64 -TemplateName 'Contoso' -Force
```

#### Package and immediately run an install/uninstall test

```powershell
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall
```

#### Create/update org template only (no packaging)

```powershell
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
```

---

## What happens during a run

```
1. Winget check              Confirms winget is installed and available
2. Template load             Loads or creates an org template (interactive wizard if none exists)
3. App resolution            Resolves the package via search or direct ID
4. Architecture selection    Interactive menu or -Architecture parameter
5. PSADT project creation    Calls New-ADTTemplate to scaffold a v4 project
6. Download                  winget download → project\Files\
7. File rename               Normalises installer filename to AppName_arch_version.ext
8. PSADT configuration       Detects MSI / EXE / MSIX and configures Invoke-AppDeployToolkit.ps1
9. Org template application  Updates config.psd1, strings.psd1, and Invoke-AppDeployToolkit.ps1
10. Icon download             Fetches IconUrl from the Winget YAML manifest → Assets\AppIcon.png
11. Sandbox documentation    Writes TargetedDocumentationScript.ps1 and a .wsb config, launches sandbox
12. Result processing        Monitors for InstallationChanges JSON from the sandbox, then:
    a. Generates RequirementScript.ps1 (Intune requirement rule)
    b. Populates uninstall logic in Invoke-AppDeployToolkit.ps1 (EXE only; MSI uses Zero-Config)
    c. Sets AppProcessesToClose based on App Paths registry entries
13. Explorer                 Opens the finished project folder
```

---

## Output files

| File | Purpose |
|---|---|
| `Invoke-AppDeployToolkit.ps1` | Main PSADT deployment script, pre-configured for your installer |
| `Files\<installer>` | The downloaded installer file |
| `Files\installer.yaml` | Winget manifest (contains metadata used during configuration) |
| `Assets\AppIcon.png` | Application icon downloaded from the Winget manifest |
| `Config\config.psd1` | PSADT configuration — branding applied from org template |
| `Strings\strings.psd1` | PSADT localisation strings — progress and balloon messages from org template |
| `SupportFiles\TargetedDocumentationScript.ps1` | Script that runs inside Windows Sandbox to capture install changes |
| `SupportFiles\RequirementScript.ps1` | Ready-to-paste Intune Win32 requirement script |
| `<ProjectName>_TargetedDocumentation.wsb` | Windows Sandbox configuration — double-click to re-run documentation |

---

---

## Test-Win32ToolkitProject

Tests a PSADT project by launching a **Windows Sandbox** session that runs a full install/uninstall cycle (or another scenario). This can be called standalone after packaging, as part of a pipeline via `-RunTest` on `Invoke-Win32Toolkit`, or at any time against any existing PSADT project folder.

```powershell
Test-Win32ToolkitProject
    [-ProjectPath <string>]
    [-BasePath <string>]
    [-Scenario <string>]
```

### Parameters

#### `-ProjectPath <string>`

Full path to an existing PSADT project folder (the folder that contains `Invoke-AppDeployToolkit.ps1`). If omitted, an interactive numbered list is shown that scans `BasePath` for valid projects.

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0'
```

---

#### `-BasePath <string>`

Root folder to scan for PSADT projects when `-ProjectPath` is not provided. Defaults to `C:\Win32Apps`.

```powershell
# Show a project picker over all projects in a custom folder
Test-Win32ToolkitProject -BasePath 'D:\Packaging\Projects'
```

---

#### `-Scenario <string>`

The test scenario to execute. Defaults to `InstallUninstall`.

| Value | Description |
|---|---|
| `InstallUninstall` | Install → 2-minute countdown (skippable) → Uninstall. Sandbox stays open for verification. |
| `Update` | *Reserved — placeholder for a future update-over-existing-install test.* |

```powershell
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0' -Scenario InstallUninstall
```

---

### How InstallUninstall works

When this scenario runs the function:

1. Creates `<ProjectPath>\Sandbox\Countdown.ps1` — a WinForms countdown dialog (2 minutes, skippable) displayed between install and uninstall
2. Writes `<ProjectPath>\Sandbox\FinalDemo.wsb` — the Windows Sandbox configuration that maps the project folder to `C:\PSADT` inside the sandbox
3. Launches Windows Sandbox with the `.wsb` file; the sandbox automatically:
   - Runs `Invoke-AppDeployToolkit.ps1` (install)
   - Shows the countdown dialog
   - Runs `Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall`
   - Keeps the sandbox window open for manual verification

```
Sandbox\
  Countdown.ps1      WinForms dialog with 2-min timer and Skip button
  FinalDemo.wsb      Sandbox config — double-click to re-run the test
```

### Examples

```powershell
# Interactive project picker (scans C:\Win32Apps)
Test-Win32ToolkitProject

# Direct path
Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0'

# Interactive picker over a custom folder
Test-Win32ToolkitProject -BasePath 'D:\Packaging'

# Called automatically at the end of a packaging run
Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall
```

---

## Notes

- **MSI installers** use PSADT's Zero-Config MSI feature — `AppName` is left empty so PSADT reads the product name directly from the MSI database. No manual uninstall logic is required.
- **EXE installers** have install and uninstall logic generated and inserted automatically using data from the sandbox documentation run.
- The **Windows Sandbox** session maps the project folder to `C:\PSADT` inside the sandbox. Documentation output (JSON + log) is written back to `C:\PSADT\Documentation` on the host via the mapped folder.
- If no `IconUrl` is present in the Winget YAML manifest, the default PSADT icon is kept unchanged.
- The PSAppDeployToolkit module update check (step 1 of `Create-PSADTProject`) can be suppressed with `-Force`.
