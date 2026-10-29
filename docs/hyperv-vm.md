---
description: "Decide if you need the Hyper-V test VM, build it once, make it your default, and keep its checkpoint fresh."
---

# Set up the Hyper-V test VM

win32-toolkit can test your packages in the [Hyper-V test VM](glossary.md#hyper-v-test-vm): a Windows
11 virtual machine (VM) that you build once on your PC. Every test starts from its clean [checkpoint](glossary.md#checkpoint) `clean-base`, a saved state of the running VM.

The test VM is optional. [Windows Sandbox](glossary.md#windows-sandbox) stays the default. It is an empty
Windows desktop that starts fresh for every test.

## When you need the test VM

| Topic | Windows Sandbox | Hyper-V test VM |
|---|---|---|
| Account that runs the install | The Windows Sandbox administrator | [SYSTEM](glossary.md#system-account), the account Intune uses on devices |
| [Unattended tests](glossary.md#unattended-test), without pauses | Silent mode | The exact command line that Intune uses |
| Enforce rules for prior installs | Not possible | Needed to capture and prove them |
| Start of each test | A fresh, empty Windows | Your own updated Windows 11, running and signed in |
| Time of an unattended test | About 2 minutes | About 4 to 5 minutes (depends on your PC) |
| Setup | Nothing to build | A one-time build, admin rights, disk space and memory |

Choose the test VM for tests that run like Intune. You also need it for [Enforce rules](prior-installs-enforce.md):
they remove another install of the app. It also helps if you test many packages and want an updated Windows.

Stay on Windows Sandbox if you cannot run PowerShell as administrator. It is also the better choice for a PC with
little disk space or memory. Turning on Hyper-V does not turn off Windows Sandbox.

## Prepare your PC

win32-toolkit never turns on Windows features. You turn them on once.

- Windows 11 Pro, Enterprise or Education, with virtualization on in the firmware. [Hyper-V](glossary.md#hyper-v), the virtual machine software of Windows, does not exist on Home.
- Hyper-V turned on: run the command below in PowerShell as administrator, then restart your PC.
- PowerShell 7 started with **Run as administrator**, an [elevated](glossary.md#elevated) window. Use
  it for every VM command and every test on the VM.
- A Windows 11 x64 [ISO](glossary.md#iso), the file of a Windows installation disc. An Enterprise
  evaluation ISO stops working properly after 90 days.
- Internet on your PC. The VM uses it for Windows Update and for tests.
- Optional: the app that shows the VM window (`vmconnect.exe`). Hyper-V usually installs it.

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

Plan about 60 to 80 GB of free disk space. The virtual disk grows to about 40 GB (at most 64 GB). Each checkpoint adds
about 2 to 4 GB. A running test adds 2 to 10 GB, which the next restore removes.

The VM holds all its memory while it runs. The default is 4 GB. Give the VM 6 to 8 GB if your PC has the memory. With
4 GB, some tests run much slower, and some installers refuse to install.

## Build the VM

You build the VM once. Time: about 30 to 60 minutes, plus Windows Update time.

=== "Menu"

    1. Open PowerShell 7 as administrator.
    2. Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)).
    3. Choose **Settings** > **Hyper-V test VM** > **Provision the test VM from a Windows 11 ISO**.
    4. At **Path to a Windows 11 x64 ISO**, type the path, for example `C:\ISO\Win11_x64.iso`, and press <kbd>Enter</kbd>.

    The menu always uses the default name, Windows edition, processors and memory. To give the VM more memory, change
    it after the build: see [Change processors or memory](hyperv-vm-care.md#change-processors-or-memory).

    Many yellow lines that start with `VERBOSE:` appear. They are normal, even the ones that say `PowerShell Direct is
    not ready yet`. PowerShell Direct is how the toolkit reaches Windows in the VM.

    If a VM or its disk is left from an earlier build, the menu asks **Delete it and rebuild from scratch?** The default
    is Yes. Answer `n` to keep your VM, and see [Rebuild the VM](hyperv-vm-care.md#rebuild-the-vm).

=== "Command line"

    Open PowerShell 7 as administrator and build the VM from your ISO:

    ```powershell
    New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso'
    ```

    `-Edition` or `-ImageIndex` chooses the Windows edition. By default, the toolkit takes Windows 11 Pro, or
    Enterprise when the ISO has no Pro. `-MemoryStartupBytes 8GB` gives the VM 8 GB. `-Unattended` is for automation
    only: no preparation pause, no VM window, no internet check, and a checkpoint without updates.

    For every option, see [New-Win32ToolkitTestVM](reference/New-Win32ToolkitTestVM.md).

The toolkit then asks for the account of the VM:

```text title="What you see"
Guest local-admin credential for VM 'win32tk-golden' - enter the password twice; it must NOT be blank.
  User name [w32admin]:
  Password for w32admin:
  Confirm password for w32admin:
```

Press <kbd>Enter</kbd> to keep the user name `w32admin`, the administrator inside the VM. Then type a password twice.
It cannot be blank.

Use a password for this lab only, because it is stored in clear text inside the VM. In the toolkit's messages, "guest"
means the Windows inside the VM.

What the toolkit does next:

1. It builds a virtual disk from the ISO in your [base folder](glossary.md#base-folder), under
   `HyperV\Golden`.
2. It creates the VM `win32tk-golden`, with Secure Boot and a virtual TPM, as Windows 11 needs.
3. Windows installs by itself and signs in the VM account.
4. The toolkit turns on [AutoLogon](glossary.md#autologon): Windows signs you in after each restart.
5. It waits while you prepare Windows (next section).
6. It takes the checkpoint `clean-base` and saves the VM name and password for later tests.

The command prints `✓ Warm 'clean-base' checkpoint taken.` The menu shows a green **Done** panel.

When you build from an ISO, the toolkit sets the language settings of Windows in the VM to English (United States).
It also sets the UTC time zone and the computer name `GOLDENBASE`. The toolkit enters no product key. Activate
Windows in the VM with your own license, or use an evaluation ISO.

## Prepare Windows inside the VM

When Windows is ready, the toolkit opens the VM window and checks the internet in the VM. If the check fails, the
toolkit sets the public name servers (DNS) `1.1.1.1` and `8.8.8.8` in the VM and tries again. These name servers
stay in the VM. Then the toolkit shows this yellow banner in PowerShell.

```text title="What you see"
──────────────────────────────────────────────────────────────────────────────
  PREPARE THE VM, THEN CONFIRM - the checkpoint freezes whatever state is live
──────────────────────────────────────────────────────────────────────────────
  The VM 'win32tk-golden' IS created and running right now - this prompt is only waiting for you.
  Guest internet: OK (DNS + outbound reachable) - Windows Update should work.
  A console window opened for 'win32tk-golden'. In that window:
    1. Sign in if you're not already (user: w32admin).
    2. Run Windows Update until nothing is left; install everything.
    3. Let ALL reboots finish and return to the desktop (AutoLogon signs back in).
    4. Close first-run app windows so the desktop is idle and clean.

  Every test run reverts to exactly this moment - make it a fully patched, idle desktop.

  When the desktop is fully ready, press Enter to capture the clean-base checkpoint:
```

<!-- SCREENSHOT: the yellow "PREPARE THE VM, THEN CONFIRM" console banner during New-Win32ToolkitTestVM, next to the open VM console window -->

Do these steps in the VM window.

1. Sign in as `w32admin` if Windows shows the sign-in screen.
2. Run Windows Update until nothing is left to install.
3. Let every restart finish. AutoLogon signs you in again.
4. Close first-run windows, so that the desktop is idle.
5. Stay signed in at the desktop.

Tests also check Microsoft Defender in the checkpoint. Keep its real-time protection on, without exclusions. Update its
signatures with `Update-MpSignature`. Also check that Windows is activated (`slmgr /dlv`).

Then press <kbd>Enter</kbd> in PowerShell. The toolkit checks the desktop again and takes the checkpoint. Every test
starts from this moment.

If the banner says `Guest internet: NOT confirmed`, Windows Update cannot download in the VM. Follow the hints under
that line. If the VM window did not open, the banner lists other ways to open it.

!!! warning "Do not close PowerShell now"
    If you close PowerShell at this point, the VM has no checkpoint and no saved password. You do not need to rebuild
    it. Use [Repair a broken VM](hyperv-vm-care.md#repair-a-broken-vm).

## Use your own virtual disk

If you already keep a prepared Windows image, the toolkit can use it instead of an ISO. This works on the command line
only. Give the path of your `.vhdx` file:

```powershell
New-Win32ToolkitTestVM -VhdxPath 'D:\VM\win11-base.vhdx' -Credential (Get-Credential)
```

The disk must start as a Generation 2 VM (UEFI), with Windows setup finished. `Get-Credential` asks for a local
administrator account of that disk. The account must sign in automatically, or the build waits 15 minutes and stops.
The same preparation pause and checkpoint follow.

!!! warning "The toolkit changes your file"
    The VM runs on your file, not on a copy. The toolkit changes its sign-in and script settings. Copy the file
    first if you need the original.

## Make the test VM your default

Building the VM does not change your default [test machine](glossary.md#test-machine), the place where
tests run. You still have to choose the test VM.

=== "Menu"

    1. In the main menu, choose **Settings** > **Hyper-V test VM** > **Set the default test backend**.
    2. Choose **Hyper-V VM**.

    The menu confirms with `Default backend set to HyperV.` From now on, tests and captures use the test VM.

=== "Command line"

    To use the test VM for one test only, add `-Backend HyperV` to
    [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md):

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Test-Win32ToolkitProject -ProjectPath $project -Scenario InstallUninstall -Backend HyperV
    ```

    Other commands, such as [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md), use the default. To change it
    without the menu, set `TestBackend`:

    ```powershell
    Set-ItemProperty -Path 'HKCU:\Software\CloudFlow\win32-toolkit' -Name TestBackend -Value 'HyperV'
    ```

    For every option, see [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

## Check that the VM is ready

In the main menu, choose **Settings** > **Hyper-V test VM**. The first lines show the state of the VM.

```text title="What you see"
Default test backend: HyperV
Hyper-V backend is READY - VM, checkpoint and guest credential are configured.
VM resources: 2 vCPU / 4 GB  (win32tk-golden)
```

<!-- SCREENSHOT: the TUI Hyper-V test VM screen showing "Hyper-V backend is READY" and the menu options -->

The last line shows the virtual processors (vCPU) and the memory of the VM. If something is missing, the second line
starts with `Hyper-V backend not ready:` and lists the reasons.

| Reason | What to do |
|---|---|
| `host session is not elevated` | Start PowerShell 7 with Run as administrator. |
| `Hyper-V PowerShell module is not installed` | Turn on Hyper-V and restart your PC. |
| `VM 'win32tk-golden' not found` | Build the VM, or set the default back to Windows Sandbox. |
| `checkpoint 'clean-base' not found on VM` | The build stopped early. [Repair the VM](hyperv-vm-care.md#repair-a-broken-vm). |
| `guest credential is not configured` | No saved VM password. [Repair the VM](hyperv-vm-care.md#repair-a-broken-vm). |

When the test VM is your default, the [system check](glossary.md#system-check) on the main screen also
has a `Hyper-V test backend` row. It shows `ready`, or the same reasons as this table.

A VM that is not ready does not stop your tests. They run in Windows Sandbox, with a warning. On the command line it
starts with `Hyper-V test backend requested but not ready`. The menu wizards show `Hyper-V is selected but NOT ready`.

"Ready" does not check that the saved password is right. A wrong password shows only in the next test, after a
15-minute wait. "Ready" also does not check that the checkpoint shows a signed-in desktop.

## Re-take the checkpoint

The checkpoint gets old: every test goes back to the Windows updates of that day. Re-take it at least every 35 days,
after you change Windows in the VM, and when a test prints one of the warnings below.

There is no toolkit command for this. Do not use the repair item of the menu. It resets the VM first, so you lose
your updates. Time: Windows Update time plus a minute or two.

1. In PowerShell 7 as administrator, run [Reset-Win32ToolkitTestVM](reference/Reset-Win32ToolkitTestVM.md). It prints
   nothing when it works.
2. If the VM is not running now, run `Start-VM -Name 'win32tk-golden'`.
3. Open the VM window: in Hyper-V Manager, choose **Connect**.
4. In the VM, run Windows Update until nothing is left.
5. Let every restart finish.
6. Run `Update-MpSignature` in the VM.
7. Leave the VM signed in at an idle desktop.
8. On your PC, replace the checkpoint with these four Hyper-V commands.

```powershell
$vm = 'win32tk-golden'   # your VM name
Get-VMCheckpoint -VMName $vm | Remove-VMCheckpoint
Set-VM -Name $vm -CheckpointType Standard
Set-VM -Name $vm -AutomaticCheckpointsEnabled $false
Checkpoint-VM -VMName $vm -SnapshotName 'clean-base'
```

Removing the old checkpoint keeps the current state of the VM, so your updates stay. It also removes the other
checkpoints of the VM. The toolkit creates the ones it needs again.

These warnings never stop a test, and each one shows once per PowerShell window. Fix the cause, then re-take the
checkpoint.

| Warning starts with | What to do |
|---|---|
| `The test VM's checkpoint 'clean-base' was taken with automatic checkpoints on` | Nothing more: the commands above turn them off. |
| `The test VM's checkpoint 'clean-base' is <n> days old` | Run Windows Update in the VM. |
| `The test VM's checkpoint 'clean-base' restores with nobody signed in` | Sign in at the desktop of the VM. |
| `Defender real-time protection is off` | Turn it on in the VM. |
| `The test VM's checkpoint 'clean-base' has <n> Defender exclusion(s)` | Remove the exclusions in the VM. |
| `Defender signatures in the test VM's checkpoint` | Run `Update-MpSignature` in the VM. |

## Make Hyper-V tests faster

Every Hyper-V test restores the checkpoint twice: before the test and after it. In one measurement on a Windows 365
Cloud PC, one restore took about 30 seconds. Your own times are in `Documentation\TestResults.json` of your project,
under `Timing`.

- **A Standard checkpoint at a signed-in desktop**. It saves the memory as well as the disk, so the VM comes back
  already running. If a test warns `VM 'win32tk-golden' was not Running after restoring`, re-take the checkpoint.
- **Automatic checkpoints off**. With them on, Hyper-V adds a checkpoint at every start and each restore is slower.
  Run `Set-VM -Name 'win32tk-golden' -AutomaticCheckpointsEnabled $false`, then re-take the checkpoint.
- **Enough memory**. Give the VM 6 to 8 GB if your PC has the memory. See
  [Change processors or memory](hyperv-vm-care.md#change-processors-or-memory).
- **Several tests in one PowerShell window**. After an unattended test, the next test can skip its first restore.
  This works within 10 minutes, if no other window used the VM.

The restore mode `HyperVRevertMode` is `TurnOffFirst` by default: the toolkit turns the VM off, restores the
checkpoint and starts the VM. It needs a checkpoint taken with automatic checkpoints off. Set `Legacy` only if
`TurnOffFirst` causes problems on your PC. You can also set it if a new checkpoint does not stop the warning
`The automatic-checkpoint setting of the test VM's checkpoint ...`.

```powershell
Set-ItemProperty -Path 'HKCU:\Software\CloudFlow\win32-toolkit' -Name HyperVRevertMode -Value 'Legacy'
```

Four more speed settings are off by default. Set them the same way. Measure your tests on your PC first, then change
one setting at a time. See [Settings and folders](settings.md#hyper-v-test-vm).

| Setting | Default | What the other value does |
|---|---|---|
| `HyperVAsyncTeardown` | `Off` | `On`: in the menu and `Invoke-Win32Toolkit`, the restore after an unattended test runs in the background. |
| `HyperVCapturePrewarm` | `Off` | `On`: `Invoke-Win32Toolkit` restores the VM during the download. |
| `HyperVDepsCheckpoint` | `Off` | `On`: a checkpoint with the apps the project needs first, so tests skip installing them. |
| `HyperVTeardownPark` | `Running` | `Saved`: between unattended tests, the VM waits on disk and uses no memory. |

With `HyperVAsyncTeardown` on, the menu keeps the test VM for itself after an unattended test. Other PowerShell
windows wait until the menu uses the VM again or you leave the menu. `Invoke-Win32Toolkit` keeps the VM until its
run ends. See [When another window is using the VM](hyperv-vm-care.md#when-another-window-is-using-the-vm).

### Stop Edge and WebView2 updates in the VM

Microsoft Edge and WebView2 update themselves after each restore. These updates add changes to captures that do not
come from your app. They also slow the installer.
Turn their updates off once, from PowerShell 7 as administrator on your PC, while the VM runs:

```powershell
$vm   = 'win32tk-golden'                      # your VM name
$cred = Get-Credential -UserName 'w32admin'   # the VM account
Invoke-Command -VMName $vm -Credential $cred -ScriptBlock {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    Set-ItemProperty $p -Name AutoUpdateCheckPeriodMinutes -Type DWord -Value 0
    Set-ItemProperty $p -Name UpdateDefault -Type DWord -Value 0
    Set-ItemProperty $p -Name 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -Type DWord -Value 0   # Edge
    Set-ItemProperty $p -Name 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Type DWord -Value 0   # WebView2
    'edgeupdate', 'edgeupdatem' | ForEach-Object {
        Stop-Service $_ -Force -ErrorAction SilentlyContinue
        Set-Service $_ -StartupType Disabled -ErrorAction SilentlyContinue
    }
    Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue | Disable-ScheduledTask
}
```

Then [re-take the checkpoint](#re-take-the-checkpoint). If your apps need a recent WebView2, update it by hand when
you next update the VM.

## Keep the VM safe

- The VM password is in clear text inside the VM, in the Windows setup answer file and the AutoLogon settings. Use it
  for this lab only.
- On your PC, the password is encrypted, and only your Windows user can read it.
- During the build and the repair, the VM downloads Microsoft Sysinternals Autologon from the internet.
- The VM runs untrusted installers as SYSTEM, with internet access. Use it for nothing else.
- Treat the whole `<base folder>\HyperV` folder as secret. The VM disk in `HyperV\Golden` holds the password. If you
  use your own virtual disk, that file holds it too. Do not share these files.

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `New-Win32ToolkitTestVM requires an elevated (Administrator) session` | Start PowerShell 7 with Run as administrator, then run the command again. |
| `The Hyper-V PowerShell module is not installed` | Turn on Hyper-V and restart your PC. |
| `VHDX already exists` | An earlier build left its disk file (VHDX). [Repair the VM](hyperv-vm-care.md#repair-a-broken-vm) if it exists, or [rebuild it](hyperv-vm-care.md#rebuild-the-vm). |
| `PowerShell Direct did not become ready within 900 s` | Windows did not start, or nobody signed in. Often your own disk has no automatic sign-in, or the password is wrong. |
| `No preferred edition` | The toolkit builds the first edition, often Home. Run the command again with `-Edition` or `-ImageIndex`, and `-Force`. |
| `Stored Hyper-V guest credential could not be decrypted` | Another Windows user saved the VM password. See [Fix a wrong VM password](hyperv-vm-care.md#fix-a-wrong-vm-password). |

For more messages, see [Troubleshooting](troubleshooting.md#hyper-v-test-vm).

## Next steps

- [Look after the Hyper-V test VM](hyperv-vm-care.md): change, reset, repair, rebuild or remove the VM.
- [Test as Intune does](testing.md#test-as-intune-does): run an unattended test on the VM.
