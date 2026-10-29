---
description: "Change, reset, repair, rebuild or remove the Hyper-V test VM, and share it between PowerShell windows."
---

# Look after the Hyper-V test VM

The [Hyper-V test VM](glossary.md#hyper-v-test-vm) is a Windows 11 virtual machine (VM) that
win32-toolkit can use for tests. Before and after each test, the VM goes back to its [checkpoint](glossary.md#checkpoint) `clean-base`: a saved state of the running VM. This page shows how to change,
reset, repair, rebuild, remove and share the VM.

## Before you start

- You built the test VM ([Set up the Hyper-V test VM](hyperv-vm.md)).
- Open PowerShell 7 as administrator for every task on this page.
- Only one PowerShell window at a time can use the test VM.
- Time: about 30 to 70 seconds for a reset, a few minutes for a change. A rebuild takes about 30 to 60 minutes, plus
  Windows Update time.

## Change processors or memory

Give the VM more virtual processors or more memory without a rebuild. The default is 4 GB. Give the VM 6 to 8 GB if
your PC has the memory.

!!! warning "Reset the VM first"
    This change deletes every checkpoint of the VM, including the ones you made yourself. The new `clean-base` keeps the
    disk of the VM as it is now. So [reset the VM](#reset-the-vm-by-hand) first.

=== "Menu"

    1. Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)).
    2. Choose **Settings** > **Hyper-V test VM** > **Change VM resources**.
    3. At **New vCPU count**, type the number of virtual processors. Leave it blank to keep the current number.
    4. At **New memory**, type a size such as `8GB`. Leave it blank to keep the current size.
    5. At **Apply now?** answer `y`. (The default is Yes.)

=== "Command line"

    [Set-Win32ToolkitTestVMResource](reference/Set-Win32ToolkitTestVMResource.md) does not ask for confirmation. This
    example gives the VM 4 processors and 8 GB of memory.

    ```powershell
    Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB
    ```

    For every option, see [Set-Win32ToolkitTestVMResource](reference/Set-Win32ToolkitTestVMResource.md).

Limits: 1 to 64 processors, and never more than your PC has. Memory: from 2 GB to the memory of your PC minus 2 GB.

The toolkit turns the VM off, applies the change, starts the VM and takes a new `clean-base`. The new values also
become the defaults for your next VM build. Time: a few minutes.

## Reset the VM by hand

Tests already reset the VM before and after each run. Reset it by hand after you used the VM yourself, and before you
change its processors or memory.

=== "Menu"

    Choose **Settings** > **Hyper-V test VM** > **Reset the VM to its clean checkpoint**.

=== "Command line"

    [Reset-Win32ToolkitTestVM](reference/Reset-Win32ToolkitTestVM.md) prints nothing when it works.

    ```powershell
    Reset-Win32ToolkitTestVM
    ```

    For every option, see [Reset-Win32ToolkitTestVM](reference/Reset-Win32ToolkitTestVM.md).

In some cases the VM stays **Saved** after the reset (paused, with its memory on disk). Then start it with
`Start-VM -Name 'win32tk-golden'` (use your VM name). Time: about 30 to 70 seconds, depending on your PC.

## Repair a broken VM

Use the repair when the VM exists but is not ready. It is in the menu only. It fixes three cases:

- An [interactive test](glossary.md#interactive-test) warns `No interactive desktop detected`, because
  Windows shows the sign-in screen. An interactive test is a test that you watch.
- A build stopped at the preparation pause, so the checkpoint is missing.
- The toolkit has no saved VM password (`guest credential is not configured`).

The menu label says **guest**: the Windows inside the VM. [AutoLogon](glossary.md#autologon) signs the
VM user in when Windows starts.

!!! warning "The repair resets the VM first"
    You lose every change since the last checkpoint, including new Windows updates. To keep updates, follow
    [Re-take the checkpoint](hyperv-vm.md#re-take-the-checkpoint) instead.

1. Choose **Settings** > **Hyper-V test VM** > **Configure guest AutoLogon + re-checkpoint**.
2. If the toolkit asks for a user name, type the one that the VM was built with. (The default is `w32admin`.)
3. Type the password of that user twice.

The repair tests the password and turns on AutoLogon. Then it deletes all checkpoints and takes a new `clean-base` at
the signed-in desktop.

If a yellow panel says `Could not reach a desktop to re-checkpoint`, sign in once in the VM window. Then run the repair
again. A wrong password is never saved, but the repair finds it only after about 15 minutes.

## Fix a wrong VM password

The check that the VM is ready does not test the saved VM password. With a wrong password, every Hyper-V test waits
about 15 minutes. Then it stops with `PowerShell Direct did not become ready within 900 s`. PowerShell Direct is how the
toolkit reaches Windows in the VM.

This happens when you type a wrong password in [New-Win32ToolkitTestVM](reference/New-Win32ToolkitTestVM.md) on an
existing VM. To fix it, run the command again with the same VM name and ISO path. Do not add `-Force`.

```powershell
New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -Name 'win32tk-golden'
```

At **User name**, type the user name of the VM. (The default is `w32admin`.) Then type the right password twice. The
command prints `VM 'win32tk-golden' already exists with checkpoint 'clean-base' - reusing.` and saves the password
without a test, so type it with care.

The saved password works only for the Windows user who saved it, on this PC. If you see `Stored Hyper-V guest
credential could not be decrypted`, run the [repair](#repair-a-broken-vm) as the user who runs the tests. If nobody
knows the password, [rebuild the VM](#rebuild-the-vm).

## Rebuild the VM

`New-Win32ToolkitTestVM` with the same name reuses an existing VM and its checkpoint. To start again from nothing, add
`-Force`:

```powershell
New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -Force
```

This deletes the VM, its checkpoints and its disk. Then it builds everything again, and you
[prepare Windows](hyperv-vm.md#prepare-windows-inside-the-vm) as you did the first time. Time: about 30 to 60 minutes,
plus Windows Update time.

If a build stopped before its checkpoint, a new run without `-Force` stops with `VHDX already exists`. (The VHDX is the
disk file of the VM.) Use the [repair](#repair-a-broken-vm) instead.

!!! warning "The menu rebuilds by default"
    **Settings** > **Hyper-V test VM** > **Provision the test VM from a Windows 11 ISO** checks for an existing VM or
    disk. If it finds one, it asks **Delete it and rebuild from scratch?** The default is Yes. Answer `n` to keep your
    VM.

## Remove the VM

Remove the VM when you stop testing on Hyper-V. If you built the VM on your own virtual disk, the removal can delete
that file. Copy it first if you need it.

=== "Menu"

    1. Choose **Settings** > **Hyper-V test VM** > **Remove the test VM**.
    2. At **Remove the test VM and delete its VHDX?** answer `y`. (The default is No.)

    The menu always deletes the disk files too.

=== "Command line"

    [Remove-Win32ToolkitTestVM](reference/Remove-Win32ToolkitTestVM.md) does not ask for confirmation. `-RemoveVhdx`
    also deletes the disk files.

    ```powershell
    Remove-Win32ToolkitTestVM -RemoveVhdx
    ```

    For every option, see [Remove-Win32ToolkitTestVM](reference/Remove-Win32ToolkitTestVM.md).

Then check the folder `<base folder>\HyperV\Golden`. If `win32tk-golden.vhdx` is still there, delete it by hand to get
the space back.

Your settings stay. If the test VM was your default, tests warn `Hyper-V test backend requested but not ready` and use
Windows Sandbox. Set the default back with **Settings** > **Hyper-V test VM** > **Set the default test backend** >
**Windows Sandbox**. Without the menu, change the setting `TestBackend` to `Sandbox`
([Settings and folders](settings.md#change-a-setting)).

## Use another VM in one PowerShell window

To test on a second VM in one window only, set the [environment variable](glossary.md#environment-variable) `W32T_HYPERV_VM` there. An environment variable is a named value that
a PowerShell window and its programs can read. Other windows keep your usual VM.

The variable chooses the VM, not where tests run. So add `-Backend HyperV` to
[Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md), unless the test VM is already your default.

```powershell
$env:W32T_HYPERV_VM = 'win32tk-second'   # this window only
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Test-Win32ToolkitProject -ProjectPath $project -Scenario InstallUninstall -Backend HyperV
```

The console calls this VM [pinned](glossary.md#pin). In this window:

- Hyper-V tests and the commands that change, reset or remove the VM use the pinned VM.
- The VM commands do not save its name, checkpoint or size as your defaults.
- The checkpoint name stays your usual one (`clean-base`), unless you also set `W32T_HYPERV_CHECKPOINT`.
- If the pinned VM is not ready, the test stops. It never uses Windows Sandbox instead.

To build the second VM, set the variable first. Then run `New-Win32ToolkitTestVM` with `-Name 'win32tk-second'` in
that window. Without the variable, the command saves the second VM as your default.

Use the same user name and password as your first VM: all test VMs share one saved password. To stop using the
second VM, close the window.

## When another window is using the VM

Every Hyper-V test and every VM command waits while another PowerShell window uses the test VM. The waiting window
prints:

```text title="What you see"
Waiting for the test VM 'win32tk-golden': another process is using it (test run since 2026-10-29 09:15:30Z, process 4242); up to 60 minutes...
```

The waiting window continues by itself when the other task ends or its window closes. With `HyperVAsyncTeardown` on,
the menu keeps the VM after an unattended test. Other windows then wait until the menu uses the VM again or you leave
the menu. After 60 minutes, the waiting window stops
with `Another process kept the test VM` (error ID `W32T.HyperVLeaseTimeout`). Nothing was started or reset.

Try again later, or use [another VM](#use-another-vm-in-one-powershell-window). To wait longer, raise the setting
`HyperVLeaseWaitMinutes` (1 to 240, see [Settings and folders](settings.md#hyper-v-test-vm)).

Hyper-V Manager and Hyper-V's own commands, such as `Start-VM`, do not wait. Do not reset, start or change the test VM
with them while a test runs.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `Requested` (then `vCPU exceeds` or a size in GB) | Stay inside the limits of [Change processors or memory](#change-processors-or-memory). |
| `No guest credential is stored - cannot verify the VM desktop` | Run the [repair](#repair-a-broken-vm) once to save the password, then try again. |
| `Could not power off VM` | Nothing changed. Run `Stop-VM -Name 'win32tk-golden' -TurnOff`, then try again. |
| `The guest desktop (explorer) did not come up within 10 minutes` | The VM has the new values but no `clean-base`. Look at the VM window, then run the [repair](#repair-a-broken-vm). |
| `Test VM 'win32tk-golden' does not exist` | No VM has this name. Check the name in Hyper-V Manager, or [build the VM](hyperv-vm.md#build-the-vm). |

For more messages, see [Troubleshooting](troubleshooting.md#hyper-v-test-vm).

## Next steps

- [Set up the Hyper-V test VM](hyperv-vm.md): build the VM, re-take the checkpoint and make tests faster.
- [Settings and folders](settings.md): the Hyper-V settings and where the VM files are.
