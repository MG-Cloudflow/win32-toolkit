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

        See knowledge-base/designs/manual-app-packaging.md.
    .PARAMETER ProjectPath
        Full path to the scaffolded PSADT project.
    .PARAMETER ProjectName
        Project (folder) name — used for the sandbox documentation config.
    .PARAMETER AppInfo
        App metadata object (passed through to New-TargetedDocumentation).
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
        # interactive picker (current behavior). SpecificVersion wins when both are supplied.
        [ValidateRange(1, 1000)]
        [int]$UpdateVersionsBack,

        [string]$UpdateSpecificVersion,

        [switch]$PackageIntune,

        [switch]$PublishIntune,

        # Also publish the update app (2nd app, same version, requirement-gated to installed devices).
        [switch]$PublishUpdate
    )

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
    $docSuccess = New-TargetedDocumentation -ProjectPath $ProjectPath -ProjectName $ProjectName -AppInfo $AppInfo -Backend $backend

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

    # 3. Optional test scenarios. The Update scenario returns a verdict ($true/$false/$null) —
    #    surface a failure loudly before any packaging/publishing continues.
    if ($RunTest) {
        foreach ($scenario in $RunTest) {
            $testArgs = @{ ProjectPath = $ProjectPath; Scenario = $scenario }
            if ($scenario -eq 'Update') {
                # Plumb the baseline choice through so automation never lands on the interactive picker.
                if ($UpdateSpecificVersion)   { $testArgs['SpecificVersion'] = $UpdateSpecificVersion }
                elseif ($UpdateVersionsBack)  { $testArgs['VersionsBack']    = $UpdateVersionsBack }
            }
            $verdict = Test-Win32ToolkitProject @testArgs
            if ($verdict -eq $false) {
                $assertLog = if ($scenario -eq 'InstallUninstall') { 'InstallAssertions.log' } else { 'UpdateAssertions.log' }
                Write-Warning "The $scenario test FAILED its assertions — review $ProjectPath\Sandbox\Logs\$assertLog before publishing this package."
            }
        }
    }

    # 3. Optional package / publish (-PublishIntune / -PublishUpdate imply packaging).
    if ($PackageIntune -or $PublishIntune -or $PublishUpdate) {
        Export-Win32ToolkitIntuneWin -ProjectPath $ProjectPath -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate
    }
}
