<#
    Installer-identity PR 1 (spec 2.8): Get-Win32ToolkitPreviousProject, the predecessor lookup.

      - match by winget id, else by Vendor + DisplayName (across ids);
      - only strictly LOWER versions (4 numeric parts, 8.9.10 > 8.9.9, 'v' prefix tolerated);
      - anchored = published (per tenant with -TenantId) or persisted Source.PinnedBy parameter/operator;
        'continuity' alone does not anchor; Anchor = the highest anchored, HighestUnanchored above it;
      - AmbiguousIds = the winget ids sharing this app's Vendor + DisplayName;
      - ExcludePath, unreadable AppConfig, missing folders: skipped, never a throw.

    A temp template folder with fake projects (AppConfig.json, Intune\Publications.json, optional manifest);
    the real Get-Win32ToolkitProjectSource supplies InstallerType/Family (Get-Win32ToolkitMsiProperty is
    shadowed: no COM).

    Run:  pwsh -File Tests\PreviousProject.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Get-Win32ToolkitPreviousProject', 'Get-Win32ToolkitProjectSource', 'Get-Win32ToolkitInstallerFamily',
               'ConvertTo-Win32ToolkitSafeText', 'Get-Win32ToolkitAppConfig', 'Get-WingetIdFromProject', 'Get-WingetManifestFile',
               'Get-Win32ToolkitPublication', 'Get-YAMLInstallerInfo', 'Get-InstallerFileInfo', 'Get-Win32ToolkitInstallerExtension') {
    . (Join-Path $repo "Private\$f.ps1")
}
function Get-Win32ToolkitMsiProperty { [CmdletBinding()] param([string]$Path, [string]$Property) '' }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32prev_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}
# A fake project: Invoke-AppDeployToolkit.ps1 + SupportFiles\AppConfig.json (+ Source, publications, manifest).
function New-FakeProject {
    param(
        [string]$Template, [string]$Name, [string]$Version, [string]$Vendor = 'Contoso', [string]$DisplayName = 'Contoso App',
        [string]$ScriptAuthor = 'Contoso IT', [string]$ScriptDate = '2026-10-01', [string]$WingetId = '', [string]$Type = 'nullsoft',
        [string]$PinnedBy = '', [string[]]$PublishedTenants = @(), [string]$ManifestId = '', [switch]$NoScript, [string]$RawConfig
    )
    $p = Join-Path (Join-Path $tmpRoot $Template) $Name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    if (-not $NoScript) { Write-Text (Join-Path $p 'Invoke-AppDeployToolkit.ps1') '# fake' }
    if ($RawConfig) { Write-Text (Join-Path $p 'SupportFiles\AppConfig.json') $RawConfig; return $p }
    $cfg = [ordered]@{
        SchemaVersion = '1.0'
        App           = [ordered]@{ Vendor = $Vendor; Name = ''; DisplayName = $DisplayName; Version = $Version; Arch = 'x64'; ScriptAuthor = $ScriptAuthor; ScriptDate = $ScriptDate }
        Installer     = [ordered]@{ Type = 'exe'; FileName = 'setup.exe'; SilentArgs = '/S' }
    }
    if ($WingetId) {
        $cfg.Source = [ordered]@{
            SchemaVersion = '1.0'; WingetId = $WingetId; Version = $Version; InstallerType = $Type
            Family = (Get-Win32ToolkitInstallerFamily -Type $Type).Family; Scope = 'machine'; Architecture = 'x64'; Locale = 'en-US'
            PinnedBy = $(if ($PinnedBy) { $PinnedBy } else { 'winget-default' }); RequestedInstallerType = ''; WingetClient = ''
            ProductCode = ''; UpgradeCode = ''; UpgradeBehavior = 'install'
        }
    }
    Write-Text (Join-Path $p 'SupportFiles\AppConfig.json') ($cfg | ConvertTo-Json -Depth 6)
    if ($ManifestId) {
        Write-Text (Join-Path $p "Files\$ManifestId.yaml") ("PackageIdentifier: $ManifestId`nPackageVersion: $Version`nInstallers:`n- Architecture: x64`n  InstallerType: $Type`n")
    }
    if ($PublishedTenants.Count) {
        $entries = @($PublishedTenants | ForEach-Object { [ordered]@{ TenantId = $_; AppId = [guid]::NewGuid().ToString(); DisplayName = $DisplayName; DisplayVersion = $Version; WingetId = $WingetId; PublishedUtc = '2026-10-01T00:00:00Z' } })
        Write-Text (Join-Path $p 'Intune\Publications.json') (ConvertTo-Json -InputObject ([object[]]$entries) -Depth 4)
    }
    $p
}
function Names($r) { (@($r.Matches) | ForEach-Object Name) -join ',' }

