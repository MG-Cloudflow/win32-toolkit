<#
    Installer-identity PR 1 (spec 2.9): Get-Win32ToolkitIdentityDelta (Data + Project sets) and
    Write-Win32ToolkitIdentityDelta (Documentation\IdentityDelta.json).

      Data set   : the PR 1 finding codes from a Source, a predecessor and a probe (pure).
      Project set: inputs gathered from a project (Source / predecessor / probe SHADOWED), -NoProbe,
                   -ReuseProbe, the tenant pass-through.
      Writer     : BOM-less JSON that round-trips and holds no host path; fail-open.
      K1         : every catch of every new WP-3 file starts with the C-2 line; the files are ASCII-only
                   and define one function with no top-level code.

    The probes of the Data-set cases are REAL Get-Win32ToolkitSiblingInstaller results over the
    Tests\Fixtures\winget-manifests manifests (Invoke-WebRequest shadowed: no network).

    Run:  pwsh -File Tests\IdentityDelta.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-WebRequest is shadowed: the suite never touches the network')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$wp3Files = @(
    'Get-Win32ToolkitInstallerFamily', 'Test-Win32ToolkitWingetNoApplicableInstaller', 'ConvertTo-Win32ToolkitSafeText',
    'Get-Win32ToolkitProjectSource', 'Get-Win32ToolkitSiblingInstaller', 'Get-Win32ToolkitPreviousProject',
    'Get-Win32ToolkitIdentityDelta', 'Write-Win32ToolkitIdentityDelta'
)
foreach ($f in $wp3Files + @('Get-Win32ToolkitAppConfig')) { . (Join-Path $repo "Private\$f.ps1") }

# --- Real probes over the fixtures (Invoke-WebRequest shadowed) ----------------------------------
$fx = Join-Path $repo 'Tests\Fixtures\winget-manifests'
$script:body = ''
function Invoke-WebRequest { [CmdletBinding()] param([string]$Uri, [int]$TimeoutSec, [int]$MaximumRedirection, [switch]$SkipHttpErrorCheck) [pscustomobject]@{ StatusCode = 200; Content = $script:body } }
function Get-FixtureProbe([string]$Rel, [string]$Id, [string]$Ver, [string]$Arch, [string]$Type) {
    $script:body = Get-Content -LiteralPath (Join-Path $fx $Rel) -Raw -Encoding UTF8
    Get-Win32ToolkitSiblingInstaller -WingetId $Id -Version $Ver -Architecture $Arch -PackagedType $Type -NoMemo
}
$probeNpp  = Get-FixtureProbe 'Notepad++.Notepad++\8.9.8.1.installer.yaml' 'Notepad++.Notepad++' '8.9.8.1' 'x64' 'wix'
$probeTv   = Get-FixtureProbe 'TeamViewer.TeamViewer\15.82.6.installer.yaml' 'TeamViewer.TeamViewer' '15.82.6' 'x64' 'nullsoft'
$probePdn  = Get-FixtureProbe 'dotPDN.PaintDotNet\5.1.installer.yaml' 'dotPDN.PaintDotNet' '5.1' 'x64' 'wix'
$probeAppx = Get-FixtureProbe 'synthetic\appx-sibling.installer.yaml' 'Contoso.AppxSibling' '3.1.0' 'x64' 'exe'
$script:body = "PackageIdentifier: Git.Git`nPackageVersion: 2.55.0`nInstallers:`n- Architecture: x64`n  InstallerType: inno`n  Scope: machine`n- Architecture: x64`n  InstallerType: inno`n  Scope: user`n"
$probeGit  = Get-Win32ToolkitSiblingInstaller -WingetId 'Git.Git' -Version '2.55.0' -Architecture x64 -PackagedType inno -NoMemo
$probeDown = [pscustomobject]@{ SchemaVersion = '1.0'; Status = 'Unavailable'; Reason = 'NotFound'; Url = 'https://example.invalid/x'; ProbedUtc = ''
                                WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = 'x64'; PackagedType = 'wix'; PackagedFamily = 'msi'
                                Tuples = @(); Siblings = @(); SameFamilyOther = @(); NotRegistering = @() }
if ($probeNpp.Status -eq 'Ok' -and $probeTv.Status -eq 'Ok' -and $probePdn.Status -eq 'Ok' -and $probeAppx.Status -eq 'Ok' -and $probeGit.Status -eq 'Ok') { Ok 'fixture probes parsed (Notepad++, TeamViewer, Paint.NET, appx, Git)' } else { Bad 'a fixture probe failed to parse' }

