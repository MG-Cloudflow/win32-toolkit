# Configuration reference

All win32-toolkit settings are stored as per-user registry values under:

```
HKCU:\Software\CloudFlow\win32-toolkit
```

There is no config file. The module reads each value on demand and falls back to a built-in default when the value is absent or blank.

## How to change a setting

There is no public `Set-...ConfigValue` command; the setter is a private helper. You change settings in one of three ways:

1. **The TUI**: run [Show-Win32Toolkit](reference/Show-Win32Toolkit.md), open **Settings**. This covers the base folder (`BasePath`) and, under **Hyper-V test VM**, the default test backend (`TestBackend`) plus VM provisioning, resources, reset and removal.
2. **The exported Hyper-V commands**: [New-Win32ToolkitTestVM](reference/New-Win32ToolkitTestVM.md) and [Set-Win32ToolkitTestVMResource](reference/Set-Win32ToolkitTestVMResource.md) persist the VM name, checkpoint name, CPU and memory values for you as part of doing their job. You normally never set those by hand.
3. **Editing the registry directly**, for the values with no TUI control (`SandboxTestMode`, `HyperVTestMode`, `PipelineCache`, `HyperVDepsCheckpoint`, `PreferredPsadtVersion`). For example:

```powershell
Set-ItemProperty -Path 'HKCU:\Software\CloudFlow\win32-toolkit' -Name 'PipelineCache' -Value 'Off'
```

