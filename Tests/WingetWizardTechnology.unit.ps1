<#
    Installer-identity PR 1, spec 3.4 task 5 (WP-2, D4, L3): the winget wizard's installer-technology question.

    The wizard (Invoke-Win32ToolkitWingetWizard) is driven end to end with every Spectre cmdlet, the menu
    helpers and Invoke-Win32Toolkit shadowed; the predecessor lookup and the sibling probe are shadowed with
    REAL probe results over Tests\Fixtures\winget-manifests (Invoke-WebRequest shadowed: no network).
    Get-Win32ToolkitInstallerFamily, Sanitize-ProjectName and Get-Win32ToolkitPaths are real.

      [1] no anchor + two families (Notepad++ wix / nullsoft) -> asked once, winget's default marked, the
          choice reaches Invoke-Win32Toolkit as -InstallerType <pin value>; the grey two-registrations hint
      [2] anchor + two families -> 'Keep <anchor> (recommended: ...)' first, no "Let winget choose";
          Keep -> NO -InstallerType (continuity pins it); the other family -> -InstallerType <pin value>
      [2b] the would-be project already exists and is published / pinned (Get-Win32ToolkitSelfAnchor) ->
          it is the anchor: 'Keep <family> (recommended: <name> is published; rebuilding it)', Keep passes
          nothing, no predecessor lookup
      [3] anchor + one family / probe unavailable -> not asked, grey 'keeps' line, no -InstallerType
      [3b] the probe answers and the version ships no packageable installer of the anchor's family -> no
          'keeps' line and no 'recommended' Keep; one yellow line (keeping stops the build:
          W32T.InstallerVariantUnavailable); asked: skip (recommended, nothing built) / 'Switch to <family>'
          (-InstallerType <pin value>) / Keep (no -InstallerType)
      [4] no anchor + one family (TeamViewer: zip-wrapped MSI listed, not selectable; Git) / probe unavailable
          -> not asked, no -InstallerType
      [5] msix family whose top testable tuple is appx (also msstore + appx) -> passes msix
      [6] version 'Unknown' -> no probe request, no lookup, grey line
      [7] the lookup and probe get the template folder, tenant, would-be project and architecture; the
          summary has the 'Installer tech' row; hostile labels are escaped
      [9] TUI audit G3: with the test ticked, the Review panel (winget and manual wizard) has a 'Test mode' row
          naming the effective mode and why; without the test, no row

    Run:  pwsh -File Tests\WingetWizardTechnology.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Clear-Host and Invoke-WebRequest are shadowed: nothing renders, no network')]
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

# C-9 (TUI audit G2): the wizard renders its result panel with Show-Win32ToolkitRunResult (real; the Invoke shadow
# returns no result object, so it shows the yellow 'Finished' panel).
# C-9 (TUI audit G4): a failed build names the folder it left marked (Find-Win32ToolkitNotConfiguredProject + the marker reader).
foreach ($f in 'Sanitize-ProjectName', 'Get-Win32ToolkitPaths', 'Get-Win32ToolkitInstallerFamily', 'ConvertTo-Win32ToolkitSafeText',
    'Get-Win32ToolkitSiblingInstaller', 'Invoke-Win32ToolkitWingetWizard', 'Show-Win32ToolkitRunResult',
    'Get-Win32ToolkitNotConfiguredMarker', 'Find-Win32ToolkitNotConfiguredProject') {
    . (Join-Path $repo "Private\$f.ps1")
}

# --- real probe results over the fixtures (before the probe is shadowed) -----------------------------
$fx = Join-Path $repo 'Tests\Fixtures\winget-manifests'
$script:body = ''
function Invoke-WebRequest { [CmdletBinding()] param([string]$Uri, [int]$TimeoutSec, [int]$MaximumRedirection, [switch]$SkipHttpErrorCheck) [pscustomobject]@{ StatusCode = 200; Content = $script:body } }
function Get-FixtureProbe([string]$Rel, [string]$Id, [string]$Ver) {
    $script:body = if ($Rel -like 'inline:*') { $Rel.Substring(7) } else { Get-Content -LiteralPath (Join-Path $fx $Rel) -Raw -Encoding UTF8 }
    Get-Win32ToolkitSiblingInstaller -WingetId $Id -Version $Ver -Architecture x64 -NoMemo
}
$probeNpp  = Get-FixtureProbe 'Notepad++.Notepad++\8.9.8.1.installer.yaml' 'Notepad++.Notepad++' '8.9.8.1'
$probeTv   = Get-FixtureProbe 'TeamViewer.TeamViewer\15.82.6.installer.yaml' 'TeamViewer.TeamViewer' '15.82.6'
$probeAppx = Get-FixtureProbe 'synthetic\appx-sibling.installer.yaml' 'Contoso.AppxSibling' '3.1.0'
$probeGit  = Get-FixtureProbe "inline:PackageIdentifier: Git.Git`nPackageVersion: 2.55.0`nInstallers:`n- Architecture: x64`n  InstallerType: inno`n  Scope: machine`n- Architecture: x64`n  InstallerType: inno`n  Scope: user`n" 'Git.Git' '2.55.0'
$probeWix  = Get-FixtureProbe "inline:PackageIdentifier: Notepad++.Notepad++`nPackageVersion: 8.9.8.1`nInstallers:`n- Architecture: x64`n  InstallerType: wix`n  Scope: machine`n" 'Notepad++.Notepad++' '8.9.8.1'
$probeDown = [pscustomobject]@{ SchemaVersion = '1.0'; Status = 'Unavailable'; Reason = 'Network'; Url = ''; ProbedUtc = ''; FromMemo = $false
                                WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = 'x64'; PackagedType = ''; PackagedFamily = ''
                                Tuples = @(); Siblings = @(); SameFamilyOther = @(); NotRegistering = @() }
