<#
    TUI audit G2 (tui-gaps-spec 6.4): the wizards judge a run by its Win32Toolkit.RunResult.

    Before: the winget wizard, the manual wizard (Easy), Advanced finish and Project actions > Finalize showed a
    green 'Done' panel whenever the command did not throw, even after a failed test, an incomplete capture, a
    failed upload or a non-W32T error.

    Now Show-Win32ToolkitRunResult renders one panel from the LAST RunResult in the command's output:
      Succeeded              -> 'Done' (green)
      CompletedWithProblems  -> 'Finished with problems' (red), one '- <problem>' line per problem (escaped)
      Failed                 -> 'Finished with problems' (red), 'stopped before the end'
      Scaffolded             -> 'Scaffolded' (blue), the project path
      no result object       -> 'Finished' (yellow)
    Anything else in the output is ignored; a W32T.* error still shows the red 'Something went wrong' panel.

    Driven with shadows: every Spectre cmdlet, the menu helpers, and the commands (Invoke-Win32Toolkit,
    New-/Complete-Win32ToolkitManualApp) return scripted output built with the REAL Complete-Win32ToolkitRunResult.
    Nothing renders, nothing runs.

    Run:  pwsh -File Tests\TuiWizardResult.unit.ps1
#>
# Test shadows keep the real command names and signatures.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Clear-Host is shadowed: nothing renders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows and case helpers')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Sanitize-ProjectName', 'Get-Win32ToolkitPaths', 'Initialize-Win32ToolkitRunResult', 'Complete-Win32ToolkitRunResult',
    'Show-Win32ToolkitRunResult', 'Invoke-Win32ToolkitWingetWizard', 'Invoke-Win32ToolkitManualWizard', 'Show-Win32ToolkitAdvancedFinish',
    'Show-Win32ToolkitProjectActions',
    # TUI audit G4 (C-9): the wizards name the folder a failed run left marked not configured; Browse and the project list say so.
    'ConvertTo-Win32ToolkitSafeText', 'Get-Win32ToolkitNotConfiguredMarker', 'Find-Win32ToolkitNotConfiguredProject', 'Show-Win32ToolkitBrowse',
    # Test helper: writes the markers the scripted commands leave behind.
    'Write-Win32ToolkitNotConfiguredMarker') {
    . (Join-Path $repo "Private\$f.ps1")
}

$BASE = Join-Path ([System.IO.Path]::GetTempPath()) ('w32tw_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path (Join-Path $BASE 'Templates') -Force | Out-Null

# --- Spectre / rendering shadows (recorded, nothing renders) ---------------------------------------------
function winget { }   # Get-Command winget must succeed; the wizard never runs it
function Clear-Host { }
function Write-SpectreRule { param($Title, $Color) }
$script:hostLines = [System.Collections.Generic.List[string]]::new()
function Write-SpectreHost { param($Message) $script:hostLines.Add([string]$Message) }
function Out-SpectreHost { param([Parameter(ValueFromPipeline)]$InputObject) process {} }
$script:panels = [System.Collections.Generic.List[object]]::new()
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) $script:panels.Add([pscustomobject]@{ Data = [string]$Data; Header = [string]$Header; Color = [string]$Color }) }
function Read-SpectrePause { param($Message, [switch]$AnyKey) }
function Read-SpectreText { param($Message) 'something' }
function Get-SpectreEscapedText { param($Text) ([string]$Text).Replace('[', '[[').Replace(']', ']]') }
$script:multi = @()
function Read-SpectreMultiSelection { param($Message, $Choices, $Color, [switch]$AllowEmpty) @($Choices | Where-Object { $p = $_; @($script:multi | Where-Object { $p -like $_ }).Count }) }
$script:confirmPublish = $false   # [9]: also say yes to the 'Publishing UPLOADS ...' gate
$script:confirmDeps = $false      # [10]: also say yes to 'Does this app need another app installed FIRST ...?'
function Read-SpectreConfirm { param($Message, $DefaultAnswer) ($Message -in @('Build this now?', 'Continue?')) -or ($script:confirmPublish -and $Message -like 'Publishing UPLOADS*') -or ($script:confirmDeps -and $Message -like 'Does this app need*') }
# Object choices take the next queued key; when none is left: 'back' / 'later' in the menus, else the first one.
$script:keys = [System.Collections.Queue]::new()
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, [switch]$EnableSearch, $PageSize)
    if ($ChoiceLabelProperty) {
        $want = if ($script:keys.Count) { $script:keys.Dequeue() } elseif ($Message -eq 'What would you like to do?') { 'back' } elseif ($Message -eq 'Advanced app') { 'later' } else { $null }
        $m = @($Choices | Where-Object { $_.Key -eq $want })
        if ($m.Count) { return $m[0] }
    }
    @($Choices)[0]
}
$script:selectionShadow = ${function:Read-SpectreSelection}   # [7] replaces it; later sections restore it
$script:silentSwitch = '/S'   # the Easy wizard's silent-install answer ('' = blank switches)
$script:textPrompts = [System.Collections.Generic.List[string]]::new()
function Read-Win32ToolkitValidatedText {
    param($Message, $Validator, $ErrorMessage, [switch]$AllowEmpty)
    $script:textPrompts.Add([string]$Message)
    if ($Message -like 'Full path*') { return $script:manualSource }
    if ($Message -like 'Application name*') { return 'Tool[1]' }
    if ($Message -like 'Silent-install*') { return $script:silentSwitch }
    if ($AllowEmpty) { return '' }
    '1.0'
}

# --- menu / domain shadows ---------------------------------------------------------------------------------
function Get-WingetAppDetails { param($AppId) 'x64' }
function Get-Win32ToolkitTemplateChoice { param($BasePath) 'Contoso' }
$script:pickerArgs = $null   # [10]: what the wizards pass to the dependency picker
function Show-Win32ToolkitDependencyPicker { param($BasePath, $Existing, $ExcludeProject) $script:pickerArgs = $PSBoundParameters; @() }
function Get-Win32ToolkitBackendInfo { [pscustomobject]@{ Label = 'Windows Sandbox'; Resolved = 'Sandbox'; FellBack = $false; Reasons = @() } }
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitTestMode { param($Backend, [switch]$Unattended, $TestMode) 'Interactive' }
$script:apps = @([pscustomobject]@{ Name = 'Git[x]'; Id = 'Git.Git'; Version = '2.55.0'; Source = 'winget' })
function Search-WingetApps { param($SearchTerm) $script:apps }
function Get-Win32ToolkitPreviousProject { [CmdletBinding()] param($TemplateDirectory, $Version, $WingetId, $Vendor, $DisplayName, $ExcludePath, $TenantId) [pscustomobject]@{ Anchor = $null } }
function Get-Win32ToolkitSelfAnchor { [CmdletBinding()] param($ProjectPath, $TenantId) $null }
function Get-Win32ToolkitSiblingInstaller { [CmdletBinding()] param($WingetId, $Version, $Architecture, $PackagedType, $TimeoutSec, $BaseUri, [switch]$NoMemo) $null }
function Get-PSADTProjects { param($BasePath) @([pscustomobject]@{ Template = 'Contoso'; Name = 'Tool_x64_1.0'; Path = (Join-Path $BASE 'Projects\Contoso\Tool_x64_1.0'); ScriptPath = '' }) }
$script:projectsShadow = ${function:Get-PSADTProjects}   # [7] replaces it; later sections restore it
function Get-Win32ToolkitDependencies { param($ProjectPath) @() }