function New-Source([hashtable]$Over) {
    $s = [ordered]@{
        SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; InstallerType = 'wix'; Family = 'msi'; Scope = 'machine'
        Architecture = 'x64'; Locale = 'en-US'; PinnedBy = 'winget-default'; RequestedInstallerType = ''; WingetClient = '1.29.380'
        ProductCode = ''; UpgradeCode = ''; UpgradeBehavior = 'install'; Rebuilt = $false
    }
    if ($Over) { foreach ($k in $Over.Keys) { $s[$k] = $Over[$k] } }
    [pscustomobject]$s
}
function New-Match([hashtable]$Over) {
    $m = [ordered]@{
        Name = 'Notepad++_x64_8.9.6.4'; Template = 'Contoso'; Path = 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.6.4'; Version = '8.9.6.4'
        WingetId = 'Notepad++.Notepad++'; Vendor = 'Notepad++ Team'; DisplayName = 'Notepad++'; ScriptAuthor = 'Contoso IT'
        TattooKey = 'Contoso IT\Notepad++ Team\Notepad++'; InstallerType = 'nullsoft'; Family = 'exe'; PinnedBy = 'winget-default'
        SourceRebuilt = $true; Published = $true; Anchored = $true; AnchorReason = 'published'; MatchedBy = 'WingetId'
    }
    if ($Over) { foreach ($k in $Over.Keys) { $m[$k] = $Over[$k] } }
    [pscustomobject]$m
}
function New-Lookup($Anchor, $Highest, [string[]]$Ambiguous = @()) {
    [pscustomobject]@{ Anchor = $Anchor; HighestUnanchored = $Highest; Matches = @(@($Highest, $Anchor) | Where-Object { $_ }); AmbiguousIds = $Ambiguous }
}
$tattooNew = 'Contoso IT\Notepad++ Team\Notepad++'
$allMessages = [System.Collections.Generic.HashSet[string]]::new()
function Codes($d) { foreach ($f in @($d.Findings)) { [void]$allMessages.Add([string]$f.Message) }; (@($d.Findings) | ForEach-Object Code) -join ',' }
function Find($d, [string]$Code) { foreach ($f in @($d.Findings)) { [void]$allMessages.Add([string]$f.Message) }; @($d.Findings) | Where-Object Code -eq $Code | Select-Object -First 1 }

# --- [1] Notepad++: sibling family + no anchor ---------------------------------------------------
Write-Host '[1] Notepad++ 8.9.8.1 wix (winget-default), nullsoft sibling -> ID-SIBLING-FAMILY + ID-NO-ANCHOR' -ForegroundColor Cyan
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source) -Probe $probeNpp -TattooKey $tattooNew
if ((Codes $d) -eq 'ID-SIBLING-FAMILY,ID-NO-ANCHOR') { Ok 'codes = ID-SIBLING-FAMILY, ID-NO-ANCHOR' } else { Bad "codes = $(Codes $d)" }
$sf = Find $d 'ID-SIBLING-FAMILY'
if ($sf.Severity -eq 'Warning' -and $sf.Message -match '-InstallerType nullsoft;' -and $sf.Message -match '-BaselineInstallerType Both' -and
    $sf.Message -match "ProductCode/ARP key 'Notepad\+\+'" -and $sf.Message -match '^winget also ships nullsoft \(vendor EXE, NSIS\) for x64 of Notepad\+\+\.Notepad\+\+ 8\.9\.8\.1 ') {
    Ok "ID-SIBLING-FAMILY (Warning) names the label, the ARP key, -InstallerType nullsoft and -BaselineInstallerType Both"
} else { Bad "ID-SIBLING-FAMILY = $($sf | ConvertTo-Json -Compress)" }
if ((@($sf.Data.Families) -join ',') -eq 'exe' -and (@($sf.Data.Types) -join ',') -eq 'nullsoft') { Ok 'Data: Families [exe], Types [nullsoft]' } else { Bad "Data = $($sf.Data | ConvertTo-Json -Compress)" }
$na = Find $d 'ID-NO-ANCHOR'
if ($na.Severity -eq 'Warning' -and $na.Message -match '^winget chose wix \(MSI\) and no earlier version' -and $na.Message -match 'Pin it with -InstallerType wix ' -and $na.Data.InstallerType -eq 'wix') {
    Ok 'ID-NO-ANCHOR (Warning): "winget chose wix (MSI) ... Pin it with -InstallerType wix" (the type is not repeated)'
} else { Bad "ID-NO-ANCHOR = $($na | ConvertTo-Json -Compress)" }
if (@($d.Siblings).Count -eq 1 -and @($d.NotRegistering).Count -eq 1 -and $d.Probe.Status -eq 'Ok' -and $d.Probe.TupleCount -eq 7 -and $d.SchemaVersion -eq '1.0') {
    Ok 'Siblings / NotRegistering / Probe summary (TupleCount 7) / SchemaVersion carried into the delta'
} else { Bad "delta shape: $($d | ConvertTo-Json -Depth 3 -Compress)" }
# No @() around the values here: a one-entry list must stay an array, an empty one must not become $null.
if ($d.Siblings -is [array] -and $d.Siblings.Count -eq 1 -and $d.SameFamilyOther -is [array] -and $d.SameFamilyOther.Count -eq 0 -and
    $d.NotRegistering -is [array] -and $d.NotRegistering.Count -eq 1) {
    Ok 'one sibling / no same-family entry / one non-registering entry -> three arrays (1, 0, 1), never a bare object or $null'
} else { Bad "array shape: Siblings $(if ($null -eq $d.Siblings) { 'null' } else { $d.Siblings.GetType().Name }), SameFamilyOther $(if ($null -eq $d.SameFamilyOther) { 'null' } else { $d.SameFamilyOther.GetType().Name })" }

$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'parameter'; RequestedInstallerType = 'wix' }) -Probe $probeNpp -TattooKey $tattooNew
if ((Codes $d) -eq 'ID-SIBLING-FAMILY') { Ok 'PinnedBy parameter -> only ID-SIBLING-FAMILY' } else { Bad "parameter -> $(Codes $d)" }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'continuity'; RequestedInstallerType = 'wix' }) -Probe $probeNpp -TattooKey $tattooNew
if ((Codes $d) -eq 'ID-SIBLING-FAMILY') { Ok 'PinnedBy continuity -> no ID-NO-ANCHOR' } else { Bad "continuity -> $(Codes $d)" }
$anch = New-Match @{ InstallerType = 'wix'; Family = 'msi' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source) -Predecessor (New-Lookup $anch $null) -Probe $probeNpp -TattooKey $tattooNew
if ((Codes $d) -eq 'ID-SIBLING-FAMILY') { Ok 'winget-default but an anchored same-family predecessor exists -> no ID-NO-ANCHOR' } else { Bad "anchored winget-default -> $(Codes $d)" }