# msstore + appx + exe (synthetic: the msix family's top tuple is msstore, which cannot be packaged).
function New-Tuple([string]$Type) {
    $r = Get-Win32ToolkitInstallerFamily -Type $Type
    [pscustomobject]@{ Architecture = 'x64'; InstallerType = $Type; NestedInstallerType = ''; EffectiveType = $r.EffectiveType; RegisteredType = ''; Family = $r.Family
                       Scope = ''; ProductCode = ''; Locale = ''; ZipWrapped = $r.ZipWrapped; Registers = $r.Registers; Testable = $r.Testable; PinValue = $r.PinValue
                       Precedence = $r.Precedence; Label = $r.Label }
}
$probeStore = [pscustomobject]@{ SchemaVersion = '1.0'; Status = 'Ok'; Reason = ''; Url = ''; ProbedUtc = ''; FromMemo = $false; WingetId = 'Contoso.Store'; Version = '1.0'
                                 Architecture = 'x64'; PackagedType = ''; PackagedFamily = ''; Tuples = @(); SameFamilyOther = @(); NotRegistering = @()
                                 Siblings = @((New-Tuple 'msstore'), (New-Tuple 'appx'), (New-Tuple 'exe')) }
$fxOk = ($probeNpp.Status, $probeTv.Status, $probeAppx.Status, $probeGit.Status, $probeWix.Status) -join ','
if ($fxOk -eq 'Ok,Ok,Ok,Ok,Ok') { Ok 'fixture probes parsed (Notepad++, TeamViewer, appx, Git, wix only)' } else { Bad "fixture probes: $fxOk" }

# --- shadows ------------------------------------------------------------------------------------------
$BASE = Join-Path ([System.IO.Path]::GetTempPath()) ('w32wz_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path (Join-Path $BASE 'Templates') -Force | Out-Null
'{ "TemplateName": "Contoso", "TenantId": "tenant-1" }' | Set-Content -LiteralPath (Join-Path $BASE 'Templates\Contoso.json') -Encoding UTF8

function winget { }   # Get-Command winget must succeed; the wizard never runs it
function Clear-Host { }
function Write-SpectreRule { param($Title, $Color) }
$script:hostLines = [System.Collections.Generic.List[string]]::new()
function Write-SpectreHost { param($Message) $script:hostLines.Add([string]$Message) }
$script:panels = [System.Collections.Generic.List[string]]::new()
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) $script:panels.Add([string]$Data) }
function Read-SpectrePause { param($Message, [switch]$AnyKey) }
function Read-SpectreText { param($Message) 'something' }
function Get-SpectreEscapedText { param($Text) ([string]$Text).Replace('[', '[[').Replace(']', ']]') }
# Nothing ticked unless a case sets $script:multiPattern ([9]: the install/uninstall test).
$script:multiPattern = $null
function Read-SpectreMultiSelection { param($Message, $Choices, $Color, [switch]$AllowEmpty) if ($script:multiPattern) { @($Choices | Where-Object { $_ -like $script:multiPattern }) } else { @() } }
function Read-SpectreConfirm { param($Message, $DefaultAnswer) $Message -eq 'Build this now?' }
function Get-WingetAppDetails { param($AppId) 'x64' }
function Get-Win32ToolkitTemplateChoice { param($BasePath) 'Contoso' }
function Show-Win32ToolkitDependencyPicker { param($BasePath) @() }
$script:biResolved = 'Sandbox'
function Get-Win32ToolkitBackendInfo { [pscustomobject]@{ Label = $(if ($script:biResolved -eq 'HyperV') { 'Hyper-V VM (vm-test)' } else { 'Windows Sandbox' }); Resolved = $script:biResolved; FellBack = $false; Reasons = @() } }
# TUI audit G3 (C-9): the Review panel names the ticked test's effective mode (config value per backend; shadowed).
$script:cfg = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
function Get-Win32ToolkitTestMode {
    param($Backend, [switch]$Unattended, $TestMode)
    $n = if ($Backend -eq 'HyperV') { 'HyperVTestMode' } else { 'SandboxTestMode' }
    if ($Unattended -or $TestMode -eq 'Unattended' -or (Get-Win32ToolkitConfigValue -Name $n -Default 'Interactive') -eq 'Unattended') { 'Unattended' } else { 'Interactive' }
}
$script:apps = @()
function Search-WingetApps { param($SearchTerm) $script:apps }

$script:techAsked = 0; $script:techMessage = ''; $script:techChoices = @(); $script:techPick = 0
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, [switch]$EnableSearch, $PageSize)
    if ([string]$Message -like 'Installer technology*') {
        $script:techAsked++; $script:techMessage = [string]$Message; $script:techChoices = @($Choices)
        return @($Choices)[$script:techPick]
    }
    return @($Choices)[0]
}

