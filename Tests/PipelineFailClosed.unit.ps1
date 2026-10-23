<#
    Orchestration fail-closed tests (spec 2.0 C-1/C-2, 3.2 tasks 5, 9-12).

    A configuration that did not succeed must STOP the pipeline: nothing is documented, tested, packaged
    or published. Fatal errors carry a W32T.* FullyQualifiedErrorId and reach scripted callers as
    terminating errors; any other error keeps today's Write-Error behaviour.

      * Invoke-Win32Toolkit: Create-PSADTProject -> $false => W32T.ProjectCreationFailed;
        Configure-PSADTForInstaller -> $false => W32T.PipelineAborted; a W32T error from Configure
        propagates unchanged; Finalize never runs in any of these; a plain error -> Write-Error.
      * New-Win32ToolkitManualApp: same for Create / Apply-OrgTemplate / the generator.
      * Complete-Win32ToolkitManualApp + the real Invoke-Win32ToolkitFinalize: the Finalize pre-flight
        (Assert-Win32ToolkitPackageReady) runs FIRST, its W32T.PackageNotReady propagates, and
        -AllowLegacyScript reaches both the Assert and Export-Win32ToolkitIntuneWin; a relative
        -ProjectPath reaches the Assert as an absolute path.
      * Configure-PSADTForInstaller: W32T errors propagate; Apply-OrgTemplate -> $false => $false.
      * Installer technology (installer-identity PR 1, spec 3.4): the pin is resolved before the download
        and reaches it and Configure (AppConfig.Source); the identity checks run after the icon step with
        the template tenant; -UpdateBaselineInstallerType reaches Finalize only when bound; a
        W32T.InstallerVariantUnavailable from the download passes Invoke unchanged and nothing downstream runs.
        A rebuild reads the project's own anchor (Get-Win32ToolkitSelfAnchor) BEFORE Create-PSADTProject removes
        the old folder, passes it as -SelfAnchor, and keeps the old Intune\Publications.json.

    Everything downstream is shadowed: no winget, no PSADT, no sandbox, no Intune.

    Run:  pwsh -File Tests\PipelineFailClosed.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
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

. (Join-Path $repo 'Private\Sanitize-ProjectName.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Add-Win32ToolkitInstallerFiles.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitFinalize.ps1')
. (Join-Path $repo 'Private\Configure-PSADTForInstaller.ps1')
# C-9: the -DependsOn pre-flight of Invoke-Win32Toolkit / New-Win32ToolkitManualApp (B3 r2.1; real, pure).
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Assert-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Initialize-Win32ToolkitRunResult.ps1')   # C-9: the result object (TUI audit G2, S8-F3)
. (Join-Path $repo 'Private\Complete-Win32ToolkitRunResult.ps1')
# C-9 (TUI audit G4): every error after the scaffold, before the end of the configure step, marks the project (temp folders).
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Write-Win32ToolkitNotConfiguredMarker.ps1')
. (Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1')
. (Join-Path $repo 'Public\New-Win32ToolkitManualApp.ps1')
. (Join-Path $repo 'Public\Complete-Win32ToolkitManualApp.ps1')

$BASE = Join-Path ([System.IO.Path]::GetTempPath()) ('w32pf_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $BASE -Force | Out-Null

function New-W32TError([string]$Id, [string]$Message) {
    [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message), $Id, [System.Management.Automation.ErrorCategory]::InvalidData, $null)
}

# -- shadows (behaviour switched per case through $script:Mode) -----------------------------------
$script:Mode = @{}
$script:Calls = [System.Collections.Generic.List[string]]::new()
function Reset-Case([hashtable]$Mode) { $script:Mode = $Mode; $script:Calls.Clear() }

function Test-WingetInstalled { $true }
# Counters (not in $script:Calls, whose exact sequences other cases pin): the -DependsOn pre-flight runs before them.
$script:BaseCalls = 0; $script:ResolveCalls = 0; $script:SetDepSeen = $null
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure) $script:BaseCalls++; $BASE }
function Get-OrgTemplate {
    param($TemplateName, $BasePath)
    $name = if ($script:Mode.TemplateName) { $script:Mode.TemplateName } else { 'Contoso' }
    $t = [pscustomobject]@{ TemplateName = $name; AppScriptAuthor = 'IT' }
    if ($script:Mode.TenantId) { $t | Add-Member -NotePropertyName TenantId -NotePropertyValue $script:Mode.TenantId }
    $t
}
function Resolve-Win32ToolkitWingetId { param($Id) $script:ResolveCalls++; if ($script:Mode.ResolveNull) { return $null }; [pscustomobject]@{ Name = 'Git'; Id = $Id; Version = '2.45.0'; Source = 'winget' } }
function Search-WingetApps { param($SearchTerm) @() }
$script:DetailsCalls = 0
function Get-WingetAppDetails { param($AppId) $script:DetailsCalls++; if ($script:Mode.DetailsThrows) { throw 'winget exploded' }; @('x64') }
function Select-Architecture { param($Architectures, $AppName, $PreSelected) 'x64' }
function Get-Win32ToolkitPaths {
    param($BasePath)
    [pscustomobject]@{ Templates = Join-Path $BASE 'Templates'; Projects = Join-Path $BASE 'Projects'; Staging = Join-Path $BASE 'Staging'; IntuneWin = Join-Path $BASE 'IntuneWin' }
}
function Create-PSADTProject {
    param($ProjectName, $ProjectPath, [switch]$Force)
    $script:Calls.Add('create')
    if ($script:Mode.CreateFails) { return $false }
    $full = Join-Path $ProjectPath $ProjectName
    # -Force re-creation, as the real one: the old project folder is removed first.
    if ($script:Mode.Recreate -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $full -Recurse -Force }
    foreach ($d in 'Files', 'SupportFiles') { New-Item -ItemType Directory -Path (Join-Path $full $d) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $full 'Invoke-AppDeployToolkit.ps1') -Value '# scaffold'
    return $true
}
# Installer technology (installer-identity PR 1, C-9): shadows mirror the real contracts.
$script:PinSeen = $null; $script:DlSeen = $null; $script:SourceSeen = $null; $script:IdentitySeen = $null; $script:IdentityAt = $null
# The rebuild self-anchor is read BEFORE Create-PSADTProject removes the old folder (it records the calls made so far).
$script:SelfSeen = $null; $script:SelfAt = $null
function Get-Win32ToolkitSelfAnchor {
    param($ProjectPath, $TenantId)
    $script:SelfSeen = $PSBoundParameters; $script:SelfAt = @($script:Calls)
    $script:SelfFolderExisted = Test-Path -LiteralPath (Join-Path $ProjectPath 'SupportFiles')
    $script:Mode.SelfAnchor
}
function Resolve-Win32ToolkitInstallerPin {
    param($TemplateDirectory, $WingetId, $Version, $InstallerType, $ExcludePath, $TenantId, $SelfAnchor)
    $script:PinSeen = $PSBoundParameters
    [pscustomobject]@{
        InstallerType = [string]$InstallerType; Family = ''; Predecessor = $null; WingetClient = '1.29.380'
        PinnedBy      = if ($InstallerType) { 'parameter' } else { 'winget-default' }
        Reason        = if ($InstallerType) { 'requested' } else { "winget's choice" }
    }
}
function Get-Win32ToolkitProjectSource {
    param($ProjectPath, [switch]$Rebuild, $Architecture, $PinnedBy, $RequestedInstallerType, $WingetClient)
    $script:SourceSeen = $PSBoundParameters
    [pscustomobject]@{ SchemaVersion = '1.0'; PinnedBy = $PinnedBy; RequestedInstallerType = $RequestedInstallerType; WingetClient = $WingetClient }
}
function Write-Win32ToolkitIdentityDelta {
    param($ProjectPath, $TenantId, [switch]$Quiet)
    $script:IdentitySeen = $PSBoundParameters; $script:IdentityAt = @($script:Calls)
}
function Download-WingetApp {
    param($AppId, $AppName, $DownloadPath, $Architecture, $InstallerType, $PinnedBy, $PinReason)
    $script:Calls.Add('download'); $script:DlSeen = $PSBoundParameters
    if ($script:Mode.DownloadUnavailable) {
        throw (New-W32TError 'W32T.InstallerVariantUnavailable' "winget offers no vendor EXE installer for $AppId (x64); tried: nullsoft, burn, inno, exe. Nothing was downloaded.")
    }
    Set-Content (Join-Path $DownloadPath 'setup.exe') 'x'; $true
}
function Rename-InstallerFile { param($FilesPath, $AppName, $Version, $Architecture) }
function Get-AppIconFromWinget {
    param($ProjectPath, $FilesPath)
    $script:Calls.Add('icon')
    if ($script:Mode.IconWarns) { Write-Warning 'No WinGet IconUrl found in YAML (test shadow)' }
    if ($script:Mode.IconThrows) { throw (New-W32TError 'W32T.Test' 'icon step failed after the configure step') }
    $true
}
function Set-Win32ToolkitAppDependency { param($ProjectPath, $DependsOn, $DependencyType) $script:SetDepSeen = $PSBoundParameters }
function Get-YAMLInstallerInfo { param($FilesPath) $null }
function New-Win32ToolkitIntuneDefaults { param($Template) $null }
function Update-PSADTMsixUninstallLogic { param($ProjectPath) $true }
function Update-PSADTMsixProcessesToClose { param($ProjectPath) $true }
function Set-Win32ToolkitIconSource { param($ProjectPath, $Source) }
function Set-PSADTDataDrivenScript {
    param($ScriptPath, [switch]$ManualInstall)
    $script:Calls.Add('generate')
    if ($script:Mode.GeneratorThrows) { throw (New-W32TError 'W32T.UnsupportedTemplateShape' 'Unsupported PSADT template shape: x; shape Psadt42Default; DeployAppScriptVersion 4.2.0; supported: 4.1.x and 4.2.x. hint Nothing was changed.') }
    if ($script:Mode.GeneratorPlainThrows) { throw 'plain generator failure' }
    if ($script:Mode.GeneratorFalse) { Write-Warning 'Data-driven patch anchor not found: AppScriptDate'; return $false }
    return $true
}
function Apply-OrgTemplate { param($ProjectPath, $Template, $BasePath) $script:Calls.Add('apply'); $script:ApplyBase = $BasePath; return (-not $script:Mode.ApplyFails) }
function Assert-Win32ToolkitPackageReady {
    param($ProjectPath, $Stage, [switch]$AllowLegacyScript)
    $script:Calls.Add("assert:${Stage}:$([bool]$AllowLegacyScript)")
    $script:AssertPath = $ProjectPath
    if ($script:Mode.AssertFails) { throw (New-W32TError 'W32T.PackageNotReady' "The package is not ready:`n- Unsupported PSADT template shape: x") }
    [pscustomobject]@{ Ready = $true; Shape = 'Psadt41'; VersionText = '4.1.8'; Warnings = @() }
}
function Get-Win32ToolkitTestBackend { if ($script:Mode.BackendThrows) { throw 'backend exploded' }; 'Sandbox' }
# The capture: $false (did not complete) unless the case sets CapturePath, the expected-JSON path a completed capture
# returns; Wait-ForDocumentationAndProcess (C-9) then processes it per CaptureProcessed (default $true).
function New-TargetedDocumentation {
    param($ProjectPath, $ProjectName, $AppInfo, $Backend, $BasePath)
    $script:Calls.Add('document'); $script:DocBase = $BasePath
    if ($script:Mode.CapturePath) { return $script:Mode.CapturePath }
    return $false
}
function Invoke-Win32ToolkitHyperVRun { param($ProjectPath, $Phase, $Output) $true }
$script:WaitSeen = $null
function Wait-ForDocumentationAndProcess {
    param($ProjectPath, $InstallerType, $ExpectedJsonPath)
    $script:Calls.Add('process'); $script:WaitSeen = $PSBoundParameters
    if ($script:Mode.ContainsKey('CaptureProcessed')) { return [bool]$script:Mode.CaptureProcessed }
    $true
}
function Import-Win32ToolkitCapturedIcon { param($ProjectPath) }
# C-9: the capture run-log helpers Finalize calls (test campaign 2026-10-21, H5-F5/H7-F1); no disk writes.
function Initialize-Win32ToolkitTestRunLog { param($ProjectPath, $Scenario, $Family) $null }
function Save-Win32ToolkitTestRunLog { param($Run) $null }
function Wait-Win32ToolkitCollectedLog { param($ProjectPath, $TimeoutSeconds) $true }
function Test-Win32ToolkitProject {
    param($ProjectPath, $Scenario, $SpecificVersion, $VersionsBack, $BasePath)
    $script:Calls.Add('test')
    if ($script:Mode.ContainsKey('TestVerdict')) { return $script:Mode.TestVerdict }
    $true
}
# A failed verdict names the run's own log folder (Finalize); none here -> the flat Sandbox\Logs fallback.
function Get-Win32ToolkitTestRunLogFolder { param($ProjectPath, $Scenario, $SinceUtc) }
function Export-Win32ToolkitIntuneWin {
    param($ProjectPath, [switch]$PublishIntune, [switch]$PublishUpdate, [switch]$AllowLegacyScript, [switch]$NoPublishPrompt, [switch]$PassThru)
    $script:Calls.Add("export:$([bool]$AllowLegacyScript)")
    $script:ExportPassThru = [bool]$PassThru
    # TUI audit G5: bound only when the caller passed -NoPublishPrompt ($null = not called).
    $script:ExportNoPrompt = if ($PSBoundParameters.ContainsKey('NoPublishPrompt')) { [bool]$NoPublishPrompt } else { 'unbound' }
    if ($script:Mode.ExportThrows) { throw $script:Mode.ExportThrows }
    if ($PassThru) {
        if ($script:Mode.ExportSummary) { return $script:Mode.ExportSummary }
        [pscustomobject]@{ IntuneWinPath = ''; Published = @(); Problems = @() }
    }
}