# --- [1] id match + published anchor ---------------------------------------------------------------
Write-Host '[1] Match by winget id; a published lower version anchors' -ForegroundColor Cyan
$t1 = 'T1'
$null = New-FakeProject -Template $t1 -Name 'App_x64_1.0' -Version '1.0' -WingetId 'Contoso.App' -Type 'nullsoft' -PublishedTenants 'tenant-a'
$null = New-FakeProject -Template $t1 -Name 'Other_x64_1.0' -Version '1.0' -WingetId 'Contoso.Other' -Vendor 'Contoso' -DisplayName 'Other'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot $t1) -Version '2.0' -WingetId 'contoso.app'
$a = $r.Anchor
if ($a -and $a.Name -eq 'App_x64_1.0' -and $a.MatchedBy -eq 'WingetId' -and $a.Published -and $a.Anchored -and $a.AnchorReason -eq 'published') {
    Ok 'Anchor = App_x64_1.0, MatchedBy WingetId (case-insensitive), published'
} else { Bad "Anchor = $($a | ConvertTo-Json -Compress)" }
if ($a.InstallerType -eq 'nullsoft' -and $a.Family -eq 'exe' -and $a.Template -eq 'T1' -and $a.Path -and $a.TattooKey -eq 'Contoso IT\Contoso\Contoso App' -and $a.Version -eq '1.0') {
    Ok 'the match carries InstallerType/Family (from its Source), Template, Path, TattooKey, Version'
} else { Bad "match fields: $($a | ConvertTo-Json -Compress)" }
if ((Names $r) -eq 'App_x64_1.0' -and $null -eq $r.HighestUnanchored) { Ok 'the other app does not match; HighestUnanchored $null' } else { Bad "matches: $(Names $r)" }

# --- [2] Vendor + DisplayName across ids ------------------------------------------------------------
Write-Host '[2] Match by Vendor + DisplayName across winget ids (PowerShell msi vs msix)' -ForegroundColor Cyan
$t2 = 'T2'
$null = New-FakeProject -Template $t2 -Name 'PowerShell_x64_7.5.0' -Version '7.5.0' -WingetId 'Microsoft.PowerShell' -Type 'wix' `
    -Vendor 'Microsoft Corporation' -DisplayName 'PowerShell 7-x64' -PublishedTenants 'tenant-a'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot $t2) -Version '7.6.0' -WingetId 'Contoso.PowerShell.Msix' `
    -Vendor 'MICROSOFT CORPORATION' -DisplayName 'powershell 7-x64'
if ($r.Anchor.Name -eq 'PowerShell_x64_7.5.0' -and $r.Anchor.MatchedBy -eq 'VendorDisplayName' -and $r.Anchor.Family -eq 'msi') { Ok 'MatchedBy VendorDisplayName (case-insensitive), Family msi' } else { Bad "V+DN: $($r.Anchor | ConvertTo-Json -Compress)" }
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot $t2) -Version '7.6.0' -WingetId 'Contoso.PowerShell.Msix' -Vendor 'Microsoft Corporation'
if (@($r.Matches).Count -eq 0) { Ok 'Vendor alone (no DisplayName) never matches' } else { Bad 'Vendor-only matched' }

# --- [3] higher unanchored vs lower published --------------------------------------------------------
Write-Host '[3] A higher UNANCHORED version vs a lower PUBLISHED one' -ForegroundColor Cyan
$t3 = 'T3'
$null = New-FakeProject -Template $t3 -Name 'App_1.0' -Version '1.0' -WingetId 'Contoso.App' -PublishedTenants 'tenant-a'
$null = New-FakeProject -Template $t3 -Name 'App_1.5' -Version '1.5' -WingetId 'Contoso.App' -Type 'wix'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot $t3) -Version '2.0' -WingetId 'Contoso.App'
if ($r.Anchor.Name -eq 'App_1.0' -and $r.HighestUnanchored.Name -eq 'App_1.5' -and -not $r.HighestUnanchored.Anchored -and (Names $r) -eq 'App_1.5,App_1.0') {
    Ok 'Anchor = App_1.0 (published), HighestUnanchored = App_1.5; Matches highest first'
} else { Bad "anchor $($r.Anchor.Name) / unanchored $($r.HighestUnanchored.Name) / matches $(Names $r)" }

