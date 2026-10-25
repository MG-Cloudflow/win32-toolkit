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
        [switch]$NoPublishPrompt
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

    # 3. Optional test scenarios. The Update scenario returns a verdict ($true/$false/$null) —
    #    surface a failure loudly before any packaging/publishing continues.
    if ($RunTest) {
        foreach ($scenario in $RunTest) {
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
                Write-Warning "The $scenario test produced NO verdict — it may never have run (see the errors above). The package is about to be processed UNTESTED for this scenario."
                if ($Result) {
                    $what = if ($scenario -eq 'Update') { 'update an earlier version' } else { 'install and uninstall' }
                    $Result.Tests.Add([pscustomobject]@{ Scenario = $scenario; Verdict = 'Inconclusive' })
                    $Result.Problems.Add("The $scenario test gave no verdict (Inconclusive): the package was not shown to $what.")
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