# Runs an action; returns @{ Fqid; Message; Errors (non-terminating) }.
function Invoke-Case([scriptblock]$Action) {
    # Dot-sourced so the action's '-ErrorVariable ev' lands in this scope.
    $ev = $null
    try { $null = . $Action 3>$null 6>$null; [pscustomobject]@{ Fqid = ''; Message = ''; Errors = @($ev) } }
    catch { [pscustomobject]@{ Fqid = $_.FullyQualifiedErrorId; Message = $_.Exception.Message; Errors = @($ev) } }
}
$downstream = { param($c) @($c | Where-Object { $_ -like 'assert:*' -or $_ -in 'document', 'test' -or $_ -like 'export:*' }) }

# == Invoke-Win32Toolkit ===========================================================================
Write-Host '[1] Invoke-Win32Toolkit fails closed' -ForegroundColor Cyan
$runInvoke = { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune -PublishIntune -ErrorAction SilentlyContinue -ErrorVariable ev }

Reset-Case @{ CreateFails = $true }
$script:OrgTemplate = $null
$r = Invoke-Case $runInvoke
if ($r.Fqid -eq 'W32T.ProjectCreationFailed' -and 'download' -notin $script:Calls -and (& $downstream $script:Calls).Count -eq 0) { Ok 'Create-PSADTProject $false -> W32T.ProjectCreationFailed; no download, no finalize' } else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }
if ($null -eq $script:OrgTemplate) { Ok '$script:OrgTemplate is still cleared by the finally' } else { Bad 'org template leaked' }

Reset-Case @{ ApplyFails = $true }
$r = Invoke-Case $runInvoke
if ($r.Fqid -eq 'W32T.PipelineAborted' -and $r.Message -match 'NOT documented, tested, packaged or published' -and (& $downstream $script:Calls).Count -eq 0) {
    Ok 'Configure-PSADTForInstaller $false (org template not applied) -> W32T.PipelineAborted; Finalize never called'
} else { Bad "fqid='$($r.Fqid)' $($r.Message) calls=[$($script:Calls -join ',')]" }

Reset-Case @{ GeneratorThrows = $true }
$r = Invoke-Case $runInvoke
if ($r.Fqid -eq 'W32T.UnsupportedTemplateShape' -and $r.Message.StartsWith('Unsupported PSADT template shape: ') -and (& $downstream $script:Calls).Count -eq 0 -and 'apply' -notin $script:Calls) {
    Ok 'a W32T error from the generator propagates unchanged through Configure and Invoke; nothing downstream ran'
} else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }

# Without -Architecture (the architecture lookup only runs then; Select-Architecture is shadowed to 'x64').
Reset-Case @{ DetailsThrows = $true }
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Force -PackageIntune -PublishIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
if (-not $r.Fqid -and ($r.Errors | ForEach-Object { "$_" }) -match 'Script execution failed: winget exploded') { Ok 'a non-W32T error keeps the Write-Error behaviour (non-terminating)' } else { Bad "fqid='$($r.Fqid)' errors=[$($r.Errors -join '; ')]" }

# -Architecture x64 needs no 'winget show' scrape (it only produced a misleading warning; test campaign 2026-10-21).
Reset-Case @{}
$script:DetailsCalls = 0
$null = Invoke-Case $runInvoke
$withArch = $script:DetailsCalls -gt 0
Reset-Case @{}
$script:DetailsCalls = 0
$null = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Force -PackageIntune -PublishIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
$withoutArch = $script:DetailsCalls -gt 0
if (-not $withArch -and $withoutArch) { Ok '-Architecture x64 skips the architecture lookup (Get-WingetAppDetails); without it the lookup runs' } else { Bad "details called: with -Architecture=$withArch, without=$withoutArch" }