# --- the commands: scripted output ------------------------------------------------------------------------
# $script:output is what the next command returns (any objects); $script:throwThis is thrown instead when set.
$script:output = @(); $script:throwThis = $null; $script:beforeRun = $null   # beforeRun: what the command does first (e.g. writes a marker)
$script:completeOutput = $null
$script:throwOnce = $null; $script:completeCalls = 0
$script:invokeArgs = $null; $script:newArgs = $null; $script:completeArgs = $null
function Invoke-Win32Toolkit {
    param($Id, $Architecture, $TemplateName, $BasePath, [switch]$Force, $DependsOn, $RunTest, [switch]$PackageIntune, [switch]$PublishIntune, $InstallerType, [switch]$NoPublishPrompt)
    $script:invokeArgs = $PSBoundParameters
    if ($script:beforeRun) { & $script:beforeRun }
    if ($script:throwThis) { throw $script:throwThis }
    $script:output
}
$script:newWarnings = @()   # [9]: the warnings the scaffold prints (they must reach the wizard's -WarningVariable)
function New-Win32ToolkitManualApp {
    [CmdletBinding()]   # common parameters: the Advanced scaffold is called with -WarningVariable (TUI audit G6)
    param($Name, $Version, $Architecture, $SourcePath, $TemplateName, $BasePath, [switch]$Force, $Publisher, $Description, $InformationUrl, $IconPath, $DependsOn,
        [switch]$Advanced, $SilentArgs, [switch]$Continue, $RunTest, [switch]$PackageIntune, [switch]$PublishIntune, [switch]$NoPublishPrompt)
    $script:newArgs = $PSBoundParameters
    foreach ($w in $script:newWarnings) { Write-Warning $w }
    if ($script:beforeRun) { & $script:beforeRun }
    if ($script:throwThis) { throw $script:throwThis }
    $script:output
}
function Complete-Win32ToolkitManualApp {
    param($ProjectPath, $RunTest, [switch]$PackageIntune, [switch]$PublishIntune, [switch]$PublishUpdate, [switch]$AllowLegacyScript, [switch]$NoPublishPrompt)
    $script:completeArgs = $PSBoundParameters
    $script:completeCalls++
    if ($script:throwOnce) { $once = $script:throwOnce; $script:throwOnce = $null; throw $once }   # [11]: the first call only
    if ($script:throwThis) { throw $script:throwThis }
    if ($null -ne $script:completeOutput) { $script:completeOutput } else { $script:output }   # [9]: its own output after a scaffold
}
function New-RR {
    param([string]$Command = 'Invoke-Win32Toolkit', [string[]]$Problems = @(), [switch]$Failed, [switch]$Scaffolded, [string]$ProjectPath = 'C:\B\Projects\Contoso\Git_x64_2.55.0', [string]$Mode = 'Winget')
    $c = Initialize-Win32ToolkitRunResult -Command $Command -Mode $Mode
    $c.ProjectPath = $ProjectPath; $c.ProjectName = Split-Path -Leaf $ProjectPath
    foreach ($p in $Problems) { $c.Problems.Add($p) }
    Complete-Win32ToolkitRunResult -Result $c -Failed:$Failed -Scaffolded:$Scaffolded
}
function Reset-Run([object[]]$Output, $Throw = $null) {
    $script:output = $Output; $script:throwThis = $Throw; $script:beforeRun = $null; $script:newWarnings = @(); $script:completeOutput = $null
    $script:panels.Clear(); $script:hostLines.Clear(); $script:textPrompts.Clear(); $script:keys = [System.Collections.Queue]::new()
    $script:invokeArgs = $null; $script:newArgs = $null; $script:completeArgs = $null
}
# The last panel the run showed (the result panel comes after the Review panel).
function LastPanel { $script:panels[$script:panels.Count - 1] }