# --- [2] TeamViewer, Paint.NET, appx, Git ----------------------------------------------------------
Write-Host '[2] Zip-wrapped / registered-as / appx / single-technology siblings' -ForegroundColor Cyan
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ WingetId = 'TeamViewer.TeamViewer'; Version = '15.82.6'; InstallerType = 'nullsoft'; Family = 'exe' }) -Probe $probeTv
$u = Find $d 'ID-SIBLING-UNTESTABLE'
if ((Codes $d) -eq 'ID-SIBLING-UNTESTABLE' -and $u.Severity -eq 'Info' -and $u.Message -match 'wix \(MSI\), zip-wrapped' -and
    $u.Message -notmatch '-InstallerType' -and $u.Message -notmatch 'Both') {
    Ok "TeamViewer nullsoft -> only ID-SIBLING-UNTESTABLE (Info, 'wix (MSI), zip-wrapped', no remedy); no ID-SIBLING-FAMILY, no ID-NO-ANCHOR"
} else { Bad "TeamViewer -> $(Codes $d) / $($u.Message)" }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ WingetId = 'dotPDN.PaintDotNet'; Version = '5.1' }) -Probe $probePdn
if ((Codes $d) -eq '') { Ok 'Paint.NET wix -> no finding (the zipped EXE registers as the same wix)' } else { Bad "Paint.NET -> $(Codes $d)" }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ WingetId = 'Contoso.AppxSibling'; Version = '3.1.0'; InstallerType = 'exe'; Family = 'exe' }) -Probe $probeAppx
$sf = Find $d 'ID-SIBLING-FAMILY'
if ($sf -and $sf.Message -match '-InstallerType msix;' -and $sf.Message -notmatch '-InstallerType appx' -and (Find $d 'ID-NO-ANCHOR').Message -match '-InstallerType exe ') {
    Ok 'an appx sibling -> the remedy names -InstallerType msix (never appx)'
} else { Bad "appx -> $(Codes $d) / $($sf.Message)" }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ WingetId = 'Git.Git'; Version = '2.55.0'; InstallerType = 'inno'; Family = 'exe' }) -Probe $probeGit
if ((Codes $d) -eq '') { Ok 'Git inno, only inno for x64 (scope variants) -> no finding' } else { Bad "Git -> $(Codes $d)" }

# --- [3] probe unavailable / skipped ---------------------------------------------------------------
Write-Host '[3] Probe unavailable -> only ID-PROBE-UNAVAILABLE (L4); skipped -> nothing' -ForegroundColor Cyan
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source) -Probe $probeDown -TattooKey $tattooNew
$pu = Find $d 'ID-PROBE-UNAVAILABLE'
if ((Codes $d) -eq 'ID-PROBE-UNAVAILABLE' -and $pu.Severity -eq 'Warning' -and $pu.Message -match 'Notepad\+\+\.Notepad\+\+ 8\.9\.8\.1 \(NotFound' -and $pu.Message -match 'pin one with -InstallerType') {
    Ok 'ID-PROBE-UNAVAILABLE names the id, version, reason and the -InstallerType advice; no ID-NO-ANCHOR'
} else { Bad "unavailable -> $(Codes $d) / $($pu.Message)" }
$skipped = [pscustomobject]@{ Status = 'Skipped'; Reason = 'NoWingetId'; Siblings = @() }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ WingetId = ''; PinnedBy = 'parameter' }) -Probe $skipped
if ((Codes $d) -eq '' -and $d.Probe.Status -eq 'Skipped') { Ok 'Skipped probe (manual project) -> no finding' } else { Bad "skipped -> $(Codes $d)" }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source)
if ((Codes $d) -eq '' -and $null -eq $d.Probe) { Ok 'no probe at all -> no probe finding, Probe $null' } else { Bad "no probe -> $(Codes $d)" }
if ($d.Siblings -is [array] -and $d.Siblings.Count -eq 0 -and $d.SameFamilyOther -is [array] -and $d.SameFamilyOther.Count -eq 0 -and
    $d.NotRegistering -is [array] -and $d.NotRegistering.Count -eq 0) {
    Ok 'no probe -> Siblings / SameFamilyOther / NotRegistering are empty arrays (not $null)'
} else { Bad 'no probe -> a sibling list is not an empty array' }

