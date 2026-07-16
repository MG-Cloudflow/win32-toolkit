# Set up and manage the Hyper-V test VM

Windows Sandbox is the default test/capture backend. The Hyper-V test VM is an **opt-in, faster
alternative**: you provision one persistent Windows 11 VM once, and every later test run reverts it
to a warm checkpoint instead of cold-booting a fresh Sandbox.

## Why Hyper-V instead of Sandbox

| | Windows Sandbox | Hyper-V test VM |
|---|---|---|
| Start of each run | Cold boot of a fresh sandbox, every time | **Revert to a memory-state ("Standard") checkpoint** — the VM resumes on an already running, logged-in desktop in seconds |
| Test context | Sandbox's built-in user | **Every phase runs as SYSTEM** — the same context Intune uses on real devices, so install/uninstall behavior matches deployment |
| Base image | Always the pristine Sandbox image | A **fully patched** Windows 11 you prepared once (no Windows Update noise during test runs) |
| Extras | — | Optional deps checkpoint that skips repeated dependency installs (see [Configuration](configuration.md)) |

The backend is resolved **per run**: if the VM, its checkpoint, or the stored guest credential is
missing — or the session is not elevated — the toolkit warns and falls back to Sandbox automatically.

## Prerequisites

- The **Hyper-V feature and its PowerShell module** enabled on the host.
- An **elevated (Administrator) PowerShell session** — Hyper-V and PowerShell Direct require it. Provisioning refuses to start without it.
- A **Windows 11 x64 ISO**, or your own bootable Generation-2 VHDX.

## Provision the VM (one time)

To provision from an ISO:

```powershell
New-Win32ToolkitTestVM -IsoPath 'C:\iso\Win11_x64.iso'
```

To attach a VHDX you already built (BYO):

```powershell
New-Win32ToolkitTestVM -VhdxPath 'D:\vm\win11-base.vhdx' -Credential (Get-Credential)
```

See [New-Win32ToolkitTestVM](reference/New-Win32ToolkitTestVM.md) for all options. Key behavior:

- **Guest credential** — you are prompted for a guest local-admin credential (typed twice; a blank password is refused because it breaks PowerShell Direct and AutoLogon). When building from an ISO it is baked into the image; it is then stored DPAPI-protected on the host for later test runs.
- **Edition selection (ISO builds)** — by default the toolkit picks **Windows 11 Pro first, Enterprise as a fallback**. Use `-Edition` (name substring, e.g. `'Enterprise'`) or an explicit `-ImageIndex` to override. Pro is the right choice for a consumer multi-edition ISO.
- **Secure Boot + vTPM** — the VM is Generation 2 with Secure Boot on and a virtual TPM attached by default (Windows 11 requires both).
- If a VM with the configured name and checkpoint already exists, provisioning **reuses it** and just refreshes the stored config and credential.

### The manual prep step — do not skip it

After first boot, provisioning **pauses**: it opens the VM console (`vmconnect`), verifies the guest
has working internet, and waits for you. In the VM window:

1. Sign in (AutoLogon is configured as a safety net for reboots).
2. Run **Windows Update until nothing is left**; install everything.
3. Let **all reboots finish** and return to the desktop.
4. Close any first-run app windows so the desktop is idle and clean.

Only when you press Enter does the toolkit freeze the **`clean-base` Standard checkpoint**. This
matters because a Standard checkpoint captures the *live* state — memory and disk — and **every
future test run reverts to exactly that moment**. A patched, logged-in, idle desktop means tests
start instantly and never compete with Windows Update or first-run pop-ups. `-Unattended` skips the
pause (CI/automation) and checkpoints the bare first-boot desktop instead.

<!-- SCREENSHOT: the yellow "PREPARE THE VM, THEN CONFIRM" console banner during New-Win32ToolkitTestVM, next to the open VM console window -->

## Enable the backend

Set the default backend to Hyper-V in the TUI (*Hyper-V test VM* screen, below), or pass
`-Backend HyperV` for a single run of [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

## Day-2 management

### Change CPU or memory

```powershell
Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB
```

This reconfigures the **existing** VM in place (minutes) — no ISO rebuild. It must turn the VM off
(static memory/vCPU cannot change while running) and it **recreates the `clean-base` checkpoint**:
the old Standard checkpoint encodes the old memory state, so keeping it would silently revert your
hardware change on the next reset. Requests above the host's CPU/RAM are refused. Details:
[Set-Win32ToolkitTestVMResource](reference/Set-Win32ToolkitTestVMResource.md).

### Reset, remove

- [Reset-Win32ToolkitTestVM](reference/Reset-Win32ToolkitTestVM.md) — manually revert the VM to `clean-base` (test runs do this for you).
- [Remove-Win32ToolkitTestVM](reference/Remove-Win32ToolkitTestVM.md) — tear the VM down; add `-RemoveVhdx` to also delete its virtual disks.

### Re-checkpoint after Windows Updates

The frozen base ages. Periodically: reset the VM, open its console, run Windows Update in the guest,
let reboots finish, then replace the checkpoint at the idle desktop:

```powershell
Get-VMCheckpoint -VMName 'win32tk-golden' | Remove-VMCheckpoint
Set-VM -Name 'win32tk-golden' -CheckpointType Standard
Checkpoint-VM -VMName 'win32tk-golden' -SnapshotName 'clean-base'
```

### The TUI screen

`Show-Win32Toolkit` → **Hyper-V test VM** shows backend readiness and the VM's current CPU/RAM, and
wraps everything above: set the default backend, provision from an ISO, change resources, reset,
fix a login-screen checkpoint (AutoLogon + re-checkpoint), and remove the VM.

<!-- SCREENSHOT: the TUI Hyper-V test VM screen showing "Hyper-V backend is READY" and the menu options -->

## Configuration keys involved

| Key | Meaning |
|---|---|
| `TestBackend` | `Sandbox` (default) or `HyperV` — the default backend for test/capture runs |
| `HyperVVMName` | VM name (default `win32tk-golden`) |
| `HyperVCheckpoint` | Warm checkpoint name (default `clean-base`) |
| `HyperVProcessorCount` / `HyperVMemoryStartupBytes` | Last chosen hardware — reused as defaults by the next provision |
| `HyperVTestMode` | `Unattended` makes Hyper-V test runs non-interactive by default |
| `HyperVDepsCheckpoint` | `On` freezes a `clean-base+deps-*` checkpoint after a successful dependency install so later runs of that project skip it — see [Configuration](configuration.md) |

All keys live in the toolkit's registry config; see [Configuration](configuration.md) for the full list.
