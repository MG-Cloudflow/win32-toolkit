---
description: "Approve, prove and ship an Enforce rule that removes another installer technology as SYSTEM before your package installs."
---

# Remove a prior install (Enforce rules)

Some devices already have your app, installed with another kind of setup program. That other install is a [prior install](glossary.md#prior-install). An [Enforce](glossary.md#enforce) rule makes your
package remove it first, and then install. This page shows how to approve, prove and ship such a rule.

!!! danger "Removal runs as SYSTEM"
    Enforce removes another install as SYSTEM. Assign the package to a pilot group first. [SYSTEM](glossary.md#system-account) is the Windows account that Intune uses to install apps. A [pilot group](glossary.md#pilot-group) is a small group of devices that gets the app before everyone else.

The examples use Notepad++. Your package installs the WiX MSI, and some devices have the vendor's NSIS setup. The rule
ID is `nsis-x64`. To capture the other installs first, see [Devices that already have the app](prior-installs.md).

**Why so many steps?** A wrong rule could remove software on every device. So Enforce has five safety measures:

- **An exact match.** The rule names one install exactly. Other installs stay as they are.
- **Fixed switches.** The package runs that install's own uninstaller with fixed silent switches.
- **A passed test.** A test shows that this exact package removes the install.
- **Your approval.** You approve each suggested rule, one at a time.
- **A way to stop.** A registry value on devices stops every removal. See
  [Prior installs on devices](prior-installs-devices.md#stop-all-removals-with-the-kill-switch).

## When Enforce is possible

Enforce is possible only when all of these are true:

- The project was made by this version of win32-toolkit. The toolkit has recorded what your package installs.
- The other install was made by [NSIS or Inno Setup](glossary.md#nsis-inno-setup-wix-and-burn), two
  common makers of setup `.exe` files. The toolkit never removes installs made by other setup programs.
- The [Hyper-V test VM](glossary.md#hyper-v-test-vm) is ready. This is a virtual machine (VM) on your
  PC that the toolkit resets before each test. You also run PowerShell 7 as administrator. See
  [Check that the VM is ready](hyperv-vm.md#check-that-the-vm-is-ready).
- A rule from a [sibling capture](glossary.md#sibling-capture) needs a capture that ran unattended on
  the test VM. A sibling capture is a capture of the other installer technologies of the app. A capture in Windows
  Sandbox, or one where you install the setup by hand, allows only Block or Report for that install. A later capture
  does not change this.
- For such a rule, the **Enforce** line of the review card in the menu
  ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) does not say `not offered`. A typical reason is an Electron
  app: its uninstaller needs other switches.

## Approve a proposal as Enforce

A sibling capture never writes a rule. It gives [proposals](glossary.md#proposal): suggested rules that
do nothing until you apply them. Enforce needs your [approval](glossary.md#approval) of exactly one
proposal. Then the rule needs a [proof](glossary.md#proof): a passed test on the test VM with this
exact package.

=== "Menu"

    Start the menu (`Show-Win32Toolkit`).

    1. In the main menu, choose **Work with an existing project**, then choose your project.
    2. Choose **Prior installs**, then **Review the capture proposals**.
    3. On the card, check the publisher, the **Window** line and the **Data loss** line.
    4. At **What should the package do with Notepad++?**, choose **Enforce: remove it before installing**. (Block is
       highlighted first.)
    5. At **Remove Notepad++ as SYSTEM on every device before installing?**, type `y` and press <kbd>Enter</kbd>.
       (The default is No.)
    6. Wait while the toolkit records your approval and proves the rule on the test VM.
    7. Answer the questions about data loss or the signer, if the menu asks any.

    The **Proof** panel shows the result:

    | Panel text starts with | What it means |
    |---|---|
    | `Proven:` (green) | The rule works. |
    | `Not proven (` (red) | The test failed. The rule is a proposal again, so the package removes nothing. |
    | `Not proven yet` (yellow) | Read the warnings above it. The build refuses the rule until it is proven. |

=== "Command line"

    Name the proposal by its ID with [Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md).
    Each proposal gets its own approval.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
    Set-Win32ToolkitPriorInstall -ProjectPath $project -FromSiblingCapture -Mode Enforce -ProposalId nsis-x64
    ```

    Read the line `Device consequence`: it says what devices will do. Then type `Y` and press <kbd>Enter</kbd>. The
    command writes the rule and your approval. It also adds `notepad++` to the apps that the close-apps dialog closes.

    The command does not run the proof. Next, run the command that the line `Prove it:` shows. A line that starts with
    `Export also needs` names an acknowledgement (see [Acknowledgements and waivers](#acknowledgements-and-waivers)).
    For every option, see [Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md).

## Prove the rule

A proof is an unattended [update test](glossary.md#update-test) on the Hyper-V test VM. An update test
installs an old version first, here the vendor's NSIS setup. Then it installs your package over it. An [unattended test](glossary.md#unattended-test) runs without a person and without pauses.

The test must pass with its requirement check, so never add `-SkipRequirementCheck`. The proof counts only while the
package stays the same. An interactive test, or a test in Windows Sandbox, never proves a rule.

Time: about 4 to 5 minutes (depends on your PC) for each group of rules.

=== "Menu"

    1. In the main menu, choose **Work with an existing project**, then choose your project.
    2. Choose **Prior installs**, then **Prove now**.
    3. Read the **Proof** panel. `Proven:` lists the rules that passed.
    4. Check the line `Demoted to proposals:`. These captured rules failed and are proposals again.

    `Not proven (never demoted):` lists your other Enforce rules that are still not proven. Without a ready test VM,
    the menu prints `Hyper-V is not ready (` and runs nothing.

=== "Command line"

    Run [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md) on the test VM.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
    Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -Backend HyperV -TestMode Unattended
    ```

    One run proves one group of rules, for example the rules from one capture. Without `-ProofEntryId`, it proves
    only the first group. With several groups, the line `Prove it:` adds this option for you.

    `-SiblingProof FloorAndNewest` adds a run from the newest captured version. That run never proves a rule, but a
    failure there takes the proof away. For every option, see
    [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

## What takes a proof away

A proof covers this exact package. These things take it away:

- You add, change or remove a rule. Applying the same proposal again also counts.
- You run the [install capture](glossary.md#install-capture) again. It records what your package
  installs.
- You change the dependencies, the installer or any other file of the package.
- A newer update test of this package that checks the rule fails, in Windows Sandbox or on the test VM, in any
  mode. A retry code such as 1618 or 69107 also counts.

Then prove the rule again, and build and publish the new package. See
[Build and publish a project with rules](prior-installs.md#build-and-publish-a-project-with-rules).

The install capture runs again with **Finalize / refresh** in the menu, or with
[Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md). In that run, a captured Enforce rule
without a proof becomes a proposal again. Then [approve it again](#approve-a-proposal-as-enforce) before you prove it.

To prove such a rule in the same run, add `-RunTest Update` while the test VM is ready.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest Update
```

!!! note "Known issue: a pending restart"
    Windows in the test VM sometimes still needs a restart after a reset. The package then stops with 69107, and the
    toolkit records a failed test. In the menu or in a build, a captured rule then becomes a proposal again. Approve
    it again, then run the proof again.

## Acknowledgements and waivers

Some risks need your decision before the build accepts a rule. An [acknowledgement](glossary.md#acknowledgement) says that you know a risk and accept it. A [waiver](glossary.md#waiver) lets the build accept a rule without something it normally needs.

| Code | Kind | When you need it | Allowed for a captured rule |
|---|---|---|---|
| `PROOF` | Waiver | You ship an Enforce rule without a proof. | No |
| `VERSIONMIN` | Waiver | The rule covers versions older than any version that a proof removed. | No |
| `DISPLAYNAME` | Waiver | A typed rule has no display name. Record the waiver before the rule. | No |
| `DATA-LOSS` | Acknowledgement | The uninstaller deletes user data or settings files. | Yes |
| `SIGNER-MISMATCH` | Acknowledgement | The other install is signed differently from your package. | Yes |
| `ID-PRIOR-DROPPED` | Acknowledgement | A rule of the previous version is missing on purpose. | Yes |

Record a decision with the rule ID in `-Target` and a reason of 1 to 512 characters in `-Reason`.

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
Set-Win32ToolkitPriorInstall -ProjectPath $project -Acknowledge DATA-LOSS -Target nsis-x64 -Reason 'Settings live in %APPDATA%'
```

To remove this acknowledgement, use `-Revoke DATA-LOSS -Target nsis-x64`. Decisions stay on your PC, in
`Documentation\PriorInstallDecisions.json` in the project folder. The package never contains them, and the next
version does not get them.

In the menu, the review card asks for `DATA-LOSS` and `SIGNER-MISMATCH` after a proof. An empty reason records
nothing.

## Get a rule from a failed update test

An update test from the other installer technology fails when the old install stays next to your package. The toolkit
then saves that install as a candidate for a rule.

=== "Menu"

    1. Run the update test from the other technology. See
       [Choose the installer technology of the old version](testing.md#choose-the-installer-technology-of-the-old-version).
    2. Choose **Work with an existing project** > choose your project > **Prior installs**.
    3. Choose **Declare from the last Update test**.
    4. Choose a mode. **Block** is first and highlighted.
    5. If you choose **Enforce**, the menu asks once more. (The default is No.)
    6. For an Enforce rule, choose **Prove now**.

    The menu uses only the candidate with High confidence.

=== "Command line"

    Run the update test with the NSIS setup as the old version.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
    Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -BaselineInstallerType nullsoft
    ```

    If the old install stays, the test prints `Prior install candidate: nsis-x64 (High)`. Declare it as Block first.

    ```powershell
    Set-Win32ToolkitPriorInstall -ProjectPath $project -FromUpdateTest -Mode Block
    ```

    If the toolkit asks you to choose a candidate, add `-CandidateKey 'Notepad++'`. Then switch the rule to Enforce.
    The candidate already holds the data that Enforce needs.

    ```powershell
    Set-Win32ToolkitPriorInstall -ProjectPath $project -Id nsis-x64 -Mode Enforce
    ```

    Then [prove the rule](#prove-the-rule). For every option, see
    [Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md).

Re-creating the project deletes the candidates. Run the update test again after that.

## Type a rule by hand

Type a rule when the toolkit cannot capture the other install, for example for an app that is not in winget. You need
the exact data of its [uninstall entry](glossary.md#uninstall-entry), the registry key behind its line
in Installed apps.

The toolkit refuses a typed rule with the ID of a captured rule. It also refuses one with the same install data as a
captured rule or a proposal. For such an install, apply its proposal instead.

This example writes a Block rule, with the options in a list ([Use the commands in scripts](automation.md)).

```powershell
$project = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'   # your project folder
$rule = @{
    ProjectPath = $project
    Id          = 'nsis-x64'
    Mode        = 'Block'
    Key         = 'Notepad++'                 # the uninstall key name
    View        = 'Native'                    # the 64-bit registry
    Publisher   = 'Notepad++ Team'
    DisplayName = 'Notepad++ (64-bit x64)'
    VersionMin  = '8.7.9'
    VersionMax  = '8.9.8.1'
}
Set-Win32ToolkitPriorInstall @rule
```

An Enforce rule needs more data:

- The kind of uninstaller: `nullsoft` for NSIS or `inno` for Inno Setup.
- The file name of the uninstaller.
- The install folder, under `%ProgramFiles%` or `%ProgramFiles(x86)%`.
- The main program. It must differ from the uninstaller.
- At least one app to close. Write the name without `.exe`.

A typed Block rule without this data does not become Enforce when you change only its mode. Add all this data to the
same list and run the command again. The new rule replaces the rule with the same ID.

```powershell
$rule.Mode                = 'Enforce'
$rule.UninstallerType     = 'nullsoft'
$rule.UninstallerFileName = 'uninstall.exe'
$rule.InstallDir          = '%ProgramFiles%\Notepad++'
$rule.MainExe             = 'notepad++.exe'
$rule.ProcessName         = 'notepad++'
Set-Win32ToolkitPriorInstall @rule
```

Then [prove the rule](#prove-the-rule). For every option, see
[Set-Win32ToolkitPriorInstall](reference/Set-Win32ToolkitPriorInstall.md).

## Keep Enforce rules on the next version

A new version of the app takes the rules of its highest earlier version, and every Enforce rule needs a new proof. So
build it with [Invoke-Win32Toolkit](reference/Invoke-Win32Toolkit.md) while the test VM is ready.

```powershell
Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -TemplateName 'Contoso' -Force -RunTest Update
```

The proofs then replace the normal update test. Without a ready test VM, captured Enforce rules become proposals
again. They also become proposals again without `-RunTest Update`. The warning then starts with
`Captured Enforce prior-install rules are proven by an Update test`.

A build from the menu always turns them into proposals, because the winget wizard cannot run the update test. The
build of the package then refuses the project until you approve and prove the rules again, or acknowledge
`ID-PRIOR-DROPPED`.

On each new version:

- Give your acknowledgements and waivers again, for example `DATA-LOSS` for each Notepad++ version.
- The next version keeps your approvals of captured rules.
- A newer sibling capture of the same install raises the [version window](glossary.md#version-window),
  the range of versions that a rule covers. The rule then needs a new proof.

To capture again in the same build, add `-CaptureSiblingTechnologies`. See also [Ship a new version](new-version.md).

## If something goes wrong

The build of the package stops with one message that lists every problem. Each line about a rule starts with
`Prior install:`.

| Message starts with | What to do |
|---|---|
| `Prior install: the Enforce rule '<id>' is not proven` | Prove the rule as the message says. After 1618 or 69107, run the proof again. |
| `Prior install: the captured Enforce rule '<id>' has no current approval` | Approve its proposal again, then prove it. |
| `Prior install: the Enforce rule '<id>' removes versions from` | Raise `VersionMin` to the version in the message, or prove the older version. |
| `Prior install: the proof run saw the uninstaller` or `Prior install: the removability probe saw` | The uninstaller deletes data. If your users can accept that, record the `DATA-LOSS` acknowledgement. |
| `Prior install: the signer of the captured install` | Check that it comes from the same vendor. Then record the `SIGNER-MISMATCH` acknowledgement. |
| `Demoted to proposals:` | The rule is not proven, so it is a proposal again. Fix the cause, then approve and prove it again. |
| `Rule '<id>' comes from a sibling capture` | A captured rule takes no waiver and changes only through its proposal. Run the command in the message, or prove the rule. |

More messages: [Troubleshooting](troubleshooting.md#prior-installs).

## Next steps

- [Prior installs on devices](prior-installs-devices.md): roll out safely, read what devices report, and stop every
  removal.
- [Look after the Hyper-V test VM](hyperv-vm-care.md): keep the test VM ready for proofs.