try {
    # == [1] winget wizard ====================================================================================
    Write-Host '[1] the winget wizard shows the panel of its RunResult' -ForegroundColor Cyan
    Reset-Run @(New-RR)
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($script:invokeArgs -and $p.Header -eq 'Done' -and $p.Color -eq 'Green' -and $p.Data -ceq "Finished [green]Git[[x]][/].`nUse [blue]Browse projects[/] to find it; review the messages above for details.") { Ok 'Succeeded -> green Done (the app name escaped)' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    Reset-Run @(New-RR -Problems 'The InstallUninstall test FAILED: review C:\x\[run]\InstallAssertions.log.', 'IntuneWinAppUtil.exe finished, but x was not found: no package was built.')
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    $want = "[red]Git[[x]][/] finished, but not everything worked:`n- The InstallUninstall test FAILED: review C:\x\[[run]]\InstallAssertions.log.`n- IntuneWinAppUtil.exe finished, but x was not found: no package was built.`n`nReview the messages above for details."
    if ($p.Header -eq 'Finished with problems' -and $p.Color -eq 'Red' -and $p.Data -ceq $want) { Ok 'CompletedWithProblems -> red "Finished with problems", one escaped line per problem (no green Done)' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }
    if (-not @($script:panels | Where-Object { $_.Header -eq 'Done' }).Count) { Ok 'no Done panel after a run with problems' } else { Bad 'a Done panel was shown' }

    Reset-Run @(New-RR -Problems 'boom' -Failed)
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Finished with problems' -and $p.Color -eq 'Red' -and $p.Data -ceq "[red]Git[[x]][/] stopped before the end:`n- boom`n`nThe steps after it did not run. Review the messages above for details.") { Ok 'Failed -> red "stopped before the end" with the error' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    Reset-Run @('stray text', 42, (New-RR -Problems 'first'), 'more stray', (New-RR))
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Done') { Ok 'stray output is ignored and the LAST RunResult decides' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    Reset-Run @('only stray text')
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Finished' -and $p.Color -eq 'Yellow' -and $p.Data -ceq 'Git[[x]]: no result came back. Review the messages above for details.') { Ok 'no RunResult -> yellow Finished' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    Reset-Run @() ([System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('Download FAILED for x'), 'W32T.DownloadFailed', 'ResourceUnavailable', $null))
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Something went wrong' -and $p.Color -eq 'Red' -and $p.Data -like '*Download FAILED for x*') { Ok 'a W32T.* error still shows the red "Something went wrong" panel' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    # == [2] manual wizard, Easy ==============================================================================
    Write-Host '[2] the manual wizard (Easy) shows the panel of its RunResult' -ForegroundColor Cyan
    $script:manualSource = Join-Path $BASE 'src\tool.exe'
    New-Item -ItemType Directory -Path (Split-Path $script:manualSource) -Force | Out-Null; Set-Content -LiteralPath $script:manualSource 'x'
    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Problems 'The install capture did not complete: x')
    $script:keys.Enqueue('easy')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($script:newArgs -and $script:newArgs['Continue'] -and $p.Header -eq 'Finished with problems' -and $p.Data.StartsWith('[red]Tool[[1]][/] finished, but not everything worked:') -and $p.Data.Contains("`n- The install capture did not complete: x")) { Ok 'Easy + a problem -> red "Finished with problems" naming the app' } else { Bad "panel: $($p | ConvertTo-Json -Compress) args=$($script:newArgs.Keys -join ',')" }
    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp')
    $script:keys.Enqueue('easy')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    if ((LastPanel).Header -eq 'Done') { Ok 'Easy + Succeeded -> Done' } else { Bad "panel: $(LastPanel | ConvertTo-Json -Compress)" }
    # An EXE with blank silent switches becomes a hard app: New-Win32ToolkitManualApp returns Status Scaffolded.
    $scafPath = Join-Path $BASE 'Projects\Contoso\Tool_1_x64_1.0'
    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Scaffolded -ProjectPath $scafPath)
    $script:silentSwitch = ''
    $script:keys.Enqueue('easy')
    try { Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null } finally { $script:silentSwitch = '/S' }
    $p = LastPanel
    $want = "Tool[[1]] was created at:`n[blue]$scafPath[/]`nFinish it from [blue]Work with an existing project[/] > Finalize / refresh."
    if ($script:newArgs -and $script:newArgs['SilentArgs'] -eq '' -and $p.Header -eq 'Scaffolded' -and $p.Color -eq 'Blue' -and $p.Data -ceq $want) {
        Ok 'Easy + blank silent switches + a Scaffolded result -> blue Scaffolded panel with the project path and where to finish it (no Done)'
    } else { Bad "panel: $($p | ConvertTo-Json -Compress) silent='$(if ($script:newArgs) { $script:newArgs['SilentArgs'] })'" }

    # == [3] Advanced finish ==================================================================================
    Write-Host '[3] Advanced finish shows the panel of the Complete-Win32ToolkitManualApp RunResult' -ForegroundColor Cyan
    $proj = Join-Path $BASE 'Projects\Contoso\Tool_x64_1.0'
    Reset-Run @(New-RR -Command 'Complete-Win32ToolkitManualApp' -Problems 'The update app was not published: x' -ProjectPath $proj)
    $script:keys.Enqueue('finish')
    Show-Win32ToolkitAdvancedFinish -ProjectPath $proj -DoTest -DoPackage 6>$null 3>$null
    $p = LastPanel
    if ($script:completeArgs -and $script:completeArgs['ProjectPath'] -eq $proj -and $p.Header -eq 'Finished with problems' -and $p.Data -like '`[red`]Tool_x64_1.0`[/] finished, but not everything worked:*- The update app was not published: x*') { Ok 'a problem -> red "Finished with problems" named after the project folder' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }
    Reset-Run @(New-RR -Command 'Complete-Win32ToolkitManualApp' -ProjectPath $proj)
    $script:keys.Enqueue('finish')
    Show-Win32ToolkitAdvancedFinish -ProjectPath $proj 6>$null 3>$null
    if ((LastPanel).Header -eq 'Done' -and (LastPanel).Color -eq 'Green') { Ok 'Succeeded -> Done' } else { Bad "panel: $(LastPanel | ConvertTo-Json -Compress)" }

    # == [4] Project actions > Finalize / refresh ============================================================
    Write-Host '[4] Project actions > Finalize / refresh shows the panel (the object never prints raw)' -ForegroundColor Cyan
    Reset-Run @(New-RR -Command 'Complete-Win32ToolkitManualApp' -Problems 'The InstallUninstall test gave no verdict (Inconclusive): x' -ProjectPath $proj)
    $script:keys.Enqueue('finish')
    $leak = @(Show-Win32ToolkitProjectActions -BasePath $BASE 6>$null 3>$null)
    $rp = @($script:panels | Where-Object { $_.Header -eq 'Finished with problems' })
    if ($script:completeArgs -and $rp.Count -eq 1 -and $rp[0].Data -like '`[red`]Tool_x64_1.0`[/] finished, but not everything worked:*Inconclusive*') { Ok 'Finalize with a problem -> red "Finished with problems"' } else { Bad "panels: $($script:panels | ConvertTo-Json -Compress)" }
    if (-not @($leak | Where-Object { $_ -and $_.PSObject.TypeNames -contains 'Win32Toolkit.RunResult' }).Count) { Ok 'the RunResult is captured: nothing of it leaves the screen' } else { Bad 'the RunResult leaked out of Show-Win32ToolkitProjectActions' }

    # == [5] winget wizard: the folder a failed build left marked not configured (TUI audit G4) =============
    Write-Host '[5] the winget wizard names the project folder a failed build left marked not configured' -ForegroundColor Cyan
    $tplDir = Join-Path $BASE 'Projects\Contoso'
    $gitProj = Join-Path $tplDir 'Git_x_x64_2.55.0'
    $line2 = 'Package and Publish refuse it until you package the app again (that replaces the folder).'
    $kept = { param([string]$Path) "`n`nThe project folder was kept and marked not configured: $Path`n$line2" }
    $w32tErr = { param([string]$Id, [string]$Message, $Target) [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message), $Id, 'InvalidData', $Target) }
    $writeRaw = {
        param([string]$Project, [datetime]$Stamp, [datetime]$FileTime)
        New-Item -ItemType Directory -Path (Join-Path $Project 'Documentation') -Force | Out-Null
        $f = Join-Path $Project 'Documentation\NotConfigured.json'
        [System.IO.File]::WriteAllText($f, "{ `"SchemaVersion`": `"1.0`", `"Stage`": `"Configure`", `"ErrorId`": `"W32T.X`", `"Reason`": `"r`", `"TimestampUtc`": `"$($Stamp.ToString('o'))`" }", [System.Text.UTF8Encoding]::new($false))
        (Get-Item -LiteralPath $f).LastWriteTimeUtc = $FileTime
    }
    $resetMarkers = { Remove-Item -LiteralPath $tplDir -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Path $tplDir -Force | Out-Null }

    & $resetMarkers
    $modDir = Join-Path $BASE 'Templates\Contoso\PSAppDeployToolkit.Contoso'
    Reset-Run @() (& $w32tErr 'W32T.OrgExtensionInvalid' "Org extension module 'PSAppDeployToolkit.Contoso' cannot be used: no manifest" $modDir)
    $script:beforeRun = { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $gitProj -Stage Configure -ErrorId 'W32T.OrgExtensionInvalid' -Reason 'no manifest' }
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    $want = "[red]Org extension module 'PSAppDeployToolkit.Contoso' cannot be used: no manifest[/]" + (& $kept $gitProj)
    if ($p.Header -eq 'Something went wrong' -and $p.Data -ceq $want) { Ok 'W32T.OrgExtensionInvalid (TargetObject the module folder) -> the red panel names the kept, marked project (template-folder scan)' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    & $resetMarkers
    & $writeRaw (Join-Path $tplDir 'Old_x64_1.0') ([datetime]::UtcNow.AddHours(-1)) ([datetime]::UtcNow.AddHours(-1))
    & $writeRaw (Join-Path $tplDir 'Future_x64_1.0') ([datetime]::UtcNow.AddDays(1)) ([datetime]::UtcNow.AddMinutes(-5))
    Reset-Run @() (& $w32tErr 'W32T.OrgExtensionInvalid' 'refused' $modDir)
    $script:beforeRun = { & $writeRaw (Join-Path $tplDir 'FutureNow_x64_1.0') ([datetime]::UtcNow.AddDays(1)) ([datetime]::UtcNow) }
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Something went wrong' -and $p.Data -ceq '[red]refused[/]') { Ok 'a marker older than the run, a future-dated one written before it and a future-dated one written during it -> none is named' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    # Each time rule on its own (a sibling the other rule lets through), next to a fresh marker that IS named.
    $freshProj = Join-Path $tplDir 'Fresh_x64_1.0'
    & $resetMarkers
    Reset-Run @() (& $w32tErr 'W32T.OrgExtensionInvalid' 'refused' $modDir)
    $script:beforeRun = {
        Write-Win32ToolkitNotConfiguredMarker -ProjectPath $freshProj -Stage Configure -ErrorId 'W32T.OrgExtensionInvalid' -Reason 'refused'
        & $writeRaw (Join-Path $tplDir 'OldFile_x64_1.0') ([datetime]::UtcNow) ([datetime]::UtcNow.AddHours(-1))
    }
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Something went wrong' -and $p.Data -ceq ('[red]refused[/]' + (& $kept $freshProj))) { Ok 'a sibling marker stamped during the run whose file was last written before it -> not named (the fresh one is)' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    & $resetMarkers
    Reset-Run @() (& $w32tErr 'W32T.OrgExtensionInvalid' 'refused' $modDir)
    $script:beforeRun = {
        Write-Win32ToolkitNotConfiguredMarker -ProjectPath $freshProj -Stage Configure -ErrorId 'W32T.OrgExtensionInvalid' -Reason 'refused'
        & $writeRaw (Join-Path $tplDir 'OldStamp_x64_1.0') ([datetime]::UtcNow.AddHours(-1)) ([datetime]::UtcNow)
    }
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Something went wrong' -and $p.Data -ceq ('[red]refused[/]' + (& $kept $freshProj))) { Ok 'a sibling marker written during the run whose TimestampUtc is an hour old -> not named (the fresh one is)' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    # File times are coarser than [datetime]::UtcNow (about 16 ms on NTFS, 2 s on FAT): a marker written in the same
    # clock tick as the run start can carry a write time just before it (CI flake on a fast runner). Still this run's.
    & $resetMarkers
    $since = [datetime]::UtcNow
    $tickProj = Join-Path $tplDir 'Tick_x64_1.0'; $staleProj = Join-Path $tplDir 'StaleFile_x64_1.0'
    & $writeRaw $tickProj $since.AddMilliseconds(5) $since.AddMilliseconds(-15)
    & $writeRaw $staleProj $since.AddMilliseconds(5) $since.AddSeconds(-3)
    $named = @(Find-Win32ToolkitNotConfiguredProject -TemplateDirectory $tplDir -SinceUtc $since)
    if ($named.Count -eq 1 -and $named[0] -eq [System.IO.Path]::GetFullPath($tickProj)) { Ok 'a marker file written 15 ms before the run start (coarse file clock) is named; one 3 s before is not' } else { Bad "named: $($named -join ', ')" }

    & $resetMarkers
    $projA = Join-Path $tplDir 'A_x64_1.0'; $projB = Join-Path $tplDir 'B_x64_1.0'
    Reset-Run @() (& $w32tErr 'W32T.PipelineAborted' 'PSADT configuration failed' $projA)
    $script:beforeRun = { foreach ($pp in $projA, $projB) { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $pp -Stage Configure -ErrorId 'W32T.PipelineAborted' -Reason 'x' } }
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Data -ceq ('[red]PSADT configuration failed[/]' + (& $kept $projA))) { Ok "the error's TargetObject is a project of the template folder -> only that project is named (no scan; B's fresh marker is not)" } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    & $resetMarkers
    $script:apps = @([pscustomobject]@{ Name = 'Git[x]'; Id = 'Git.Git'; Version = 'Unknown'; Source = 'winget' })
    $unk = Join-Path $tplDir 'Git_x_x64_Unknown'
    Reset-Run @() (& $w32tErr 'W32T.DownloadFailed' 'Download FAILED' $unk)
    $script:beforeRun = { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $unk -Stage Download -ErrorId 'W32T.DownloadFailed' -Reason 'Download FAILED' }
    $threw = $null
    try { Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null } catch { $threw = $_ }
    $p = LastPanel
    if (-not $threw -and $p.Data -ceq ('[red]Download FAILED[/]' + (& $kept $unk))) { Ok 'version Unknown (no technology checks) -> the catch still knows the template folder and names the project' } else { Bad "threw=$threw panel: $($p | ConvertTo-Json -Compress)" }
    $script:apps = @([pscustomobject]@{ Name = 'Git[x]'; Id = 'Git.Git'; Version = '2.55.0'; Source = 'winget' })

    & $resetMarkers
    Reset-Run @('stray', (New-RR -Problems 'Script stopped' -Failed -ProjectPath $gitProj))
    $script:beforeRun = { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $gitProj -Stage Configure -Reason 'Script stopped' }
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $y = @($script:hostLines | Where-Object { $_ -like '`[yellow`]*' })
    if ((LastPanel).Header -eq 'Finished with problems' -and $y.Count -eq 2 -and $y[0] -ceq "[yellow]The project folder was kept and marked not configured: $gitProj[/]" -and $y[1] -ceq "[yellow]$line2[/]") {
        Ok 'a Failed result (a non-W32T error after the scaffold) -> the two kept-and-marked lines in yellow after the result panel'
    } else { Bad "yellow lines: $($y -join ' | ') panel: $(LastPanel | ConvertTo-Json -Compress)" }
    & $resetMarkers
    Reset-Run @((New-RR -Problems 'p' -ProjectPath $gitProj))
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    if (-not @($script:hostLines | Where-Object { $_ -like '*kept and marked not configured*' }).Count) { Ok 'a result that is not Failed -> no kept-and-marked lines' } else { Bad "lines: $($script:hostLines -join ' | ')" }

    # == [6] manual wizard: the same in the Advanced and Easy catches and after a Failed result ==============
    Write-Host '[6] the manual wizard names the project folder a failed build left marked not configured' -ForegroundColor Cyan
    $toolProj = Join-Path $tplDir 'Tool_1_x64_1.0'
    & $resetMarkers
    Reset-Run @() (& $w32tErr 'W32T.PipelineAborted' 'org template refused' $toolProj)
    $script:beforeRun = { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $toolProj -Stage Configure -ErrorId 'W32T.PipelineAborted' -Reason 'org template refused' }
    $script:keys.Enqueue('advanced')
    $threw = $null
    try { Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null } catch { $threw = $_ }
    $p = LastPanel
    if (-not $threw -and $script:newArgs['Advanced'] -and $p.Header -eq 'Scaffold failed' -and $p.Data -ceq ('[red]org template refused[/]' + (& $kept $toolProj))) { Ok 'Advanced: the red "Scaffold failed" panel names the kept, marked project' } else { Bad "threw=$threw panel: $($p | ConvertTo-Json -Compress)" }

    & $resetMarkers
    Reset-Run @() (& $w32tErr 'W32T.PipelineAborted' 'org template refused' $toolProj)
    $script:beforeRun = { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $toolProj -Stage Configure -ErrorId 'W32T.PipelineAborted' -Reason 'org template refused' }
    $script:keys.Enqueue('easy')
    $threw = $null
    try { Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null } catch { $threw = $_ }
    $p = LastPanel
    if (-not $threw -and $p.Header -eq 'Something went wrong' -and $p.Data -ceq ('[red]org template refused[/]' + (& $kept $toolProj))) { Ok 'Easy: the red "Something went wrong" panel names it; the catch does not throw' } else { Bad "threw=$threw panel: $($p | ConvertTo-Json -Compress)" }

    & $resetMarkers
    Reset-Run @((New-RR -Command 'New-Win32ToolkitManualApp' -Problems 'No installer (msi/exe/msix/appx) detected' -Failed -ProjectPath $toolProj))
    $script:beforeRun = { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $toolProj -Stage Download -Reason 'No installer (msi/exe/msix/appx) detected' }
    $script:keys.Enqueue('easy')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    $y = @($script:hostLines | Where-Object { $_ -like '`[yellow`]*kept and marked*' })
    if ((LastPanel).Header -eq 'Finished with problems' -and $y.Count -eq 1 -and $y[0] -ceq "[yellow]The project folder was kept and marked not configured: $toolProj[/]") { Ok 'Easy + a Failed result with a freshly marked ProjectPath -> the yellow kept-and-marked lines' } else { Bad "lines: $($script:hostLines -join ' | ')" }

    # == [7] Browse and the project list say "(not configured)" ============================================
    Write-Host '[7] Browse and the project list mark a not-configured project' -ForegroundColor Cyan
    $script:browseRows = [System.Collections.Generic.List[object]]::new()
    function Format-SpectreTable { param([Parameter(ValueFromPipeline)]$InputObject, $Border, $Color, $Title) process { $script:browseRows.Add($InputObject) } }
    function Get-Win32ToolkitProjectPsadtVersion { param($ProjectPath) [pscustomobject]@{ VersionText = '4.1.8'; IsLegacy = $false; IsSupported = $true } }
    function Get-PSADTProjects {
        param($BasePath)
        @([pscustomobject]@{ Template = 'Contoso'; Name = 'Tool_x64_1.0'; Path = $toolProj; ScriptPath = ''; NotConfigured = $true },
          [pscustomobject]@{ Template = 'Contoso'; Name = 'Zed_x64_1.0'; Path = (Join-Path $tplDir 'Zed_x64_1.0'); ScriptPath = ''; NotConfigured = $false })
    }
    Show-Win32ToolkitBrowse -BasePath $BASE 6>$null 3>$null
    $apps = @($script:browseRows | ForEach-Object Application)
    if (($apps -join '|') -ceq 'Tool_x64_1.0 (not configured)|Zed_x64_1.0') { Ok "Browse: Application 'Tool_x64_1.0 (not configured)'; the other project unchanged" } else { Bad "browse rows: $($apps -join '|')" }
    $script:labelsSeen = @()
    function Read-SpectreSelection {
        param($Message, $Choices, $ChoiceLabelProperty, $Color, [switch]$EnableSearch, $PageSize)
        if ($Message -like 'Select a project*') { $script:labelsSeen = @($Choices); return 'no such project' }   # -> the screen returns
        @($Choices)[0]
    }
    Show-Win32ToolkitProjectActions -BasePath $BASE 6>$null 3>$null
    if (($script:labelsSeen -join '|') -ceq 'Contoso  /  Tool_x64_1.0  (not configured)|Contoso  /  Zed_x64_1.0') { Ok "the project list: 'Contoso  /  Tool_x64_1.0  (not configured)'" } else { Bad "labels: $($script:labelsSeen -join '|')" }

    # == [8] the menu never reaches the raw 'Upload to Microsoft Intune now?' prompt (TUI audit G5) ==========
    # The wizards ask about publishing themselves; a build with 'Package to .intunewin' ticked and publish not
    # ticked must not stop at Export's Read-Host. Every TUI caller passes -NoPublishPrompt.
    Write-Host '[8] the wizards, Advanced finish and Finalize / refresh pass -NoPublishPrompt' -ForegroundColor Cyan
    ${function:Read-SpectreSelection} = $script:selectionShadow
    ${function:Get-PSADTProjects} = $script:projectsShadow
    $script:apps = @([pscustomobject]@{ Name = 'Git[x]'; Id = 'Git.Git'; Version = '2.55.0'; Source = 'winget' })   # [7] reused $apps
    $script:multi = @('Package*')
    try {
        Reset-Run @(New-RR)
        Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
        $ia = $script:invokeArgs
        if ($ia -and $ia['PackageIntune'] -and -not $ia['PublishIntune'] -and $ia.ContainsKey('NoPublishPrompt') -and $ia['NoPublishPrompt']) { Ok 'winget wizard, Package ticked, Publish not: Invoke-Win32Toolkit gets -NoPublishPrompt' } else { Bad "invoke args: $(if ($ia) { ($ia.Keys | Sort-Object) -join ',' })" }

        Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp')
        $script:keys.Enqueue('easy')
        Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
        $na = $script:newArgs
        if ($na -and $na['PackageIntune'] -and $na.ContainsKey('NoPublishPrompt') -and $na['NoPublishPrompt']) { Ok 'manual wizard (Easy), Package ticked: New-Win32ToolkitManualApp gets -NoPublishPrompt' } else { Bad "new args: $(if ($na) { ($na.Keys | Sort-Object) -join ',' })" }

        Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Scaffolded -ProjectPath $proj)
        $script:keys.Enqueue('advanced')
        Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
        $na = $script:newArgs
        if ($na -and $na['Advanced'] -and $na['NoPublishPrompt']) { Ok 'manual wizard (Advanced): the scaffold call gets -NoPublishPrompt too (the same common parameters)' } else { Bad "new args: $(if ($na) { ($na.Keys | Sort-Object) -join ',' })" }

        Reset-Run @(New-RR -Command 'Complete-Win32ToolkitManualApp' -ProjectPath $proj)
        $script:keys.Enqueue('finish')
        Show-Win32ToolkitAdvancedFinish -ProjectPath $proj -DoPackage 6>$null 3>$null
        $ca = $script:completeArgs
        if ($ca -and $ca['PackageIntune'] -and $ca.ContainsKey('NoPublishPrompt') -and $ca['NoPublishPrompt']) { Ok 'Advanced finish with Package: Complete-Win32ToolkitManualApp gets -NoPublishPrompt' } else { Bad "complete args: $(if ($ca) { ($ca.Keys | Sort-Object) -join ',' })" }

        Reset-Run @(New-RR -Command 'Complete-Win32ToolkitManualApp' -ProjectPath $proj)
        $script:keys.Enqueue('finish')
        $null = @(Show-Win32ToolkitProjectActions -BasePath $BASE 6>$null 3>$null)
        $ca = $script:completeArgs
        if ($ca -and $ca.ContainsKey('NoPublishPrompt') -and $ca['NoPublishPrompt']) { Ok 'Project actions > Finalize / refresh: Complete-Win32ToolkitManualApp gets -NoPublishPrompt (uniform)' } else { Bad "complete args: $(if ($ca) { ($ca.Keys | Sort-Object) -join ',' })" }
    }
    finally { $script:multi = @() }

    # == [9] the manual wizard keeps its scaffold result, warnings and chosen actions (TUI audit G6) =========
    Write-Host '[9] the manual wizard keeps the scaffold result, its warnings and the chosen actions' -ForegroundColor Cyan
    $rebuilt = Get-SpectreEscapedText -Text (Join-Path $tplDir ('{0}_x64_1.0' -f (Sanitize-ProjectName -Name 'Tool[1]')))   # what the wizard computes from the answers (escaped as shown)
    $scaffolded = Join-Path $tplDir 'Tool_1_x64_1.0_scaffolded'   # what the scaffold says it created (must win)
    $yourTurn = { @($script:panels | Where-Object { $_.Header -like 'Advanced app ? your turn' }) }   # ASCII only: '?' is the em dash

    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Scaffolded -Mode 'Advanced' -ProjectPath $scaffolded)
    $script:newWarnings = @('Deploy-script patching did not complete cleanly [x]', 'MSIX uninstall data could not be written')
    $script:keys.Enqueue('advanced')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    $wp = @($script:panels | Where-Object { $_.Header -eq 'Check these warnings' })
    $wantW = "Scaffolding Tool[[1]] printed 2 warning(s):`n- Deploy-script patching did not complete cleanly [[x]]`n- MSIX uninstall data could not be written`n`nRead them before you write the install code."
    if ($wp.Count -eq 1 -and $wp[0].Color -eq 'Yellow' -and $wp[0].Data -ceq $wantW) { Ok 'Advanced + two scaffold warnings -> one yellow "Check these warnings" panel listing both (escaped)' } else { Bad "warning panels: $($wp | ConvertTo-Json -Compress)" }
    $yt = & $yourTurn
    if ($yt.Count -ge 1 -and $yt[0].Data.Contains("[blue]$scaffolded[/]") -and -not $yt[0].Data.Contains("[blue]$rebuilt[/]")) { Ok "the Advanced step gets the result's ProjectPath, not a path rebuilt from the answers" } else { Bad "your-turn panels: $($yt | ConvertTo-Json -Compress)" }
    if (@($script:panels).IndexOf($wp[0]) -lt @($script:panels).IndexOf($yt[0])) { Ok 'the warnings come before the Advanced step (which clears the screen)' } else { Bad 'the warnings panel is not before the Advanced step' }

    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Scaffolded -Mode 'Advanced' -ProjectPath $scaffolded)
    $script:keys.Enqueue('advanced')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    if (-not @($script:panels | Where-Object { $_.Header -eq 'Check these warnings' }).Count -and (& $yourTurn).Count -ge 1) { Ok 'Advanced without warnings -> no warnings panel, straight to the Advanced step' } else { Bad "panels: $(@($script:panels | ForEach-Object Header) -join ', ')" }

    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Failed -Problems 'Name, Version, and SourcePath are required.', 'boom [y]' -ProjectPath $scaffolded)
    $script:keys.Enqueue('advanced')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    $wantF = "The project was not scaffolded:`n- Name, Version, and SourcePath are required.`n- boom [[y]]`n`nReview the messages above for details."
    if ($p.Header -eq 'Scaffold failed' -and $p.Color -eq 'Red' -and $p.Data -ceq $wantF -and (& $yourTurn).Count -eq 0) { Ok 'Advanced + a Status Failed result -> red "Scaffold failed" with each problem; the Advanced step is not shown' } else { Bad "panel: $($p | ConvertTo-Json -Compress) your-turn=$((& $yourTurn).Count)" }

    # A Failed result whose ProjectPath this run left marked not configured (a non-W32T error after the scaffold):
    # the panel, then the two yellow kept-and-marked lines naming that folder (TUI audit G4 + G6).
    & $resetMarkers
    $keptProj = Join-Path $tplDir 'Tool_1_x64_1.0'
    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Failed -Problems 'boom' -ProjectPath $keptProj)
    $script:beforeRun = { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $keptProj -Stage Configure -Reason 'boom' }
    $script:keys.Enqueue('advanced')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    $sf = @($script:panels | Where-Object { $_.Header -eq 'Scaffold failed' })
    $keptLine = "[yellow]The project folder was kept and marked not configured: $keptProj[/]"
    $y = @($script:hostLines | Where-Object { $_ -like '`[yellow`]*kept and marked*' })
    if ($sf.Count -eq 1 -and $sf[0].Data -ceq "The project was not scaffolded:`n- boom`n`nReview the messages above for details." -and $y.Count -eq 1 -and $y[0] -ceq $keptLine -and $script:hostLines -ccontains "[yellow]$line2[/]" -and (& $yourTurn).Count -eq 0) {
        Ok 'Advanced + a Failed result with a freshly marked ProjectPath -> "Scaffold failed", then the yellow kept-and-marked lines; the Advanced step is not shown'
    } else { Bad "kept: panels=$($sf | ConvertTo-Json -Compress) lines=$($script:hostLines -join ' | ') your-turn=$((& $yourTurn).Count)" }
    & $resetMarkers

    Reset-Run @('stray')
    $script:keys.Enqueue('advanced')
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    $p = LastPanel
    if ($p.Header -eq 'Scaffold failed' -and $p.Data -ceq "The project was not scaffolded:`n- New-Win32ToolkitManualApp returned no result.`n`nReview the messages above for details." -and (& $yourTurn).Count -eq 0) { Ok 'Advanced + no result object -> "Scaffold failed: New-Win32ToolkitManualApp returned no result."' } else { Bad "panel: $($p | ConvertTo-Json -Compress)" }

    # Easy + an EXE + blank switches: New-Win32ToolkitManualApp sets it up as an Advanced app (Mode Advanced).
    $script:multi = @('Run an install*', 'Package*', 'Publish*'); $script:confirmPublish = $true; $script:silentSwitch = ''
    try {
        Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Scaffolded -Mode 'Advanced' -ProjectPath $scaffolded) $null
        $script:keys.Enqueue('easy'); $script:keys.Enqueue('finish')
        $script:completeOutput = @(New-RR -Command 'Complete-Win32ToolkitManualApp' -ProjectPath $scaffolded)
        Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
        $review = @($script:panels | Where-Object { $_.Header -eq 'Review' }) | Select-Object -First 1
        if ($review -and $review.Data.Contains('Mode         : Advanced (an EXE with no silent switch: you write the install logic)')) { Ok "Easy + .exe + blank switches -> the Review panel says 'Mode         : Advanced (an EXE with no silent switch: ...)'" } else { Bad "review: $($review | ConvertTo-Json -Compress)" }
        $ap = @($script:panels | Where-Object { $_.Header -eq 'Advanced app' })
        $wantA = 'No silent switch was given for this EXE, so Tool[[1]] was set up as an Advanced app: write the install code yourself, then choose Finish setup. Your test, package and publish choices are kept.'
        if ($ap.Count -eq 1 -and $ap[0].Color -eq 'Yellow' -and $ap[0].Data -ceq $wantA -and -not @($script:panels | Where-Object { $_.Header -eq 'Scaffolded' }).Count) { Ok 'a Mode Advanced result -> the yellow "Advanced app" panel (not "Scaffolded")' } else { Bad "panels: $($script:panels | ConvertTo-Json -Compress)" }
        $ca = $script:completeArgs
        if ((& $yourTurn).Count -ge 1 -and (& $yourTurn)[0].Data.Contains("[blue]$scaffolded[/]") -and $ca -and $ca['ProjectPath'] -eq $scaffolded -and $ca['RunTest'] -eq 'InstallUninstall' -and $ca['PackageIntune'] -and $ca['PublishIntune']) {
            Ok 'then the Advanced step on that project, and Finish setup keeps the ticked test, package and publish'
        } else { Bad "your-turn=$((& $yourTurn).Count) complete args: $(if ($ca) { ($ca.Keys | Sort-Object | ForEach-Object { "$_=$($ca[$_])" }) -join '; ' })" }
        if (@($script:textPrompts) -ccontains 'Silent-install switch(es) (e.g. /S, or /qn /norestart). Blank for an MSI or MSIX; an EXE without a switch becomes an Advanced app') { Ok 'the silent-switch prompt says an EXE without a switch becomes an Advanced app' } else { Bad "prompts: $($script:textPrompts -join ' | ')" }
    }
    finally { $script:multi = @(); $script:confirmPublish = $false; $script:silentSwitch = '/S' }

    # The Review row for blank switches by the installer's extension (a folder: the installer is not known yet).
    $script:silentSwitch = ''
    try {
        foreach ($case in @(@('tool.msi', 'Easy (MSI / Zero-Config)'), @('tool.msix', 'Easy (MSIX / APPX package)'), @('tool.appx', 'Easy (MSIX / APPX package)'),
                @('', 'Easy if the installer is an MSI or MSIX; an EXE without a switch becomes Advanced'))) {
            $script:manualSource = if ($case[0]) { Join-Path $BASE "src\$($case[0])" } else { Join-Path $BASE 'src' }
            if ($case[0]) { Set-Content -LiteralPath $script:manualSource 'x' }
            Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp')
            $script:keys.Enqueue('easy')
            Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
            $review = @($script:panels | Where-Object { $_.Header -eq 'Review' }) | Select-Object -First 1
            $what = if ($case[0]) { $case[0] } else { 'a folder' }
            if ($review -and $review.Data.Contains("Mode         : $($case[1])")) { Ok "blank switches + $what -> 'Mode         : $($case[1])'" } else { Bad "${what}: review $($review | ConvertTo-Json -Compress)" }
        }
    }
    finally { $script:silentSwitch = '/S'; $script:manualSource = Join-Path $BASE 'src\tool.exe' }

    # == [10] the wizards leave the project they build out of the dependency picker (TUI audit G9) ===========
    Write-Host '[10] the wizards pass the project they build as -ExcludeProject to the dependency picker' -ForegroundColor Cyan
    $script:confirmDeps = $true
    try {
        Reset-Run @(New-RR); $script:pickerArgs = $null
        Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
        $wantW = 'Contoso\{0}_x64_2.55.0' -f (Sanitize-ProjectName -Name 'Git[x]')
        if ($script:pickerArgs -and (@($script:pickerArgs['ExcludeProject']) -join '|') -ceq $wantW) { Ok "winget wizard -> -ExcludeProject '$wantW' (the template folder and the project it builds)" } else { Bad "picker args: $(if ($script:pickerArgs) { ($script:pickerArgs.Keys | ForEach-Object { "$_=$($script:pickerArgs[$_])" }) -join '; ' })" }

        Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp'); $script:pickerArgs = $null
        $script:keys.Enqueue('easy')
        Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
        $wantM = 'Contoso\{0}_x64_1.0' -f (Sanitize-ProjectName -Name 'Tool[1]')
        if ($script:pickerArgs -and (@($script:pickerArgs['ExcludeProject']) -join '|') -ceq $wantM) { Ok "manual wizard -> -ExcludeProject '$wantM'" } else { Bad "picker args: $(if ($script:pickerArgs) { ($script:pickerArgs.Keys | ForEach-Object { "$_=$($script:pickerArgs[$_])" }) -join '; ' })" }
    }
    finally { $script:confirmDeps = $false }

    # == [11] Advanced finish stays on its screen after a refusal (TUI audit G11) =============================
    Write-Host '[11] Advanced finish: W32T.PackageNotReady -> "Not ready to finish", the screen again, the choices kept' -ForegroundColor Cyan
    Reset-Run @(New-RR -Command 'Complete-Win32ToolkitManualApp' -ProjectPath $proj)
    $script:completeCalls = 0
    $script:throwOnce = & $w32tErr 'W32T.PackageNotReady' "The package is not ready:`n- Invoke-AppDeployToolkit.ps1 does not parse [x]" $proj
    $script:keys.Enqueue('finish'); $script:keys.Enqueue('finish')
    $threw = $null
    try { Show-Win32ToolkitAdvancedFinish -ProjectPath $proj -DoTest -DoPackage 6>$null 3>$null } catch { $threw = $_ }
    $nr = @($script:panels | Where-Object { $_.Header -eq 'Not ready to finish' })
    $wantNr = "[red]The package is not ready:`n- Invoke-AppDeployToolkit.ps1 does not parse [[x]][/]`n`nFix the deploy script (Open Invoke-AppDeployToolkit.ps1 in Notepad), then choose Finish setup again: your test, package and publish choices are kept."
    if (-not $threw -and $nr.Count -eq 1 -and $nr[0].Color -eq 'Red' -and $nr[0].Data -ceq $wantNr) { Ok 'the refusal -> one red "Not ready to finish" panel (escaped) with the fix' } else { Bad "threw=$threw panels: $($script:panels | ConvertTo-Json -Compress)" }
    $yt = @($script:panels | Where-Object { $_.Header -like 'Advanced app ? your turn' })
    $ca = $script:completeArgs
    if ($yt.Count -eq 2 -and $script:completeCalls -eq 2 -and (LastPanel).Header -eq 'Done' -and $ca['RunTest'] -eq 'InstallUninstall' -and $ca['PackageIntune']) {
        Ok 'the screen comes back; Finish setup again (same test and package choices) succeeds and shows the result panel; then the screen ends'
    } else { Bad "your-turn=$($yt.Count) completeCalls=$script:completeCalls last=$((LastPanel).Header) args=$(if ($ca) { ($ca.Keys | Sort-Object) -join ',' })" }

    Reset-Run @() (& $w32tErr 'W32T.Other' 'something else' $proj)
    $script:completeCalls = 0
    $script:keys.Enqueue('finish')
    Show-Win32ToolkitAdvancedFinish -ProjectPath $proj 6>$null 3>$null
    if ($script:completeCalls -eq 1 -and (LastPanel).Header -eq 'Something went wrong' -and @($script:panels | Where-Object { $_.Header -like 'Advanced app ? your turn' }).Count -eq 1) { Ok 'any other error -> "Something went wrong" and the screen ends as before' } else { Bad "calls=$script:completeCalls panels: $(@($script:panels | ForEach-Object Header) -join ', ')" }

    # == [12] blank problems and warnings never reach Get-SpectreEscapedText (it refuses an empty string) =====
    Write-Host '[12] the scaffold panels skip blank problems and warnings (faithful Get-SpectreEscapedText)' -ForegroundColor Cyan
    $script:threw12 = $null
    $faithful = {
        param([scriptblock]$Run)
        function Get-SpectreEscapedText { param([Parameter(Mandatory)][string]$Text) $Text.Replace('[', '[[').Replace(']', ']]') }
        try { & $Run } catch { $script:threw12 = $_ }
    }
    Reset-Run @(New-RR -Command 'New-Win32ToolkitManualApp' -Scaffolded -Mode 'Advanced' -ProjectPath $scaffolded)
    $script:newWarnings = @('', 'real warning')
    $script:keys.Enqueue('advanced')
    & $faithful { Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null }
    $wp = @($script:panels | Where-Object { $_.Header -eq 'Check these warnings' })
    if (-not $script:threw12 -and $wp.Count -eq 1 -and $wp[0].Data -ceq "Scaffolding Tool[[1]] printed 1 warning(s):`n- real warning`n`nRead them before you write the install code.") { Ok 'a blank warning is skipped (no throw); the panel counts and lists the real one' } else { Bad "threw=$($script:threw12) panels: $($wp | ConvertTo-Json -Compress)" }

    $script:threw12 = $null
    # Hand-built (Complete-Win32ToolkitRunResult drops blank problems itself): a result from anywhere else may carry one.
    $blankRR = [pscustomobject]@{ Command = 'New-Win32ToolkitManualApp'; ProjectPath = $scaffolded; ProjectName = 'x'; Mode = ''; Status = 'Failed'; Capture = 'NotRun'
                                  Tests = @(); IntuneWinPath = ''; Published = @(); Problems = [string[]]@('', 'real problem') }
    $blankRR.PSObject.TypeNames.Insert(0, 'Win32Toolkit.RunResult')
    Reset-Run @($blankRR)
    $script:keys.Enqueue('advanced')
    & $faithful { Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null }
    $p = LastPanel
    if (-not $script:threw12 -and $p.Header -eq 'Scaffold failed' -and $p.Data -ceq "The project was not scaffolded:`n- real problem`n`nReview the messages above for details.") { Ok 'a blank problem is skipped (no throw); the real one is listed' } else { Bad "threw=$($script:threw12) panel: $($p | ConvertTo-Json -Compress)" }
}
finally {
    Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TuiWizardResult tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail TuiWizardResult test(s) FAILED." -ForegroundColor Red
exit 1