# --- [4] ID-FAMILY ------------------------------------------------------------------------------------
Write-Host '[4] ID-FAMILY: anchored predecessor of another family; Edge wix -> msi is the same family' -ForegroundColor Cyan
$pred = New-Match
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'continuity' }) -Predecessor (New-Lookup $pred $null) -Probe $probeNpp -TattooKey $tattooNew
$fam = Find $d 'ID-FAMILY'
if ($fam -and $fam.Severity -eq 'Warning' -and $fam.Message -match '^The installer technology changed: Notepad\+\+_x64_8\.9\.6\.4 \(published\) is nullsoft \(exe\), this package is wix \(msi\)\.' -and
    $fam.Message -match 'Rebuild with -InstallerType nullsoft to keep it\.$') {
    Ok 'anchored nullsoft predecessor vs wix -> ID-FAMILY with -InstallerType nullsoft'
} else { Bad "ID-FAMILY = $($fam.Message) / codes $(Codes $d)" }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source) -Predecessor (New-Match @{ AnchorReason = 'pinned:parameter'; Published = $false })
if ((Find $d 'ID-FAMILY').Message -match '\(pinned\) is nullsoft') { Ok 'a pinned anchor is named (pinned); a single match object is accepted as -Predecessor' } else { Bad "pinned anchor -> $((Find $d 'ID-FAMILY').Message)" }
$edge = New-Match @{ Name = 'Edge_x64_151'; InstallerType = 'wix'; Family = 'msi'; WingetId = 'Microsoft.Edge' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ WingetId = 'Microsoft.Edge'; Version = '152.0'; InstallerType = 'msi'; Family = 'msi'; PinnedBy = 'continuity'; RequestedInstallerType = 'wix' }) -Predecessor (New-Lookup $edge $null)
$vs = Find $d 'ID-VARIANT-SUBSTITUTE'
if (-not (Find $d 'ID-FAMILY') -and $vs.Severity -eq 'Info' -and $vs.Message -ceq 'Requested wix; this version offers msi in the same technology family - packaged msi.') {
    Ok 'Edge 151 wix -> 152 msi (anchored): no ID-FAMILY; requested wix got msi -> ID-VARIANT-SUBSTITUTE (Info)'
} else { Bad "Edge -> $(Codes $d)" }
$store = New-Match @{ InstallerType = 'msstore'; Family = 'msix' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source) -Predecessor (New-Lookup $store $null)
if ((Find $d 'ID-FAMILY').Message -match 'Rebuild from a package that ships msix\.$') { Ok "a predecessor type without a pin value (msstore) -> 'Rebuild from a package that ships msix.'" } else { Bad "msstore -> $((Find $d 'ID-FAMILY').Message)" }
$unanchored = New-Match @{ Anchored = $false; AnchorReason = ''; Published = $false; ScriptAuthor = 'Other IT'; TattooKey = 'Other IT\Notepad++ Team\Notepad++' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'parameter' }) -Predecessor (New-Lookup $null $unanchored) -TattooKey $tattooNew
if ((Codes $d) -eq '' -and $null -eq $d.Predecessor -and $d.HighestUnanchored.Name -eq 'Notepad++_x64_8.9.6.4') { Ok 'an UNANCHORED predecessor never raises ID-FAMILY or ID-TATTOO (kept as HighestUnanchored)' } else { Bad "unanchored -> $(Codes $d)" }
$other = New-Match @{ InstallerType = 'pwa'; Family = 'other' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source) -Predecessor (New-Lookup $other $null)
if (-not (Find $d 'ID-FAMILY')) { Ok "family 'other' is never compared" } else { Bad 'other family compared' }

# --- [5] ID-TATTOO -------------------------------------------------------------------------------------
Write-Host '[5] ID-TATTOO: the full tattoo key changed; a case-only change is not a change' -ForegroundColor Cyan
$oldAuthor = New-Match @{ ScriptAuthor = 'Fabrikam Packaging'; TattooKey = 'Fabrikam Packaging\Notepad++ Team\Notepad++'; InstallerType = 'wix'; Family = 'msi' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'continuity' }) -Predecessor (New-Lookup $oldAuthor $null) -TattooKey $tattooNew
$tt = Find $d 'ID-TATTOO'
if ($tt.Severity -eq 'Warning' -and $tt.Message -ceq "The detection key changed from HKLM\SOFTWARE\Fabrikam Packaging\Notepad++ Team\Notepad++ to HKLM\SOFTWARE\Contoso IT\Notepad++ Team\Notepad++. Devices that have Notepad++_x64_8.9.6.4 keep it detected under the old key; the update app's requirement does not see them.") {
    Ok 'ScriptAuthor changed -> ID-TATTOO with both keys'
} else { Bad "ID-TATTOO = $($tt.Message)" }
$caseOnly = New-Match @{ TattooKey = 'CONTOSO IT\notepad++ team\NOTEPAD++'; InstallerType = 'wix'; Family = 'msi' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'continuity' }) -Predecessor (New-Lookup $caseOnly $null) -TattooKey $tattooNew
if ((Codes $d) -eq '') { Ok 'case-only change -> no finding' } else { Bad "case-only -> $(Codes $d)" }
$noKey = New-Match @{ TattooKey = '\Notepad++ Team\Notepad++'; InstallerType = 'wix'; Family = 'msi' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'continuity' }) -Predecessor (New-Lookup $noKey $null) -TattooKey $tattooNew
if (-not (Find $d 'ID-TATTOO')) { Ok 'a predecessor without a ScriptAuthor wrote no tattoo -> no ID-TATTOO' } else { Bad 'incomplete old key compared' }

