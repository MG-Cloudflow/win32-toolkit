---
description: "Make your package refuse, remove or report another installer technology of the same app that devices already have."
---

# Devices that already have the app

Many apps come in more than one [installer technology](glossary.md#installer-technology): the kind
of setup program that installs them. Notepad++, for example, ships an MSI and the vendor's own `.exe` setup. If you
package the MSI, devices that already have the `.exe` setup then have two Notepad++ entries for one program folder.

That other install is a [prior install](glossary.md#prior-install): the same app, from another
installer technology. A [prior-install rule](glossary.md#prior-install-rule) describes one prior
install exactly and tells your package what to do with it. win32-toolkit can find prior installs for you and propose
the rules.

## When you need this

[winget](glossary.md#winget) is the Windows package manager that the toolkit downloads apps from. It
often ships one app in several installer technologies. You need rules if some devices may already have the app from
another installer technology.

You do not need them if winget ships only one technology, or if the app goes only to new devices.

The toolkit can remove only installs made by [NSIS or Inno Setup](glossary.md#nsis-inno-setup-wix-and-burn). These are two common tools that make `.exe` setup programs.
The vendor setup of Notepad++ is an NSIS setup.

## Block, Enforce and Report

The mode of a rule decides what your package does on a device that has the prior install.

| Mode | What the device does | What you must do first | Exit code |
|---|---|---|---|
| [Block](glossary.md#block) | The install fails. Nothing is removed. | Nothing more | 69101 |
| [Enforce](glossary.md#enforce) | The close-apps dialog closes the old app. The package runs the old app's uninstaller as SYSTEM, checks that it is gone, then installs. | Prove it in a test. A captured rule also needs your approval. | None when it works |
| [Report](glossary.md#report) | The package writes a marker in the registry and installs. Nothing is removed. | Nothing more | None |

With Block and Enforce, your install fails with 69102 if the prior install is newer than the rule covers. The package
leaves an older prior install, or one from another publisher, as it is. Your install then continues. For every code,
see [Prior-install codes](exit-codes.md#prior-install-codes).

Enforce removes software as SYSTEM, so it has its own page:
[Remove a prior install (Enforce rules)](prior-installs-enforce.md).

### What can be removed

| Prior install made by | Modes you can use |
|---|---|
| NSIS or Inno Setup | Block, Enforce or Report |
| Another `.exe` setup program | Block or Report |
| MSI, WiX, Burn or MSIX | None yet: the capture can only list them |
| Portable apps, zip files and ARM64 installers | Not captured |

## What you need first

- The project was created by this version of the toolkit. If not, [re-create](glossary.md#re-create) it: make it again from the start, in the same folder. Re-creating a project
  deletes its folder.
  Copy your own code out first. See [Re-create a project](projects.md#re-create-a-project).
- The [install capture](glossary.md#install-capture) ran. It records your own app's uninstall entry, so
  no rule can name your own app. It runs during a build from winget, and when you complete a manual app.
- For a capture of the other technologies: an app from winget, packaged for x64 or x86.
- For Enforce: a ready [Hyper-V test VM](glossary.md#hyper-v-test-vm). This is a Hyper-V virtual
  machine (VM) that the toolkit resets before each test. See [Set up the Hyper-V test VM](hyperv-vm.md).

## Capture the other installer technologies

The console calls a capture of the other installer technologies a [sibling capture](glossary.md#sibling-capture). A sibling capture installs each other technology on a clean test machine,
at two versions, and records what the setup registered. From these records, the toolkit makes [proposals](glossary.md#proposal): suggested rules that do nothing until you apply them.

The capture runs on the Hyper-V test VM when it is ready. Otherwise it runs in [Windows Sandbox](glossary.md#windows-sandbox), a clean and temporary Windows desktop. There the setup runs as the Windows
Sandbox user, not as SYSTEM, so its proposals can only be Block or Report.

Time: 3 to 5 minutes per capture run (each technology is captured twice).

=== "Menu"

    **During a new build from winget:**

    1. In the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)), choose **Package an app from winget**.
    2. Find the app and answer the first questions as usual ([Run the wizard](packaging.md#run-the-wizard)).
    3. At the question that starts with **Also capture the other installer technologies**, type `y` and press
       <kbd>Enter</kbd>. (The default is No.)
    4. Answer the other questions. At **After building, also…**, tick the test only if it runs on the Hyper-V test VM.
    5. At **Build this now?**, type `y` and press <kbd>Enter</kbd>. (The default is No.)
    6. After the build, press any key to open the review.

    The capture runs before the test, so the test finds capture records. In Windows Sandbox, the toolkit then refuses
    the test, unless [`SandboxTestMode`](settings.md#tests) is `Unattended`. The build stops before the review.

    The wizard asks the capture question only if winget ships a technology that a package can remove.

    ```text title="What you see (example)"
    Also capture the other installer technologies (nullsoft) so the package can remove them before installing? About 2 capture runs now (about 6-10 min) and 1 proof run per identity.
    ```

    **For a project you already built:**

    1. Choose **Work with an existing project**, then choose your project.
    2. Choose **Prior installs** > **Capture the other installer technologies**.
    3. Without a ready test VM, the menu asks **Capture in Windows Sandbox anyway?** Answer `y` only if Block or
       Report will always be enough. (The default is No.)
    4. When the capture has recorded something, press any key to open the review.

=== "Command line"

    For a new build, add `-CaptureSiblingTechnologies` to [`Invoke-Win32Toolkit`](reference/Invoke-Win32Toolkit.md).
    Add `-ApplySiblingCapture Block` to turn every clean proposal (high confidence, no flags) into a Block rule in the
    same run. There is no Enforce value.

    ```powershell
    Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -InstallerType wix -CaptureSiblingTechnologies
    ```

    For a project you already built, use [`Test-Win32ToolkitProject`](reference/Test-Win32ToolkitProject.md).

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
    Test-Win32ToolkitProject -ProjectPath $project -Scenario SiblingCapture
    ```

    At the end, it names every proposal that is not a rule yet, with the command to apply it. For every option,
    see [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

!!! warning "Windows Sandbox captures cannot be undone"
    A capture in Windows Sandbox, or one where you install the setup by hand, means that prior install can never be
    Enforce. A later capture on the Hyper-V test VM does not change this. No command undoes it.

Without a ready test VM, the menu warns and asks first. On the command line, the capture runs in Windows Sandbox with
only a warning, even with `Test-Win32ToolkitProject -Backend HyperV`. A PowerShell window that does not run as
administrator counts as not ready.

There is one exception on the command line: if an earlier capture allows Enforce for that install, the toolkit
refuses or skips the capture. To capture there anyway, use `Test-Win32ToolkitProject -Backend Sandbox`. The first
capture of an install has no such protection. So if you may want Enforce, open PowerShell 7 as administrator and
[check that the VM is ready](hyperv-vm.md#check-that-the-vm-is-ready) before you capture.

## Review the proposals

The review shows one card per proposal, for example **Proposal nsis-x64: Notepad++**. Each proposal covers a
[version window](glossary.md#version-window): the versions from the oldest to the newest capture.

| Card line | What it tells you |
|---|---|
| Uninstall key, Publisher | The exact registry entry and publisher. Another publisher is left as it is. |
| Window | The versions the rule covers, and the versions the captures saw. |
| Not covered | Devices with an older version keep the prior install next to your package. A newer version fails with 69102. |
| Removal | The fixed uninstall command of Enforce. Switches from the capture are never used. |
| Data loss | The uninstaller deleted settings in its folder. Enforce then needs you to accept this, with a reason. |
| Enforce | Shown only when Enforce is not possible, with the reason. |

Below the card, the menu asks **What should the package do with Notepad++?** Block is listed first and highlighted.

<!-- SCREENSHOT: The review screen of a sibling capture: the Notepad++ NSIS card with Block preselected -->

| Choice | What happens |
|---|---|
| **Block** | Recommended. Devices with that install fail your install (69101) until the rule is Enforce. |
| **Enforce** | Only when the proposal allows it and the test VM is ready. It asks again, then proves the rule. See [Approve a proposal as Enforce](prior-installs-enforce.md#approve-a-proposal-as-enforce). |
| **Report** | Devices get a marker, and the install continues. |
| **Widen** | Asks for one older version, captures it, then shows the card again. |
| **Skip** | Writes nothing. The build and the publish warn about the proposal. |

A grey **Not proposed** panel then lists what the capture saw but did not propose. From the winget wizard, the toolkit
builds the package only after this review, so your choices are in it.

## Apply proposals from the command line

With only the project folder, [`Set-Win32ToolkitPriorInstall`](reference/Set-Win32ToolkitPriorInstall.md) lists the
rules and the proposals. It writes nothing.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
Set-Win32ToolkitPriorInstall -ProjectPath $project
```

```text title="What you see (example)"
No prior-install rules in this project.
Sibling-capture proposals (apply with -FromSiblingCapture -Mode <mode> -ProposalId <id>):
  nsis-x64     Notepad++ [Native] nullsoft 8.8.9.0 <= version <= 8.9.8.1; High, Current, Enforce-eligible; not applied; data loss (its uninstaller deletes configuration in its folder: Enforce needs -Acknowledge DATA-LOSS)
```

This command applies every clean proposal as a Block rule. A clean proposal has high confidence, no flags, and is not
a rule yet. The others are listed with the reason.

```powershell
Set-Win32ToolkitPriorInstall -ProjectPath $project -FromSiblingCapture -Mode Block
```

To apply one proposal as Block or Report, name it.

```powershell
Set-Win32ToolkitPriorInstall -ProjectPath $project -FromSiblingCapture -Mode Block -ProposalId nsis-x64
```

Every write first shows the rule and what it does on devices, then asks you to confirm. In a script, add
`-Confirm:$false`. For Enforce, see [Approve a proposal as Enforce](prior-installs-enforce.md#approve-a-proposal-as-enforce).
For every option, see [Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md).

## See, change or remove rules

An Enforce rule needs a [proof](glossary.md#proof) before you can build the package. A proof is a
passed [update test](glossary.md#update-test) on the Hyper-V test VM. It shows that your package
removes the prior install.

=== "Menu"

    1. Choose **Work with an existing project**, then choose your project.
    2. Choose **Prior installs**. The label shows how many rules the project has and how many are proven.
    3. Choose **Change the mode of a rule** or **Remove a rule**, then choose the rule.
    4. For a change of mode, choose the new mode.

    <!-- SCREENSHOT: The Prior installs screen of Notepad++_x64_8.9.8.1 with the rules table (rule nsis-x64 in Block mode) and the action list -->

    The table shows Id, Mode, Key, Window, Source, Captured, Approved and Proof for each rule. Proof is Proven or
    NotProven for an Enforce rule, and NotNeeded for Block and Report rules.

    **Remove a rule** asks first, and so does a change to Enforce. (The default is No.) The screen also offers
    **Review the capture proposals**, **Declare from the last Update test** and **Prove now**.

=== "Command line"

    To change the mode of a rule, name it with `-Id`.

    ```powershell
    Set-Win32ToolkitPriorInstall -ProjectPath $project -Id nsis-x64 -Mode Block
    ```

    To remove a rule, use `-Remove`.

    ```powershell
    Set-Win32ToolkitPriorInstall -ProjectPath $project -Remove nsis-x64
    ```

    A captured rule becomes Enforce only through its proposal, never with `-Id`. For every option, see
    [Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md).

A change reaches devices only after you build and publish the package again. A change also takes away the proof of
Enforce rules (see [What takes a proof away](prior-installs-enforce.md#what-takes-a-proof-away)).

Did the previous version of the app have the rule you removed? Then the build refuses until you accept the removal
with `ID-PRIOR-DROPPED` (see [Acknowledgements and waivers](prior-installs-enforce.md#acknowledgements-and-waivers)).

## Capture more versions or capture by hand

To cover older versions, capture more versions in one of these ways.

- **Widen** on a review card asks for one older version, for example `8.7.9`, and captures it.
- `-SiblingVersion` captures exactly the versions you name.
- `-SiblingCaptureVersionsBack` makes the oldest capture a given number of versions older than the newest one.
- `-SiblingCaptureCoverage 3` captures the newest version of each of the 3 newest version lines, for example 8.9, 8.8
  and 8.7. The number can be 1 to 10.

```powershell
Test-Win32ToolkitProject -ProjectPath $project -Scenario SiblingCapture -SiblingVersion 8.7.9
```

Some setups cannot run silently. With `-Assisted`, you run an [assisted capture](glossary.md#assisted-capture): you install the setup by hand in the window of the Hyper-V test VM. Its
proposals can only be Block or Report, and that install can never be Enforce. For every option, see
[Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

## Build and publish a project with rules

Build the package as usual ([Build the package](build-intunewin.md)). If a rule is not ready, the build refuses.
Each problem is on a line that starts with `Prior install:`.

| Message starts with | What to do |
|---|---|
| `Prior install: the Enforce rule '<id>' is not proven` | See [Prove the rule](prior-installs-enforce.md#prove-the-rule). |
| `Prior install: the rule '<id>' (...) of <project> is missing from this package` | Declare the rule again, or accept the removal with `ID-PRIOR-DROPPED`. |
| `Prior install: the removability probe saw the uninstaller` | Accept the data loss with `DATA-LOSS`. See [Acknowledgements and waivers](prior-installs-enforce.md#acknowledgements-and-waivers). |

For more messages, see [Troubleshooting](troubleshooting.md#prior-installs).

Before you sign in, the publish checks that the package carries the rules of the project. If you changed a rule after
the build, it refuses with `Prior install: the prior-install rules changed after Export`. Build the package again.

The publish also warns, but never stops:

- **Block rules:** devices with that install fail your install (69101). Use a [pilot group](glossary.md#pilot-group) first: a small group of devices that gets the app before everyone else.
- **Enforce rules:** the package removes another install as SYSTEM. The warning also says how to stop all removals
  on devices ([Stop all removals with the kill switch](prior-installs-devices.md#stop-all-removals-with-the-kill-switch)).
- **Enforce rules, after sign-in:** it names Intune apps that are assigned as Required and detect the prior install.
  They would install it again. Unassign or retire them first.

!!! warning "Start with a pilot group"
    Enforce removes another install as SYSTEM. Assign the package to a pilot group first.

Keep the [maximum run time](glossary.md#maximum-run-time) of the app at the default of 60 minutes or
more. It comes from the template wizard question **Max run time (minutes)**. With Enforce, the uninstaller of the prior
install can run up to 30 minutes before your install starts.

The [update app](glossary.md#update-app) is the second app that the toolkit can publish, for devices
with an older version of your app. With Enforce rules, it also reaches devices that have only the prior install. For
what happens on devices, see [Prior installs on devices](prior-installs-devices.md).

## Next versions and re-created projects

A re-created project and the next version keep the rules, but not everything. An [acknowledgement](glossary.md#acknowledgement) records that you accept a known risk, such as data loss. A [waiver](glossary.md#waiver) lets the build accept a rule without a part it needs, such as a proof. A waiver
works only for rules you typed or got from an update test, never for captured rules.

| What | Re-created, same version | Next version |
|---|---|---|
| Rules | Kept as they were | Taken from the highest earlier version of the same app and architecture |
| Version window | Unchanged | Rules you typed or got from an update test: moves up. Captured rules: unchanged until a new capture |
| Capture records and approvals | Kept | Kept for captured rules |
| Acknowledgements and waivers | Kept | Not kept: record them again |
| Proofs | Not kept: prove again | Not kept: prove again |

Captured Enforce rules need a new proof. So build the next version, or re-create the project, with `-RunTest Update`
while the test VM is ready. Without that test, the toolkit demotes these rules: they become proposals again. In a next
version, the build then refuses until you apply the proposal again or accept the removal with `ID-PRIOR-DROPPED`.

This command builds the next version with that test. It also captures the new version, so captured rules can cover it.

```powershell
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -CaptureSiblingTechnologies -RunTest Update
```

The winget wizard in the menu never runs this update test, so it always demotes captured Enforce rules. To approve and
prove them again, choose **Review the capture proposals** on the **Prior installs** screen. See
[With prior-install rules](new-version.md#with-prior-install-rules).

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `No prior-install rule can be written into` | Usually the project is from an older version of the toolkit: [re-create it](projects.md#re-create-a-project). |
| `This project's own uninstall identity is not known yet` | [Run the install capture again](projects.md#run-the-install-capture-again), then write the rule again. |
| `The other installer technologies of '<project>' cannot be captured` | Read the reason, for example a manual app or an ARM64 package. |
| `The other installer technologies of '<project>' were not captured: another Windows Sandbox is still running after 90 s` | Windows allows one Windows Sandbox at a time. Close it and capture again. |
| `Prior install: the prior-install rules changed after Export` | Build the package again, then publish the new package. |
| `Nothing was captured: the winget manifest of` | If it says `GitHub limits requests from this computer until`, capture again after that time (UTC). |

For more messages, see [Troubleshooting](troubleshooting.md#prior-installs).

## Next steps

- [Remove a prior install (Enforce rules)](prior-installs-enforce.md): approve, prove and ship an Enforce rule.
- [Prior installs on devices](prior-installs-devices.md): exit codes and the kill switch.
- [Ship a new version](new-version.md): the next version of an app with rules.
