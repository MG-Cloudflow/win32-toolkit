function Invoke-Win32ToolkitFinalize {
    <#
    .SYNOPSIS
        Runs the back half of the packaging pipeline for a scaffolded project.
    .DESCRIPTION
        Shared "finalize" tail used by both Invoke-Win32Toolkit (winget flow) and
        Complete-Win32ToolkitManualApp (manual flow), so the two cannot drift:

          1. New-TargetedDocumentation — launch the documentation sandbox (installs via the
             project's Invoke-AppDeployToolkit.ps1 and captures the install changes). Returns the
             expected capture path (truthy string) on success, $false on failure.
          2. Wait-ForDocumentationAndProcess -ExpectedJsonPath — waits for exactly this run's
             capture (never a stale one), then writes AppConfig.Uninstall, the requirement script,
             and processes-to-close from it.
          3. Optional -RunTest scenarios, then -PackageIntune / -PublishIntune.

        Pre-flight (D15): before anything runs, Assert-Win32ToolkitPackageReady -Stage Finalize must pass:
        the deploy script exists, parses, carries the AppConfig loader and uses a supported template
        shape (projects patched by older win32-toolkit versions pass with a warning). A failure throws
        W32T.PackageNotReady and nothing is documented, tested, packaged or published.

        See knowledge-base/designs/manual-app-packaging.md.
    .PARAMETER ProjectPath
        Full path to the scaffolded PSADT project.
    .PARAMETER ProjectName
        Project (folder) name — used for the sandbox documentation config.
    .PARAMETER AppInfo
        App metadata object (passed through to New-TargetedDocumentation).
    .PARAMETER UpdateBaselineInstallerType
        Update test only: the installer technology of the old-version baseline (Auto, Both, Packaged or an
        installer type), passed on as Test-Win32ToolkitProject -BaselineInstallerType only when it is given
        (unbound = that command's default, Auto).
    .PARAMETER AllowLegacyScript
        Finalise a deploy script that win32-toolkit never patched (no AppConfig loader) or whose template
        layout this version does not support; the package is built as-is (passed on to the export).
    .PARAMETER BasePath
        The run's base folder: 'project:' dependencies are staged from <BasePath>\Projects for the capture and
        every -RunTest scenario (passed on to New-TargetedDocumentation and Test-Win32ToolkitProject when given).
        Empty: the configured base folder.
    .PARAMETER Result
        The run-result collector of the calling command (Initialize-Win32ToolkitRunResult; TUI audit G2,
        S8-F3). When given, Finalize records the capture state, one { Scenario; Verdict } per test, the
        .intunewin path, the published apps and a plain sentence per problem in it, and runs the export with
        -PassThru. Without it the behaviour and output are unchanged (nothing is emitted).
    .PARAMETER NoPublishPrompt
        Passed on to the export: no 'Upload to Microsoft Intune now? (Y/N)' question after packaging (TUI
        audit G5; the menu asks about publishing itself).
    .PARAMETER CaptureSiblingTechnologies
        Installer-identity PR 3b (spec 2.17): after the install capture, capture the other installer technologies
        winget ships for the app (Test-Win32ToolkitSiblingCapturePreflight, Get-Win32ToolkitSiblingCapturePlan,
        Invoke-Win32ToolkitSiblingCapture on the Hyper-V test VM, or in Windows Sandbox with Block-only proposals when the
        VM is not ready), then raise the windows of the captured rules
        (Update-Win32ToolkitPriorInstallWindow). A refused pre-flight or a failed capture is one problem sentence; the
        pipeline goes on. W32T.GuestTamper stays fatal. Without a ready VM, a project whose captures already allow an
        Enforce rule (an Enforce-eligible proposal, or a captured Enforce rule) is not captured: a Sandbox record would
        make that identity Block-only (Get-Win32ToolkitSiblingSandboxImpact); one problem sentence names them.
    .PARAMETER ApplySiblingCapture
        With -CaptureSiblingTechnologies: None (default; the proposals are listed with their commands) or Block (every
        High-confidence proposal without flags whose identity is not a rule yet becomes a Block rule; never Enforce).

        Whatever the switches: when Enforce prior-install rules are unproven and -RunTest has Update, the proof and
        demotion loop (Invoke-Win32ToolkitPriorDemotion -Prove) runs instead of the generic Update test; without Update
        in -RunTest the unproven captured Enforce rules are demoted (one round, no proof). The capture, the raise, the
        proof and the demotion run under the optional per-project lease (TestProjectLease).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectName,

        [object]$AppInfo,

        [ValidateSet('InstallUninstall', 'Update')]
        [string[]]$RunTest,

        # Update-test baseline selection, passed through to Test-Win32ToolkitProject so a scripted
        # pipeline never blocks on the interactive version picker mid-run. Omit both to keep the
        # interactive picker (an unattended run or a non-interactive host then uses the previous version,
        # with a warning: Test-Win32ToolkitProject, test campaign F5). SpecificVersion wins when both are supplied.
        [ValidateRange(1, 1000)]
        [int]$UpdateVersionsBack,

        [string]$UpdateSpecificVersion,

        # Update-test baseline technology (installer-identity PR 1), passed through only when bound.
        [ValidateSet('Auto', 'Both', 'Packaged', 'msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')]
        [string]$UpdateBaselineInstallerType,

        [switch]$PackageIntune,

        [switch]$PublishIntune,

        # Also publish the update app (2nd app, same version, requirement-gated to installed devices).
        [switch]$PublishUpdate,

        # D15 override: package a deploy script without the AppConfig loader / with an unsupported layout as-is.
        [switch]$AllowLegacyScript,

        # The run's base folder for 'project:' dependencies (capture + tests); empty = the configured one.
        [string]$BasePath,

        # The calling command's run-result collector (TUI audit G2, S8-F3); declared last.
        [pscustomobject]$Result,

        # No 'Upload to Microsoft Intune now?' question after packaging (TUI audit G5); declared last.
        [switch]$NoPublishPrompt,

        # Installer-identity PR 3b: capture the other installer technologies (passed by the callers only when set).
        [switch]$CaptureSiblingTechnologies,

        [ValidateSet('None', 'Block')]
        [string]$ApplySiblingCapture = 'None'
    )

    # Pre-flight (D15): never document, test, package or publish a deploy script win32-toolkit cannot
    # vouch for. Throws W32T.PackageNotReady (all problems listed); warnings are written by the Assert.
    $null = Assert-Win32ToolkitPackageReady -ProjectPath $ProjectPath -Stage Finalize -AllowLegacyScript:$AllowLegacyScript

    $filesPath = Join-Path $ProjectPath 'Files'

    # 1-2. Sandbox documentation capture → uninstall / requirement / processes.
    # New-TargetedDocumentation returns the EXPECTED capture path (truthy) on success, $false on
    # failure; passing it to the waiter makes the wait immune to stale captures from earlier runs.
    # Documentation capture follows the configured test backend (Sandbox default; HyperV opt-in, falls
    # back to Sandbox if the VM isn't ready). Under Sandbox the .wsb launches inside
    # New-TargetedDocumentation; under HyperV the script is prepared here and executed in the VM below
    # (revert → copy-in → run over PS Direct → copy-out), then the SAME waiter/consumer processes it.
    $backend = Get-Win32ToolkitTestBackend
    Write-Host "`nGenerating targeted installation documentation ($backend)..." -ForegroundColor Yellow
    # The capture's own PSADT/MSI logs land in the flat Sandbox\Logs, where the first test run below overwrote
    # them (same file names): keep them in Sandbox\Logs\Runs\<ts>_Capture (test campaign 2026-10-21, H5-F5 /
    # H7-F1). Prepared BEFORE New-TargetedDocumentation: under Sandbox the sandbox launches inside it.
    # Best effort: $null (no per-run folder) never stops the capture.
    $captureRun = Initialize-Win32ToolkitTestRunLog -ProjectPath $ProjectPath -Scenario Capture
    # The run's -BasePath reaches the dependency staging of the capture and of every test below (re-verification
    # 2026-10-21, B3 #4: they staged 'project:' dependencies from the registry base folder).
    $docArgs = @{ ProjectPath = $ProjectPath; ProjectName = $ProjectName; AppInfo = $AppInfo; Backend = $backend }
    if ($BasePath) { $docArgs['BasePath'] = $BasePath }

    # Installer-identity PR 3 (live rows DEMOTE and RAISE, 2026-10-26): a rebuilt version keeps its prior-install rules and
    # a next version carries them BEFORE this capture (Copy-Win32ToolkitPriorInstallState), but the capture runs the
    # package's own deploy script, whose prior-check refuses every Enforce rule while the package's own identity is unknown
    # (69105) - and this capture is what records that identity. So while the own identity is unknown, the Enforce rules
    # are written as Block for the capture (the clean capture guest has no prior install, so a Block rule refuses
    # nothing there) and as Enforce again right after it, also when the capture throws (an interrupted run leaves them
    # Block: more restrictive, never less), then re-checked against the identity the capture recorded.
    $heldEnforce = [string[]]@()
    if (Test-Path -LiteralPath (Join-Path $ProjectPath 'SupportFiles\AppConfig.json') -PathType Leaf) {
        try {
            $holdCfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
            $holdOwn = if ($holdCfg.PSObject.Properties['OwnIdentity']) { $holdCfg.OwnIdentity } else { $null }
            $ownKnown = $null -ne $holdOwn -and ([string]$(if ($holdOwn.PSObject.Properties['ProductCode']) { $holdOwn.ProductCode }) -or
                @(@($(if ($holdOwn.PSObject.Properties['ArpKeys']) { $holdOwn.ArpKeys })) | Where-Object { $_ }).Count -gt 0)
            $holdSet = if ($holdCfg.PSObject.Properties['PriorInstalls'] -and $holdCfg.PriorInstalls -and $holdCfg.PriorInstalls.PSObject.Properties['Entries']) { @(@($holdCfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ }) } else { @() }
            $holdEntries = @($holdSet | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and $_.PSObject.Properties['Mode'] -and [string]$_.Mode -ceq 'Enforce' -and $_.PSObject.Properties['Id'] })
            if (-not $ownKnown -and $holdEntries.Count -gt 0) {
                foreach ($he in $holdEntries) { $he.Mode = 'Block' }
                $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $holdCfg -Confirm:$false
                $heldEnforce = [string[]]@($holdEntries | ForEach-Object { [string]$_.Id })
                Write-Host "Prior installs   : $($heldEnforce -join ', ') run as Block in the install capture (this package's own identity is recorded there); Enforce again right after it." -ForegroundColor Gray
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Warning "The Enforce prior-install rules could not be set aside for the install capture ($(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)): the capture may refuse them (69105)."
        }
    }
    # Sets the held rules back to Enforce (only those still Block: the capture's re-check may have removed one) and re-checks
    # them with the full Enforce rules against the identity the capture recorded. Once.
    $heldBack = $false
    $resumeHeld = {
        if ($heldEnforce.Count -eq 0) { return }
        try {
            $backCfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
            $backSet = if ($backCfg.PSObject.Properties['PriorInstalls'] -and $backCfg.PriorInstalls -and $backCfg.PriorInstalls.PSObject.Properties['Entries']) { @(@($backCfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ }) } else { @() }
            $back = @($backSet | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and $_.PSObject.Properties['Id'] -and $heldEnforce -ccontains [string]$_.Id -and $_.PSObject.Properties['Mode'] -and [string]$_.Mode -ceq 'Block' })
            foreach ($be in $back) { $be.Mode = 'Enforce' }
            if ($back.Count -gt 0) { $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $backCfg -Confirm:$false }
            if ($back.Count -lt $heldEnforce.Count) { Write-Warning "The install capture removed the prior-install rule(s) $(@($heldEnforce | Where-Object { @($back | ForEach-Object { [string]$_.Id }) -cnotcontains $_ }) -join ', ') (see the warnings above)." }
            # Only once the capture recorded the own identity (a capture that failed or threw recorded none: the full rules
            # would drop the rule for that alone; Export reports it instead).
            $backOwn = if ($backCfg.PSObject.Properties['OwnIdentity']) { $backCfg.OwnIdentity } else { $null }
            $backKnown = $null -ne $backOwn -and ([string]$(if ($backOwn.PSObject.Properties['ProductCode']) { $backOwn.ProductCode }) -or
                @(@($(if ($backOwn.PSObject.Properties['ArpKeys']) { $backOwn.ArpKeys })) | Where-Object { $_ }).Count -gt 0)
            if ($back.Count -gt 0 -and $backKnown) { $null = Sync-Win32ToolkitPriorInstallOwnIdentity -ProjectPath $ProjectPath }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $holdText = "The prior-install rule(s) $($heldEnforce -join ', ') could not be set back to Enforce after the install capture ($(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)): they stay Block; set them with Set-Win32ToolkitPriorInstall -Id <id> -Mode Enforce."
            Write-Warning $holdText
            if ($Result) { $Result.Problems.Add($holdText) }
        }
    }

    $docSuccess = $false
    $captureReady = $false
    $captureStarted = $false
    try {
        $docSuccess = New-TargetedDocumentation @docArgs

        $captureReady = [bool]$docSuccess
        if ($docSuccess -and $backend -eq 'HyperV') {
            Write-Host 'Running documentation capture inside the Hyper-V VM...' -ForegroundColor Cyan
            $ran = Invoke-Win32ToolkitHyperVRun -ProjectPath $ProjectPath -Phase @(
                @{ Label = 'Document install changes'; Command = "& 'C:\PSADT\SupportFiles\TargetedDocumentationScript.ps1'" }
            ) -Output @('Documentation\InstallationChanges_*.json', 'Documentation\Targeted_Documentation_Log_*.txt', 'Sandbox\Logs\*')
            if (-not $ran) {
                $captureReady = $false
                Write-Warning 'Hyper-V documentation capture did not complete — skipping processing. Review the VM and its logs.'
            }
        }
        $captureStarted = $true
    }
    finally {
        if (-not $captureStarted -and -not $heldBack) { $heldBack = $true; & $resumeHeld }
    }
    # Hyper-V speed-up PR 4 (D14): a capture pre-warm (Invoke-Win32Toolkit, HyperVCapturePrewarm) is released here, right
    # after the capture's teardown (its open joined the pre-warm and skipped its restore); when the capture ran under
    # Sandbox or did not run, the pre-warm is joined and released here too. No pre-warm: nothing happens.
    $null = Wait-Win32ToolkitHyperVTeardown -Prewarm

    $jsonProcessed = $false
    try {
        if ($captureReady) {
            Write-Host '✓ Targeted documentation setup completed!' -ForegroundColor Green
            Write-Host "`nWaiting for documentation completion..." -ForegroundColor Yellow
            $fileInfo      = Get-InstallerFileInfo -FilesPath $filesPath
            $jsonProcessed = Wait-ForDocumentationAndProcess -ProjectPath $ProjectPath -InstallerType $fileInfo.Type -ExpectedJsonPath $docSuccess
            if ($jsonProcessed) {
                Write-Host '✓ Documentation processing completed successfully!' -ForegroundColor Green
            }
            else {
                Write-Warning 'Documentation processing had issues - please review manually'
            }

            # Promote the icon extracted during the install run to Assets\AppIcon.png. A winget IconUrl or a
            # manual -IconPath already applied takes precedence (winget-primary); otherwise this is how manual
            # and iconless apps finally get a real Intune tile. Best-effort — never let it derail packaging.
            try { $null = Import-Win32ToolkitCapturedIcon -ProjectPath $ProjectPath }
            catch { Write-Warning "Captured-icon promotion skipped: $($_.Exception.Message)" }
        }
        else {
            Write-Warning 'Documentation generation had issues - please review manually'
        }
    }
    finally {
        if (-not $heldBack) { $heldBack = $true; & $resumeHeld }
    }
    if ($Result) {
        # The capture state for the caller's result object (TUI audit G2): what the warnings above said.
        $Result.Capture = if ($captureReady -and $jsonProcessed) { 'Done' } else { 'Problems' }
        if (-not $captureReady) {
            $Result.Problems.Add('The install capture did not complete: the uninstall, the processes to close and the capture-based detection rule were not updated (see the warnings above).')
        }
        elseif (-not $jsonProcessed) {
            $Result.Problems.Add('The install capture could not be processed cleanly: review the uninstall and the processes to close (see the warnings above).')
        }
    }

    # Keep the capture's logs in their own folder BEFORE any test run can overwrite them. Under Sandbox the
    # guest's log collector runs after the capture JSON is written, so wait for it (bounded); a Hyper-V
    # capture brought its logs back with the copy-out.
    if ($captureRun -and $docSuccess) {
        try {
            if ($backend -eq 'Sandbox' -and $jsonProcessed -and -not (Wait-Win32ToolkitCollectedLog -ProjectPath $ProjectPath -TimeoutSeconds 60)) {
                Write-Warning "The Sandbox log collector did not finish within 60 s: the capture's log folder may miss its PSADT/MSI logs (see Sandbox\Logs)."
            }
            $captureLogs = Save-Win32ToolkitTestRunLog -Run $captureRun
            if ($captureLogs) { Write-Host "Capture logs     : $(Join-Path $ProjectPath $captureLogs)" -ForegroundColor Gray }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Warning "The capture's logs could not be kept in their own folder: $($_.Exception.Message)"
        }
    }

    # 2b. Prior installs (installer-identity PR 3b, spec 2.17): capture the other installer technologies, raise the
    #     windows of the captured rules, apply the Block proposals, then prove and demote - after the install capture's
    #     logs are kept and before the test loop, under the optional per-project lease (TestProjectLease).
    $skipGenericUpdate = $false
    # An unreadable rule state never stops the run (C-7): the prior-install step is skipped with one warning.
    $priorStates = @()
    try { $priorStates = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath) }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        $readText = "The prior-install rules could not be read ($(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)): no capture, proof or demotion ran."
        Write-Warning $readText
        if ($Result) { $Result.Problems.Add($readText) }
        $CaptureSiblingTechnologies = $false
    }
    $unprovenEnforce = @($priorStates | Where-Object { $_.Mode -ceq 'Enforce' -and $_.State -eq 'NotProven' })
    if ($CaptureSiblingTechnologies -or $unprovenEnforce.Count -gt 0) {
        $priorLease = $null
        try {
            if (([string](Get-Win32ToolkitConfigValue -Name 'TestProjectLease' -Default 'Off')).Trim() -eq 'On' -and (Test-Win32ToolkitElevated)) {
                $priorLease = Enter-Win32ToolkitHyperVLease -ProjectPath $ProjectPath -Purpose 'test'
            }
            $problem = { param([string]$Text) Write-Warning $Text; if ($Result) { $Result.Problems.Add($Text) } }
            if ($CaptureSiblingTechnologies) {
                if (-not $jsonProcessed) {
                    & $problem "The other installer technologies were not captured: the install capture did not complete, and a sibling capture needs the package's own identity it records."
                }
                else {
                    $pre = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $ProjectPath -Backend HyperV
                    # A Windows Sandbox record joins the records of the identity it sees and makes it Block-only (SV28):
                    # without a ready VM, a project whose captures already allow an Enforce rule is not captured again.
                    $sandboxLoss = @(if ($pre.Ok -and [string]$pre.Backend -eq 'Sandbox') { Get-Win32ToolkitSiblingSandboxImpact -ProjectPath $ProjectPath })
                    if (-not $pre.Ok) {
                        & $problem ("The other installer technologies were not captured: " + ($pre.Reasons -join '; ') + '.')
                    }
                    elseif ($sandboxLoss.Count -gt 0) {
                        & $problem ("The other installer technologies were not captured: the Hyper-V test VM is not ready, and a capture in Windows Sandbox would make " + ($sandboxLoss -join ', ') +
                            " Block-only (a Sandbox record is never Enforce-eligible and stays with the records of the identity it sees). Capture again when the VM is ready, or in Windows Sandbox on purpose: Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario SiblingCapture -Backend Sandbox.")
                    }
                    else {
                        # SV28: a Hyper-V VM that is not ready means Windows Sandbox (Block-only proposals), said here.
                        foreach ($note in @($pre.Notes | Where-Object { $_ })) { Write-Warning $note }
                        try {
                            $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $ProjectPath
                            $plan.Backend = [string]$pre.Backend
                            $captured = Invoke-Win32ToolkitSiblingCapture -ProjectPath $ProjectPath -Plan $plan -Backend ([string]$pre.Backend)
                            # Nothing planned (live rows RAISE, INNO): the winget manifests could not be read, and no index was
                            # written. What helps follows the plan's causes: only when every cause is Permanent does capturing
                            # again change nothing; else WingetList (this computer's winget), else Transient (later).
                            if ($captured -eq $false -and [int]$plan.EstimatedRuns -eq 0) {
                                $pkgCause = @($plan.PSObject.Properties['PackageProbe'] | Where-Object { $_.Value -and [string]$_.Value.Status -ne 'Ok' } | ForEach-Object { [string]$_.Value.Cause })
                                $causes = @($pkgCause + @(@($plan.Types) | Where-Object { $_ -and $_.PSObject.Properties['ProbeFailed'] -and $_.ProbeFailed } | ForEach-Object { [string]$_.ProbeCause }))
                                $retryable = @($causes | Where-Object { $_ -ne 'Permanent' })
                                $again = "Test-Win32ToolkitProject -ProjectPath '$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent((ConvertTo-Win32ToolkitSafeText -Text $ProjectPath -MaxLength 1024)))' -Scenario SiblingCapture"
                                if ($causes.Count -gt 0 -and $retryable.Count -eq 0) {
                                    & $problem ("The other installer technologies were not captured: their winget manifests could not be used (the warning above says why); capturing again will not change that" +
                                        $(if ($pkgCause.Count -gt 0) { ": check the project's winget id and version." } else { '.' }))
                                }
                                elseif ($retryable -contains 'WingetList') { & $problem "The other installer technologies were not captured: the app's winget versions could not be listed (the warning above says why). Check winget on this computer, then capture them again: $again." }
                                else { & $problem "The other installer technologies were not captured: their winget manifests could not be read (the warning above says why and when). Capture them again later: $again." }
                            }
                            elseif ($captured -eq $false) { & $problem 'Every capture of the other installer technologies failed (Documentation\SiblingCapture.json lists why): no new proposal.' }
                        }
                        catch {
                            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                            & $problem "The capture of the other installer technologies failed: $(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)"
                        }
                        # The D61 raise, whatever -ApplySiblingCapture says (it never adds, removes or re-modes a rule).
                        $null = Update-Win32ToolkitPriorInstallWindow -ProjectPath $ProjectPath
                        $proposals = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath).Proposals)
                        if ($ApplySiblingCapture -eq 'Block' -and $proposals.Count -gt 0) {
                            # The switch is the operator's consent for the bulk Block (spec 2.12 rule 7): High, flag-free,
                            # an identity that is not a rule yet; an existing rule is never changed here.
                            $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -FromSiblingCapture -Mode Block -Confirm:$false
                        }
                        foreach ($row in @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $ProjectPath -Stage Advisory | Where-Object { $_.Code -eq 'ID-SIBLING-UNAPPLIED' })) {
                            Write-Host "Sibling capture: $($row.Message)" -ForegroundColor Yellow
                        }
                    }
                }
                # Read again after the capture (the bulk Block may have added rules). Unreadable now: the capture ran, the
                # proof and the demotion are skipped with one warning, and the run goes on (C-7).
                $priorStates = @()
                try { $priorStates = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath) }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    $readText = "The prior-install rules could not be read after the capture ($(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)): no proof or demotion ran."
                    Write-Warning $readText
                    if ($Result) { $Result.Problems.Add($readText) }
                }
                $unprovenEnforce = @($priorStates | Where-Object { $_.Mode -ceq 'Enforce' -and $_.State -eq 'NotProven' })
            }
            if ($unprovenEnforce.Count -gt 0) {
                if ($RunTest -contains 'Update') {
                    $notReady = @(Test-Win32ToolkitHyperVReady)
                    if ($notReady.Count -eq 0) {
                        # The proof loop IS the Update test of this run (L37): one run per group, each from its own baseline.
                        $skipGenericUpdate = $true
                        if ($UpdateSpecificVersion -or $UpdateVersionsBack -or $UpdateBaselineInstallerType) {
                            Write-Host 'Note: -UpdateVersionsBack, -UpdateSpecificVersion and -UpdateBaselineInstallerType apply only to the generic Update test; the proof runs of the prior-install rules start from each group''s own baseline.' -ForegroundColor Gray
                        }
                    }
                    $demotion = Invoke-Win32ToolkitPriorDemotion -ProjectPath $ProjectPath -Prove:($notReady.Count -eq 0)
                    if ($skipGenericUpdate) {
                        $verdict = if (@($demotion.Demoted).Count -gt 0 -or @($demotion.Unproven).Count -gt 0) { 'Failed' } else { 'Passed' }
                        if ($Result) { $Result.Tests.Add([pscustomobject]@{ Scenario = 'Update'; Verdict = $verdict }) }
                    }
                    else { & $problem ("The Enforce prior-install rules could not be proven: Hyper-V is not ready (" + ($notReady -join '; ') + ').') }
                }
                else {
                    $demotion = Invoke-Win32ToolkitPriorDemotion -ProjectPath $ProjectPath
                    if (@($demotion.Demoted).Count -gt 0) {
                        Write-Warning "Captured Enforce prior-install rules are proven by an Update test on the Hyper-V test VM: run again with -RunTest Update. Demoted to proposals: $(@($demotion.Demoted | ForEach-Object { $_.Id }) -join ', ')."
                    }
                }
                foreach ($d in @($demotion.Demoted)) { if ($Result) { $Result.Problems.Add("The captured prior-install rule '$($d.Id)' was not proven ($($d.Reason)) and was demoted to a proposal.") } }
                foreach ($u in @($demotion.Unproven)) { if ($Result) { $Result.Problems.Add("The Enforce prior-install rule '$u' is not proven: Export refuses it until it is proven or waived (-Waive PROOF).") } }
            }
        }
        finally {
            if ($null -ne $priorLease) { $null = Exit-Win32ToolkitHyperVLease -Lease $priorLease }
        }
    }

    # 3. Optional test scenarios. The Update scenario returns a verdict ($true/$false/$null) —
    #    surface a failure loudly before any packaging/publishing continues.
    if ($RunTest) {
        foreach ($scenario in $RunTest) {
            if ($scenario -eq 'Update' -and $skipGenericUpdate) { continue }   # the proof loop above was this run's Update test
            $testArgs = @{ ProjectPath = $ProjectPath; Scenario = $scenario }
            if ($BasePath) { $testArgs['BasePath'] = $BasePath }
            if ($scenario -eq 'Update') {
                # Plumb the baseline choice through so automation never lands on the interactive picker.
                if ($UpdateSpecificVersion)   { $testArgs['SpecificVersion'] = $UpdateSpecificVersion }
                elseif ($UpdateVersionsBack)  { $testArgs['VersionsBack']    = $UpdateVersionsBack }
                if ($UpdateBaselineInstallerType) { $testArgs['BaselineInstallerType'] = $UpdateBaselineInstallerType }
            }
            $testStartUtc = [datetime]::UtcNow
            $verdict = Test-Win32ToolkitProject @testArgs
            if ($verdict -eq $false) {
                $assertLog = if ($scenario -eq 'InstallUninstall') { 'InstallAssertions.log' } else { 'UpdateAssertions.log' }
                # Name the failed run's own log folder (each leg of an Update 'Both' run has one; test campaign F2).
                $review = @(Get-Win32ToolkitTestRunLogFolder -ProjectPath $ProjectPath -Scenario $scenario -SinceUtc $testStartUtc |
                        ForEach-Object { Join-Path $_ $assertLog })
                if ($review.Count -eq 0) { $review = @("$ProjectPath\Sandbox\Logs\$assertLog") }
                Write-Warning "The $scenario test FAILED its assertions — review $($review -join ' and ') before publishing this package."
                if ($Result) {
                    $Result.Tests.Add([pscustomobject]@{ Scenario = $scenario; Verdict = 'Failed' })
                    $Result.Problems.Add("The $scenario test FAILED: review $($review -join ' and ').")
                }
            }
            elseif ($null -eq $verdict) {
                # $null means NO verdict — the test errored before running (e.g. a sandbox that never
                # freed), timed out, or produced no assertions. Packaging continues (matching the
                # $false policy of warn-don't-block), but a run that never happened must never read
                # as a pass.
                # A run the toolkit decided not to start (the Intune-parity pre-check records it as NotRun) is named as
                # such, not as a run that "may never have run" after errors (live row GOAL-CAPTURE).
                $notRunCode = ''
                $notRunNotes = ''
                try {
                    # Assigned first: the reader returns its array as ONE pipeline object (unary comma).
                    $testRecords = Get-Win32ToolkitTestResult -ProjectPath $ProjectPath
                    $notRunRecord = @($testRecords | Where-Object {
                            if (-not $_ -or [string]$_.Scenario -ne $scenario -or -not $_.PSObject.Properties['NotRun'] -or $null -eq $_.NotRun) { return $false }
                            $ts = $_.TimestampUtc
                            $at = if ($ts -is [datetime]) { $ts.ToUniversalTime() } else { [datetime]::Parse([string]$ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) }
                            $at -ge $testStartUtc.AddSeconds(-1)
                        }) | Select-Object -Last 1
                    if ($notRunRecord) {
                        $notRunCode = ConvertTo-Win32ToolkitSafeText -Text ([string]$notRunRecord.NotRun.Code) -MaxLength 64
                        $notRunNotes = ConvertTo-Win32ToolkitSafeText -Text ([string]$notRunRecord.Notes) -MaxLength 400
                    }
                }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    Write-Verbose "Could not read the test record of the $scenario test: $($_.Exception.Message)"
                }
                $what = if ($scenario -eq 'Update') { 'update an earlier version' } else { 'install and uninstall' }
                if ($notRunCode) {
                    Write-Warning "The $scenario test was NOT run ($notRunCode): the toolkit did not start it, for the reason the warning above gives. The package is about to be processed UNTESTED for this scenario."
                }
                else {
                    Write-Warning "The $scenario test produced NO verdict — it may never have run (see the errors above). The package is about to be processed UNTESTED for this scenario."
                }
                if ($Result) {
                    $Result.Tests.Add([pscustomobject]@{ Scenario = $scenario; Verdict = 'Inconclusive' })
                    if ($notRunCode) { $Result.Problems.Add("The $scenario test was not run ($notRunCode, Inconclusive): the package was not shown to $what. $notRunNotes".TrimEnd()) }
                    else { $Result.Problems.Add("The $scenario test gave no verdict (Inconclusive): the package was not shown to $what.") }
                }
            }
            elseif ($Result) {
                $Result.Tests.Add([pscustomobject]@{ Scenario = $scenario; Verdict = 'Passed' })
            }
        }
    }

    # 3. Optional package / publish (-PublishIntune / -PublishUpdate imply packaging).
    if ($PackageIntune -or $PublishIntune -or $PublishUpdate) {
        $exportArgs = @{ ProjectPath = $ProjectPath; PublishIntune = [bool]$PublishIntune; PublishUpdate = [bool]$PublishUpdate; AllowLegacyScript = [bool]$AllowLegacyScript }
        # With a result collector the export returns its summary (-PassThru); without one it emits nothing, as before.
        if ($Result) { $exportArgs['PassThru'] = $true }
        if ($NoPublishPrompt) { $exportArgs['NoPublishPrompt'] = $true }
        $exported = Export-Win32ToolkitIntuneWin @exportArgs
        if ($Result) {
            $summary = @($exported | Where-Object { $_ -and $_.PSObject.Properties['IntuneWinPath'] }) | Select-Object -Last 1
            if ($summary) {
                $Result.IntuneWinPath = [string]$summary.IntuneWinPath
                foreach ($pub in @($summary.Published)) { if ($null -ne $pub) { $Result.Published.Add($pub) } }
                foreach ($problem in @($summary.Problems)) { if (-not [string]::IsNullOrWhiteSpace([string]$problem)) { $Result.Problems.Add([string]$problem) } }
            }
        }
    }
}