# --- [6] ID-SCOPE, ID-PREDECESSOR-AMBIGUOUS ------------------------------------------------------------
Write-Host '[6] ID-SCOPE (manifest user scope); ID-PREDECESSOR-AMBIGUOUS' -ForegroundColor Cyan
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ Scope = 'user'; PinnedBy = 'parameter' })
$sc = Find $d 'ID-SCOPE'
if ((Codes $d) -eq 'ID-SCOPE' -and $sc.Severity -eq 'Warning' -and $sc.Message -match 'user-scope' -and $sc.Message -match 'InstallationChanges_\*\.json') { Ok 'Scope user -> ID-SCOPE' } else { Bad "scope -> $(Codes $d)" }
$chrome = New-Match @{ Name = 'Chrome_msi'; WingetId = 'Google.Chrome'; InstallerType = 'wix'; Family = 'msi'; MatchedBy = 'VendorDisplayName' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ WingetId = 'Google.Chrome.EXE'; InstallerType = 'wix'; PinnedBy = 'parameter' }) -Predecessor (New-Lookup $chrome $null @('Google.Chrome.EXE', 'Google.Chrome'))
$am = Find $d 'ID-PREDECESSOR-AMBIGUOUS'
if ($am.Severity -eq 'Warning' -and $am.Message -ceq 'Several winget ids in this template look like the same product (Google.Chrome.EXE, Google.Chrome). The predecessor was matched by VendorDisplayName; check that Chrome_msi is the right one.') {
    Ok 'two ids -> ID-PREDECESSOR-AMBIGUOUS naming the ids, MatchedBy and the predecessor'
} else { Bad "ambiguous = $($am.Message)" }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'parameter' }) -Predecessor ([pscustomobject]@{ Anchor = $null; HighestUnanchored = $null; Matches = @(); AmbiguousIds = @('A.B', 'A.B.EXE') })
if ((Find $d 'ID-PREDECESSOR-AMBIGUOUS').Message -match 'check that this package uses the id') { Ok 'two ids and no predecessor -> the short form of the message' } else { Bad 'no-predecessor ambiguity message' }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'parameter' }) -Predecessor ([pscustomobject]@{ Anchor = $null; HighestUnanchored = $null; Matches = @(); AmbiguousIds = @('A.B') })
if (-not (Find $d 'ID-PREDECESSOR-AMBIGUOUS')) { Ok 'one id -> not ambiguous' } else { Bad 'one id flagged' }

# --- [7] shape, hostile values, L12 --------------------------------------------------------------------
Write-Host '[7] No Path in the delta; hostile values sanitised; no -CaptureSiblingTechnologies anywhere (L12)' -ForegroundColor Cyan
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'continuity' }) -Predecessor (New-Lookup (New-Match) (New-Match @{ Anchored = $false; Version = '8.9.7' })) -Probe $probeNpp -TattooKey $tattooNew
if (-not $d.Predecessor.PSObject.Properties['Path'] -and -not $d.HighestUnanchored.PSObject.Properties['Path'] -and $d.Predecessor.Name) { Ok 'Predecessor and HighestUnanchored carry no Path' } else { Bad 'Path leaked into the delta' }
if ($d.Source.PSObject.Properties['Rebuilt'] -and $d.Source.Rebuilt -eq $false) { Ok 'Source carries Rebuilt' } else { Bad 'Source.Rebuilt missing' }
$esc = [char]0x1B; $rlo = [char]0x202E
$evilProbe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; WingetId = "Evil${esc}.App"; Version = '1.0'; Architecture = 'x64'
    Siblings = @([pscustomobject]@{ EffectiveType = 'nullsoft'; Family = 'exe'; Registers = $true; Testable = $true; ZipWrapped = $false; PinValue = 'nullsoft'
                                     Label = "nullsoft${rlo}"; ProductCode = "Evil${esc}[2J" }) }
$d = Get-Win32ToolkitIdentityDelta -Source (New-Source @{ PinnedBy = 'parameter' }) -Probe $evilProbe
$m = (Find $d 'ID-SIBLING-FAMILY').Message
if ($m -and $m -notmatch '[\x00-\x1F\u202E]' -and $m -match "ProductCode/ARP key 'Evil\?\[2J'") { Ok 'control / bidi characters in probe values never reach a message' } else { Bad "hostile message: $m" }
$null = Codes $d
if (@($allMessages | Where-Object { $_ -match 'CaptureSiblingTechnologies' }).Count -eq 0 -and $allMessages.Count -ge 12) { Ok "no message names -CaptureSiblingTechnologies ($($allMessages.Count) messages checked)" } else { Bad "L12: $($allMessages.Count) messages, offending: $(@($allMessages | Where-Object { $_ -match 'CaptureSiblingTechnologies' }))" }
if (@($allMessages | Where-Object { $_ -match '[^\x20-\x7E]' }).Count -eq 0) { Ok 'every message is printable ASCII' } else { Bad 'a message has non-ASCII characters' }

# ======================== Project set (shadows) ========================
Write-Host '[8] Project set: inputs gathered from the project (Source / predecessor / probe shadowed)' -ForegroundColor Cyan
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32delta_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proj = Join-Path $tmpRoot 'Contoso\Notepad++_x64_8.9.8.1'
New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
$cfg = [ordered]@{
    SchemaVersion = '1.0'
    App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = ''; DisplayName = 'Notepad++'; Version = '8.9.8.1'; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
    Intune = [ordered]@{ TenantId = 'tenant-from-appconfig' }
}
[System.IO.File]::WriteAllText((Join-Path $proj 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))

$script:shadowSource = New-Source @{ Rebuilt = $true }
$script:predArgs = $null
$script:predResult = [pscustomobject]@{ Anchor = $null; HighestUnanchored = $null; Matches = @(); AmbiguousIds = @() }
$script:probeCalls = 0; $script:probeArgs = $null
$script:probeAnswer = $probeNpp
function Get-Win32ToolkitProjectSource { [CmdletBinding()] param([string]$ProjectPath, [switch]$Rebuild) $script:shadowSource }
function Get-Win32ToolkitPreviousProject {
    [CmdletBinding()]
    param([string]$TemplateDirectory, [string]$Version, [string]$WingetId, [string]$Vendor, [string]$DisplayName, [string]$ExcludePath, [string]$TenantId)
    $script:predArgs = [pscustomobject]$PSBoundParameters
    $script:predResult
}
function Get-Win32ToolkitSiblingInstaller {
    [CmdletBinding()]
    param([string]$WingetId, [string]$Version, [string]$Architecture, [string]$PackagedType)
    $script:probeCalls++
    $script:probeArgs = [pscustomobject]$PSBoundParameters
    if ($script:probeAnswer -is [scriptblock]) { & $script:probeAnswer } else { $script:probeAnswer }
}