# --- [4] pinned anchors, continuity does not ----------------------------------------------------------
Write-Host '[4] PinnedBy parameter/operator anchors; continuity alone does not' -ForegroundColor Cyan
$t4 = 'T4'
$null = New-FakeProject -Template $t4 -Name 'App_1' -Version '1.0' -WingetId 'Contoso.App' -PinnedBy 'parameter'
$null = New-FakeProject -Template $t4 -Name 'App_2' -Version '2.0' -WingetId 'Contoso.App' -PinnedBy 'continuity'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot $t4) -Version '3.0' -WingetId 'Contoso.App'
if ($r.Anchor.Name -eq 'App_1' -and $r.Anchor.AnchorReason -eq 'pinned:parameter' -and -not $r.Anchor.Published -and $r.HighestUnanchored.Name -eq 'App_2') {
    Ok 'v3 anchors on the pinned v1 through the unpinned continuity v2 (AnchorReason pinned:parameter)'
} else { Bad "pinned: $($r.Anchor | ConvertTo-Json -Compress)" }
$null = New-FakeProject -Template 'T4b' -Name 'App_1' -Version '1.0' -WingetId 'Contoso.App' -PinnedBy 'operator'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot 'T4b') -Version '3.0' -WingetId 'Contoso.App'
if ($r.Anchor.AnchorReason -eq 'pinned:operator') { Ok "PinnedBy 'operator' anchors (reserved value)" } else { Bad "operator: $($r.Anchor.AnchorReason)" }
$null = New-FakeProject -Template 'T4c' -Name 'App_1' -Version '1.0' -WingetId 'Contoso.App' -PinnedBy 'winget-default'
$null = New-FakeProject -Template 'T4c' -Name 'App_2' -Version '2.0' -ManifestId 'Contoso.App'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot 'T4c') -Version '3.0' -WingetId 'Contoso.App'
if ($null -eq $r.Anchor -and $r.HighestUnanchored.Name -eq 'App_2' -and @($r.Matches).Count -eq 2) { Ok 'winget-default and a pre-PR-1 project (id from its manifest) match but never anchor' } else { Bad "unanchored: $($r.Anchor.Name) / $($r.HighestUnanchored.Name) / $(Names $r)" }
if (($r.Matches | Where-Object Name -eq 'App_2').SourceRebuilt -and ($r.Matches | Where-Object Name -eq 'App_2').PinnedBy -eq 'winget-default') { Ok 'the pre-PR-1 match has a rebuilt Source (PinnedBy winget-default)' } else { Bad 'pre-PR-1 Source not rebuilt' }

# --- [5] tenant filter ------------------------------------------------------------------------------
Write-Host '[5] -TenantId filters publications (Dv4: without it any publication anchors)' -ForegroundColor Cyan
$t5 = Join-Path $tmpRoot 'T5'
$null = New-FakeProject -Template 'T5' -Name 'App_1' -Version '1.0' -WingetId 'Contoso.App' -PublishedTenants 'tenant-a'
$ra = Get-Win32ToolkitPreviousProject -TemplateDirectory $t5 -Version '2.0' -WingetId 'Contoso.App' -TenantId 'tenant-a'
$rb = Get-Win32ToolkitPreviousProject -TemplateDirectory $t5 -Version '2.0' -WingetId 'Contoso.App' -TenantId 'tenant-b'
$rn = Get-Win32ToolkitPreviousProject -TemplateDirectory $t5 -Version '2.0' -WingetId 'Contoso.App'
if ($ra.Anchor -and $null -eq $rb.Anchor -and $rb.HighestUnanchored.Name -eq 'App_1' -and $rn.Anchor) { Ok 'tenant-a anchors; tenant-b does not; no tenant -> any publication anchors' } else { Bad "tenant: a=$([bool]$ra.Anchor) b=$([bool]$rb.Anchor) none=$([bool]$rn.Anchor)" }

