function Invoke-Win32ToolkitFinalize {
    <#
    .SYNOPSIS
        Runs the back half of the packaging pipeline for a scaffolded project.
    .DESCRIPTION
        Shared "finalize" tail used by both Invoke-Win32Toolkit (winget flow) and
        Complete-Win32ToolkitManualApp (manual flow), so the two cannot drift:

          1. New-TargetedDocumentation — launch the documentation sandbox (installs via the
             project's Invoke-AppDeployToolkit.ps1 and captures the install changes).
          2. Wait-ForDocumentationAndProcess — from the captured JSON, write AppConfig.Uninstall,
             the requirement script, and processes-to-close.
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

        [switch]$PackageIntune,

        [switch]$PublishIntune,

        # Also publish the update app (2nd app, same version, requirement-gated to installed devices).
        [switch]$PublishUpdate
    )

    $filesPath = Join-Path $ProjectPath 'Files'

    # 1-2. Sandbox documentation capture → uninstall / requirement / processes.
    Write-Host "`nGenerating targeted installation documentation..." -ForegroundColor Yellow
    $docSuccess = New-TargetedDocumentation -ProjectPath $ProjectPath -ProjectName $ProjectName -AppInfo $AppInfo

    if ($docSuccess) {
        Write-Host '✓ Targeted documentation setup completed!' -ForegroundColor Green
        Write-Host "`nWaiting for documentation completion..." -ForegroundColor Yellow
        $fileInfo      = Get-InstallerFileInfo -FilesPath $filesPath
        $jsonProcessed = Wait-ForDocumentationAndProcess -ProjectPath $ProjectPath -InstallerType $fileInfo.Type
        if ($jsonProcessed) {
            Write-Host '✓ Documentation processing completed successfully!' -ForegroundColor Green
        }
        else {
            Write-Warning 'Documentation processing had issues - please review manually'
        }
    }
    else {
        Write-Warning 'Documentation generation had issues - please review manually'
    }

    # 3. Optional test scenarios. The Update scenario returns a verdict ($true/$false/$null) —
    #    surface a failure loudly before any packaging/publishing continues.
    if ($RunTest) {
        foreach ($scenario in $RunTest) {
            $verdict = Test-Win32ToolkitProject -ProjectPath $ProjectPath -Scenario $scenario
            if ($verdict -eq $false) {
                Write-Warning "The $scenario test FAILED its assertions — review $ProjectPath\Sandbox\Logs\UpdateAssertions.log before publishing this package."
            }
        }
    }

    # 3. Optional package / publish (-PublishIntune / -PublishUpdate imply packaging).
    if ($PackageIntune -or $PublishIntune -or $PublishUpdate) {
        Export-Win32ToolkitIntuneWin -ProjectPath $ProjectPath -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate
    }
}