Reset-Case @{ GeneratorFalse = $true }
$r = Invoke-Case $runInvoke
$c = @($script:Calls)
if (-not $r.Fqid -and ($c -join ',') -match 'generate,apply,icon,assert:Finalize:False,document,export:False') { Ok 'non-critical generator warnings ($false) still configure; Finalize (pre-flight first) and packaging run' } else { Bad "fqid='$($r.Fqid)' $($r.Message) calls=[$($c -join ',')]" }

# The icon step's warning reaches Invoke-Win32Toolkit -WarningVariable (re-verification 2026-10-21, B1 #2: the
# call was piped to Out-Null, and a warning from a command in a pipeline never reaches the caller's variable).
Reset-Case @{ IconWarns = $true }
$wv = $null
$null = Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -WarningVariable wv -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 6>$null
$iconW = @($wv | Where-Object { "$_" -like 'No WinGet IconUrl found in YAML*' })
if ('icon' -in $script:Calls -and $iconW.Count -eq 1) { Ok "the icon step's warning is in Invoke-Win32Toolkit -WarningVariable ($(@($wv).Count) warning(s))" } else { Bad "icon warnings in -WarningVariable: $($iconW.Count); all: [$(@($wv) -join ' | ')] calls=[$($script:Calls -join ',')]" }
if (@(Select-String -LiteralPath (Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1') -Pattern 'Get-AppIconFromWinget[^#]*\|\s*Out-Null').Count -eq 0) { Ok 'Invoke-Win32Toolkit never pipes Get-AppIconFromWinget to Out-Null' } else { Bad 'Get-AppIconFromWinget is piped to Out-Null' }

# == New-Win32ToolkitManualApp =====================================================================
Write-Host '[2] New-Win32ToolkitManualApp fails closed' -ForegroundColor Cyan
$src = Join-Path $BASE 'src'; New-Item -ItemType Directory -Path $src -Force | Out-Null; Set-Content (Join-Path $src 'tool.msi') 'x'
$runManual = { New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $src 'tool.msi') -TemplateName 'Contoso' -Force -Continue -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }

Reset-Case @{ CreateFails = $true }
$r = Invoke-Case $runManual
if ($r.Fqid -eq 'W32T.ProjectCreationFailed' -and (& $downstream $script:Calls).Count -eq 0) { Ok 'Create-PSADTProject $false -> W32T.ProjectCreationFailed' } else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }

Reset-Case @{ ApplyFails = $true }
$r = Invoke-Case $runManual
if ($r.Fqid -eq 'W32T.PipelineAborted' -and (& $downstream $script:Calls).Count -eq 0) { Ok 'Apply-OrgTemplate $false -> W32T.PipelineAborted; Finalize never called' } else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }

Reset-Case @{ GeneratorThrows = $true }
$r = Invoke-Case $runManual
if ($r.Fqid -eq 'W32T.UnsupportedTemplateShape' -and 'apply' -notin $script:Calls -and (& $downstream $script:Calls).Count -eq 0) { Ok 'a W32T generator error propagates; no org template, no Finalize' } else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }

# The manual app's base folder reaches the real Finalize and its capture (re-verification 2026-10-21, B3 #4).
Reset-Case @{}
$script:DocBase = $null
$r = Invoke-Case $runManual
if (-not $r.Fqid -and 'document' -in $script:Calls -and $script:DocBase -eq $BASE) { Ok 'New-Win32ToolkitManualApp -Continue passes its -BasePath through Finalize to the capture' } else { Bad "fqid='$($r.Fqid)' capture BasePath='$script:DocBase' calls=[$($script:Calls -join ',')]" }

Reset-Case @{ GeneratorFalse = $true }
$r = Invoke-Case $runManual
if (-not $r.Fqid -and 'apply' -in $script:Calls -and 'assert:Finalize:False' -in $script:Calls) { Ok 'generator warnings ($false) keep today''s warning and continue' } else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }

Reset-Case @{}
$r = Invoke-Case { New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $BASE 'nope.msi') -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
if (-not $r.Fqid -and ($r.Errors | ForEach-Object { "$_" }) -match 'New-Win32ToolkitManualApp failed: Source path not found') { Ok 'a non-W32T error keeps the Write-Error behaviour' } else { Bad "fqid='$($r.Fqid)' errors=[$($r.Errors -join '; ')]" }

# == Complete-Win32ToolkitManualApp + the real Finalize ============================================
Write-Host '[3] Complete-Win32ToolkitManualApp: the Finalize pre-flight runs first and propagates' -ForegroundColor Cyan
$proj = Join-Path $BASE 'Projects\Contoso\Tool_x64_1.0'
New-Item -ItemType Directory -Path (Join-Path $proj 'Files') -Force | Out-Null
Set-Content (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') '# x'
$runComplete = { Complete-Win32ToolkitManualApp -ProjectPath $proj -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }

Reset-Case @{ AssertFails = $true }
$r = Invoke-Case $runComplete
if ($r.Fqid -eq 'W32T.PackageNotReady' -and $r.Message -match 'Unsupported PSADT template shape: ' -and ($script:Calls -join ',') -eq 'assert:Finalize:False') { Ok 'W32T.PackageNotReady propagates; nothing documented, tested or packaged' } else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }

Reset-Case @{}
$r = Invoke-Case { Complete-Win32ToolkitManualApp -ProjectPath $proj -PackageIntune -AllowLegacyScript -ErrorAction SilentlyContinue -ErrorVariable ev }
if (-not $r.Fqid -and 'assert:Finalize:True' -in $script:Calls -and 'export:True' -in $script:Calls -and $script:Calls[0] -eq 'assert:Finalize:True') { Ok '-AllowLegacyScript reaches the Finalize pre-flight (first) and Export-Win32ToolkitIntuneWin' } else { Bad "fqid='$($r.Fqid)' calls=[$($script:Calls -join ',')]" }

Reset-Case @{ BackendThrows = $true }
$r = Invoke-Case $runComplete
if (-not $r.Fqid -and ($r.Errors | ForEach-Object { "$_" }) -match 'Complete-Win32ToolkitManualApp failed: backend exploded') { Ok 'a non-W32T error keeps the Write-Error behaviour' } else { Bad "fqid='$($r.Fqid)' errors=[$($r.Errors -join '; ')]" }

# A relative -ProjectPath reaches the helpers (which read files through .NET) as an absolute path.
Reset-Case @{}
$script:AssertPath = $null
Push-Location -LiteralPath (Join-Path $BASE 'Projects\Contoso')
try { $r = Invoke-Case { Complete-Win32ToolkitManualApp -ProjectPath '.\Tool_x64_1.0' -PackageIntune -AllowLegacyScript -ErrorAction SilentlyContinue -ErrorVariable ev } }
finally { Pop-Location }
if (-not $r.Fqid -and $script:AssertPath -eq $proj -and 'export:True' -in $script:Calls) { Ok "relative -ProjectPath '.\Tool_x64_1.0' reaches the Finalize pre-flight as the absolute project path" } else { Bad "fqid='$($r.Fqid)' assert path='$($script:AssertPath)' calls=[$($script:Calls -join ',')]" }

# == Configure-PSADTForInstaller ===================================================================
Write-Host '[4] Configure-PSADTForInstaller: W32T errors propagate; an unapplied org template is a failure' -ForegroundColor Cyan
$cp = Join-Path $BASE 'cfg'
New-Item -ItemType Directory -Path (Join-Path $cp 'Files') -Force | Out-Null
Set-Content (Join-Path $cp 'Files\setup.exe') 'x'; Set-Content (Join-Path $cp 'Invoke-AppDeployToolkit.ps1') '# x'
$script:OrgTemplate = [pscustomobject]@{ TemplateName = 'Contoso'; AppScriptAuthor = 'IT' }
$app = [pscustomobject]@{ Name = 'Tool'; Version = '1.0' }
function Invoke-Configure([hashtable]$Mode) {
    Reset-Case $Mode
    $wv = $null; $ret = $null
    try { $ret = Configure-PSADTForInstaller -ProjectPath $cp -AppInfo $app -Architecture x64 -WarningVariable wv -WarningAction SilentlyContinue 6>$null; [pscustomobject]@{ Ret = $ret; Fqid = ''; Warnings = @($wv) } }
    catch { [pscustomobject]@{ Ret = $null; Fqid = $_.FullyQualifiedErrorId; Warnings = @($wv) } }
}
$r = Invoke-Configure @{ GeneratorThrows = $true }
if ($r.Fqid -eq 'W32T.UnsupportedTemplateShape' -and 'apply' -notin $script:Calls) { Ok 'generator W32T error propagates (C-2); the org template is not applied' } else { Bad "ret=$($r.Ret) fqid='$($r.Fqid)'" }
$r = Invoke-Configure @{ ApplyFails = $true }
if ($r.Ret -eq $false -and ($r.Warnings -join ' ') -match 'NOT configured') { Ok 'Apply-OrgTemplate $false -> Configure returns $false with a warning' } else { Bad "ret=$($r.Ret) warnings=[$($r.Warnings -join '; ')]" }
$r = Invoke-Configure @{ GeneratorFalse = $true }
if ($r.Ret -eq $true -and ($r.Warnings -join ' ') -match 'completed with warnings') { Ok 'generator $false (non-critical) -> warning, still configured' } else { Bad "ret=$($r.Ret) warnings=[$($r.Warnings -join '; ')]" }
$r = Invoke-Configure @{ GeneratorPlainThrows = $true }
if ($r.Ret -eq $false -and ($r.Warnings -join ' ') -match 'Failed to configure PSADT: plain generator failure') { Ok 'a non-W32T error keeps today''s warning + $false' } else { Bad "ret=$($r.Ret) fqid='$($r.Fqid)'" }
$script:OrgTemplate = $null

