function Update-OrgTemplateIfNeeded {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Template,
        [string]$FilePath,
        # The run's base folder (TUI audit G4): the template wizard opened for the upgrade saves under it and checks
        # the extension module in its Templates\ folder. Empty = the configured base folder.
        [string]$BasePath
    )

    $schemaVer   = if ($Template.TemplateSchemaVersion) { $Template.TemplateSchemaVersion } else { '1.0' }
    $currentVer  = $script:TemplateSchemaVersion
    $needsUpdate = ([System.Version]$schemaVer) -lt ([System.Version]$currentVer)

    if (-not $needsUpdate) { return $Template }

    # Nobody can answer the upgrade prompt on a non-interactive host (service, CI, redirected input) or in a
    # 'pwsh -NonInteractive' console: the Read-Host threw there and aborted the whole pipeline, even with an
    # explicit -TemplateName (test campaign 2026-10-21, S12-F1). Such a run takes the decline path below: the
    # missing options use their defaults for THIS run only and the template file is not changed.
    $noPrompt = "Template '$($Template.TemplateName)' uses schema v$schemaVer, current is v$currentVer; this run cannot prompt, so the missing options use their defaults for this run only (the template file is unchanged). Update it interactively with Show-Win32Toolkit, or Invoke-Win32Toolkit -NewTemplate -TemplateName '$($Template.TemplateName)'."
    $cannotPrompt = $false
    try { $cannotPrompt = [bool](Test-Win32ToolkitHostNonInteractive) -or [bool](Test-Win32ToolkitNonInteractiveSwitch) }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        $cannotPrompt = $false
    }
    if ($cannotPrompt) {
        Write-Warning $noPrompt
    }
    else {
        Write-Host ''
        Write-Host "  Template '$($Template.TemplateName)' uses schema v$schemaVer, current is v$currentVer." -ForegroundColor Yellow
        Write-Host '  New options are available. Would you like to update the template now?' -ForegroundColor Yellow
        $ans = 'n'
        try { $ans = Read-Host '  Update template? (y/n) [y]' }
        catch {
            # A host the checks above did not recognise still refuses the prompt: same fallback. Anything else
            # is a real error.
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            if ($_.FullyQualifiedErrorId -notlike '*,Microsoft.PowerShell.Commands.ReadHostCommand') { throw }
            Write-Warning $noPrompt
            $ans = 'n'
        }
        if ("$ans".Trim() -in @('','y','Y','yes','Yes','1','true')) {
            Write-Host '  Opening template wizard with existing values pre-filled...' -ForegroundColor Cyan
            $updated = New-OrgTemplate -ExistingTemplate $Template -BasePath $BasePath
            return $updated
        }
    }

    # User skipped — patch missing fields silently with defaults so Apply-OrgTemplate won't fail
    if (-not $Template.PSObject.Properties['TemplateSchemaVersion']) { $Template | Add-Member -NotePropertyName TemplateSchemaVersion -NotePropertyValue $currentVer -Force }
    if (-not $Template.PSObject.Properties['PsadtVersion'])          { $Template | Add-Member -NotePropertyName PsadtVersion -NotePropertyValue 'unknown' -Force }
    if (-not $Template.PSObject.Properties['DialogStyle'])           { $Template | Add-Member -NotePropertyName DialogStyle -NotePropertyValue 'Fluent' -Force }
    if (-not $Template.PSObject.Properties['LanguageOverride'])      { $Template | Add-Member -NotePropertyName LanguageOverride -NotePropertyValue '' -Force }
    if (-not $Template.PSObject.Properties['Hooks'])                 { $Template | Add-Member -NotePropertyName Hooks -NotePropertyValue ([PSCustomObject]@{ Enabled = $false; FailureAction = 'Fail' }) -Force }
    if (-not $Template.PSObject.Properties['ExtensionModule'])       { $Template | Add-Member -NotePropertyName ExtensionModule -NotePropertyValue $false -Force }
    if (-not $Template.PSObject.Properties['CustomAssets'])          { $Template | Add-Member -NotePropertyName CustomAssets -NotePropertyValue $false -Force }
    if (-not $Template.PSObject.Properties['IntuneDefaults'])        { $Template | Add-Member -NotePropertyName IntuneDefaults -NotePropertyValue ([PSCustomObject]@{ MinimumWindowsRelease = '1607'; DeviceRestartBehavior = 'suppress'; MaxRuntimeMinutes = 60; DescriptionBoilerplate = ''; PrivacyUrl = '' }) -Force }
    if (-not $Template.PSObject.Properties['DocFooter'])             { $Template | Add-Member -NotePropertyName DocFooter -NotePropertyValue '' -Force }
    # Unpinned by default: an existing template keeps working, and publish warns rather than refusing.
    if (-not $Template.PSObject.Properties['TenantId'])              { $Template | Add-Member -NotePropertyName TenantId -NotePropertyValue '' -Force }
    if (-not $Template.PSObject.Properties['UninstallWelcomeDialog']) {
        $Template | Add-Member -NotePropertyName UninstallWelcomeDialog -NotePropertyValue (
            [PSCustomObject]@{ Enabled = $true; CloseProcessesCountdown = 60; PersistPrompt = $false; BlockExecution = $false }
        ) -Force
    }
    return $Template
}