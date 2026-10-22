# Test fixtures - PSADT deploy-script goldens

These files are **test data**. The suites copy them to `%TEMP%` before touching them; nothing in this
folder runs as a suite (`Tests\Run-All.ps1` does not recurse into sub-folders) and nothing in it is
shipped with the module. The one exception is `RunAll\` (below): tiny fake suites that the runner's own
self-test executes on purpose.

**Do not edit these files by hand.** The bytes are stored as-is (`.gitattributes`:
`Tests/Fixtures/** -text`): the goldens are UTF-8 with BOM and CRLF, exactly as `New-ADTTemplate`
writes them, and `core.autocrlf` must not re-normalise them. Regenerate the PSADT goldens with the
drift test (`Tests\PsadtGoldenDrift.integration.ps1`, which compares a fresh `New-ADTTemplate` output
with these files after normalising BOM, line endings and `AppScriptDate`) and replace them only
together with a reviewed template-shape change.

## PSADT goldens (pristine `New-ADTTemplate` output)

| Folder | PSADT | Command | Shape |
|---|---|---|---|
| `psadt-4.1.8/` | 4.1.8 (PSGallery) | `New-ADTTemplate -Destination <out> -Name v418_default` | `Psadt41` |
| `psadt-4.2.0/` | 4.2.0-rc2 (upstream commit `2ce3910`) | `New-ADTTemplate -Destination <out> -Name v420_default` | `Psadt42Default` (recognised, unsupported for generation) |
| `psadt-4.2.0-zeroconfig/` | 4.2.0-rc2 (upstream commit `2ce3910`) | `New-ADTTemplate -Destination <out> -Name v420_zeroconfig -ZeroConfig` | `Psadt42ZeroConfig` |

Generated on 2026-10-15, one child process per PSADT version, each module imported by full path (the
4.2.0-rc2 module was saved to a scratch folder, never installed). `New-ADTTemplate` strips the
signature block; the only run-to-run difference is `AppScriptDate` (the generation date). A
prerelease is compared against the golden of its base version (`4.2.0-rc2` -> `psadt-4.2.0*`).

## Legacy fixtures (projects patched by win32-toolkit 1.1.6)

These are the deploy scripts that every project created by win32-toolkit <= 1.1.6 contains. They
are classified `Psadt41`, `GeneratorVersion 0`, `Support = 'Legacy'` and must stay packageable
without `-AllowLegacyScript`; the generator and the org-template code never modify them.

| Folder | Produced by (released 1.1.6 code, commit `22d2889`) | 4.1 markers replaced |
|---|---|---|
| `legacy-1.1.6-auto/` | `Set-PSADTDataDrivenScript` (default mode) on a copy of `psadt-4.1.8` | Installation, Uninstallation |
| `legacy-1.1.6-manual/` | `Set-PSADTDataDrivenScript -ManualInstall` on a copy of `psadt-4.1.8` | Uninstallation |
| `legacy-1.1.6-org/` | `Set-PSADTDataDrivenScript` (default mode), then 1.1.6 `Apply-OrgTemplate` with a template that enables the welcome, progress and completion dialogs and the `PreInstall.ps1`/`PostInstall.ps1` hooks (`FailureAction = 'Fail'`) | Installation, Uninstallation |

All three contain `$appConfig =` without the `## win32-toolkit:Session:loader` sentinel.
`legacy-1.1.6-org` has mixed line endings (the 1.1.6 org-template code inserted LF-only text into the
CRLF script) - exactly what such projects contain on disk.

Generating commands (run once, on 2026-10-15; the generator script lives outside the repository):

```powershell
git worktree add --detach C:\w32t\v116 22d2889
# In a child pwsh: dot-source the v116 worktree's
#   Private\Set-PSADTDataDrivenScript.ps1, Set-Win32ToolkitTextBlock.ps1,
#   ConvertTo-Win32ToolkitAccentLiteral.ps1, New-Win32ToolkitSparseConfig.ps1,
#   Test-Win32ToolkitPS51Syntax.ps1, Add-Win32ToolkitOrgHooks.ps1, Apply-OrgTemplate.ps1,
# shadow Get-Win32ToolkitTemplateAssetFolder (-> a scratch template folder holding
# Hooks\PreInstall.ps1 and Hooks\PostInstall.ps1) and Add-Win32ToolkitTemplateAssets (no-op), then on
# three copies of psadt-4.1.8\Invoke-AppDeployToolkit.ps1 (each alone in a scratch project folder):
Set-PSADTDataDrivenScript -ScriptPath <auto>\Invoke-AppDeployToolkit.ps1
Set-PSADTDataDrivenScript -ScriptPath <manual>\Invoke-AppDeployToolkit.ps1 -ManualInstall
Set-PSADTDataDrivenScript -ScriptPath <org>\Invoke-AppDeployToolkit.ps1
Apply-OrgTemplate -ProjectPath <org> -Template ([pscustomobject]@{
    TemplateName = 'Contoso'; AppScriptAuthor = 'Contoso IT'
    WelcomeDialog = [pscustomobject]@{ Enabled = $true; AllowDefer = $true; DeferTimes = 3; CheckDiskSpace = $false
                                        PersistPrompt = $true; BlockExecution = $true; CloseProcessesCountdown = 180 }
    UninstallWelcomeDialog = [pscustomobject]@{ Enabled = $true; CloseProcessesCountdown = 60; PersistPrompt = $false; BlockExecution = $false }
    ProgressDialog = [pscustomobject]@{ Enabled = $true; StatusMessage = 'Installing Contoso software'; StatusMessageDetail = '' }
    CompletionPrompt = [pscustomobject]@{ Enabled = $true; Message = 'The installation has completed successfully.'; ButtonRightText = 'OK' }
    Hooks = [pscustomobject]@{ Enabled = $true; FailureAction = 'Fail' }; ExtensionModule = $false })
git worktree remove C:\w32t\v116
```

The auto and manual outputs were byte-compared with an independent run of the same 1.1.6 code
(identical).

## winget installer manifests (installer-identity checks)

Read-only inputs for `Tests\SiblingProbe.unit.ps1` and `Tests\IdentityDelta.unit.ps1` (the sibling probe's
tuple reader). The suites read the text and feed it to a shadowed `Invoke-WebRequest`; nothing is downloaded
or installed, and nothing in these files is executed.

| Folder | Content | What it exercises |
|---|---|---|
| `winget-manifests/Notepad++.Notepad++/` | `8.8.9.installer.yaml`, `8.9.8.1.installer.yaml` (public winget-pkgs manifests, byte copies) | 8.9.8.1 x64 ships nullsoft (ARP key `Notepad++`) and wix next to each other (one testable sibling); 8.8.9 ships nullsoft only; zip/portable items register nothing |
| `winget-manifests/dotPDN.PaintDotNet/` | `5.1.installer.yaml` (public winget-pkgs manifest, byte copy) | root-level `InstallerType: zip` and `Scope` inherited by every item; the zipped EXE declares `AppsAndFeaturesEntries` `InstallerType: wix` (it registers as the same MSI: no sibling) |
| `winget-manifests/TeamViewer.TeamViewer/` | `15.82.6.installer.yaml` (public winget-pkgs manifest, byte copy) | a zip-wrapped wix next to nullsoft: a registering sibling that cannot be packaged or tested |
| `winget-manifests/synthetic/` | `quoted-rootkeys.installer.yaml`, `appx-sibling.installer.yaml` (hand-made, not real packages) | quoted values, root-level keys, an indented `Installers:` list and trailing comments; an appx sibling whose pin value is `msix` |

Fetched on 2026-10-19 from https://github.com/microsoft/winget-pkgs (`manifests/<letter>/<publisher>/<package>/<version>/`).

## Install captures (uninstall data)

Hand-built synthetic `InstallationChanges_*.json` captures (only the `NewFiles` / `NewRegistryKeys` entries a
case needs; generic product paths, no template or customer names; ASCII, LF) read by `Tests\CleanupPath.unit.ps1`,
which describes each one in its header. Read-only: the suite copies them to `%TEMP%`.

| File | What it exercises |
|---|---|
| `captures/coinstalled-first.json` | a co-installed key (`AcmeUpdater`, WOW6432Node) captured **before** the app's own key (`Acme Widget`): the app's own uninstaller is written first (I-3) and `Uninstall.AppName` is its DisplayName (I-4) |
| `captures/x86-primary.json` | the app's only uninstall key is in the 32-bit view (WOW6432Node): Uninstall.PrimaryKeys records View Registry32 (F13) |

## Run-All fixtures (fake suites for the runner's self-test)

`Tests\RunAllParallel.unit.ps1` runs `Tests\Run-All.ps1 -Path <folder>` in a child process against these
folders, never against the real suites. Each fixture only prints `RA|<tag>|...` lines (with UTC ticks at
`START`/`END`) and exits with a fixed code; the two peers drop one marker file in the rendezvous folder
the self-test passes in `$env:W32T_RA_RENDEZVOUS`, and the `edge`/`hang` fixtures record there the
processes they start (`<pid> <start time>`), which the self-test checks and stops by PID and start
time. They change nothing else.

| Folder | Fixtures | What it exercises |
|---|---|---|
| `RunAll/mixed/` | `RA-Alpha.pass`, `RA-Bravo.pass` (peers that must meet: run side by side), `RA-Charlie.fail` (exit 1, one stderr line), `RA-Delta.selfskip` (exit 3), `RA-Echo.gated` (gated by `W32T_LIVE_RUNALL_FIXTURE`, never set), `RA-Foxtrot.serial`, `RA-Golf.serial` (`# W32T-RUN-SERIAL:` line), `nested/RA-Hotel.nested` (a sub-folder: never discovered) | totals and exit code, gate SKIP, exit-3 SKIP, no recursion, parallelism, one contiguous output block per suite, serial-only suites after the parallel batch, `-Serial` |
| `RunAll/green/` | `RA-Kilo.pass`, `RA-Lima.gated`, `RA-Mike.serial` | a run with no failure exits 0 |
| `RunAll/edge/` | `RA-India.timeout` (hangs with a child holding its output), `RA-Juliet.orphan` (leaves a child holding its output behind; one `Read-Host`), `RA-November.bigout` (6,000 lines and one non-ASCII line) | `-SuiteTimeoutMinutes` kills the process tree (FAIL, `TIMEOUT` line), a leftover child delays a result by 10 s at most, stdin is closed, a big log prints in chunks as one block, the console code page is left alone |
| `RunAll/hang/` | `RA-Papa.hang` (hangs), `RA-Quebec.pass` | a stop (Ctrl+C) names the suite still running, kills it and keeps the logs |

Generated by hand (ASCII, CRLF); keep each fixture writing only to stdout/stderr so two runs can overlap.

## License

The winget manifests under `winget-manifests/` (except `synthetic/`) are copied unmodified from the
microsoft/winget-pkgs repository (https://github.com/microsoft/winget-pkgs), which is licensed under the MIT
License, solely as test data.

The deploy-script templates are generated by PSAppDeployToolkit
(https://github.com/PSAppDeployToolkit/PSAppDeployToolkit), which is licensed under the GNU Lesser
General Public License v3.0 (LGPL-3.0). They are included unmodified (goldens) or as patched by
win32-toolkit 1.1.6 (legacy fixtures), solely as test data.