# == Installer technology (installer-identity PR 1) ================================================
Write-Host '[5] Invoke-Win32Toolkit: installer pin, AppConfig.Source, identity checks, baseline technology, W32T.InstallerVariantUnavailable' -ForegroundColor Cyan
$projDir = Join-Path $BASE 'Projects\Contoso'
$newProj = Join-Path $projDir 'Git_x64_2.45.0'

Reset-Case @{}
$script:PinSeen = $null; $script:DlSeen = $null; $script:SourceSeen = $null; $script:IdentitySeen = $null; $script:IdentityAt = $null
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -InstallerType nullsoft -ErrorAction SilentlyContinue -ErrorVariable ev }
$ps = $script:PinSeen
if (-not $r.Fqid -and $ps -and $ps['TemplateDirectory'] -eq $projDir -and $ps['WingetId'] -eq 'Git.Git' -and $ps['Version'] -eq '2.45.0' -and $ps['InstallerType'] -eq 'nullsoft' -and
    $ps['ExcludePath'] -eq $newProj -and $ps['TenantId'] -eq '') {
    Ok 'the pin is resolved with the template folder, winget id, version, -InstallerType, the new project excluded and the tenant'
} else { Bad "fqid='$($r.Fqid)' pin args: $(if ($ps) { ($ps.Keys | ForEach-Object { "$_=$($ps[$_])" }) -join '; ' })" }
$ds = $script:DlSeen
if ($ds -and $ds['InstallerType'] -eq 'nullsoft' -and $ds['PinnedBy'] -eq 'parameter' -and $ds['PinReason'] -eq 'requested') { Ok '-InstallerType nullsoft reaches Download-WingetApp with PinnedBy/PinReason' } else { Bad "download args: $(if ($ds) { ($ds.Keys | ForEach-Object { "$_=$($ds[$_])" }) -join '; ' })" }
$ss = $script:SourceSeen
if ($ss -and $ss['Rebuild'] -and $ss['PinnedBy'] -eq 'parameter' -and $ss['RequestedInstallerType'] -eq 'nullsoft' -and $ss['WingetClient'] -eq '1.29.380') { Ok 'Configure gets the pin: AppConfig.Source built with PinnedBy parameter, RequestedInstallerType nullsoft, the winget client' } else { Bad "source args: $(if ($ss) { ($ss.Keys | ForEach-Object { "$_=$($ss[$_])" }) -join '; ' })" }
$cfgSrc = (Get-Win32ToolkitAppConfig -ProjectPath $newProj).Source
if ($cfgSrc -and $cfgSrc.PinnedBy -eq 'parameter') { Ok 'AppConfig.json carries the Source section' } else { Bad 'no Source in AppConfig.json' }
$is = $script:IdentitySeen
if ($is -and $is['ProjectPath'] -eq $newProj -and $is['TenantId'] -eq '' -and (@($script:IdentityAt) -join ',') -eq 'create,download,generate,apply,icon') { Ok 'the identity checks run once, after the icon step and before Finalize, for the new project' } else { Bad "identity args: $(if ($is) { ($is.Keys | ForEach-Object { "$_=$($is[$_])" }) -join '; ' }) calls before: [$(@($script:IdentityAt) -join ',')]" }
if (($script:Calls -join ',') -match 'icon,assert:Finalize:False,document') { Ok 'Finalize still runs after the identity checks (warnings never block)' } else { Bad "calls=[$($script:Calls -join ',')]" }

Reset-Case @{ TenantId = 'tenant-9' }
$script:PinSeen = $null; $script:IdentitySeen = $null; $script:DlSeen = $null
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
if (-not $r.Fqid -and $script:PinSeen['TenantId'] -eq 'tenant-9' -and $script:IdentitySeen['TenantId'] -eq 'tenant-9' -and $script:PinSeen['InstallerType'] -eq '' -and $script:DlSeen['InstallerType'] -eq '' -and $script:DlSeen['PinnedBy'] -eq 'winget-default') {
    Ok "the template tenant reaches the pin and the identity checks; no -InstallerType -> the download is unpinned ('')"
} else { Bad "fqid='$($r.Fqid)' pin tenant=$($script:PinSeen['TenantId']) identity tenant=$($script:IdentitySeen['TenantId']) dl type=[$($script:DlSeen['InstallerType'])]" }

# Rebuilding a version that is itself published or pinned: Create-PSADTProject removes the old folder, so the
# self-anchor is read BEFORE it and handed to the resolver, and the old Intune\Publications.json is kept.
$pubFile = Join-Path $newProj 'Intune\Publications.json'
New-Item -ItemType Directory -Path (Split-Path -Path $pubFile -Parent) -Force | Out-Null
$pubBytes = [System.Text.Encoding]::UTF8.GetBytes('[ { "TenantId": "tenant-9", "AppId": "11111111-2222-3333-4444-555555555555", "WingetId": "Git.Git" } ]')
[System.IO.File]::WriteAllBytes($pubFile, $pubBytes)
$selfGit = [pscustomobject]@{ Name = 'Git_x64_2.45.0'; Path = $newProj; InstallerType = 'inno'; Family = 'exe'; PinnedBy = 'winget-default'; Published = $true; Anchored = $true; AnchorReason = 'published' }
Reset-Case @{ TenantId = 'tenant-9'; Recreate = $true; SelfAnchor = $selfGit }
$script:SelfSeen = $null; $script:SelfAt = $null; $script:SelfFolderExisted = $false; $script:PinSeen = $null
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
$ss = $script:SelfSeen
if (-not $r.Fqid -and $ss -and $ss['ProjectPath'] -eq $newProj -and $ss['TenantId'] -eq 'tenant-9' -and 'create' -notin @($script:SelfAt) -and 'create' -in $script:Calls -and $script:SelfFolderExisted) {
    Ok 'the self-anchor is read for the project being rebuilt (template tenant) BEFORE Create-PSADTProject removes the old folder'
} else { Bad "fqid='$($r.Fqid)' self args: $(if ($ss) { ($ss.Keys | ForEach-Object { "$_=$($ss[$_])" }) -join '; ' }) calls before: [$(@($script:SelfAt) -join ',')] folder existed: $script:SelfFolderExisted" }
if ($script:PinSeen -and $script:PinSeen['SelfAnchor'] -and $script:PinSeen['SelfAnchor'].Name -eq 'Git_x64_2.45.0' -and $script:PinSeen['ExcludePath'] -eq $newProj) { Ok 'the resolver gets it as -SelfAnchor (next to the excluded project path)' } else { Bad "pin args: $(if ($script:PinSeen) { ($script:PinSeen.Keys | ForEach-Object { "$_=$($script:PinSeen[$_])" }) -join '; ' })" }
if ((Test-Path -LiteralPath $pubFile) -and [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pubFile)) -ceq [Convert]::ToBase64String($pubBytes)) { Ok 'Intune\Publications.json survives the re-creation byte for byte (the rebuilt version keeps anchoring later versions)' } else { Bad "Publications.json after the rebuild: exists=$(Test-Path -LiteralPath $pubFile)" }
Reset-Case @{}
$script:PinSeen = $null
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
if (-not $r.Fqid -and $script:PinSeen -and $script:PinSeen.ContainsKey('SelfAnchor') -and $null -eq $script:PinSeen['SelfAnchor']) { Ok 'no self-anchor -> the resolver gets -SelfAnchor $null (continuity from earlier versions as before)' } else { Bad "pin args: $(if ($script:PinSeen) { ($script:PinSeen.Keys | ForEach-Object { "$_=$($script:PinSeen[$_])" }) -join '; ' })" }