# --- [6] versions -------------------------------------------------------------------------------------
Write-Host '[6] Versions: only strictly lower; 8.9.10 > 8.9.9; v prefix; unparsable skipped' -ForegroundColor Cyan
$t6 = Join-Path $tmpRoot 'T6'
$null = New-FakeProject -Template 'T6' -Name 'App_8.9.9' -Version '8.9.9' -WingetId 'Contoso.App' -PublishedTenants 't'
$null = New-FakeProject -Template 'T6' -Name 'App_8.9.10' -Version '8.9.10' -WingetId 'Contoso.App' -PublishedTenants 't'
$null = New-FakeProject -Template 'T6' -Name 'App_v1.2' -Version 'v1.2' -WingetId 'Contoso.App' -PublishedTenants 't'
$null = New-FakeProject -Template 'T6' -Name 'App_unknown' -Version 'Unknown' -WingetId 'Contoso.App' -PublishedTenants 't'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t6 -Version '8.9.10' -WingetId 'Contoso.App'
if ((Names $r) -eq 'App_8.9.9,App_v1.2' -and $r.Anchor.Name -eq 'App_8.9.9') { Ok '8.9.10: 8.9.9 and v1.2 are lower, 8.9.10 (equal) ignored, Unknown skipped' } else { Bad "8.9.10 -> $(Names $r)" }
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t6 -Version '8.9.9' -WingetId 'Contoso.App'
if ((Names $r) -eq 'App_v1.2') { Ok '8.9.9: 8.9.10 is higher (numeric, not text) and ignored' } else { Bad "8.9.9 -> $(Names $r)" }
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t6 -Version '1.2.0.0' -WingetId 'Contoso.App'
if (@($r.Matches).Count -eq 0) { Ok "1.2.0.0 equals v1.2 (missing parts are 0) -> no match" } else { Bad "1.2.0.0 -> $(Names $r)" }
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t6 -Version 'Unknown' -WingetId 'Contoso.App'
if (@($r.Matches).Count -eq 0 -and $null -eq $r.Anchor) { Ok "new version 'Unknown' -> no predecessor" } else { Bad "Unknown -> $(Names $r)" }
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t6 -Version '9.0-beta1' -WingetId 'Contoso.App'
if (@($r.Matches).Count -eq 3) { Ok "'9.0-beta1' reads as 9.0 (leading numeric run)" } else { Bad "9.0-beta1 -> $(Names $r)" }

# --- [7] tie -> newest ScriptDate ---------------------------------------------------------------------
Write-Host '[7] Same version in two folders -> the newest App.ScriptDate is the anchor' -ForegroundColor Cyan
$null = New-FakeProject -Template 'T7' -Name 'App_old' -Version '1.0' -WingetId 'Contoso.App' -ScriptDate '2026-01-01' -PublishedTenants 't'
$null = New-FakeProject -Template 'T7' -Name 'App_new' -Version '1.0' -WingetId 'Contoso.App' -ScriptDate '2026-09-01' -PublishedTenants 't'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot 'T7') -Version '2.0' -WingetId 'Contoso.App'
if ($r.Anchor.Name -eq 'App_new') { Ok 'tie -> App_new (2026-09-01)' } else { Bad "tie -> $($r.Anchor.Name)" }

