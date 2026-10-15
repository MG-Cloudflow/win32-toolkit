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
function Get-OrgTemplate { param($TemplateName, $BasePath) [pscustomobject]@{ TemplateName = 'Contoso'; AppScriptAuthor = 'IT' } }
function Resolve-Win32ToolkitWingetId { param($Id) [pscustomobject]@{ Name = 'Git'; Id = $Id; Version = '2.45.0'; Source = 'winget' } }
function Get-WingetAppDetails { param($AppId) if ($script:Mode.DetailsThrows) { throw 'winget exploded' }; @('x64') }
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
    foreach ($d in 'Files', 'SupportFiles') { New-Item -ItemType Directory -Path (Join-Path $full $d) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $full 'Invoke-AppDeployToolkit.ps1') -Value '# scaffold'
    return $true
}
function Download-WingetApp { param($AppId, $AppName, $DownloadPath, $Architecture) $script:Calls.Add('download'); Set-Content (Join-Path $DownloadPath 'setup.exe') 'x'; $true }
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

Reset-Case @{ DetailsThrows = $true }
$r = Invoke-Case $runInvoke
if (-not $r.Fqid -and ($r.Errors | ForEach-Object { "$_" }) -match 'Script execution failed: winget exploded') { Ok 'a non-W32T error keeps the Write-Error behaviour (non-terminating)' } else { Bad "fqid='$($r.Fqid)' errors=[$($r.Errors -join '; ')]" }

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

Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'PipelineFailClosed unit test PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