# -UpdateBaselineInstallerType reaches Finalize only when bound (Finalize shadowed in a child scope).
$finalizeRun = {
    param([hashtable]$Extra)
    function Invoke-Win32ToolkitFinalize {
        param($ProjectPath, $ProjectName, $AppInfo, $RunTest, $UpdateVersionsBack, $UpdateSpecificVersion, $UpdateBaselineInstallerType,
            [switch]$PackageIntune, [switch]$PublishIntune, [switch]$PublishUpdate, $BasePath, $Result)
        $script:FinalizeSeen = $PSBoundParameters
    }
    $script:FinalizeSeen = $null
    # Invoke-Win32Toolkit returns its result object (TUI audit G2): discard it, only the Finalize arguments count.
    $null = Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force @Extra 6>$null 3>$null
    $script:FinalizeSeen
}
Reset-Case @{}
$fs = & $finalizeRun @{ RunTest = @('Update'); UpdateVersionsBack = 1; UpdateBaselineInstallerType = 'Both' }
if ($fs -and $fs['UpdateBaselineInstallerType'] -eq 'Both' -and $fs['RunTest'] -eq 'Update' -and $fs['UpdateVersionsBack'] -eq 1) { Ok '-UpdateBaselineInstallerType Both reaches Invoke-Win32ToolkitFinalize' } else { Bad "finalize args: $(if ($fs) { ($fs.Keys | ForEach-Object { "$_=$($fs[$_])" }) -join '; ' })" }
$fs = & $finalizeRun @{ RunTest = @('Update') }
if ($fs -and -not $fs.ContainsKey('UpdateBaselineInstallerType')) { Ok 'not bound -> not passed (Finalize and Test keep their own default)' } else { Bad "finalize args: $(if ($fs) { ($fs.Keys | ForEach-Object { "$_=$($fs[$_])" }) -join '; ' })" }
# The run's base folder reaches Finalize (re-verification 2026-10-21, B3 #4): its capture and tests stage
# 'project:' dependencies from it, not from the registry base folder.
if ($fs -and $fs['BasePath'] -eq $BASE) { Ok 'Invoke-Win32Toolkit passes its resolved -BasePath to Invoke-Win32ToolkitFinalize' } else { Bad "finalize BasePath: '$(if ($fs) { $fs['BasePath'] })'" }
$fs = & $finalizeRun @{}
if (@($fs).Count -eq 1 -and $fs -is [System.Collections.IDictionary] -and $fs['Result'] -and $fs['Result'].Command -eq 'Invoke-Win32Toolkit') { Ok '$finalizeRun returns exactly the Finalize arguments (one dictionary), with the run-result collector as -Result' } else { Bad "finalizeRun returned $(@($fs).Count) object(s): $(@($fs) | ForEach-Object { $_.GetType().Name })" }

# W32T.InstallerVariantUnavailable from the download passes Invoke unchanged; nothing downstream runs.
Reset-Case @{ DownloadUnavailable = $true }
$script:IdentitySeen = $null
$script:OrgTemplate = [pscustomobject]@{ TemplateName = 'stale' }
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -InstallerType nullsoft -PackageIntune -PublishIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
if ($r.Fqid -eq 'W32T.InstallerVariantUnavailable' -and $r.Message.StartsWith('winget offers no vendor EXE installer for Git.Git (x64); tried: nullsoft, burn, inno, exe.')) { Ok 'W32T.InstallerVariantUnavailable reaches the caller unchanged (C-2 re-throw)' } else { Bad "fqid='$($r.Fqid)' message=$($r.Message)" }
if (($script:Calls -join ',') -eq 'create,download' -and $null -eq $script:IdentitySeen -and (& $downstream $script:Calls).Count -eq 0) { Ok 'nothing after the download ran: no configure, icon, identity checks, finalize, test or export' } else { Bad "calls=[$($script:Calls -join ',')] identity=$($null -ne $script:IdentitySeen)" }
if ($null -eq $script:OrgTemplate) { Ok '$script:OrgTemplate is cleared by the finally' } else { Bad 'org template leaked' }

# == -DependsOn pre-flight (re-verification 2026-10-21, B3 r2.1) ===================================
# Live: 'Invoke-Win32Toolkit ... -DependsOn project:..\EvilB3T' downloaded 7-Zip, scaffolded and configured the
# project, printed SUCCESS, and only then failed with a NON-terminating 'Script execution failed: Dependency ...
# must be ...', leaving a half-configured project. Now the references are checked first: W32T.InvalidDependencyReference
# (terminating), and nothing is resolved, created or downloaded. A fresh template folder proves no folder was created.
Write-Host '[6] An invalid -DependsOn stops Invoke-Win32Toolkit / New-Win32ToolkitManualApp before anything is downloaded or created' -ForegroundColor Cyan
$fresh = 'FreshB3'
$freshDir = Join-Path $BASE "Projects\$fresh"
$shapeCases = @(
    @("project:..\EvilB3T", "must be '<Template>\<ProjectName>' under Projects\ (not a full path or '..')"),
    @('intune:notaguid', "Dependency 'intune:notaguid' is not a valid Intune app id (expected a GUID)."),
    @('project:Contoso\Sub\Tool', '(exactly two names, neither empty)'),
    @('project:C:\W32T-Test\Projects\CloudFlow\7-Zip_x64_26.04', "(not a full path or '..')")
)
foreach ($case in $shapeCases) {
    Reset-Case @{ TemplateName = $fresh }
    $script:BaseCalls = 0; $script:ResolveCalls = 0; $script:SetDepSeen = $null
    $r = Invoke-Case { Invoke-Win32Toolkit -Id '7zip.7zip' -Architecture x64 -Force -InstallerType wix -DependsOn $case[0] -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
    if ($r.Fqid -eq 'W32T.InvalidDependencyReference' -and $r.Message.Contains($case[1]) -and $script:Calls.Count -eq 0 -and $script:BaseCalls -eq 0 -and
        $script:ResolveCalls -eq 0 -and $null -eq $script:SetDepSeen -and -not (Test-Path -LiteralPath $freshDir)) {
        Ok "Invoke-Win32Toolkit -DependsOn '$($case[0])' -> W32T.InvalidDependencyReference before the base folder, the winget lookup, Create-PSADTProject and Download-WingetApp"
    } else { Bad "Invoke '$($case[0])': fqid='$($r.Fqid)' msg='$($r.Message)' calls=[$($script:Calls -join ',')] base=$script:BaseCalls resolve=$script:ResolveCalls set=$($null -ne $script:SetDepSeen) folder=$(Test-Path -LiteralPath $freshDir)" }
}
# The app itself: refused once the project name is known, before the template folder or the project is created.
foreach ($selfRef in @("project:$fresh\Git_x64_2.45.0", "project:$($fresh.ToUpperInvariant())\git_x64_2.45.0")) {
    Reset-Case @{ TemplateName = $fresh }
    $script:ResolveCalls = 0; $script:SetDepSeen = $null
    $r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -DependsOn 'winget:Microsoft.VCRedist.2015+.x64', $selfRef -ErrorAction SilentlyContinue -ErrorVariable ev }
    if ($r.Fqid -eq 'W32T.InvalidDependencyReference' -and $r.Message -ceq "An app cannot depend on itself ('$fresh\Git_x64_2.45.0')." -and $script:ResolveCalls -eq 1 -and
        $script:Calls.Count -eq 0 -and $null -eq $script:SetDepSeen -and -not (Test-Path -LiteralPath $freshDir)) {
        Ok "Invoke-Win32Toolkit -DependsOn '$selfRef' (the app itself) -> W32T.InvalidDependencyReference; no template folder, no scaffold, no download"
    } else { Bad "Invoke self '$selfRef': fqid='$($r.Fqid)' msg='$($r.Message)' calls=[$($script:Calls -join ',')] resolve=$script:ResolveCalls folder=$(Test-Path -LiteralPath $freshDir)" }
}
# A valid reference still flows through: the scaffold and the download run, then the declaration.
Reset-Case @{}
$script:SetDepSeen = $null
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -DependsOn 'winget:Microsoft.VCRedist.2015+.x64', 'project:Contoso\VCRedist_x64_14.38' -ErrorAction SilentlyContinue -ErrorVariable ev }
if (-not $r.Fqid -and 'create' -in $script:Calls -and 'download' -in $script:Calls -and $script:SetDepSeen -and @($script:SetDepSeen['DependsOn']).Count -eq 2) { Ok 'valid -DependsOn references pass the pre-flight; the project is built and they are declared after the scaffold' } else { Bad "valid deps: fqid='$($r.Fqid)' $($r.Message) calls=[$($script:Calls -join ',')] declared=$(if ($script:SetDepSeen) { @($script:SetDepSeen['DependsOn']) -join ';' })" }