# --- [8] ExcludePath, unreadable, not a project, missing folder -----------------------------------------
Write-Host '[8] ExcludePath; unreadable AppConfig; folder without a deploy script; missing template folder' -ForegroundColor Cyan
$t8 = Join-Path $tmpRoot 'T8'
$self = New-FakeProject -Template 'T8' -Name 'App_1.0' -Version '1.0' -WingetId 'Contoso.App' -PublishedTenants 't'
$null = New-FakeProject -Template 'T8' -Name 'App_corrupt' -RawConfig '{ not : json ]['
$null = New-FakeProject -Template 'T8' -Name 'App_noscript' -Version '0.5' -WingetId 'Contoso.App' -PublishedTenants 't' -NoScript
$threw = $false
try { $r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t8 -Version '2.0' -WingetId 'Contoso.App' -ExcludePath ($self + '\') 3>$null } catch { $threw = $true }
if (-not $threw -and @($r.Matches).Count -eq 0) { Ok 'the excluded project (trailing \ tolerated), the corrupt AppConfig and the folder without a deploy script are all skipped, no throw' } else { Bad "threw=$threw matches=$(Names $r)" }
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t8 -Version '2.0' -WingetId 'Contoso.App' 3>$null
if ((Names $r) -eq 'App_1.0') { Ok 'without -ExcludePath the same project matches' } else { Bad "no exclude -> $(Names $r)" }
$threw = $false
try { $r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot 'missing') -Version '2.0' -WingetId 'Contoso.App' -ErrorAction Stop } catch { $threw = $true }
if (-not $threw -and $null -eq $r.Anchor -and @($r.Matches).Count -eq 0 -and @($r.AmbiguousIds).Count -eq 0) { Ok 'a missing template folder -> empty result, no throw' } else { Bad "missing folder: threw=$threw" }

# --- [9] AmbiguousIds ---------------------------------------------------------------------------------
Write-Host '[9] AmbiguousIds: winget ids that share this app''s Vendor + DisplayName (Chrome / Chrome.EXE)' -ForegroundColor Cyan
$t9 = Join-Path $tmpRoot 'T9'
$null = New-FakeProject -Template 'T9' -Name 'Chrome_msi' -Version '140.0' -WingetId 'Google.Chrome' -Type 'wix' -Vendor 'Google LLC' -DisplayName 'Google Chrome' -PublishedTenants 't'
$null = New-FakeProject -Template 'T9' -Name 'Chrome_exe' -Version '141.0' -WingetId 'Google.Chrome.EXE' -Type 'exe' -Vendor 'Google LLC' -DisplayName 'Google Chrome'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t9 -Version '142.0' -WingetId 'Google.Chrome' -Vendor 'Google LLC' -DisplayName 'Google Chrome'
$ids = (@($r.AmbiguousIds) | Sort-Object) -join ','
if ($ids -eq 'Google.Chrome,Google.Chrome.EXE') { Ok "AmbiguousIds = $ids" } else { Bad "AmbiguousIds = $ids" }
if ($r.Anchor.Name -eq 'Chrome_msi' -and $r.Anchor.MatchedBy -eq 'WingetId' -and $r.HighestUnanchored.Name -eq 'Chrome_exe' -and $r.HighestUnanchored.MatchedBy -eq 'VendorDisplayName') {
    Ok 'Anchor by id (Chrome_msi), the higher Chrome.EXE matched by Vendor + DisplayName is HighestUnanchored'
} else { Bad "chrome: $($r.Anchor.Name)/$($r.Anchor.MatchedBy) $($r.HighestUnanchored.Name)/$($r.HighestUnanchored.MatchedBy)" }
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory $t9 -Version '142.0' -WingetId 'Google.Chrome'
if (@($r.AmbiguousIds).Count -eq 0) { Ok 'no Vendor/DisplayName given -> AmbiguousIds empty' } else { Bad "AmbiguousIds without V+DN = $($r.AmbiguousIds -join ',')" }

# --- [10] hostile strings from another project are sanitised -----------------------------------------
Write-Host '[10] Strings read from other projects are sanitised (C-6)' -ForegroundColor Cyan
$esc = [char]0x1B
$null = New-FakeProject -Template 'T10' -Name 'App_1' -Version '1.0' -WingetId 'Contoso.App' -Vendor "Con${esc}[31mtoso" -DisplayName 'App' -PublishedTenants 't'
$r = Get-Win32ToolkitPreviousProject -TemplateDirectory (Join-Path $tmpRoot 'T10') -Version '2.0' -WingetId 'Contoso.App'
if ($r.Anchor.Vendor -ceq 'Con?[31mtoso' -and $r.Anchor.TattooKey -ceq 'Contoso IT\Con?[31mtoso\App') { Ok 'ESC in another project''s Vendor -> ?' } else { Bad "vendor: $($r.Anchor.Vendor)" }

# --- [11] source hygiene ------------------------------------------------------------------------------
Write-Host '[11] Source: every catch starts with the C-2 line; ASCII-only' -ForegroundColor Cyan
$file = Join-Path $repo 'Private\Get-Win32ToolkitPreviousProject.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
$badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
if ($catches.Count -ge 1 -and $badCatch.Count -eq 0) { Ok "$($catches.Count) catch clause(s), each starts with the C-2 line" } else { Bad 'a catch does not start with the C-2 line' }
if (@([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'ASCII-only' } else { Bad 'non-ASCII bytes' }

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'All PreviousProject tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PreviousProject test(s) FAILED." -ForegroundColor Red; exit 1 }