$script:anchor = $null; $script:lookupArgs = $null; $script:lookupCalls = 0
function Get-Win32ToolkitPreviousProject {
    [CmdletBinding()]
    param($TemplateDirectory, $Version, $WingetId, $Vendor, $DisplayName, $ExcludePath, $TenantId)
    $script:lookupCalls++; $script:lookupArgs = $PSBoundParameters
    [pscustomobject]@{ Anchor = $script:anchor; HighestUnanchored = $null; Matches = @(); AmbiguousIds = @() }
}
# The rebuild self-anchor (C-9): the would-be project folder, when it already exists and is published or pinned.
$script:selfAnchor = $null; $script:selfArgs = $null; $script:selfCalls = 0
function Get-Win32ToolkitSelfAnchor {
    [CmdletBinding()]
    param($ProjectPath, $TenantId)
    $script:selfCalls++; $script:selfArgs = $PSBoundParameters
    $script:selfAnchor
}
$script:probe = $null; $script:probeArgs = $null; $script:probeCalls = 0
function Get-Win32ToolkitSiblingInstaller {
    [CmdletBinding()]
    param($WingetId, $Version, $Architecture, $PackagedType, $TimeoutSec, $BaseUri, [switch]$NoMemo)
    $script:probeCalls++; $script:probeArgs = $PSBoundParameters
    $script:probe
}
$script:invokeArgs = $null
function Invoke-Win32Toolkit {
    # C-9 (TUI audit G5): the wizard always passes -NoPublishPrompt.
    param($Id, $Architecture, $TemplateName, $BasePath, [switch]$Force, $DependsOn, $RunTest, [switch]$PackageIntune, [switch]$PublishIntune, $InstallerType, [switch]$NoPublishPrompt)
    $script:invokeArgs = $PSBoundParameters
}

function New-Anchor([string]$Type, [string]$Reason = 'published', [string]$Name = 'Notepad++_x64_8.8.9') {
    [pscustomobject]@{ Name = $Name; Template = 'Contoso'; Path = "C:\x\$Name"; Version = '8.8.9'; WingetId = 'Notepad++.Notepad++'; InstallerType = $Type
                       Family = (Get-Win32ToolkitInstallerFamily -Type $Type).Family; PinnedBy = 'winget-default'; Published = ($Reason -eq 'published')
                       Anchored = $true; AnchorReason = $Reason; MatchedBy = 'WingetId' }
}
function Invoke-Wizard {
    param($App, $Probe, $Anchor, [int]$Pick = 0, $Self = $null)
    $script:apps = @($App); $script:probe = $Probe; $script:anchor = $Anchor; $script:techPick = $Pick
    $script:selfAnchor = $Self; $script:selfCalls = 0; $script:selfArgs = $null
    $script:techAsked = 0; $script:techChoices = @(); $script:techMessage = ''; $script:invokeArgs = $null
    $script:lookupCalls = 0; $script:probeCalls = 0; $script:lookupArgs = $null; $script:probeArgs = $null
    $script:hostLines.Clear(); $script:panels.Clear()
    Invoke-Win32ToolkitWingetWizard -BasePath $BASE 6>$null 3>$null
    $script:invokeArgs
}
function App([string]$Name, [string]$Id, [string]$Ver) { [pscustomobject]@{ Name = $Name; Id = $Id; Version = $Ver; Source = 'winget' } }
$npp = App 'Notepad++' 'Notepad++.Notepad++' '8.9.8.1'
$grey = { param([string]$Pattern) @($script:hostLines | Where-Object { $_ -like '`[grey`]*' -and $_ -match $Pattern }).Count -ge 1 }
$yellow = { param([string]$Pattern) @($script:hostLines | Where-Object { $_ -like '`[yellow`]*' -and $_ -match $Pattern }).Count -ge 1 }
function HasType($a) { $a -and $a.ContainsKey('InstallerType') }