# New-Win32ToolkitManualApp: the form before any prompt or base folder, the app itself before anything is created.
$manualDeps = { param($Deps) New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $src 'tool.msi') -TemplateName 'Contoso' -Force -Continue -PackageIntune -DependsOn $Deps -ErrorAction SilentlyContinue -ErrorVariable ev }
foreach ($case in $shapeCases) {
    Reset-Case @{ TemplateName = $fresh }
    $script:BaseCalls = 0; $script:SetDepSeen = $null
    $r = Invoke-Case { & $manualDeps $case[0] }
    if ($r.Fqid -eq 'W32T.InvalidDependencyReference' -and $r.Message.Contains($case[1]) -and $script:Calls.Count -eq 0 -and $script:BaseCalls -eq 0 -and $null -eq $script:SetDepSeen -and -not (Test-Path -LiteralPath $freshDir)) {
        Ok "New-Win32ToolkitManualApp -DependsOn '$($case[0])' -> W32T.InvalidDependencyReference before the base folder and Create-PSADTProject"
    } else { Bad "Manual '$($case[0])': fqid='$($r.Fqid)' msg='$($r.Message)' calls=[$($script:Calls -join ',')] base=$script:BaseCalls folder=$(Test-Path -LiteralPath $freshDir)" }
}
Reset-Case @{ TemplateName = $fresh }
$script:SetDepSeen = $null
$r = Invoke-Case { & $manualDeps "project:$fresh\Tool_x64_1.0" }
if ($r.Fqid -eq 'W32T.InvalidDependencyReference' -and $r.Message -ceq "An app cannot depend on itself ('$fresh\Tool_x64_1.0')." -and $script:Calls.Count -eq 0 -and $null -eq $script:SetDepSeen -and -not (Test-Path -LiteralPath $freshDir)) {
    Ok "New-Win32ToolkitManualApp -DependsOn 'project:$fresh\Tool_x64_1.0' (the app itself) -> W32T.InvalidDependencyReference; no template folder, no scaffold"
} else { Bad "Manual self: fqid='$($r.Fqid)' msg='$($r.Message)' calls=[$($script:Calls -join ',')] folder=$(Test-Path -LiteralPath $freshDir)" }

# == [RR] the result object (TUI audit G2, S8-F3) ===================================================
Write-Host '[RR] Invoke-Win32Toolkit / New- / Complete-Win32ToolkitManualApp return a Win32Toolkit.RunResult' -ForegroundColor Cyan
# Runs an action and keeps its output objects (also those written before a terminating error).
function Invoke-Collect([scriptblock]$Action) {
    $ev = $null
    $out = [System.Collections.Generic.List[object]]::new()
    $fqid = ''
    try { . $Action 3>$null 6>$null | ForEach-Object { $out.Add($_) } }
    catch { $fqid = $_.FullyQualifiedErrorId }
    [pscustomobject]@{
        Out     = @($out)
        Results = @($out | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains 'Win32Toolkit.RunResult' })
        Fqid    = $fqid
        Errors  = @($ev)
    }
}

Reset-Case @{}
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune -PublishIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Out.Count -eq 1 -and $c.Results.Count -eq 1) { Ok 'Invoke-Win32Toolkit: exactly one object in the output, a Win32Toolkit.RunResult' } else { Bad "output: $($c.Out.Count) object(s), $($c.Results.Count) RunResult(s); fqid='$($c.Fqid)'" }
$capText = 'The install capture did not complete: the uninstall, the processes to close and the capture-based detection rule were not updated (see the warnings above).'
if ($rr -and $rr.Command -eq 'Invoke-Win32Toolkit' -and $rr.Mode -eq 'Winget' -and $rr.Capture -eq 'Problems' -and $rr.Status -eq 'CompletedWithProblems' -and
    $rr.ProjectName -eq 'Git_x64_2.45.0' -and $rr.ProjectPath -eq $newProj -and @($rr.Problems) -ccontains $capText -and $script:ExportPassThru) {
    Ok 'a capture that did not complete -> Capture Problems, its problem text, Status CompletedWithProblems; Export was called with -PassThru'
} else { Bad "result: $(if ($rr) { $rr | Select-Object Command, Mode, Capture, Status, ProjectName, ProjectPath | ConvertTo-Json -Compress }) problems=[$(if ($rr) { $rr.Problems -join ' | ' })] passthru=$script:ExportPassThru" }
$propOrder = 'Command,ProjectPath,ProjectName,Mode,Status,Capture,Tests,IntuneWinPath,Published,Problems'
if ($rr -and ($rr.PSObject.Properties.Name -join ',') -eq $propOrder -and $rr.Problems -is [string[]] -and $rr.Tests -is [object[]] -and $rr.Published -is [object[]]) { Ok 'the properties are always present, in the contract order, with arrays (not lists)' } else { Bad "properties: $(if ($rr) { $rr.PSObject.Properties.Name -join ',' })" }

# A completed capture (New-TargetedDocumentation returns the expected-JSON path) that Wait-ForDocumentationAndProcess
# processed, a passed test and an export without problems: the only way a run reads as a green Done in the TUI.
$capJson = Join-Path $newProj 'Documentation\InstallationChanges_test.json'
Reset-Case @{ CapturePath = $capJson; CaptureProcessed = $true; TestVerdict = $true }
$script:WaitSeen = $null
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Results.Count -eq 1 -and $rr.Capture -eq 'Done' -and $rr.Status -eq 'Succeeded' -and @($rr.Problems).Count -eq 0 -and @($rr.Tests).Count -eq 1 -and $rr.Tests[0].Verdict -eq 'Passed' -and
    $script:WaitSeen -and $script:WaitSeen['ExpectedJsonPath'] -eq $capJson -and ($script:Calls -join ',') -match 'document,process,test,export:False') {
    Ok 'a processed capture, a passed test and a clean export -> one RunResult: Capture Done, Status Succeeded, Problems empty'
} else { Bad "results=$($c.Results.Count) result: $(if ($rr) { $rr | Select-Object Capture, Status, Problems, Tests | ConvertTo-Json -Compress -Depth 3 }) wait=$(if ($script:WaitSeen) { $script:WaitSeen['ExpectedJsonPath'] }) calls=[$($script:Calls -join ',')]" }

Reset-Case @{ CapturePath = $capJson; CaptureProcessed = $false }
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
$procText = 'The install capture could not be processed cleanly: review the uninstall and the processes to close (see the warnings above).'
if ($c.Results.Count -eq 1 -and $rr.Capture -eq 'Problems' -and @($rr.Problems).Count -eq 1 -and $rr.Problems[0] -ceq $procText -and $rr.Status -eq 'CompletedWithProblems' -and 'process' -in $script:Calls) {
    Ok 'a completed capture that could not be processed -> Capture Problems and exactly the "could not be processed cleanly" problem'
} else { Bad "results=$($c.Results.Count) result: $(if ($rr) { $rr | Select-Object Capture, Status | ConvertTo-Json -Compress }) problems=[$(if ($rr) { $rr.Problems -join ' | ' })] calls=[$($script:Calls -join ',')]" }

Reset-Case @{ TestVerdict = $false }
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
$failText = "The InstallUninstall test FAILED: review $newProj\Sandbox\Logs\InstallAssertions.log."
if ($rr -and @($rr.Tests).Count -eq 1 -and $rr.Tests[0].Scenario -eq 'InstallUninstall' -and $rr.Tests[0].Verdict -eq 'Failed' -and @($rr.Problems) -ccontains $failText -and $rr.Status -eq 'CompletedWithProblems') {
    Ok '-RunTest InstallUninstall with a failed verdict -> Tests[0] Failed and the FAILED problem naming the log'
} else { Bad "tests=$(if ($rr) { $rr.Tests | ConvertTo-Json -Compress }) problems=[$(if ($rr) { $rr.Problems -join ' | ' })]" }

Reset-Case @{ TestVerdict = $null }
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($rr -and $rr.Tests[0].Verdict -eq 'Inconclusive' -and @($rr.Problems) -ccontains 'The InstallUninstall test gave no verdict (Inconclusive): the package was not shown to install and uninstall.') { Ok 'no verdict -> Tests[0] Inconclusive and its problem text' } else { Bad "tests=$(if ($rr) { $rr.Tests | ConvertTo-Json -Compress }) problems=[$(if ($rr) { $rr.Problems -join ' | ' })]" }