$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj
if ((Codes $d) -eq 'ID-SIBLING-FAMILY,ID-NO-ANCHOR' -and $script:probeCalls -eq 1) { Ok 'one probe call, Notepad++ findings' } else { Bad "project set -> $(Codes $d), probe calls $($script:probeCalls)" }
if ($script:probeArgs.WingetId -eq 'Notepad++.Notepad++' -and $script:probeArgs.Version -eq '8.9.8.1' -and $script:probeArgs.Architecture -eq 'x64' -and $script:probeArgs.PackagedType -eq 'wix') { Ok 'the probe gets the Source id / version / arch and -PackagedType = the packaged type' } else { Bad "probe args $($script:probeArgs | ConvertTo-Json -Compress)" }
$pa = $script:predArgs
if ($pa.TemplateDirectory -eq (Split-Path $proj -Parent) -and $pa.ExcludePath -eq $proj -and $pa.WingetId -eq 'Notepad++.Notepad++' -and $pa.Vendor -eq 'Notepad++ Team' -and
    $pa.DisplayName -eq 'Notepad++' -and $pa.Version -eq '8.9.8.1' -and $pa.TenantId -eq 'tenant-from-appconfig') {
    Ok 'predecessor lookup: template folder, ExcludePath = the project, id, Vendor, DisplayName, App.Version, TenantId from AppConfig.Intune'
} else { Bad "predecessor args $($pa | ConvertTo-Json -Compress)" }
$null = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -TenantId 'tenant-param'
if ($script:predArgs.TenantId -eq 'tenant-param') { Ok '-TenantId overrides AppConfig.Intune.TenantId' } else { Bad "tenant = $($script:predArgs.TenantId)" }

# A relative -ProjectPath (Export / Publish accept one) is resolved against the PowerShell location: a bare
# folder name or '.' has no parent for Split-Path, which would leave the template folder empty.
$projParent = Split-Path $proj -Parent
$projLeaf = Split-Path $proj -Leaf
Push-Location -LiteralPath $projParent
try {
    foreach ($rel in $projLeaf, ".\$projLeaf") {
        $script:predArgs = $null
        $d = Get-Win32ToolkitIdentityDelta -ProjectPath $rel -NoProbe
        if ($d -and $script:predArgs.TemplateDirectory -eq $projParent -and $script:predArgs.ExcludePath -eq $proj) { Ok "relative -ProjectPath '$rel' -> the template folder and ExcludePath are the absolute paths" }
        else { Bad "relative '$rel' -> template=[$($script:predArgs.TemplateDirectory)] exclude=[$($script:predArgs.ExcludePath)]" }
    }
}
finally { Pop-Location }
Push-Location -LiteralPath $proj
try {
    $script:predArgs = $null
    $d = Get-Win32ToolkitIdentityDelta -ProjectPath '.' -NoProbe
    if ($d -and $script:predArgs.TemplateDirectory -eq $projParent -and $script:predArgs.ExcludePath -eq $proj) { Ok "-ProjectPath '.' from inside the project -> the template folder is its parent" }
    else { Bad "'.' -> template=[$($script:predArgs.TemplateDirectory)] exclude=[$($script:predArgs.ExcludePath)]" }
}
finally { Pop-Location }

$before = $script:probeCalls
$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -NoProbe
if ($script:probeCalls -eq $before -and $d.Probe.Status -eq 'Skipped' -and (Codes $d) -eq '') { Ok '-NoProbe -> no probe call, Probe Skipped, no probe-based finding' } else { Bad "-NoProbe -> calls $($script:probeCalls - $before), $(Codes $d)" }

$script:shadowSource = New-Source @{ WingetId = ''; PinnedBy = 'parameter'; Rebuilt = $true }
$before = $script:probeCalls
$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj
if ($script:probeCalls -eq $before -and $d.Probe.Status -eq 'Skipped' -and $d.Probe.Reason -eq 'NoWingetId') { Ok "WingetId '' (manual project) -> Probe Skipped/NoWingetId, no call" } else { Bad 'manual project probed' }
$script:shadowSource = New-Source @{ Rebuilt = $true }