try {
    # == [1] no anchor + two families ======================================================================
    Write-Host '[1] no anchor + two families -> asked once, the choice is passed as -InstallerType' -ForegroundColor Cyan
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor $null -Pick 1
    $labels = @($script:techChoices)
    if ($script:techAsked -eq 1 -and $labels.Count -eq 2) { Ok "asked once with two choices: $($labels -join ' | ')" } else { Bad "asked=$script:techAsked choices=[$($labels -join ' | ')]" }
    if ($labels[0] -eq "wix (MSI) - winget's default" -and $labels[1] -eq 'nullsoft (vendor EXE, NSIS)') { Ok "the highest-precedence family is marked winget's default (wix), nullsoft second" } else { Bad "labels=[$($labels -join ' | ')]" }
    if (-not @($labels | Where-Object { $_ -match '(?i)let winget' }).Count) { Ok 'no "Let winget choose" choice' } else { Bad 'a "Let winget choose" choice exists' }
    if ((HasType $a) -and $a['InstallerType'] -eq 'nullsoft') { Ok 'nullsoft chosen -> Invoke-Win32Toolkit -InstallerType nullsoft (PinnedBy parameter, L3)' } else { Bad "invoke InstallerType=[$($a['InstallerType'])]" }
    if (& $grey 'two registrations; pick the one your devices already have') { Ok 'grey hint about two registrations' } else { Bad "host lines: $($script:hostLines -join ' || ')" }
    if (($script:panels -join "`n") -match 'Installer tech : nullsoft \(your choice\)') { Ok "summary row 'Installer tech : nullsoft (your choice)'" } else { Bad "panels: $($script:panels -join ' || ')" }
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor $null -Pick 0
    if ((HasType $a) -and $a['InstallerType'] -eq 'wix') { Ok "choosing winget's default (wix) still pins it: -InstallerType wix" } else { Bad "invoke InstallerType=[$($a['InstallerType'])]" }

    # == [2] anchor + two families =========================================================================
    Write-Host '[2] anchor + two families -> Keep first; Keep passes nothing, the other family passes its pin value' -ForegroundColor Cyan
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor (New-Anchor 'nullsoft') -Pick 0
    $labels = @($script:techChoices)
    if ($script:techAsked -eq 1 -and $labels[0] -eq 'Keep nullsoft (vendor EXE, NSIS) (recommended: Notepad++_x64_8.8.9 is published)' -and $labels.Count -eq 2 -and $labels[1] -eq 'Switch to wix (MSI)') { Ok "choices: '$($labels -join "' / '")'" } else { Bad "asked=$script:techAsked choices=[$($labels -join ' | ')]" }
    if (-not @($labels | Where-Object { $_ -match "(?i)let winget|winget's default" }).Count) { Ok "no ""Let winget choose"" (the resolver would pin the anchor anyway)" } else { Bad 'a winget-choice option is offered next to an anchor' }
    if ($script:techMessage -eq 'Installer technology for Notepad++ in this tenant') { Ok "the question: 'Installer technology for Notepad++ in this tenant'" } else { Bad "message=[$script:techMessage]" }
    if ($a -and -not (HasType $a)) { Ok 'Keep -> NO -InstallerType (Invoke-Win32Toolkit pins the anchor as continuity)' } else { Bad "invoke InstallerType=[$($a['InstallerType'])]" }
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor (New-Anchor 'nullsoft') -Pick 1
    if ((HasType $a) -and $a['InstallerType'] -eq 'wix') { Ok 'the other family -> -InstallerType wix' } else { Bad "invoke InstallerType=[$($a['InstallerType'])]" }
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor (New-Anchor 'wix' 'pinned:parameter' 'Notepad++_x64_8.9.6') -Pick 0
    if ($script:techChoices[0] -eq 'Keep wix (MSI) (recommended: Notepad++_x64_8.9.6 is pinned)' -and -not (HasType $a)) { Ok "a pinned anchor: 'Keep wix (MSI) (recommended: ... is pinned)', Keep passes nothing" } else { Bad "choices=[$($script:techChoices -join ' | ')]" }

    # == [2b] rebuilding a version that is itself published or pinned =====================================
    # Invoke-Win32Toolkit reads the same self-anchor before Create-PSADTProject deletes the folder and pins
    # it, so the wizard names the project itself and 'Keep' still passes nothing (L3).
    Write-Host '[2b] the would-be project exists and is published / pinned -> it is the anchor (rebuilding it)' -ForegroundColor Cyan
    $selfWix = [pscustomobject]@{ Name = 'Notepad++_x64_8.9.8.1'; Path = 'C:\x\Notepad++_x64_8.9.8.1'; InstallerType = 'wix'; Family = 'msi'; PinnedBy = 'winget-default'
                                  Published = $true; Anchored = $true; AnchorReason = 'published' }
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor (New-Anchor 'nullsoft' 'published' 'Notepad++_x64_8.9.7') -Self $selfWix -Pick 0
    $labels = @($script:techChoices)
    if ($script:techAsked -eq 1 -and $labels.Count -eq 2 -and $labels[0] -eq 'Keep wix (MSI) (recommended: Notepad++_x64_8.9.8.1 is published; rebuilding it)' -and $labels[1] -eq 'Switch to nullsoft (vendor EXE, NSIS)') {
        Ok "a published wix 8.9.8.1 being rebuilt (published nullsoft 8.9.7 too): '$($labels -join "' / '")'"
    } else { Bad "asked=$script:techAsked choices=[$($labels -join ' | ')]" }
    if ($a -and -not (HasType $a)) { Ok 'Keep -> NO -InstallerType (the resolver pins the self-anchor, so the label is true)' } else { Bad "invoke InstallerType=[$($a['InstallerType'])]" }
    $wouldBeDir = Join-Path $BASE 'Projects\Contoso\Notepad++_x64_8.9.8.1'
    if ($script:selfCalls -eq 1 -and $script:selfArgs['ProjectPath'] -eq $wouldBeDir -and $script:selfArgs['TenantId'] -eq 'tenant-1' -and $script:lookupCalls -eq 0) { Ok 'the self-anchor is read for the would-be project with the template tenant; no predecessor lookup then' } else { Bad "self calls=$script:selfCalls args=$(($script:selfArgs.Keys | ForEach-Object { "$_=$($script:selfArgs[$_])" }) -join '; ') lookups=$script:lookupCalls" }
    if (($script:panels -join "`n") -match [regex]::Escape('Installer tech : keeps wix (Notepad++_x64_8.9.8.1 is published; rebuilding it)')) { Ok "summary row 'keeps wix (... is published; rebuilding it)'" } else { Bad "panels: $($script:panels -join ' || ')" }
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor (New-Anchor 'nullsoft' 'published' 'Notepad++_x64_8.9.7') -Self $selfWix -Pick 1
    if ((HasType $a) -and $a['InstallerType'] -eq 'nullsoft') { Ok 'Switch to nullsoft -> -InstallerType nullsoft' } else { Bad "invoke InstallerType=[$($a['InstallerType'])]" }
    $a = Invoke-Wizard -App $npp -Probe $probeWix -Anchor $null -Self $selfWix
    if ($script:techAsked -eq 0 -and $a -and -not (HasType $a) -and (& $grey 'Installer technology: keeps wix \(Notepad\+\+_x64_8\.9\.8\.1 is published; rebuilding it\)\.')) { Ok 'self-anchor + one family -> not asked, grey keeps line names the project itself' } else { Bad "asked=$script:techAsked lines: $($script:hostLines -join ' || ')" }
    $selfPin = [pscustomobject]@{ Name = 'Notepad++_x64_8.9.8.1'; Path = 'C:\x\Notepad++_x64_8.9.8.1'; InstallerType = 'nullsoft'; Family = 'exe'; PinnedBy = 'parameter'
                                  Published = $false; Anchored = $true; AnchorReason = 'pinned:parameter' }
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor $null -Self $selfPin -Pick 0
    if (@($script:techChoices)[0] -eq 'Keep nullsoft (vendor EXE, NSIS) (recommended: Notepad++_x64_8.9.8.1 is pinned; rebuilding it)' -and $a -and -not (HasType $a)) { Ok "a pinned self: 'Keep nullsoft ... (recommended: ... is pinned; rebuilding it)', Keep passes nothing" } else { Bad "choices=[$($script:techChoices -join ' | ')]" }
    $null = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor (New-Anchor 'nullsoft') -Pick 0
    if ($script:selfCalls -eq 1 -and $script:lookupCalls -eq 1 -and @($script:techChoices)[0] -eq 'Keep nullsoft (vendor EXE, NSIS) (recommended: Notepad++_x64_8.8.9 is published)') { Ok 'no self-anchor (a new project, or one that anchors nothing) -> the predecessor lookup as before' } else { Bad "self=$script:selfCalls lookup=$script:lookupCalls choices=[$($script:techChoices -join ' | ')]" }

    # == [3] anchor + one family / probe unavailable =======================================================
    Write-Host '[3] anchor + one family or no probe answer -> not asked, grey keeps line' -ForegroundColor Cyan
    $tv = App 'TeamViewer' 'TeamViewer.TeamViewer' '15.82.6'
    $a = Invoke-Wizard -App $tv -Probe $probeTv -Anchor (New-Anchor 'nullsoft' 'published' 'TeamViewer_x64_15.80.0')
    if ($script:techAsked -eq 0 -and $a -and -not (HasType $a) -and (& $grey 'Installer technology: keeps nullsoft \(TeamViewer_x64_15\.80\.0 is published\)\.')) { Ok 'anchor + one family -> not asked, grey line, no -InstallerType' } else { Bad "asked=$script:techAsked type=[$($a['InstallerType'])] lines: $($script:hostLines -join ' || ')" }
    $a = Invoke-Wizard -App $npp -Probe $probeDown -Anchor (New-Anchor 'nullsoft')
    if ($script:techAsked -eq 0 -and $a -and -not (HasType $a) -and (& $grey 'keeps nullsoft \(Notepad\+\+_x64_8\.8\.9 is published\)')) { Ok 'anchor + probe unavailable -> not asked, grey keeps line, no -InstallerType' } else { Bad "asked=$script:techAsked lines: $($script:hostLines -join ' || ')" }

    # == [3b] anchor family not shipped by this version (probe Ok) ==========================================
    Write-Host '[3b] the probe answers and the anchor family is not shipped -> no keeps line, asked: skip / switch / keep' -ForegroundColor Cyan
    $skipC = 'Skip this version (recommended)'
    $keepNs = 'Keep nullsoft (vendor EXE, NSIS) (not offered for this version: the build will stop)'
    $a = Invoke-Wizard -App $npp -Probe $probeWix -Anchor (New-Anchor 'nullsoft') -Pick 1
    $labels = @($script:techChoices)
    if (-not (& $grey 'keeps nullsoft') -and -not @($script:hostLines | Where-Object { $_ -match 'keeps' }).Count) { Ok "anchor nullsoft + wix-only version: no 'keeps nullsoft' line" } else { Bad "lines: $($script:hostLines -join ' || ')" }
    if (& $yellow ('^\[yellow\]' + [regex]::Escape('winget does not ship nullsoft (vendor EXE, NSIS) for this version (x64), the technology of Notepad++_x64_8.8.9 (published): keeping it will stop the build (W32T.InstallerVariantUnavailable). Skipping this version is recommended; switching gives devices that already have it a second registration.') + '\[/\]$')) { Ok 'one yellow line: not shipped, keeping stops the build (W32T.InstallerVariantUnavailable), skipping recommended, switching = second registration' } else { Bad "lines: $($script:hostLines -join ' || ')" }
    if ($script:techAsked -eq 1 -and $labels.Count -eq 3 -and $labels[0] -eq $skipC -and $labels[1] -eq 'Switch to wix (MSI)' -and $labels[2] -eq $keepNs) { Ok "asked once: '$($labels -join "' / '")'" } else { Bad "asked=$script:techAsked choices=[$($labels -join ' | ')]" }
    if (-not @($labels | Where-Object { $_ -match '^Keep .*recommended' }).Count) { Ok "Keep is not offered as 'recommended'" } else { Bad "choices=[$($labels -join ' | ')]" }
    if ((HasType $a) -and $a['InstallerType'] -eq 'wix') { Ok "'Switch to wix (MSI)' -> -InstallerType wix" } else { Bad "invoke InstallerType=[$($a['InstallerType'])]" }
    if (($script:panels -join "`n") -match [regex]::Escape('Installer tech : wix (your choice; the earlier version is nullsoft)')) { Ok "summary row 'Installer tech : wix (your choice; the earlier version is nullsoft)'" } else { Bad "panels: $($script:panels -join ' || ')" }
    $a = Invoke-Wizard -App $npp -Probe $probeWix -Anchor (New-Anchor 'nullsoft') -Pick 2
    if ($a -and -not (HasType $a) -and ($script:panels -join "`n") -match [regex]::Escape('keeps nullsoft (Notepad++_x64_8.8.9 is published; not offered for this version: the build will stop)')) { Ok 'Keep anyway -> NO -InstallerType; the summary says the build will stop' } else { Bad "type=[$($a['InstallerType'])] panels: $($script:panels -join ' || ')" }
    $a = Invoke-Wizard -App $npp -Probe $probeWix -Anchor (New-Anchor 'nullsoft') -Pick 0
    if ($null -eq $a -and @($script:hostLines | Where-Object { $_ -like '`[yellow`]Skipped: nothing was built.*' }).Count -eq 1) { Ok 'Skip this version -> Invoke-Win32Toolkit is not called' } else { Bad "invoke=[$($a | Out-String)] lines: $($script:hostLines -join ' || ')" }
    # anchor + two families, neither is the anchor's: no 'Keep ... (recommended' first; every family is a switch.
    $a = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor (New-Anchor 'msix' 'pinned:parameter' 'Notepad++_x64_8.9.0') -Pick 2
    $labels = @($script:techChoices)
    if ($labels.Count -eq 4 -and $labels[0] -eq $skipC -and $labels[1] -eq 'Switch to wix (MSI)' -and $labels[2] -eq 'Switch to nullsoft (vendor EXE, NSIS)' -and
        $labels[3] -eq 'Keep msix (MSIX package) (not offered for this version: the build will stop)' -and (HasType $a) -and $a['InstallerType'] -eq 'nullsoft') {
        Ok "anchor msix + wix/nullsoft: skip, two switches, keep last; 'Switch to nullsoft' -> -InstallerType nullsoft"
    } else { Bad "choices=[$($labels -join ' | ')] type=[$($a['InstallerType'])]" }
    if (& $yellow 'does not ship msix .* Notepad\+\+_x64_8\.9\.0 \(pinned\)') { Ok 'the yellow line names the pinned anchor' } else { Bad "lines: $($script:hostLines -join ' || ')" }
    # the anchor family is shipped only zip-wrapped (TeamViewer's MSI): it cannot be packaged either.
    $a = Invoke-Wizard -App $tv -Probe $probeTv -Anchor (New-Anchor 'wix' 'published' 'TeamViewer_x64_15.80.0') -Pick 1
    if ($script:techAsked -eq 1 -and @($script:techChoices)[1] -eq 'Switch to nullsoft (vendor EXE, NSIS)' -and (HasType $a) -and $a['InstallerType'] -eq 'nullsoft' -and
        (& $yellow 'ships wix \(MSI\) for this version \(x64\) only in a form that cannot be packaged, the technology of TeamViewer_x64_15\.80\.0 \(published\): keeping it will stop the build\. Skipping')) {
        Ok 'anchor wix, only a zip-wrapped MSI shipped -> the same question, the line says it cannot be packaged'
    } else { Bad "asked=$script:techAsked choices=[$($script:techChoices -join ' | ')] lines: $($script:hostLines -join ' || ')" }
    # hostile anchor name: escaped in the yellow line
    $null = Invoke-Wizard -App $npp -Probe $probeWix -Anchor (New-Anchor 'nullsoft' 'published' 'Evil[blink]_x64_1.0') -Pick 0
    if (& $yellow ([regex]::Escape('the technology of Evil[[blink]]_x64_1.0 (published)'))) { Ok 'a hostile anchor name is escaped in the yellow line' } else { Bad "lines: $($script:hostLines -join ' || ')" }

    # == [4] no anchor + one family / probe unavailable =====================================================
    Write-Host '[4] no anchor + one family or no probe answer -> not asked, no -InstallerType' -ForegroundColor Cyan
    $a = Invoke-Wizard -App $tv -Probe $probeTv -Anchor $null
    if ($script:techAsked -eq 0 -and $a -and -not (HasType $a)) { Ok 'TeamViewer (nullsoft + zip-wrapped MSI) is a single-family app: not asked' } else { Bad "asked=$script:techAsked type=[$($a['InstallerType'])]" }
    if (& $grey 'winget also ships wix \(MSI\), zip-wrapped for x64: it cannot be packaged') { Ok 'the zip-wrapped MSI is listed in grey as "cannot be packaged", never selectable' } else { Bad "lines: $($script:hostLines -join ' || ')" }
    $git = App 'Git' 'Git.Git' '2.55.0'
    $a = Invoke-Wizard -App $git -Probe $probeGit -Anchor $null
    if ($script:techAsked -eq 0 -and $a -and -not (HasType $a) -and (& $grey 'winget ships inno \(vendor EXE, Inno Setup\) for this version; nothing to choose')) { Ok 'Git (inno only) -> not asked, grey line, no -InstallerType' } else { Bad "asked=$script:techAsked lines: $($script:hostLines -join ' || ')" }
    $a = Invoke-Wizard -App $npp -Probe $probeDown -Anchor $null
    if ($script:techAsked -eq 0 -and $a -and -not (HasType $a) -and (& $grey "winget's choice \(the other technologies could not be checked: Network\)")) { Ok 'probe unavailable -> not asked, grey line names the reason' } else { Bad "asked=$script:techAsked lines: $($script:hostLines -join ' || ')" }

    # == [5] msix family =================================================================================
    Write-Host '[5] msix family whose top testable tuple is appx -> passes msix' -ForegroundColor Cyan
    $ax = App 'Contoso AppxSibling' 'Contoso.AppxSibling' '3.1.0'
    $a = Invoke-Wizard -App $ax -Probe $probeAppx -Anchor $null -Pick 0
    if ($script:techAsked -eq 1 -and $script:techChoices[0] -eq "appx (APPX package) - winget's default" -and (HasType $a) -and $a['InstallerType'] -eq 'msix') { Ok 'appx + exe: the appx family choice passes -InstallerType msix' } else { Bad "asked=$script:techAsked choices=[$($script:techChoices -join ' | ')] type=[$($a['InstallerType'])]" }
    $st = App 'Contoso Store' 'Contoso.Store' '1.0'
    $a = Invoke-Wizard -App $st -Probe $probeStore -Anchor $null -Pick 0
    if ($script:techAsked -eq 1 -and $script:techChoices.Count -eq 2 -and (HasType $a) -and $a['InstallerType'] -eq 'msix' -and -not (& $grey 'msstore')) { Ok 'msstore + appx: one msix choice (passes msix); msstore is not listed as unpackageable (its family can be packaged)' } else { Bad "choices=[$($script:techChoices -join ' | ')] type=[$($a['InstallerType'])]" }

    # == [6] version unknown =============================================================================
    Write-Host "[6] version 'Unknown' -> no probe, no lookup, grey line" -ForegroundColor Cyan
    $a = Invoke-Wizard -App (App 'Git' 'Git.Git' 'Unknown') -Probe $probeGit -Anchor (New-Anchor 'inno')
    if ($script:probeCalls -eq 0 -and $script:lookupCalls -eq 0 -and $script:techAsked -eq 0 -and $a -and -not (HasType $a)) { Ok 'no probe request, no predecessor lookup, not asked, no -InstallerType' } else { Bad "probe=$script:probeCalls lookup=$script:lookupCalls asked=$script:techAsked" }
    if (& $grey '^\[grey\]Installer technology: not checked \(version unknown\); the checks after the download still run\.\[/\]$') { Ok 'grey line: "Installer technology: not checked (version unknown); the checks after the download still run."' } else { Bad "lines: $($script:hostLines -join ' || ')" }

    # == [7] arguments, summary, escaping ==================================================================
    Write-Host '[7] lookup/probe arguments, summary row, escaping' -ForegroundColor Cyan
    $null = Invoke-Wizard -App $npp -Probe $probeNpp -Anchor $null -Pick 1
    $la = $script:lookupArgs; $pa = $script:probeArgs
    $tplDir = Join-Path $BASE 'Projects\Contoso'
    if ($la['TemplateDirectory'] -eq $tplDir -and $la['WingetId'] -eq 'Notepad++.Notepad++' -and $la['Version'] -eq '8.9.8.1' -and
        $la['ExcludePath'] -eq (Join-Path $tplDir 'Notepad++_x64_8.9.8.1') -and $la['TenantId'] -eq 'tenant-1' -and -not $la.ContainsKey('Vendor')) {
        Ok 'lookup: template folder, winget id, version, the would-be project excluded, the template tenant; no Vendor/DisplayName'
    } else { Bad "lookup args: $(($la.Keys | ForEach-Object { "$_=$($la[$_])" }) -join '; ')" }
    if ($pa['WingetId'] -eq 'Notepad++.Notepad++' -and $pa['Version'] -eq '8.9.8.1' -and $pa['Architecture'] -eq 'x64' -and -not $pa.ContainsKey('PackagedType')) { Ok 'probe: id, version, architecture, no -PackagedType (every family before the download)' } else { Bad "probe args: $(($pa.Keys | ForEach-Object { "$_=$($pa[$_])" }) -join '; ')" }
    if (& $grey 'Checking which installer technologies winget ships for Notepad\+\+\.Notepad\+\+ 8\.9\.8\.1 \(x64\)') { Ok 'grey "Checking which installer technologies ..." line' } else { Bad "lines: $($script:hostLines -join ' || ')" }

    $evil = App 'Evil[red]App' 'Evil.App' '2.0'
    $null = Invoke-Wizard -App $evil -Probe $probeNpp -Anchor (New-Anchor 'nullsoft' 'published' 'Evil[blink]_x64_1.0') -Pick 0
    if ($script:techMessage -eq 'Installer technology for Evil[[red]]App in this tenant' -and $script:techChoices[0] -eq 'Keep nullsoft (vendor EXE, NSIS) (recommended: Evil[[blink]]_x64_1.0 is published)') { Ok 'hostile app and project names are escaped in the question and the choices' } else { Bad "message=[$script:techMessage] choices=[$($script:techChoices -join ' | ')]" }
    if (($script:panels -join "`n") -match [regex]::Escape('Installer tech : keeps nullsoft (Evil[[blink]]_x64_1.0 is published)')) { Ok 'the summary row is escaped with the rest of the review panel' } else { Bad "panels: $($script:panels -join ' || ')" }

    # == [8] source hygiene ==============================================================================
    Write-Host '[8] the wizard: every new catch starts with the C-2 line; Get-Content passes -Encoding' -ForegroundColor Cyan
    $wFile = Join-Path $repo 'Private\Invoke-Win32ToolkitWingetWizard.ps1'
    $wAst = [System.Management.Automation.Language.Parser]::ParseFile($wFile, [ref]$null, [ref]$null)
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    $tplTry = @($wAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match 'TenantId' }, $true))
    if ($tplTry.Count -eq 1 -and $tplTry[0].CatchClauses[0].Body.Statements[0].Extent.Text -ceq $c2) { Ok 'the template-tenant read catch starts with the C-2 line (K1)' } else { Bad 'template-tenant catch' }
    $gc = @($wAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Content' }, $true))
    if ($gc.Count -ge 1 -and @($gc | Where-Object { $_.Extent.Text -notmatch '-Encoding UTF8' }).Count -eq 0) { Ok 'every Get-Content passes -Encoding UTF8' } else { Bad 'Get-Content without -Encoding' }

    # == [9] the Review panel's Test mode row (TUI audit G3) =================================================
    Write-Host '[9] the Review panel names the ticked test''s effective mode; no row without the test' -ForegroundColor Cyan
    $testRow = { @(($script:panels -join "`n") -split "`n" | Where-Object { $_ -like 'Test mode    : *' }) }
    $script:biResolved = 'HyperV'; $script:cfg = @{ HyperVTestMode = 'Unattended' }; $script:multiPattern = 'Run an install/uninstall test*'
    $a = Invoke-Wizard -App $git -Probe $probeGit -Anchor $null
    $rows = @(& $testRow)
    if ($a -and $a['RunTest'] -eq 'InstallUninstall' -and $rows.Count -eq 1 -and $rows[0] -ceq 'Test mode    : Unattended (HyperVTestMode = Unattended)') { Ok "test ticked + HyperVTestMode=Unattended (Hyper-V): '$($rows[0])'" } else { Bad "rows=[$($rows -join ' | ')] runTest=$($a['RunTest'])" }
    $script:biResolved = 'Sandbox'; $script:cfg = @{ HyperVTestMode = 'Unattended' }
    $null = Invoke-Wizard -App $git -Probe $probeGit -Anchor $null
    $rows = @(& $testRow)
    if ($rows.Count -eq 1 -and $rows[0] -ceq 'Test mode    : Interactive (default)') { Ok "Sandbox runs the test: the Sandbox value counts (HyperVTestMode does not): '$($rows[0])'" } else { Bad "rows=[$($rows -join ' | ')]" }
    $script:multiPattern = $null
    $null = Invoke-Wizard -App $git -Probe $probeGit -Anchor $null
    if (@(& $testRow).Count -eq 0 -and ($script:panels -join "`n") -match 'Test/capture : ') { Ok 'test not ticked -> no Test mode row' } else { Bad "panels: $($script:panels -join ' || ')" }

    # The manual wizard's Review panel carries the same row (driven up to the panel; 'Continue?' is answered no).
    . (Join-Path $repo 'Private\Invoke-Win32ToolkitManualWizard.ps1')
    function Read-Win32ToolkitValidatedText { param($Message, $Validator, $ErrorMessage, [switch]$AllowEmpty) if ($Message -like 'Full path*') { 'C:\x\setup.msi' } elseif ($AllowEmpty) { '' } else { '1.0' } }
    $script:biResolved = 'Sandbox'; $script:cfg = @{ SandboxTestMode = 'Unattended' }; $script:multiPattern = 'Run an install/uninstall test*'
    $script:panels.Clear()
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    $rows = @(& $testRow)
    if ($rows.Count -eq 1 -and $rows[0] -ceq 'Test mode    : Unattended (SandboxTestMode = Unattended)') { Ok "manual wizard, test ticked + SandboxTestMode=Unattended: '$($rows[0])'" } else { Bad "manual rows=[$($rows -join ' | ')] panels: $($script:panels -join ' || ')" }
    $script:multiPattern = $null; $script:panels.Clear()
    Invoke-Win32ToolkitManualWizard -BasePath $BASE 6>$null 3>$null
    if (@(& $testRow).Count -eq 0 -and ($script:panels -join "`n") -match 'Test/capture : ') { Ok 'manual wizard, test not ticked -> no Test mode row' } else { Bad "manual panels: $($script:panels -join ' || ')" }
    $script:cfg = @{}; $script:biResolved = 'Sandbox'
}
finally {
    Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All WingetWizardTechnology tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail WingetWizardTechnology test(s) FAILED." -ForegroundColor Red
exit 1
