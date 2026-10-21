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
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure) $BASE }
function Get-OrgTemplate {
    param($TemplateName, $BasePath)
    $t = [pscustomobject]@{ TemplateName = 'Contoso'; AppScriptAuthor = 'IT' }
    if ($script:Mode.TenantId) { $t | Add-Member -NotePropertyName TenantId -NotePropertyValue $script:Mode.TenantId }
    $t
}
function Resolve-Win32ToolkitWingetId { param($Id) [pscustomobject]@{ Name = 'Git'; Id = $Id; Version = '2.45.0'; Source = 'winget' } }
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
function Get-AppIconFromWinget { param($ProjectPath, $FilesPath) $script:Calls.Add('icon') }
function Set-Win32ToolkitAppDependency { param($ProjectPath, $DependsOn, $DependencyType) }
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
function Apply-OrgTemplate { param($ProjectPath, $Template) $script:Calls.Add('apply'); return (-not $script:Mode.ApplyFails) }
function Assert-Win32ToolkitPackageReady {
    param($ProjectPath, $Stage, [switch]$AllowLegacyScript)
    $script:Calls.Add("assert:${Stage}:$([bool]$AllowLegacyScript)")
    $script:AssertPath = $ProjectPath
    if ($script:Mode.AssertFails) { throw (New-W32TError 'W32T.PackageNotReady' "The package is not ready:`n- Unsupported PSADT template shape: x") }
    [pscustomobject]@{ Ready = $true; Shape = 'Psadt41'; VersionText = '4.1.8'; Warnings = @() }
}
function Get-Win32ToolkitTestBackend { if ($script:Mode.BackendThrows) { throw 'backend exploded' }; 'Sandbox' }
function New-TargetedDocumentation { param($ProjectPath, $ProjectName, $AppInfo, $Backend) $script:Calls.Add('document'); return $false }
function Invoke-Win32ToolkitHyperVRun { param($ProjectPath, $Phase, $Output) $true }
function Wait-ForDocumentationAndProcess { param($ProjectPath, $InstallerType, $ExpectedJsonPath) $true }
function Import-Win32ToolkitCapturedIcon { param($ProjectPath) }
# C-9: the capture run-log helpers Finalize calls (test campaign 2026-10-21, H5-F5/H7-F1); no disk writes.
function Initialize-Win32ToolkitTestRunLog { param($ProjectPath, $Scenario, $Family) $null }
function Save-Win32ToolkitTestRunLog { param($Run) $null }
function Wait-Win32ToolkitCollectedLog { param($ProjectPath, $TimeoutSeconds) $true }
function Test-Win32ToolkitProject { param($ProjectPath, $Scenario, $SpecificVersion, $VersionsBack) $script:Calls.Add('test'); $true }
function Export-Win32ToolkitIntuneWin { param($ProjectPath, [switch]$PublishIntune, [switch]$PublishUpdate, [switch]$AllowLegacyScript) $script:Calls.Add("export:$([bool]$AllowLegacyScript)") }

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
            [switch]$PackageIntune, [switch]$PublishIntune, [switch]$PublishUpdate)
        $script:FinalizeSeen = $PSBoundParameters
    }
    $script:FinalizeSeen = $null
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force @Extra 6>$null 3>$null
    $script:FinalizeSeen
}
Reset-Case @{}
$fs = & $finalizeRun @{ RunTest = @('Update'); UpdateVersionsBack = 1; UpdateBaselineInstallerType = 'Both' }
if ($fs -and $fs['UpdateBaselineInstallerType'] -eq 'Both' -and $fs['RunTest'] -eq 'Update' -and $fs['UpdateVersionsBack'] -eq 1) { Ok '-UpdateBaselineInstallerType Both reaches Invoke-Win32ToolkitFinalize' } else { Bad "finalize args: $(if ($fs) { ($fs.Keys | ForEach-Object { "$_=$($fs[$_])" }) -join '; ' })" }
$fs = & $finalizeRun @{ RunTest = @('Update') }
if ($fs -and -not $fs.ContainsKey('UpdateBaselineInstallerType')) { Ok 'not bound -> not passed (Finalize and Test keep their own default)' } else { Bad "finalize args: $(if ($fs) { ($fs.Keys | ForEach-Object { "$_=$($fs[$_])" }) -join '; ' })" }

# W32T.InstallerVariantUnavailable from the download passes Invoke unchanged; nothing downstream runs.
Reset-Case @{ DownloadUnavailable = $true }
$script:IdentitySeen = $null
$script:OrgTemplate = [pscustomobject]@{ TemplateName = 'stale' }
$r = Invoke-Case { Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -InstallerType nullsoft -PackageIntune -PublishIntune -ErrorAction SilentlyContinue -ErrorVariable ev }
if ($r.Fqid -eq 'W32T.InstallerVariantUnavailable' -and $r.Message.StartsWith('winget offers no vendor EXE installer for Git.Git (x64); tried: nullsoft, burn, inno, exe.')) { Ok 'W32T.InstallerVariantUnavailable reaches the caller unchanged (C-2 re-throw)' } else { Bad "fqid='$($r.Fqid)' message=$($r.Message)" }
if (($script:Calls -join ',') -eq 'create,download' -and $null -eq $script:IdentitySeen -and (& $downstream $script:Calls).Count -eq 0) { Ok 'nothing after the download ran: no configure, icon, identity checks, finalize, test or export' } else { Bad "calls=[$($script:Calls -join ',')] identity=$($null -ne $script:IdentitySeen)" }
if ($null -eq $script:OrgTemplate) { Ok '$script:OrgTemplate is cleared by the finally' } else { Bad 'org template leaked' }

Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'PipelineFailClosed unit test PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
