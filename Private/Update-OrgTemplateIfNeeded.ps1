function Update-OrgTemplateIfNeeded {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Template,
        [string]$FilePath
    )

    $schemaVer   = if ($Template.TemplateSchemaVersion) { $Template.TemplateSchemaVersion } else { '1.0' }
    $currentVer  = $script:TemplateSchemaVersion
    $needsUpdate = ([System.Version]$schemaVer) -lt ([System.Version]$currentVer)

    if (-not $needsUpdate) { return $Template }

    Write-Host ''
    Write-Host "  Template '$($Template.TemplateName)' uses schema v$schemaVer, current is v$currentVer." -ForegroundColor Yellow
    Write-Host '  New options are available. Would you like to update the template now?' -ForegroundColor Yellow
    $ans = Read-Host '  Update template? (y/n) [y]'
    if ($ans.Trim() -in @('','y','Y','yes','Yes','1','true')) {
        Write-Host '  Opening template wizard with existing values pre-filled...' -ForegroundColor Cyan
        $updated = New-OrgTemplate -ExistingTemplate $Template
        return $updated
    }

    # User skipped — patch missing fields silently with defaults so Apply-OrgTemplate won't fail
    if (-not $Template.PSObject.Properties['TemplateSchemaVersion']) { $Template | Add-Member -NotePropertyName TemplateSchemaVersion -NotePropertyValue $currentVer -Force }
    if (-not $Template.PSObject.Properties['PsadtVersion'])          { $Template | Add-Member -NotePropertyName PsadtVersion -NotePropertyValue 'unknown' -Force }
    if (-not $Template.PSObject.Properties['DialogStyle'])           { $Template | Add-Member -NotePropertyName DialogStyle -NotePropertyValue 'Fluent' -Force }
    if (-not $Template.PSObject.Properties['LanguageOverride'])      { $Template | Add-Member -NotePropertyName LanguageOverride -NotePropertyValue '' -Force }
    if (-not $Template.PSObject.Properties['Hooks'])                 { $Template | Add-Member -NotePropertyName Hooks -NotePropertyValue ([PSCustomObject]@{ Enabled = $false; FailureAction = 'Fail' }) -Force }
    if (-not $Template.PSObject.Properties['ExtensionModule'])       { $Template | Add-Member -NotePropertyName ExtensionModule -NotePropertyValue $false -Force }
    if (-not $Template.PSObject.Properties['CustomAssets'])          { $Template | Add-Member -NotePropertyName CustomAssets -NotePropertyValue $false -Force }
    if (-not $Template.PSObject.Properties['UninstallWelcomeDialog']) {
        $Template | Add-Member -NotePropertyName UninstallWelcomeDialog -NotePropertyValue (
            [PSCustomObject]@{ Enabled = $true; CloseProcessesCountdown = 60; PersistPrompt = $false; BlockExecution = $false }
        ) -Force
    }
    return $Template
}