Do **not** hand-edit `HyperVGuestUser` / `HyperVGuestSecret`. See [Guest credential](#guest-credential).

## All values

| Value | Default (when absent) | Allowed values | What it changes |
|---|---|---|---|
| `BasePath` | prompted on first run | any folder path | Root folder for all output (`Templates\`, `Projects\`, `Staging\`, `IntuneWin\`, `Cache\`). |
| `TestBackend` | `Sandbox` | `Sandbox`, `HyperV` | Which backend runs test/capture sessions. `HyperV` falls back to Sandbox when the VM is not ready. |
| `SandboxTestMode` | `Interactive` | `Interactive`, `Unattended` | Whether Sandbox test runs are watched (GUI, countdown) or unattended (`-DeployMode Silent`, back-to-back). |
| `HyperVTestMode` | `Interactive` | `Interactive`, `Unattended` | Whether Hyper-V test runs are watched (GUI, host pause) or unattended Intune-parity runs (the published command line from a 32-bit parent, as SYSTEM; see [Testing](testing.md#watched-vs-unattended)). |
| `PipelineCache` | `On` | `On`, `Off` | Download/staging cache for the pipeline (see below). |
| `HyperVDepsCheckpoint` | `Off` | `On`, `Off` | Opt-in per-project dependency checkpoint in the test VM (see below). |
| `PreferredPsadtVersion` | *(not set)*: newest supported installed | an exact version (`4.1.8`, `4.2.0-rc2`) or `Major.Minor` (`4.1`) | Which installed PSAppDeployToolkit new projects are built with (see below). |
| `HyperVVMName` | `win32tk-golden` | any VM name | Name of the Hyper-V test VM. Written by provisioning; read everywhere the VM is used. |
| `HyperVCheckpoint` | `clean-base` | any checkpoint name | The clean checkpoint every test run reverts to. |
| `HyperVBaseVhdx` | *(not set)* | path | Record of where provisioning placed the golden VHDX. Informational only: never read back by the module. |
| `HyperVProcessorCount` | `2` | integer ≥ 1 | vCPU count used at (re-)provisioning and shown in the TUI. |
| `HyperVMemoryStartupBytes` | `4294967296` (4 GB) | bytes | Startup memory used at (re-)provisioning and shown in the TUI. |
| `HyperVGuestUser` | *(not set)* | username | Local-admin account inside the test VM (for PowerShell Direct). |
| `HyperVGuestSecret` | *(not set)* | DPAPI blob | The guest admin password, encrypted. Never store a plain-text password here. |

## BasePath

`BasePath` is resolved by a single helper everywhere in the module. Precedence: an explicit `-BasePath` parameter on a command wins for that call (and is **not** saved); otherwise the stored registry value is used; otherwise you are prompted once and the answer is saved. Change it later from the TUI **Settings → Change the base folder**, or pass `-Reconfigure` where a command offers it.

## PSAppDeployToolkit version (`PreferredPsadtVersion`)

win32-toolkit builds projects with **PSAppDeployToolkit 4.1.x or 4.2.x** and never selects, installs or offers a version outside that range. Without a preference, a new project uses the newest supported version installed on this machine (a stable build before a prerelease of the same version). When no supported version is installed (none at all, or only versions outside the range), the newest stable supported version is installed from the PowerShell Gallery for the current user. A prerelease is never installed for you; one you installed yourself is used (with a warning) when it is the newest supported version.

To build new projects with a specific version, set a preference. The first non-empty source wins:

1. The environment variable `W32T_PSADT_VERSION` (this PowerShell session only; handy for testing a prerelease side by side).
2. The registry value `PreferredPsadtVersion`.

```powershell
# Pin every new project on this machine to the newest installed 4.1.x
Set-ItemProperty -Path 'HKCU:\Software\CloudFlow\win32-toolkit' -Name 'PreferredPsadtVersion' -Value '4.1'

# Try a prerelease in this session only (it must be installed and inside the supported range)
$env:W32T_PSADT_VERSION = '4.2.0-rc2'
```

The value is an exact version as PowerShellGet shows it (`4.1.8`, `4.2.0-rc2`, case-insensitive) or `Major.Minor` (`4.1` = the newest installed 4.1.x). A pinned version must already be installed: when it is not installed, or is outside the supported range, project creation stops with a warning instead of falling back to another version, and nothing is installed (the warning and the health screen name the pin to clear: the environment variable or the registry value). A pin also turns off the update offer; while a pin is active the health screen says so (for example `v4.1.8; pinned by PreferredPsadtVersion (registry); 4.2.0-rc2 also installed`).

Existing projects are not affected: each project keeps the PSAppDeployToolkit copy it was built with (the TUI's **Browse projects** shows it per project).

One PowerShell session can only hold one PSAppDeployToolkit version. If a different version is already loaded (for example after building a project with another pin), project creation stops and asks you to start a new PowerShell session.

## Test modes (`SandboxTestMode`, `HyperVTestMode`)

`Unattended` makes that backend's tests run back-to-back: no countdown or pause, and (for Sandbox) the guest shuts itself down afterwards. Under Sandbox, PSADT deploys with `-DeployMode Silent`; under Hyper-V, the install, uninstall and update run exactly the way Intune starts them (see [Testing](testing.md#watched-vs-unattended)). This changes *what is tested* (there is no human verification window), so the mode is recorded in the test outcome.

Per-run precedence, resolved identically for both backends:

1. An explicit `-Unattended` switch on [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md) always wins.
2. The config value (`Unattended` opts in).
3. A non-interactive host (redirected stdin, `pwsh -NonInteractive`) forces `Unattended` with a loud warning: interactive pauses would hang or throw there.
4. Otherwise: `Interactive`.

Set the config value when you *always* run unattended (for example on a build server); use the switch for one-off unattended runs.

## Performance switches

These two switches trade a little state on disk (or in the VM) for wall-clock time. Both fail open: any cache problem falls back to the uncached behavior.

### `PipelineCache` (default `On`)

Caches update-baseline downloads under `<BasePath>\Cache\winget\` and reuses dependency staging within 6 hours. Every reuse is SHA256-verified against the winget manifest (baselines) or re-hashed (staged files). A tampered or torn entry is re-downloaded, never trusted. Set `Off` to restore the old always-download behavior. Caching also silently disables itself when no `BasePath` is configured yet (a cache lookup never prompts).

### `HyperVDepsCheckpoint` (default `Off`)

When `On`: after a project's dependencies install once in the test VM, a `clean-base+deps-<hash>` checkpoint is taken, and later runs of that project restore it instead of re-installing the dependencies. The hash covers the dependency set, every staged installer byte, and the parent checkpoint identity. Any change falls back to `clean-base` plus a live install. VM maintenance (resource changes, re-checkpointing) deletes the checkpoint; it is simply recreated on the next run. Leave `Off` unless you repeatedly test the same dependency-heavy project.

## Guest credential

`HyperVGuestUser` / `HyperVGuestSecret`:

PowerShell Direct needs the test VM's local-admin credential on every Hyper-V run. The username is stored plain; the password is protected with Windows DPAPI (`ConvertFrom-SecureString`, no key), which means it is **bound to your Windows user on this machine**: it cannot be copied to another machine or read by another user, and if a different Windows account tries to use it the module warns and treats it as unset. It is written when you provision the VM (you are prompted, password typed twice); to change it, re-provision or re-run the provisioning command rather than editing the registry.

## Hyper-V VM identity and resources

`HyperVVMName`, `HyperVCheckpoint`, `HyperVProcessorCount` and `HyperVMemoryStartupBytes` are managed for you: provisioning writes all four, and the **Change VM resources** action (TUI) or [Set-Win32ToolkitTestVMResource](reference/Set-Win32ToolkitTestVMResource.md) updates CPU/memory and re-takes the clean checkpoint. A re-provision reuses the stored CPU/memory as its defaults, so your specs survive a rebuild. Only edit these by hand if you renamed the VM or checkpoint outside the toolkit and need the config to match.

<!-- SCREENSHOT: the TUI Settings screen showing the base folder and the Hyper-V test VM entry -->