# --- [9] Writer + ReuseProbe ---------------------------------------------------------------------------
Write-Host '[9] Write-Win32ToolkitIdentityDelta: BOM-less JSON, round-trip, no Path; -ReuseProbe makes no request' -ForegroundColor Cyan
$script:predResult = New-Lookup $null (New-Match @{ Anchored = $false; Version = '8.9.7' })
$warn = @()
$w = Write-Win32ToolkitIdentityDelta -ProjectPath $proj -WarningVariable warn 3>$null
$jsonPath = Join-Path $proj 'Documentation\IdentityDelta.json'
$bytes = [System.IO.File]::ReadAllBytes($jsonPath)
if ($bytes.Length -gt 3 -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { Ok 'Documentation\IdentityDelta.json written, BOM-less' } else { Bad 'file missing or has a BOM' }
$raw = [System.Text.Encoding]::UTF8.GetString($bytes)
$back = $raw | ConvertFrom-Json
if ($back.SchemaVersion -eq '1.0' -and (@($back.Findings) | ForEach-Object Code) -join ',' -eq 'ID-SIBLING-FAMILY,ID-NO-ANCHOR' -and
    @($back.Siblings).Count -eq 1 -and $back.Siblings[0].PinValue -eq 'nullsoft' -and $back.Probe.TupleCount -eq 7 -and $back.Source.WingetId -eq 'Notepad++.Notepad++' -and
    $back.HighestUnanchored.Version -eq '8.9.7' -and $null -eq $back.Predecessor -and @($back.Findings[0].Data.Families)[0] -eq 'exe') {
    Ok 'the JSON round-trips (findings, siblings, probe summary, Source, HighestUnanchored, Data)'
} else { Bad "round-trip: $raw" }
# Raw text, not ConvertFrom-Json: indexing [0] also works on a bare object, so only the text proves the 2.9 array shape.
if ($raw -match '"Siblings":\s*\[\s*\{' -and $raw -match '"SameFamilyOther":\s*\[\]' -and $raw -match '"NotRegistering":\s*\[\s*\{') {
    Ok 'one sibling -> "Siblings": [ { ... } ], "SameFamilyOther": [], "NotRegistering": [ { ... } ] in the file'
} else { Bad "array shape in the file: $raw" }
if ($raw -notmatch '"Path"\s*:' -and $raw -notmatch [regex]::Escape('C:\\Win32Apps')) { Ok 'no Path property and no host path in the file' } else { Bad 'a Path / host path is in the file' }
if (@($warn).Count -eq 2 -and $w.Findings.Count -eq 2) { Ok 'two Warning findings printed with Write-Warning' } else { Bad "warnings printed: $(@($warn).Count)" }

$before = $script:probeCalls
$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -ReuseProbe
if ($script:probeCalls -eq $before -and (Codes $d) -eq 'ID-SIBLING-FAMILY,ID-NO-ANCHOR' -and $d.Probe.Status -eq 'Ok' -and $d.Probe.TupleCount -eq 7) { Ok '-ReuseProbe -> no request, same findings from the stored siblings' } else { Bad "reuse -> calls $($script:probeCalls - $before), $(Codes $d)" }
if ($d.Probe.ProbedUtc -is [string] -and $d.Probe.ProbedUtc -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' -and $d.Probe.ProbedUtc -eq ([datetime]$probeNpp.ProbedUtc).ToUniversalTime().ToString('o')) {
    Ok "a reused probe keeps its original ProbedUtc in ISO 8601 ($($d.Probe.ProbedUtc))"
} else { Bad "reused ProbedUtc = $($d.Probe.ProbedUtc)" }
if ($d.Siblings -is [array] -and $d.Siblings.Count -eq 1 -and $d.SameFamilyOther -is [array] -and $d.SameFamilyOther.Count -eq 0) { Ok 'a reused probe keeps the array shape (one sibling, empty SameFamilyOther)' } else { Bad 'reused probe: a sibling list lost its array shape' }
$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -ReuseProbe -NoProbe
if ($script:probeCalls -eq $before -and (Codes $d) -eq 'ID-SIBLING-FAMILY,ID-NO-ANCHOR') { Ok '-ReuseProbe -NoProbe -> the stored probe, no request' } else { Bad 'reuse + noprobe' }
$script:shadowSource = New-Source @{ Version = '8.9.9'; Rebuilt = $true }
$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -ReuseProbe
if ($script:probeCalls -eq $before + 1) { Ok 'a stored probe for another version is not reused (one new request)' } else { Bad "version mismatch -> calls $($script:probeCalls - $before)" }
$script:shadowSource = New-Source @{ Rebuilt = $true }

# An Ok probe with no sibling at all (Git: inno only for x64) -> the three lists are written as empty JSON arrays.
$script:shadowSource = New-Source @{ WingetId = 'Git.Git'; Version = '2.55.0'; InstallerType = 'inno'; Family = 'exe'; Rebuilt = $true }
$script:probeAnswer = $probeGit
$null = Write-Win32ToolkitIdentityDelta -ProjectPath $proj -Quiet
$raw = [System.IO.File]::ReadAllText($jsonPath)
if ($raw -match '"Status":\s*"Ok"' -and $raw -match '"Siblings":\s*\[\]' -and $raw -match '"SameFamilyOther":\s*\[\]' -and $raw -match '"NotRegistering":\s*\[\]') {
    Ok 'Ok probe, no sibling -> "Siblings": [], "SameFamilyOther": [], "NotRegistering": [] in the file (not null)'
} else { Bad "no-sibling array shape in the file: $raw" }
$script:shadowSource = New-Source @{ Rebuilt = $true }

$script:probeAnswer = $probeDown
$null = Write-Win32ToolkitIdentityDelta -ProjectPath $proj -Quiet
$raw = [System.IO.File]::ReadAllText($jsonPath)
if ($raw -match '"Status":\s*"Unavailable"' -and $raw -match '"Siblings":\s*\[\]' -and $raw -match '"SameFamilyOther":\s*\[\]' -and $raw -match '"NotRegistering":\s*\[\]') {
    Ok 'Unavailable probe -> the three lists are written as empty arrays'
} else { Bad "unavailable array shape in the file: $raw" }
$before = $script:probeCalls
$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -ReuseProbe -NoProbe
if ($script:probeCalls -eq $before -and (Codes $d) -eq 'ID-PROBE-UNAVAILABLE') { Ok 'a stored Unavailable probe is reused under -NoProbe (the warning stays visible)' } else { Bad "stored unavailable + NoProbe -> $(Codes $d)" }
$script:probeAnswer = $probeNpp
$d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -ReuseProbe
if ($script:probeCalls -eq $before + 1 -and (Codes $d) -eq 'ID-SIBLING-FAMILY,ID-NO-ANCHOR') { Ok 'a stored Unavailable probe is retried when probing is allowed' } else { Bad "stored unavailable retry -> $(Codes $d)" }

[System.IO.File]::WriteAllText($jsonPath, '{ corrupt json', [System.Text.UTF8Encoding]::new($false))
$threw = $false
try { $d = Get-Win32ToolkitIdentityDelta -ProjectPath $proj -ReuseProbe -NoProbe } catch { $threw = $true }
if (-not $threw -and $d.Probe.Status -eq 'Skipped') { Ok 'a corrupt IdentityDelta.json is ignored by -ReuseProbe (no throw)' } else { Bad "corrupt stored file: threw=$threw" }

# A relative -ProjectPath: the file lands in the project, never under the PROCESS directory (which
# [System.IO.File] would use and Push-Location does not move).
$procDir = Join-Path $tmpRoot 'procdir'
New-Item -ItemType Directory -Path $procDir -Force | Out-Null
Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
$savedCwd = [Environment]::CurrentDirectory
Push-Location -LiteralPath $projParent
try {
    [Environment]::CurrentDirectory = $procDir
    $w = Write-Win32ToolkitIdentityDelta -ProjectPath ".\$projLeaf" -Quiet 3>$null
    $stray = @(Get-ChildItem -LiteralPath $procDir -Recurse -Force)
    if ($w -and (Test-Path -LiteralPath $jsonPath -PathType Leaf) -and $stray.Count -eq 0) { Ok "relative -ProjectPath '.\$projLeaf' -> the file is written to <project>\Documentation\IdentityDelta.json, nothing under the process directory" }
    else { Bad "relative writer: returned=$([bool]$w) file=$(Test-Path -LiteralPath $jsonPath) stray=[$(@($stray.FullName) -join ', ')]" }
}
finally {
    [Environment]::CurrentDirectory = $savedCwd
    Pop-Location
}

# --- [10] Writer output and fail-open --------------------------------------------------------------------
Write-Host '[10] Writer: -Quiet prints nothing; Info in grey; a throwing input -> warning + $null, no throw' -ForegroundColor Cyan
$warn = @()
$info = Write-Win32ToolkitIdentityDelta -ProjectPath $proj -Quiet -WarningVariable warn 3>$null 6>$null
if (@($warn).Count -eq 0 -and $info) { Ok '-Quiet: no warning printed, the delta is returned' } else { Bad "-Quiet printed $(@($warn).Count) warning(s)" }
$script:shadowSource = New-Source @{ WingetId = 'TeamViewer.TeamViewer'; Version = '15.82.6'; InstallerType = 'nullsoft'; Family = 'exe'; Rebuilt = $true }
$script:probeAnswer = $probeTv
$hostOut = Write-Win32ToolkitIdentityDelta -ProjectPath $proj 6>&1 3>$null | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }
if (@($hostOut | Where-Object { "$_" -match 'zip-wrapped' }).Count -eq 1) { Ok 'an Info finding is printed to the host (grey), not as a warning' } else { Bad 'Info finding not printed to the host' }
$script:probeAnswer = { throw [System.InvalidOperationException]::new('probe exploded') }
$warn = @(); $threw = $false
try { $r = Write-Win32ToolkitIdentityDelta -ProjectPath $proj -WarningVariable warn 3>$null } catch { $threw = $true }
if (-not $threw -and $null -eq $r -and @($warn | Where-Object { "$_" -match '^Identity checks failed: .*probe exploded' }).Count -eq 1) { Ok "a throwing probe -> 'Identity checks failed: ...' warning, `$null, no throw" } else { Bad "fail-open: threw=$threw r=$r warn=$($warn -join ' | ')" }
$threw = $false
try { $r = Write-Win32ToolkitIdentityDelta -ProjectPath $proj -ErrorAction Stop 3>$null } catch { $threw = $true }
if (-not $threw -and $null -eq $r) { Ok 'no throw under -ErrorAction Stop' } else { Bad 'threw under -ErrorAction Stop' }
$script:probeAnswer = $probeNpp
Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- [11] K1 + file hygiene for every new WP-3 file --------------------------------------------------------
Write-Host '[11] Every new WP-3 file: catches start with the C-2 line (K1), ASCII-only, one function, no top-level code' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$totalCatches = 0
foreach ($name in $wp3Files) {
    $file = Join-Path $repo "Private\$name.ps1"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $totalCatches += $catches.Count
    $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    $top = @($ast.EndBlock.Statements)
    $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $name -and
                   -not $ast.BeginBlock -and -not $ast.ProcessBlock -and -not $ast.ParamBlock
    if (@($errs).Count -eq 0 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "$name : $($catches.Count) catch(es) with the C-2 line, ASCII, one function, no top-level code" }
    else { Bad "$name : parse errors $(@($errs).Count), bad catches $($badCatch.Count), ascii $ascii, oneFunction $oneFunction" }
}
if ($totalCatches -ge 10) { Ok "$totalCatches catch clauses checked in total" } else { Bad "only $totalCatches catch clauses found - the K1 scan looks wrong" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All IdentityDelta tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail IdentityDelta test(s) FAILED." -ForegroundColor Red; exit 1 }