Reset-Case @{ TestVerdict = $true; ExportSummary = [pscustomobject]@{ IntuneWinPath = 'C:\out\Git_x64_2.45.0.intunewin'; Published = @([pscustomobject]@{ AppId = 'app-1'; DisplayName = 'Git'; IsUpdateApp = $false; PortalUri = 'https://x' }); Problems = @('The update app was not published: test.') } }
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($rr -and $rr.Tests[0].Verdict -eq 'Passed' -and $rr.IntuneWinPath -eq 'C:\out\Git_x64_2.45.0.intunewin' -and @($rr.Published).Count -eq 1 -and $rr.Published[0].AppId -eq 'app-1' -and
    $rr.Problems[-1] -ceq 'The update app was not published: test.') {
    Ok "a passed test -> Verdict Passed; the export summary's .intunewin path, published app and problems are copied into the result"
} else { Bad "result: $(if ($rr) { $rr | ConvertTo-Json -Compress -Depth 4 })" }

Reset-Case @{ TestVerdict = $false; ExportThrows = 'boom' }
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Results.Count -eq 1 -and $rr.Status -eq 'Failed' -and $rr.Problems[-1] -ceq 'boom' -and $rr.Tests[0].Verdict -eq 'Failed' -and
    ($c.Errors | ForEach-Object { "$_" }) -contains 'Script execution failed: boom' -and -not $c.Fqid) {
    Ok 'an export that throws a plain error -> Status Failed, Problems ends with it, the verdict recorded before it stays, and the Write-Error is still written'
} else { Bad "results=$($c.Results.Count) status=$(if ($rr) { $rr.Status }) problems=[$(if ($rr) { $rr.Problems -join ' | ' })] errors=[$($c.Errors -join ' | ')] fqid='$($c.Fqid)'" }

Reset-Case @{ ApplyFails = $true }
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
if ($c.Fqid -eq 'W32T.PipelineAborted' -and $c.Results.Count -eq 0) { Ok 'a W32T.* error is thrown and no result object is emitted' } else { Bad "fqid='$($c.Fqid)' results=$($c.Results.Count)" }

Reset-Case @{ ResolveNull = $true }
$c = Invoke-Collect { Invoke-Win32Toolkit -Id 'No.Such' -Architecture x64 -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Results.Count -eq 1 -and $rr.Status -eq 'Failed' -and $rr.Problems[-1] -ceq "Package ID 'No.Such' was not found in winget." -and $rr.ProjectPath -eq '' -and
    ($c.Errors | ForEach-Object { "$_" }) -match "Package ID 'No.Such' not found in winget" -and 'create' -notin $script:Calls) {
    Ok 'a package id winget does not know -> Status Failed with its problem; the Write-Error is unchanged; nothing created'
} else { Bad "results=$($c.Results.Count) result: $(if ($rr) { $rr | Select-Object Status, ProjectPath, Problems | ConvertTo-Json -Compress }) errors=[$($c.Errors -join ' | ')]" }

Reset-Case @{}
$c = Invoke-Collect { Invoke-Win32Toolkit -SearchTerm 'nothing-matches' -Architecture x64 -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Results.Count -eq 1 -and $rr.Status -eq 'Failed' -and $rr.Problems[-1] -ceq 'No applications found matching: nothing-matches' -and 'create' -notin $script:Calls) { Ok 'a search without results -> Status Failed with its problem' } else { Bad "results=$($c.Results.Count) result: $(if ($rr) { $rr | Select-Object Status, Problems | ConvertTo-Json -Compress })" }

Reset-Case @{}
$c = Invoke-Collect { New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $src 'tool.msi') -TemplateName 'Contoso' -Force -Advanced -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Out.Count -eq 1 -and $rr -and $rr.Status -eq 'Scaffolded' -and $rr.Mode -eq 'Advanced' -and $rr.ProjectPath -eq (Join-Path $BASE 'Projects\Contoso\Tool_x64_1.0') -and $rr.ProjectName -eq 'Tool_x64_1.0' -and $rr.Capture -eq 'NotRun') {
    Ok 'New-Win32ToolkitManualApp -Advanced -> one RunResult: Status Scaffolded, Mode Advanced, ProjectPath set, Capture NotRun'
} else { Bad "out=$($c.Out.Count) result: $(if ($rr) { $rr | Select-Object Status, Mode, ProjectPath, Capture | ConvertTo-Json -Compress })" }

Reset-Case @{}
$c = Invoke-Collect { New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $src 'tool.msi') -TemplateName 'Contoso' -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($rr -and $rr.Status -eq 'Scaffolded' -and $rr.Mode -eq 'Easy' -and 'document' -notin $script:Calls) { Ok 'an Easy app without -Continue -> Status Scaffolded, Mode Easy, nothing finalised' } else { Bad "result: $(if ($rr) { $rr | Select-Object Status, Mode | ConvertTo-Json -Compress }) calls=[$($script:Calls -join ',')]" }

Reset-Case @{}
$c = Invoke-Collect $runManual
$rr = $c.Results | Select-Object -First 1
if ($c.Out.Count -eq 1 -and $rr -and $rr.Mode -eq 'Easy' -and $rr.Status -eq 'CompletedWithProblems' -and $rr.Capture -eq 'Problems') { Ok 'an Easy app with -Continue -> one RunResult, Mode Easy, the capture problem recorded' } else { Bad "out=$($c.Out.Count) result: $(if ($rr) { $rr | Select-Object Status, Mode, Capture | ConvertTo-Json -Compress })" }

Reset-Case @{}
$c = Invoke-Collect { New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $BASE 'nope.msi') -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Results.Count -eq 1 -and $rr.Status -eq 'Failed' -and $rr.ProjectPath -eq '' -and $rr.Mode -eq '' -and $rr.Problems[-1] -like 'Source path not found: *' -and
    ($c.Errors | ForEach-Object { "$_" }) -match 'New-Win32ToolkitManualApp failed: Source path not found') {
    Ok 'a New-Win32ToolkitManualApp failure before the scaffold -> one RunResult (Status Failed, ProjectPath empty, Mode empty) and the Write-Error'
} else { Bad "results=$($c.Results.Count) result: $(if ($rr) { $rr | Select-Object Status, ProjectPath, Mode | ConvertTo-Json -Compress }) errors=[$($c.Errors -join ' | ')]" }

Reset-Case @{}
$c = Invoke-Collect { Complete-Win32ToolkitManualApp -ProjectPath $proj -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
$rr = $c.Results | Select-Object -First 1
if ($c.Out.Count -eq 1 -and $rr -and $rr.Command -eq 'Complete-Win32ToolkitManualApp' -and $rr.Mode -eq 'Finalize' -and $rr.ProjectPath -eq $proj -and $rr.ProjectName -eq 'Tool_x64_1.0') { Ok 'Complete-Win32ToolkitManualApp -> one RunResult, Mode Finalize, the project path and name' } else { Bad "out=$($c.Out.Count) result: $(if ($rr) { $rr | Select-Object Command, Mode, ProjectPath | ConvertTo-Json -Compress })" }

Reset-Case @{ AssertFails = $true }
$c = Invoke-Collect { Complete-Win32ToolkitManualApp -ProjectPath $proj -PackageIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
if ($c.Fqid -eq 'W32T.PackageNotReady' -and $c.Results.Count -eq 0) { Ok 'Complete: a W32T.* error -> thrown, no result object' } else { Bad "fqid='$($c.Fqid)' results=$($c.Results.Count)" }

function New-OrgTemplate { param($ExistingTemplate, $TemplateName, $BasePath) $script:NewTemplateCalls++; [pscustomobject]@{ TemplateName = 'Contoso' } }
Reset-Case @{}
$script:NewTemplateCalls = 0
$c = Invoke-Collect { Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso' -ErrorAction SilentlyContinue -ErrorVariable ev }
if ($script:NewTemplateCalls -eq 1 -and $c.Results.Count -eq 0 -and $c.Out.Count -eq 0 -and $c.Errors.Count -eq 0) { Ok 'Invoke-Win32Toolkit -NewTemplate returns no result object' } else { Bad "template calls=$script:NewTemplateCalls out=$($c.Out.Count) results=$($c.Results.Count) errors=[$($c.Errors -join ' | ')]" }

# == [NC] a half-built project is marked not configured (TUI audit G4, S10-F2) =====================
# Every error after a successful Create-PSADTProject and before the end of the configure step writes
# Documentation\NotConfigured.json, then the error goes on unchanged. Each case starts from a removed project folder
# (the Create-PSADTProject shadow keeps an existing folder), so no marker leaks between cases.
Write-Host '[NC] every error between the scaffold and the end of the configure step marks the project not configured' -ForegroundColor Cyan
$gitProj  = Join-Path $BASE 'Projects\Contoso\Git_x64_2.45.0'
$toolProj = Join-Path $BASE 'Projects\Contoso\Tool_x64_1.0'
function Get-Marker([string]$ProjectPath) {
    $f = Join-Path $ProjectPath 'Documentation\NotConfigured.json'
    if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } else { $null }
}
function Clear-Project([string]$ProjectPath) { Remove-Item -LiteralPath $ProjectPath -Recurse -Force -ErrorAction SilentlyContinue }
$markerText = { param($m) if ($m) { $m | Select-Object Stage, ErrorId, Reason | ConvertTo-Json -Compress } else { 'none' } }

Clear-Project $gitProj; Reset-Case @{ GeneratorThrows = $true }
$r = Invoke-Case $runInvoke
$m = Get-Marker $gitProj
if ($r.Fqid -eq 'W32T.UnsupportedTemplateShape' -and $m -and $m.Stage -eq 'Configure' -and $m.ErrorId -eq 'W32T.UnsupportedTemplateShape' -and ([string]$m.Reason).StartsWith('Unsupported PSADT template shape: ') -and $m.SchemaVersion -eq '1.0') {
    Ok 'Invoke: a W32T generator error -> marker Stage Configure with that id and message; the error still reaches the caller unchanged'
} else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText $m)" }

Clear-Project $gitProj; Reset-Case @{ ApplyFails = $true }
$r = Invoke-Case $runInvoke
$m = Get-Marker $gitProj
if ($r.Fqid -eq 'W32T.PipelineAborted' -and $m -and $m.Stage -eq 'Configure' -and $m.ErrorId -eq 'W32T.PipelineAborted') { Ok 'Invoke: the org template not applied (W32T.PipelineAborted) -> marker Stage Configure' } else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText $m)" }

