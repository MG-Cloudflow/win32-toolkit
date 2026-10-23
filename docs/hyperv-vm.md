# Set up and manage the Hyper-V test VM

Windows Sandbox is the default test/capture backend. The Hyper-V test VM is an **opt-in, faster
alternative**: you provision one persistent Windows 11 VM once, and every later test run reverts it
to a warm checkpoint instead of cold-booting a fresh Sandbox.

## Why Hyper-V instead of Sandbox

| | Windows Sandbox | Hyper-V test VM |
|---|---|---|
| Start of each run | Cold boot of a fresh sandbox, every time | **Revert to a memory-state ("Standard") checkpoint**. The VM resumes on an already running, logged-in desktop. A restore costs from seconds on a host with fast local disks to about a minute on a nested VM (for example a Windows 365 Cloud PC); see [Make Hyper-V tests faster](#make-hyper-v-tests-faster) |
| Test context | Sandbox's built-in user | **Every phase runs as SYSTEM**, the account Intune uses on real devices. Unattended runs also start the package exactly as Intune does (the published command line from a 32-bit parent), so install/uninstall behavior matches deployment (see [Testing](testing.md#watched-vs-unattended)) |
| Base image | Always the pristine Sandbox image | A **fully patched** Windows 11 you prepared once: patched when you took the checkpoint; it ages, so re-take it regularly ([below](#re-checkpoint-after-windows-updates)) |
| Extras | None | Optional deps checkpoint that skips repeated dependency installs (see [Configuration](configuration.md)) |

The backend is resolved **per run**: if the VM, its checkpoint, or the stored guest credential is
missing, or the session is not elevated, the toolkit warns and falls back to Sandbox automatically.

## Prerequisites

- The **Hyper-V feature and its PowerShell module** enabled on the host.
- An **elevated (Administrator) PowerShell session**. Hyper-V and PowerShell Direct require it. Provisioning refuses to start without it.
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

- **Guest credential**: you are prompted for a guest local-admin credential (typed twice; a blank password is refused because it breaks PowerShell Direct and AutoLogon). When building from an ISO it is baked into the image; it is then stored DPAPI-protected on the host for later test runs.
- **Edition selection (ISO builds)**: by default the toolkit picks **Windows 11 Pro first, Enterprise as a fallback**. Use `-Edition` (name substring, e.g. `'Enterprise'`) or an explicit `-ImageIndex` to override. Pro is the right choice for a consumer multi-edition ISO.
- **Secure Boot + vTPM**: the VM is Generation 2 with Secure Boot on and a virtual TPM attached by default (Windows 11 requires both).
- If a VM with the configured name and checkpoint already exists, provisioning **reuses it** and just refreshes the stored config and credential.

### The manual prep step: do not skip it

After first boot, provisioning **pauses**: it opens the VM console (`vmconnect`), verifies the guest
has working internet, and waits for you. In the VM window:

1. Sign in (AutoLogon is configured as a safety net for reboots).
2. Run **Windows Update until nothing is left**; install everything.
3. Let **all reboots finish** and return to the desktop.
4. Close any first-run app windows so the desktop is idle and clean.

Only when you press Enter does the toolkit freeze the **`clean-base` Standard checkpoint**. This
matters because a Standard checkpoint captures the *live* state (memory and disk) and **every
future test run reverts to exactly that moment**. A patched, logged-in, idle desktop means tests
start instantly and never compete with Windows Update or first-run pop-ups. `-Unattended` skips the
pause (CI/automation) and checkpoints the bare first-boot desktop instead.

> **Closed the window during the pause?** The checkpoint and the stored guest credential are only
> saved at the very end, so aborting here leaves the VM existing but the backend "not ready"
> (*checkpoint not found; guest credential is not configured*). You do **not** need to rebuild:
> run the TUI's **Configure guest AutoLogon + re-checkpoint** action — it asks for the guest
> credential the image was built with (verifying it over PowerShell Direct before saving it),
> boots the VM, and takes the missing `clean-base` checkpoint at the logged-in desktop.

<!-- SCREENSHOT: the yellow "PREPARE THE VM, THEN CONFIRM" console banner during New-Win32ToolkitTestVM, next to the open VM console window -->

## Enable the backend

Set the default backend to Hyper-V in the TUI (*Hyper-V test VM* screen, below), or pass
`-Backend HyperV` for a single run of [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

## Day-2 management

### Change CPU or memory

```powershell
Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB
```

This reconfigures the **existing** VM in place (minutes), no ISO rebuild. It must turn the VM off
(static memory/vCPU cannot change while running) and it **recreates the `clean-base` checkpoint**:
the old Standard checkpoint encodes the old memory state, so keeping it would silently revert your
hardware change on the next reset. Requests above the host's CPU/RAM are refused. Details:
[Set-Win32ToolkitTestVMResource](reference/Set-Win32ToolkitTestVMResource.md).

Provisioning, the resource change and the checkpoint repair turn Hyper-V **automatic checkpoints** off
before they start the VM, and take `clean-base` with them off. With them on, Hyper-V adds an
`Automatic Checkpoint` every time the VM starts from Off, and a checkpoint keeps the setting, so every
restore would bring it back. A test run whose checkpoint was taken with them on prints one warning and
keeps the slower restore (see [Make Hyper-V tests faster](#make-hyper-v-tests-faster)).

If the checkpoint cannot be taken (for example the host disk is full), provisioning, the resource change
and the repair stop with Hyper-V's error: they print no success line and save no settings.

### Reset, remove

- [Reset-Win32ToolkitTestVM](reference/Reset-Win32ToolkitTestVM.md) manually reverts the VM to `clean-base` (test runs do this for you).
- [Remove-Win32ToolkitTestVM](reference/Remove-Win32ToolkitTestVM.md) tears the VM down; add `-RemoveVhdx` to also delete its virtual disks.

### Re-checkpoint after Windows Updates

The frozen base ages. Periodically: reset the VM, open its console, run Windows Update in the guest,
let reboots finish, then replace the checkpoint at the idle desktop:

```powershell
Get-VMCheckpoint -VMName 'win32tk-golden' | Remove-VMCheckpoint
Set-VM -Name 'win32tk-golden' -CheckpointType Standard
Set-VM -Name 'win32tk-golden' -AutomaticCheckpointsEnabled $false
Checkpoint-VM -VMName 'win32tk-golden' -SnapshotName 'clean-base'
```

Turn automatic checkpoints off before `Checkpoint-VM`: a checkpoint keeps this setting, every restore
brings it back, and a test run warns about a checkpoint taken with it on.

Re-take the checkpoint at least every 35 days: an unattended test run warns about an older checkpoint,
about one restored with nobody signed in, and about Defender real-time protection off, Defender exclusions
or old Defender signatures in it (see [Testing](testing.md)). Leave a user signed in to the desktop,
Defender real-time protection on and no exclusions, and run `Update-MpSignature` in the guest first.

### Make Hyper-V tests faster

**What a run costs.** Every Hyper-V test run restores the checkpoint twice: before the test, and after it
to leave the VM clean. On a nested VM (a Windows 365 Cloud PC, measured on 2026-10-23) each restore took
about 70 seconds, and most of that was Hyper-V saving the running VM's memory to disk only to throw it away.
Your host's numbers are in the test record: `Documentation\TestResults.json` keeps a `Timing` object per
Hyper-V run (`OpenSeconds`, `TeardownSeconds`, `RevertMode` and more).

**Turn the VM off before a restore** (`HyperVRevertMode`, default `TurnOffFirst`). The toolkit turns the VM
off, restores the checkpoint and starts the VM again, which resumes the checkpoint's memory state. Nothing is
saved, and the guest of the last test stops at once. This needs a checkpoint taken with automatic checkpoints
**off**: a checkpoint keeps that setting, and with it on Hyper-V can add an `Automatic Checkpoint` when the VM
starts. To see the setting of every checkpoint on the host (read-only):

```powershell
Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemSettingData -Filter "VirtualSystemType = 'Microsoft:Hyper-V:Snapshot:Realized'" | Select-Object ElementName, AutomaticSnapshotsEnabled
```

A checkpoint that reads `True` (or whose setting cannot be read) keeps the slower restore, and every
PowerShell session warns once until you re-take it with automatic checkpoints off (the procedure below).
To go back to the slower restore for every checkpoint, set `HyperVRevertMode` to `Legacy`
([Configuration](configuration.md#hypervrevertmode-default-turnofffirst)).

**Re-take the clean checkpoint, in this order:**

1. `Reset-Win32ToolkitTestVM`. If the VM is not running afterwards (`Get-VM -Name 'win32tk-golden'` shows
   `Saved`), start it with `Start-VM -Name 'win32tk-golden'`. Let the desktop settle for a few minutes, then
   shut the VM down gracefully (`Stop-VM -Name 'win32tk-golden'`, not `-TurnOff`).
2. With the VM off, turn automatic checkpoints off and, optionally, set the stop and start actions (see
   *Stop and start actions* below):

   ```powershell
   Set-VM -Name 'win32tk-golden' -AutomaticCheckpointsEnabled $false
   Set-VM -Name 'win32tk-golden' -AutomaticStopAction TurnOff -AutomaticStartAction Nothing   # optional
   ```

   Do this after the reset and before anything starts the VM again. A checkpoint taken with automatic
   checkpoints on turns them back on when the reset restores it, and with them on Hyper-V adds an
   `Automatic Checkpoint` when the VM starts from Off. Hyper-V refuses to change the stop action of a running
   VM.
3. Optional: change CPU or memory with `Set-Win32ToolkitTestVMResource` (it starts the VM and takes a
   checkpoint you replace in step 6), then wait until Hyper-V has finished merging the disks of the removed
   checkpoints (Hyper-V Manager shows the merge in the VM's status).
4. Start the VM if it is off, then patch and quiet it (see *A quiet, fresh checkpoint* below).
5. Check that a user is signed in to the desktop, that Defender real-time protection is on and that there
   are no Defender exclusions.
6. Re-take `clean-base` with the commands of [Re-checkpoint after Windows Updates](#re-checkpoint-after-windows-updates)
   (with the `Set-VM -AutomaticCheckpointsEnabled $false` line). Do **not** use the TUI's repair action for
   this: it restores the old checkpoint first and throws your preparation away.
7. Check the result: `Get-VMCheckpoint -VMName 'win32tk-golden'` lists only `clean-base`, and the command above
   shows `AutomaticSnapshotsEnabled` `False` for it.

**Memory.** The toolkit's default for a new VM is 4 GB. A VM with more memory has more to save and restore;
some installers check the memory and refuse to install with 4 GB, and memory pressure can stretch an install
toward the test time limits. That gives false failures, never false passes. There is no recommended size yet.

**A quiet, fresh checkpoint** (optional; guest commands run in Windows PowerShell 5.1 inside the VM):

1. Check that Windows is activated (`slmgr /dlv`).
2. Make sure Windows Update is on, install every update and let the reboots finish.
3. Let the VM settle at the desktop.
4. Turn off what would otherwise run during your tests: automatic installation of Windows updates, the
   OneDrive updater task, Microsoft Store automatic updates and the Customer Experience Improvement Program
   tasks. Check that each policy you use applies to your Windows edition (some are Enterprise or Education
   only).
5. Update the Defender signatures (`Update-MpSignature`).
6. Keep Defender real-time and cloud-delivered protection **on** and add **no** exclusions: the tests should
   see what a device sees.
7. Re-take the checkpoint (the procedure above), and refresh it at least monthly: a test run warns when the
   checkpoint is older than 35 days.

**Stop and start actions.** `Set-VM -AutomaticStopAction TurnOff -AutomaticStartAction Nothing` before you
re-take the checkpoint means a host shutdown does not write the VM's memory to disk (the next test restores
the checkpoint anyway) and the VM does not start by itself with the host. Run it while the VM is off (step 2
of the procedure above): Hyper-V refuses to change the stop action of a running VM.

**Many tests in one PowerShell session.** A test run skips its first restore when the same PowerShell session
restored the same VM and checkpoint at the end of the previous run less than 10 minutes ago, the VM has been
running since then, and that run was not a watched one. To restore before every test (for example a final
check), start a new PowerShell session.

### Tip: stop Edge and WebView2 from updating in the VM

Microsoft Edge and the WebView2 runtime update themselves in the background. In the test VM that
happens right after a checkpoint revert, during your test run, which:
- adds unrelated files and registry changes to the install capture;
- competes with the installer for CPU and network.

Turn their updater off once, from an elevated PowerShell on the Hyper-V host. The VM must be
running: start it with `Start-VM` if it is not.

```powershell
# Elevated PowerShell on the Hyper-V host
Import-Module win32-toolkit
$mod  = Get-Module win32-toolkit
$vm   = & $mod { Get-Win32ToolkitConfigValue -Name 'HyperVVMName' }
$cred = & $mod { Get-Win32ToolkitGuestCredential }

Invoke-Command -VMName $vm -Credential $cred -ScriptBlock {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    New-Item $p -Force | Out-Null
    Set-ItemProperty $p -Name AutoUpdateCheckPeriodMinutes -Type DWord -Value 0
    Set-ItemProperty $p -Name UpdateDefault -Type DWord -Value 0
    Set-ItemProperty $p -Name 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -Type DWord -Value 0  # Edge
    Set-ItemProperty $p -Name 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Type DWord -Value 0  # WebView2

    'edgeupdate','edgeupdatem' | ForEach-Object {
        Stop-Service $_ -Force -ErrorAction SilentlyContinue
        Set-Service  $_ -StartupType Disabled -ErrorAction SilentlyContinue
    }
    Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue | Disable-ScheduledTask
}
```

**Then re-checkpoint.** Every test run reverts the VM to `clean-base`, so the change is lost unless
you freeze it into the checkpoint, the same way as after Windows Updates (above):

```powershell
Get-VMCheckpoint -VMName $vm | Remove-VMCheckpoint
Set-VM -Name $vm -CheckpointType Standard
Set-VM -Name $vm -AutomaticCheckpointsEnabled $false
Checkpoint-VM -VMName $vm -SnapshotName 'clean-base'
```

As above, automatic checkpoints are turned off before `Checkpoint-VM`: a checkpoint keeps this setting.

Edge and WebView2 now stay at the version in the checkpoint. When you next update the VM (Windows
Update, above), update them by hand as well if your apps depend on a recent WebView2.

### The TUI screen

`Show-Win32Toolkit` → **Hyper-V test VM** shows backend readiness and the VM's current CPU/RAM, and
wraps everything above: set the default backend, provision from an ISO, change resources, reset,
repair (AutoLogon + re-checkpoint), and remove the VM.

The **Configure guest AutoLogon + re-checkpoint** action is the repair path whenever the backend
banner says "not ready" but the VM exists. It fixes a checkpoint frozen at the login screen *and*
the two leftovers of an interrupted provision: a missing `clean-base` checkpoint (it boots the VM
and takes a fresh one at the logged-in desktop) and a missing stored guest credential (it prompts
for the one the image was built with and saves it only after PowerShell Direct accepts it — so a
typo is never stored).

<!-- SCREENSHOT: the TUI Hyper-V test VM screen showing "Hyper-V backend is READY" and the menu options -->

## Configuration keys involved

| Key | Meaning |
|---|---|
| `TestBackend` | `Sandbox` (default) or `HyperV`: the default backend for test/capture runs |
| `HyperVVMName` | VM name (default `win32tk-golden`) |
| `HyperVCheckpoint` | Warm checkpoint name (default `clean-base`) |
| `HyperVProcessorCount` / `HyperVMemoryStartupBytes` | Last chosen hardware, reused as defaults by the next provision |
| `HyperVTestMode` | `Unattended` makes Hyper-V test runs non-interactive (Intune-parity) by default (`-TestMode` overrides it for one run; the menu's **Hyper-V run mode** lists it first) |
| `HyperVDepsCheckpoint` | `On` freezes a `clean-base+deps-*` checkpoint after a successful dependency install so later runs of that project skip it. See [Configuration](configuration.md) |
| `HyperVRevertMode` | `TurnOffFirst` (default) turns the VM off before each restore, `Legacy` keeps the plain restore. See [Make Hyper-V tests faster](#make-hyper-v-tests-faster) |

All keys live in the toolkit's registry config; see [Configuration](configuration.md) for the full list.