Clear-Project $gitProj; Reset-Case @{ DownloadUnavailable = $true }
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -InstallerType nullsoft -PackageIntune -PublishIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
$m = Get-Marker $gitProj
if ($r.Fqid -eq 'W32T.InstallerVariantUnavailable' -and $r.Message.StartsWith('winget offers no vendor EXE installer for Git.Git (x64); tried: nullsoft, burn, inno, exe.') -and
    $m -and $m.Stage -eq 'Download' -and $m.ErrorId -eq 'W32T.InstallerVariantUnavailable') {
    Ok 'Invoke: no installer of the pinned family (W32T.InstallerVariantUnavailable) -> marker Stage Download; the error is unchanged'
} else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText $m)" }

Clear-Project $gitProj; Reset-Case @{}
$r = Invoke-Case $runInvoke
if (-not $r.Fqid -and (Test-Path -LiteralPath $gitProj) -and $null -eq (Get-Marker $gitProj)) { Ok 'Invoke: a configured project is not marked' } else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText (Get-Marker $gitProj))" }

Clear-Project $gitProj; Reset-Case @{ IconThrows = $true }
$r = Invoke-Case $runInvoke
if ($r.Fqid -eq 'W32T.Test' -and 'icon' -in $script:Calls -and $null -eq (Get-Marker $gitProj)) { Ok 'Invoke: an error after the configure step (the icon step) is re-thrown and does NOT mark the project' } else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText (Get-Marker $gitProj))" }

# A re-created project starts without the marker its old folder had (Create-PSADTProject replaces the folder).
Clear-Project $gitProj; Reset-Case @{ ApplyFails = $true }
$null = Invoke-Case $runInvoke
$had = $null -ne (Get-Marker $gitProj)
Reset-Case @{ Recreate = $true }
$r = Invoke-Case $runInvoke
if ($had -and -not $r.Fqid -and $null -eq (Get-Marker $gitProj)) { Ok 'Invoke: re-creating the project removes the marker (the folder is replaced)' } else { Bad "had=$had fqid='$($r.Fqid)' marker=$(& $markerText (Get-Marker $gitProj))" }

Clear-Project $toolProj; Reset-Case @{ ApplyFails = $true }
$r = Invoke-Case $runManual
$m = Get-Marker $toolProj
if ($r.Fqid -eq 'W32T.PipelineAborted' -and $m -and $m.Stage -eq 'Configure' -and $m.ErrorId -eq 'W32T.PipelineAborted') { Ok 'New-: the org template not applied -> marker Stage Configure, W32T.PipelineAborted' } else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText $m)" }

$readmeSrc = Join-Path $BASE 'src-readme'; New-Item -ItemType Directory -Path $readmeSrc -Force | Out-Null; Set-Content (Join-Path $readmeSrc 'readme.txt') 'no installer here'
Clear-Project $toolProj; Reset-Case @{}
$r = Invoke-Case { New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath $readmeSrc -TemplateName 'Contoso' -Force -Continue -ErrorAction SilentlyContinue -ErrorVariable ev }
$m = Get-Marker $toolProj
if (-not $r.Fqid -and $m -and $m.Stage -eq 'Download' -and $m.ErrorId -eq '' -and ([string]$m.Reason).StartsWith('No installer (msi/exe/msix/appx) detected') -and
    ($r.Errors | ForEach-Object { "$_" }) -match 'New-Win32ToolkitManualApp failed: No installer') {
    Ok 'New-: a source without an installer -> marker Stage Download, ErrorId empty (non-W32T); the Write-Error still reaches -ErrorVariable'
} else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText $m) errors=[$($r.Errors -join ' | ')]" }

Clear-Project $toolProj; Reset-Case @{ GeneratorPlainThrows = $true }
$r = Invoke-Case $runManual
$m = Get-Marker $toolProj
if (-not $r.Fqid -and $m -and $m.Stage -eq 'Configure' -and $m.ErrorId -eq '' -and $m.Reason -eq 'plain generator failure') { Ok 'New-: a non-W32T generator error -> marker Stage Configure, ErrorId empty' } else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText $m)" }

Clear-Project $toolProj; Reset-Case @{}
$r = Invoke-Case { New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $BASE 'nope.msi') -TemplateName 'Contoso' -Force -ErrorAction SilentlyContinue -ErrorVariable ev }
if (-not (Test-Path -LiteralPath (Join-Path $toolProj 'Documentation\NotConfigured.json'))) { Ok 'New-: a failure before the scaffold (source path not found) writes no marker' } else { Bad 'a marker was written before the scaffold' }

Clear-Project $toolProj; Reset-Case @{}
$r = Invoke-Case $runManual
if (-not $r.Fqid -and (Test-Path -LiteralPath $toolProj) -and $null -eq (Get-Marker $toolProj)) { Ok 'New-: a configured project is not marked' } else { Bad "fqid='$($r.Fqid)' marker=$(& $markerText (Get-Marker $toolProj))" }

# == [NP] -NoPublishPrompt reaches the export (TUI audit G5) =======================================
# The menu asks about publishing itself: with -NoPublishPrompt the packaging step never asks 'Upload to Microsoft
# Intune now? (Y/N)'. Without it the export gets no NoPublishPrompt at all (the command-line behaviour is unchanged).
Write-Host '[NP] -NoPublishPrompt on Invoke-Win32Toolkit, New- and Complete-Win32ToolkitManualApp reaches Export-Win32ToolkitIntuneWin' -ForegroundColor Cyan
$npCases = [ordered]@{
    'Invoke-Win32Toolkit'            = { param([hashtable]$X) Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune @X -ErrorAction SilentlyContinue -ErrorVariable ev }
    'New-Win32ToolkitManualApp'      = { param([hashtable]$X) New-Win32ToolkitManualApp -Name 'Tool' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $src 'tool.msi') -TemplateName 'Contoso' -Force -Continue -PackageIntune @X -ErrorAction SilentlyContinue -ErrorVariable ev }
    'Complete-Win32ToolkitManualApp' = { param([hashtable]$X) Complete-Win32ToolkitManualApp -ProjectPath $toolProj -PackageIntune @X -ErrorAction SilentlyContinue -ErrorVariable ev }
}
foreach ($npName in $npCases.Keys) {
    $npRun = $npCases[$npName]
    Reset-Case @{}
    $script:ExportNoPrompt = $null
    $r = Invoke-Case { & $npRun @{ NoPublishPrompt = $true } }
    if (-not $r.Fqid -and $script:ExportNoPrompt -eq $true) { Ok "$npName -PackageIntune -NoPublishPrompt -> the export gets -NoPublishPrompt (no 'Upload ... now?' question)" } else { Bad "${npName}: fqid='$($r.Fqid)' export NoPublishPrompt=$script:ExportNoPrompt calls=[$($script:Calls -join ',')]" }
    Reset-Case @{}
    $script:ExportNoPrompt = $null
    $r = Invoke-Case { & $npRun @{} }
    if (-not $r.Fqid -and $script:ExportNoPrompt -eq 'unbound') { Ok "$npName -PackageIntune without it -> NoPublishPrompt is not bound on the export (the CLI keeps its question)" } else { Bad "${npName}: fqid='$($r.Fqid)' export NoPublishPrompt=$script:ExportNoPrompt" }
}

Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'PipelineFailClosed unit test PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
