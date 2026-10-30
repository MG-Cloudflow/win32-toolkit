<#
    Unit tests for Get-Win32ToolkitDeployScriptShape - the single template-shape / support policy
    (implementation spec 2.5).

    Covers: the three PSADT goldens (4.1.8, 4.2.0 default, 4.2.0 Zero-Config); the three legacy-1.1.6
    fixtures (Psadt41 / GeneratorVersion 0 / Support 'Legacy' with exactly the markers 1.1.6 replaced);
    shape preserved after full patching (GeneratorVersion 3, lean deploy script PR 2); mutations that must classify as Unknown
    (missing New-Variable phase, missing dispatcher, renamed *-ADTDeployment function, changed
    InstallPhase assignment, mixed layouts, parse error, partial Zero-Config); 4.1 marker census; foreign
    AppConfig loader; out-of-range / mismatched DeployAppScriptVersion; -Path vs -Content; missing file;
    relative paths (shape reader, generator, writer) resolve against the PowerShell location;
    UninstallRevision (0 / 1 / 2, the marker only inside the toolkit uninstall block, an oversized number);
    RemovePriorRevision and PriorCheckFirst (installer-identity PR 3: 0/false before PR 3 and without the org dialogs,
    1/true generated with them; a hand-written welcome, a moved org-ui block, one block only, the marker outside).

    Fixtures are copied/normalised in memory (C-5); nothing in Tests\Fixtures is modified. No PSADT needed.

    Run:  pwsh -File Tests\DeployScriptShape.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# C-5: the supported range (normally set by win32-toolkit.psm1) + a shadow of the WP-A contract (spec 2.2).
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
function Test-Win32ToolkitPsadtVersionSupported {
    param([Parameter(Position = 0)][object]$Version)
    if ($null -eq $script:PsadtSupportedRange) { throw [System.InvalidOperationException]::new('win32-toolkit internal error: PsadtSupportedRange is not initialised') }
    if ($null -eq $Version) { return $false }
    $v = $null
    if ($Version -is [version]) { $v = $Version } elseif (-not [version]::TryParse((([string]$Version) -split '-', 2)[0], [ref]$v)) { return $false }
    return ($v -ge $script:PsadtSupportedRange.Min -and $v -lt $script:PsadtSupportedRange.MaxExclusive)
}

foreach ($f in 'Get-Win32ToolkitDeployScriptShape', 'Set-Win32ToolkitPhaseBlock', 'Remove-Win32ToolkitPhaseBlock',
    'Remove-Win32ToolkitPhaseDefaultUi', 'Get-Win32ToolkitDeployScriptBlock', 'Write-Win32ToolkitDeployScript',
    'Test-Win32ToolkitPS51Syntax', 'Set-PSADTDataDrivenScript', 'Get-Win32ToolkitAppConfig', 'Get-Win32ToolkitDeployBlockPlan', 'ConvertTo-Win32ToolkitSafeText', 'Get-Win32ToolkitDeployExtension', 'Copy-Win32ToolkitDeployExtension') {
    . (Join-Path $repo "Private\$f.ps1")
}

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32sh_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $TMP -Force | Out-Null

# Fixture text, BOM stripped, line endings normalised to LF (C-5).
function Get-Fixture([string]$Name) {
    ([System.IO.File]::ReadAllText((Join-Path $repo "Tests\Fixtures\$Name\Invoke-AppDeployToolkit.ps1"), [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
}
function Shape([string]$Text) { Get-Win32ToolkitDeployScriptShape -Content $Text }

$g418 = Get-Fixture 'psadt-4.1.8'
$g42d = Get-Fixture 'psadt-4.2.0'
$g42z = Get-Fixture 'psadt-4.2.0-zeroconfig'

# -- [1] goldens -----------------------------------------------------------------------------------
Write-Host '[1] the three PSADT goldens' -ForegroundColor Cyan
$expect = @(
    @{ N = 'psadt-4.1.8';            T = $g418; Shape = 'Psadt41';           V = '4.1.8'; Support = 'Supported' }
    @{ N = 'psadt-4.2.0';            T = $g42d; Shape = 'Psadt42Default';    V = '4.2.0'; Support = 'Unsupported' }
    @{ N = 'psadt-4.2.0-zeroconfig'; T = $g42z; Shape = 'Psadt42ZeroConfig'; V = '4.2.0'; Support = 'Supported' }
)
foreach ($e in $expect) {
    $r = Shape $e.T
    if ($r.Shape -eq $e.Shape -and $r.DeployAppScriptVersion -eq $e.V -and $r.Support -eq $e.Support) { Ok "$($e.N) -> $($r.Shape) / $($r.DeployAppScriptVersion) / $($r.Support)" }
    else { Bad "$($e.N) -> $($r.Shape) / $($r.DeployAppScriptVersion) / $($r.Support) ($($r.Reason))" }
    if (-not $r.IsPatched -and $null -eq $r.GeneratorVersion -and -not $r.HasTattoo -and $r.ParseErrors -eq 0 -and @($r.MarkerIssues).Count -eq 0) {
        Ok "$($e.N): pristine (not patched, no generator, no tattoo, no marker issues)"
    } else { Bad "$($e.N): IsPatched=$($r.IsPatched) Gen=$($r.GeneratorVersion) Tattoo=$($r.HasTattoo) MarkerIssues=$($r.MarkerIssues -join ';')" }
    # -Path and -Content agree (the -Path reader strips the BOM).
    $p = Join-Path $TMP "$($e.N).ps1"
    [System.IO.File]::WriteAllText($p, ($e.T -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $rp = Get-Win32ToolkitDeployScriptShape -Path $p
    if ($rp.Shape -eq $r.Shape -and $rp.DeployAppScriptVersion -eq $r.DeployAppScriptVersion -and $rp.Support -eq $r.Support) { Ok "$($e.N): -Path (CRLF + BOM) agrees with -Content" }
    else { Bad "$($e.N): -Path gave $($rp.Shape)/$($rp.Support)" }
}
$rd = Shape $g42d
if ($rd.SupportReason -match 'without Zero-Config') { Ok 'Psadt42Default: SupportReason names the shape' } else { Bad "SupportReason='$($rd.SupportReason)'" }

# -- [2] legacy 1.1.6 fixtures ---------------------------------------------------------------------
Write-Host '[2] projects patched by win32-toolkit 1.1.6 are Psadt41 / GeneratorVersion 0 / Legacy' -ForegroundColor Cyan
$inst = 'missing: ## <Perform Installation tasks here>'
$unin = 'missing: ## <Perform Uninstallation tasks here>'
foreach ($c in @(
        @{ N = 'legacy-1.1.6-auto';   Issues = @($inst, $unin) }
        @{ N = 'legacy-1.1.6-manual'; Issues = @($unin) }
        @{ N = 'legacy-1.1.6-org';    Issues = @($inst, $unin) })) {
    $r = Shape (Get-Fixture $c.N)
    if ($r.Shape -eq 'Psadt41' -and $r.DeployAppScriptVersion -eq '4.1.8' -and $r.GeneratorVersion -eq 0 -and $r.Support -eq 'Legacy') {
        Ok "$($c.N) -> Psadt41 / 4.1.8 / GeneratorVersion 0 / Legacy"
    } else { Bad "$($c.N) -> $($r.Shape) / $($r.DeployAppScriptVersion) / gen $($r.GeneratorVersion) / $($r.Support) ($($r.Reason))" }
    if ((@($r.MarkerIssues) -join '|') -eq ($c.Issues -join '|')) { Ok "$($c.N): MarkerIssues = exactly the replaced markers ($($c.Issues.Count))" }
    else { Bad "$($c.N): MarkerIssues = [$($r.MarkerIssues -join '; ')]" }
    if ($r.SupportReason -match 'older win32-toolkit' -and $r.IsPatched -and $r.HasTattoo) { Ok "$($c.N): legacy reason text, IsPatched, HasTattoo" }
    else { Bad "$($c.N): SupportReason='$($r.SupportReason)' IsPatched=$($r.IsPatched) HasTattoo=$($r.HasTattoo)" }
}

# -- [3] full patching keeps the shape -------------------------------------------------------------
Write-Host '[3] after full patching (generator + org-ui + hooks) the shape is unchanged, GeneratorVersion 3' -ForegroundColor Cyan
foreach ($c in @(@{ N = 'psadt-4.1.8'; T = $g418; S = 'Psadt41' }, @{ N = 'psadt-4.2.0-zeroconfig'; T = $g42z; S = 'Psadt42ZeroConfig' })) {
    $p = Join-Path $TMP "full-$($c.N).ps1"
    [System.IO.File]::WriteAllText($p, $c.T, (New-Object System.Text.UTF8Encoding($true)))
    $null = Set-PSADTDataDrivenScript -ScriptPath $p -InstallerType exe -WarningAction SilentlyContinue
    $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    $ui = [ordered]@{ 'Pre-Install' = 'OrgUiPreInstall'; 'Pre-Uninstall' = 'OrgUiPreMaintenance'; 'Pre-Repair' = 'OrgUiPreMaintenance'; 'Post-Install' = 'OrgUiPostInstall'; 'Post-Repair' = 'OrgUiPostRepair' }
    foreach ($ph in $ui.Keys) {
        $t = Remove-Win32ToolkitPhaseDefaultUi -Content $t -Phase $ph
        $t = Set-Win32ToolkitPhaseBlock -Content $t -Phase $ph -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name $ui[$ph])
    }
    foreach ($ph in 'Pre-Install', 'Post-Install', 'Pre-Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Post-Repair') {
        $t = Set-Win32ToolkitPhaseBlock -Content $t -Phase $ph -Slot 'hook' -Code (Get-Win32ToolkitDeployScriptBlock -Name Hook -Phase $ph -HookFile (($ph -replace '-', '') + '.ps1'))
    }
    $r = Shape $t
    if ($r.Shape -eq $c.S -and $r.GeneratorVersion -eq 3 -and $r.Support -eq 'Supported' -and $r.HasTattoo -and $r.IsPatched) {
        Ok "$($c.N): still $($c.S), GeneratorVersion 3, Supported, IsPatched, HasTattoo"
    } else { Bad "$($c.N): $($r.Shape) gen $($r.GeneratorVersion) $($r.Support) ($($r.Reason))" }
    $lr = Get-Win32ToolkitDeployScriptShape -Content $t -IncludeLayout
    if (@($lr.Layout.BlockIssues).Count -eq 0 -and @($lr.Layout.Blocks).Count -ge 17) { Ok "$($c.N): $(@($lr.Layout.Blocks).Count) toolkit blocks, no block issues" }
    else { Bad "$($c.N): blocks=$(@($lr.Layout.Blocks).Count) issues=$(@($lr.Layout.BlockIssues | ForEach-Object Message) -join '; ')" }
}

# -- [4] mutations -> Unknown ----------------------------------------------------------------------
Write-Host '[4] mutations of a known layout classify as Unknown (never guessed)' -ForegroundColor Cyan
$mutations = [ordered]@{
    'remove one New-Variable phase (Post-Repair)'   = ($g42z -replace '(?s)## MARK: Post-Repair\nNew-Variable -Name Post-Repair -Force -Value \{.*?\n\}\n', '')
    'remove the Get-Variable dispatcher'            = $g42z.Replace('Get-Variable -Name "Pre-$($adtSession.DeploymentType)"', 'Get-Item -Path "Pre-$($adtSession.DeploymentType)"')
    'rename one *-ADTDeployment function'           = $g418.Replace('function Repair-ADTDeployment', 'function Repair-ADTDeploymentX')
    'change one InstallPhase right-hand side'       = ([regex]'"Post-\$\(\$adtSession\.DeploymentType\)"').Replace($g418, '"Post-Install"', 1)
    'mix both layouts (4.1 + a 4.2 phase variable)' = $g418 + "`nNew-Variable -Name Install -Force -Value {`n}`n"
    'mix both layouts (4.2 + a 4.1 function)'       = $g42z + "`nfunction Install-ADTDeployment`n{`n}`n"
    'parse error'                                   = $g42z + "`nif (`n"
    'no $adtSession hashtable'                      = $g42z.Replace('$adtSession = @{', '$adtSessionX = @{')
}
# Partial Zero-Config: keep the block in Install only.
$zcBlock = ([regex]::Match($g42z, '(?s)    ## Handle Zero-Config MSI actions\.\n.*?        Start-ADTMsiProcess @ExecuteDefaultMSISplat\n    \}\n')).Value
$firstZc = $g42z.IndexOf($zcBlock)
$partial = $g42z.Substring(0, $firstZc + $zcBlock.Length) + $g42z.Substring($firstZc + $zcBlock.Length).Replace($zcBlock, '')
$mutations['partial Zero-Config (Install only)'] = $partial
foreach ($k in $mutations.Keys) {
    if ($mutations[$k] -ceq $g418 -or $mutations[$k] -ceq $g42z) { Bad "$k : the mutation did not apply (test bug)"; continue }
    $r = Shape $mutations[$k]
    if ($r.Shape -eq 'Unknown' -and $r.Support -eq 'Unsupported' -and $r.Reason) { Ok "$k -> Unknown ($($r.Reason))" }
    else { Bad "$k -> $($r.Shape) / $($r.Support)" }
}
$pe = Shape $mutations['parse error']
if ($pe.ParseErrors -gt 0 -and $pe.Reason -match 'parse error') { Ok "parse error -> ParseErrors=$($pe.ParseErrors), Reason names it" } else { Bad "ParseErrors=$($pe.ParseErrors) Reason=$($pe.Reason)" }

# -- [5] 4.1 marker census never decides the shape -------------------------------------------------
Write-Host '[5] removing or duplicating a PSADT 4.1 marker keeps Psadt41 and is listed in MarkerIssues' -ForegroundColor Cyan
$noMarker = $g418.Replace("    ## <Perform Pre-Repair tasks here>`n", '')
$r = Shape $noMarker
if ($r.Shape -eq 'Psadt41' -and (@($r.MarkerIssues) -join '|') -eq 'missing: ## <Perform Pre-Repair tasks here>') { Ok 'removed marker -> Psadt41 + "missing: ..."' } else { Bad "$($r.Shape) [$($r.MarkerIssues -join '; ')]" }
$dupMarker = $g418.Replace("    ## <Perform Post-Repair tasks here>`n", "    ## <Perform Post-Repair tasks here>`n    ## <Perform Post-Repair tasks here>`n")
$r = Shape $dupMarker
if ($r.Shape -eq 'Psadt41' -and (@($r.MarkerIssues) -join '|') -eq 'duplicate: ## <Perform Post-Repair tasks here>') { Ok 'duplicated marker -> Psadt41 + "duplicate: ..."' } else { Bad "$($r.Shape) [$($r.MarkerIssues -join '; ')]" }
if ($r.Support -eq 'Supported') { Ok 'MarkerIssues alone do not change Support (the generator gate enforces markers)' } else { Bad "Support=$($r.Support)" }

# -- [6] foreign AppConfig loader / versions -------------------------------------------------------
Write-Host '[6] foreign loader and DeployAppScriptVersion policy' -ForegroundColor Cyan
$foreign = $g42z.Replace('$adtSession = @{', "`$appConfig = @{}`n`$adtSession = @{")
$r = Shape $foreign
if ($r.Shape -eq 'Psadt42ZeroConfig' -and $r.GeneratorVersion -eq 0 -and $r.Support -eq 'Unsupported' -and $r.SupportReason -match 'did not write') {
    Ok '420zc with a hand-added $appConfig = line -> GeneratorVersion 0, Unsupported (a loader win32-toolkit did not write)'
} else { Bad "$($r.Shape) gen $($r.GeneratorVersion) $($r.Support) '$($r.SupportReason)'" }
foreach ($c in @(
        @{ N = '420zc with DeployAppScriptVersion 4.3.0'; T = $g42z.Replace("DeployAppScriptVersion = '4.2.0'", "DeployAppScriptVersion = '4.3.0'") }
        @{ N = '418 with DeployAppScriptVersion 4.3.0';   T = $g418.Replace("DeployAppScriptVersion = '4.1.8'", "DeployAppScriptVersion = '4.3.0'") }
        @{ N = '418 layout with DeployAppScriptVersion 4.2.0 (mismatch)'; T = $g418.Replace("DeployAppScriptVersion = '4.1.8'", "DeployAppScriptVersion = '4.2.0'") }
        @{ N = '420zc layout with DeployAppScriptVersion 4.1.8 (mismatch)'; T = $g42z.Replace("DeployAppScriptVersion = '4.2.0'", "DeployAppScriptVersion = '4.1.8'") }
        @{ N = '420zc without DeployAppScriptVersion'; T = $g42z.Replace("    DeployAppScriptVersion = '4.2.0'`n", '') })) {
    $r = Shape $c.T
    if ($r.Support -eq 'Unsupported' -and $r.SupportReason -match 'DeployAppScriptVersion') { Ok "$($c.N) -> Unsupported" } else { Bad "$($c.N) -> $($r.Support) '$($r.SupportReason)'" }
}
$rc = Shape ($g42z.Replace("DeployAppScriptVersion = '4.2.0'", "DeployAppScriptVersion = '4.2.0-rc2'"))
if ($rc.Support -eq 'Supported' -and $rc.IsSupportedVersion) { Ok "DeployAppScriptVersion '4.2.0-rc2' (prerelease label) -> Supported" } else { Bad "rc2 -> $($rc.Support)" }

# -- [7] never throws for content ------------------------------------------------------------------
Write-Host '[7] missing file / empty content never throw' -ForegroundColor Cyan
try {
    $m = Get-Win32ToolkitDeployScriptShape -Path (Join-Path $TMP 'nope.ps1')
    if ($m.Shape -eq 'Unknown' -and $m.Reason -match 'not found' -and $m.Support -eq 'Unsupported') { Ok 'missing file -> Unknown with Reason' } else { Bad "missing -> $($m.Shape) '$($m.Reason)'" }
    $e = Get-Win32ToolkitDeployScriptShape -Content ''
    if ($e.Shape -eq 'Unknown') { Ok 'empty content -> Unknown' } else { Bad "empty -> $($e.Shape)" }
} catch { Bad "threw: $($_.Exception.Message)" }

# -- [8] layout offsets ----------------------------------------------------------------------------
Write-Host '[8] -IncludeLayout offsets point at the anchors' -ForegroundColor Cyan
$l = (Get-Win32ToolkitDeployScriptShape -Content $g42z -IncludeLayout).Layout
if ($g42z.Substring($l.Session.LineStart).StartsWith('$adtSession = @{') -and $l.Session.Indent -eq '') { Ok '4.2: Session.LineStart is the $adtSession line (indent none)' } else { Bad '4.2 session offset wrong' }
if ($g42z[$l.Phases['Install'].Open] -eq '{' -and $g42z[$l.Phases['Install'].Close] -eq '}') { Ok '4.2: phase Open/Close are the scriptblock braces' } else { Bad '4.2 brace offsets wrong' }
$l1 = (Get-Win32ToolkitDeployScriptShape -Content $g418 -IncludeLayout).Layout
$pi = $l1.Phases['Pre-Install']
if ($g418.Substring($pi.MarkerOffset).StartsWith('## <Perform Pre-Installation tasks here>') -and $pi.MarkerOffset -gt $pi.RegionStart -and $pi.MarkerOffset -lt $pi.RegionEnd) {
    Ok '4.1: MarkerOffset lies inside the phase region'
} else { Bad '4.1 marker/region offsets wrong' }
$l1n = (Get-Win32ToolkitDeployScriptShape -Content $noMarker -IncludeLayout).Layout
if ($null -eq $l1n.Phases['Pre-Repair'].MarkerOffset) { Ok '4.1: MarkerOffset is $null for a missing marker' } else { Bad 'missing marker has an offset' }

# -- [9] relative paths resolve against the PowerShell location ------------------------------------
# .NET file APIs resolve a relative path against the process directory, which Set-Location does not move;
# the process directory is pointed at an empty folder so a wrong resolver cannot pass by accident.
Write-Host '[9] a relative -Path / -ScriptPath resolves against the PowerShell location, not the process directory' -ForegroundColor Cyan
$rel = Join-Path $TMP 'rel'; $elsewhere = Join-Path $TMP 'elsewhere'
New-Item -ItemType Directory -Path (Join-Path $rel 'proj'), $elsewhere -Force | Out-Null
$relScript = Join-Path $rel 'proj\Invoke-AppDeployToolkit.ps1'
[System.IO.File]::WriteAllText($relScript, ($g418 -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
$prevCwd = [Environment]::CurrentDirectory
Push-Location -LiteralPath $rel
try {
    [Environment]::CurrentDirectory = $elsewhere
    $r = Get-Win32ToolkitDeployScriptShape -Path '.\proj\Invoke-AppDeployToolkit.ps1'
    if ($r.Shape -eq 'Psadt41' -and $r.Support -eq 'Supported') { Ok "shape -Path '.\proj\Invoke-AppDeployToolkit.ps1' -> Psadt41 / Supported" } else { Bad "relative shape -> $($r.Shape) / $($r.Support) ($($r.Reason))" }
    $null = Set-PSADTDataDrivenScript -ScriptPath '.\proj\Invoke-AppDeployToolkit.ps1' -InstallerType exe -WarningAction SilentlyContinue
    $r = Get-Win32ToolkitDeployScriptShape -Path $relScript
    if ($r.Shape -eq 'Psadt41' -and $r.GeneratorVersion -eq 3) { Ok 'Set-PSADTDataDrivenScript with a relative -ScriptPath patches the file at the PowerShell location' } else { Bad "relative generator -> $($r.Shape) gen $($r.GeneratorVersion) ($($r.Reason))" }
    Write-Win32ToolkitDeployScript -Path '.\proj\written.ps1' -Content "'ok'`r`n" -OriginalBytes @()
    if ((Test-Path -LiteralPath (Join-Path $rel 'proj\written.ps1')) -and @(Get-ChildItem -LiteralPath $elsewhere -Force).Count -eq 0) { Ok 'Write-Win32ToolkitDeployScript with a relative -Path writes at the PowerShell location; nothing lands in the process directory' }
    else { Bad "relative writer: written=$(Test-Path -LiteralPath (Join-Path $rel 'proj\written.ps1')) elsewhere=[$(@(Get-ChildItem -LiteralPath $elsewhere -Force -Recurse | ForEach-Object Name) -join ', ')]" }
}
catch { Bad "relative path threw: $($_.Exception.Message)" }
finally { [Environment]::CurrentDirectory = $prevCwd; Pop-Location }

# -- [10] UninstallRevision (installer-identity PR 2, spec 2.4) -----------------------------------------
Write-Host '[10] UninstallRevision: 0 = no toolkit uninstall block, 1 = a block before the hardened uninstall, 2 = this version' -ForegroundColor Cyan
foreach ($c in @(@{ N = 'psadt-4.1.8'; T = $g418 }, @{ N = 'psadt-4.2.0'; T = $g42d }, @{ N = 'psadt-4.2.0-zeroconfig'; T = $g42z },
        @{ N = 'legacy-1.1.6-auto'; T = (Get-Fixture 'legacy-1.1.6-auto') }, @{ N = 'legacy-1.1.6-manual'; T = (Get-Fixture 'legacy-1.1.6-manual') }, @{ N = 'legacy-1.1.6-org'; T = (Get-Fixture 'legacy-1.1.6-org') })) {
    $r = Shape $c.T
    if ($r.PSObject.Properties['UninstallRevision'] -and $r.UninstallRevision -is [int] -and $r.UninstallRevision -eq 0) { Ok "$($c.N) -> UninstallRevision 0" } else { Bad "$($c.N) -> UninstallRevision '$($r.UninstallRevision)'" }
}
$revLine = '(?m)^[ \t]*## Uninstall revision 2 \(win32-toolkit\)[^\n]*\n'
foreach ($c in @(@{ N = 'psadt-4.1.8'; T = $g418; S = 'Psadt41' }, @{ N = 'psadt-4.2.0-zeroconfig'; T = $g42z; S = 'Psadt42ZeroConfig' })) {
    $p = Join-Path $TMP "rev-$($c.N).ps1"
    [System.IO.File]::WriteAllText($p, ($c.T -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $null = Set-PSADTDataDrivenScript -ScriptPath $p -InstallerType exe -WarningAction SilentlyContinue
    $rp = Get-Win32ToolkitDeployScriptShape -Path $p
    if ($rp.Shape -eq $c.S -and $rp.GeneratorVersion -eq 3 -and $rp.Support -eq 'Supported' -and $rp.UninstallRevision -eq 2) { Ok "$($c.N) generated by this version (-Path, CRLF + BOM) -> UninstallRevision 2, GeneratorVersion 3" } else { Bad "$($c.N) generated -> $($rp.Shape) gen $($rp.GeneratorVersion) rev $($rp.UninstallRevision)" }
    $t = ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
    $old = [regex]::Replace($t, $revLine, '')
    $r = Shape $old
    if ($old -ne $t -and $r.UninstallRevision -eq 1 -and $r.Shape -eq $c.S -and $r.GeneratorVersion -eq 3 -and $r.Support -eq 'Supported') { Ok "$($c.N): the revision line removed (a block built before PR 2) -> 1, still Supported" } else { Bad "$($c.N) without marker -> rev $($r.UninstallRevision) $($r.Shape) $($r.Support)" }
    $outside = $old + "`n## Uninstall revision 2 (win32-toolkit)`n"
    $r = Shape $outside
    if ($r.UninstallRevision -eq 1) { Ok "$($c.N): the marker text outside the uninstall block does not count -> still 1" } else { Bad "$($c.N) marker outside -> rev $($r.UninstallRevision)" }
    $huge = $t.Replace('## Uninstall revision 2 (win32-toolkit)', '## Uninstall revision 99999999999 (win32-toolkit)')
    try {
        $r = Shape $huge
        if ($huge -ne $t -and $r.UninstallRevision -eq 1 -and $r.Shape -eq $c.S -and $r.Support -eq 'Supported') { Ok "$($c.N): 'revision 99999999999' (hand-edited) -> 1, no throw, shape and support unchanged" } else { Bad "$($c.N) huge -> rev $($r.UninstallRevision) $($r.Shape) $($r.Support)" }
    } catch { Bad "$($c.N) huge revision threw: $($_.Exception.Message)" }
    $r = Shape ($t.Replace('## Uninstall revision 2 (win32-toolkit)', '## Uninstall revision 3 (win32-toolkit)'))
    if ($r.UninstallRevision -eq 3) { Ok "$($c.N): 'revision 3' -> 3 (the number is read, not assumed)" } else { Bad "$($c.N) rev 3 -> $($r.UninstallRevision)" }
}
try {
    $r = Get-Win32ToolkitDeployScriptShape -Content ''
    if ($r.UninstallRevision -eq 0) { Ok "-Content '' -> UninstallRevision 0, no throw" } else { Bad "-Content '' -> $($r.UninstallRevision)" }
    $m = Get-Win32ToolkitDeployScriptShape -Path (Join-Path $TMP 'nope.ps1')
    if ($m.UninstallRevision -eq 0) { Ok 'missing file -> UninstallRevision 0' } else { Bad "missing file -> $($m.UninstallRevision)" }
} catch { Bad "UninstallRevision threw: $($_.Exception.Message)" }

# -- [11] RemovePriorRevision / PriorCheckFirst (installer-identity PR 3, spec 2.7, L38, L39) ---------------
Write-Host '[11] RemovePriorRevision and PriorCheckFirst: 0/false before PR 3, the catalog revision (2)/true generated with the org dialogs' -ForegroundColor Cyan
foreach ($c in @(@{ N = 'psadt-4.1.8'; T = $g418 }, @{ N = 'psadt-4.2.0'; T = $g42d }, @{ N = 'psadt-4.2.0-zeroconfig'; T = $g42z },
        @{ N = 'legacy-1.1.6-auto'; T = (Get-Fixture 'legacy-1.1.6-auto') }, @{ N = 'legacy-1.1.6-org'; T = (Get-Fixture 'legacy-1.1.6-org') })) {
    $r = Shape $c.T
    if ($r.RemovePriorRevision -is [int] -and $r.RemovePriorRevision -eq 0 -and $r.PriorCheckFirst -is [bool] -and -not $r.PriorCheckFirst) { Ok "$($c.N) -> RemovePriorRevision 0, PriorCheckFirst false" } else { Bad "$($c.N) -> $($r.RemovePriorRevision) / $($r.PriorCheckFirst)" }
}
foreach ($c in @(@{ N = 'psadt-4.1.8'; T = $g418; S = 'Psadt41' }, @{ N = 'psadt-4.2.0-zeroconfig'; T = $g42z; S = 'Psadt42ZeroConfig' })) {
    $p = Join-Path $TMP "prior-$($c.N).ps1"
    [System.IO.File]::WriteAllText($p, ($c.T -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $null = Set-PSADTDataDrivenScript -ScriptPath $p -InstallerType exe -WarningAction SilentlyContinue
    $bare = ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
    $r = Shape $bare
    if ($r.RemovePriorRevision -eq 2 -and -not $r.PriorCheckFirst) { Ok "$($c.N) generated WITHOUT the org template -> revision 2, PriorCheckFirst false (the PSADT welcome runs before prior-check)" } else { Bad "$($c.N) no org -> $($r.RemovePriorRevision) / $($r.PriorCheckFirst)" }
    $o = $bare
    $o = Remove-Win32ToolkitPhaseDefaultUi -Content $o -Phase 'Pre-Install'
    $o = Set-Win32ToolkitPhaseBlock -Content $o -Phase 'Pre-Install' -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name OrgUiPreInstall)
    $r = Shape $o
    if ($r.RemovePriorRevision -eq 2 -and $r.PriorCheckFirst -and $r.Shape -eq $c.S -and $r.Support -eq 'Supported') { Ok "$($c.N) generated with the org dialogs -> revision 2, PriorCheckFirst true" } else { Bad "$($c.N) org -> $($r.RemovePriorRevision) / $($r.PriorCheckFirst)" }
    $h = Set-Win32ToolkitPhaseBlock -Content $o -Phase 'Pre-Install' -Slot 'hook' -Code (Get-Win32ToolkitDeployScriptBlock -Name Hook -Phase 'Pre-Install' -HookFile 'PreInstall.ps1')
    $r = Shape $h
    if ($r.PriorCheckFirst) { Ok "$($c.N): an org hook between org-ui and remove-prior keeps PriorCheckFirst" } else { Bad "$($c.N) hook -> PriorCheckFirst false" }
    # A PSADT welcome added by hand in Pre-Install outside every block.
    $byHand = if ($c.S -eq 'Psadt41') { $h.Replace("    ## <Perform Pre-Installation tasks here>`n", "    ## <Perform Pre-Installation tasks here>`n    Show-ADTInstallationWelcome -CloseProcesses 'x'`n") }
              else { $h.Replace("New-Variable -Name Pre-Install -Force -Value {`n", "New-Variable -Name Pre-Install -Force -Value {`n    Show-ADTInstallationWelcome -CloseProcesses 'x'`n") }
    $r = Shape $byHand
    if ($byHand -ne $h -and $r.RemovePriorRevision -eq 2 -and -not $r.PriorCheckFirst) { Ok "$($c.N): a Show-ADTInstallationWelcome written by hand in Pre-Install outside a block -> PriorCheckFirst false" } else { Bad "$($c.N) hand welcome -> $($r.PriorCheckFirst)" }
    $prog = if ($c.S -eq 'Psadt41') { $h.Replace("    ## <Perform Pre-Installation tasks here>`n", "    ## <Perform Pre-Installation tasks here>`n    Show-ADTInstallationProgress`n") } else { $h.Replace("New-Variable -Name Pre-Install -Force -Value {`n", "New-Variable -Name Pre-Install -Force -Value {`n    Show-ADTInstallationProgress`n") }
    if (-not (Shape $prog).PriorCheckFirst) { Ok "$($c.N): a hand-written Show-ADTInstallationProgress -> PriorCheckFirst false" } else { Bad "$($c.N) hand progress kept PriorCheckFirst" }
    # The org-ui block moved before prior-check.
    $orgBlock = [regex]::Match($h, '(?ms)^[ \t]*## win32-toolkit:Pre-Install:org-ui \(begin\).*?## win32-toolkit:Pre-Install:org-ui \(end\)\n').Value
    $pcBegin = [regex]::Match($h, '(?m)^[ \t]*## win32-toolkit:Pre-Install:prior-check \(begin\)')
    $moved = $h.Replace($orgBlock, '').Insert($pcBegin.Index, $orgBlock)
    if ((Shape $moved).PriorCheckFirst -eq $false -and (Shape $moved).RemovePriorRevision -eq 2) { Ok "$($c.N): org-ui placed before prior-check -> PriorCheckFirst false" } else { Bad "$($c.N) moved org-ui kept PriorCheckFirst" }
    # Only one of the two blocks; the marker outside the block; an oversized revision.
    $rpBlock = [regex]::Match($h, '(?ms)^[ \t]*## win32-toolkit:Pre-Install:remove-prior \(begin\).*?## win32-toolkit:Pre-Install:remove-prior \(end\)\n').Value
    $r = Shape ($h.Replace($rpBlock, ''))
    if ($rpBlock -and $r.RemovePriorRevision -eq 0 -and -not $r.PriorCheckFirst) { Ok "$($c.N): only the prior-check block -> revision 0" } else { Bad "$($c.N) one block -> $($r.RemovePriorRevision)" }
    $noMark = $h.Replace('## remove-prior catalog revision 2 (win32-toolkit)', '## (marker removed)')
    $r = Shape ($noMark + "`n## remove-prior catalog revision 2 (win32-toolkit)`n")
    if ($noMark -ne $h -and $r.RemovePriorRevision -eq 0) { Ok "$($c.N): the revision marker outside the prior-check block -> revision 0" } else { Bad "$($c.N) marker outside -> $($r.RemovePriorRevision)" }
    try {
        $r = Shape ($h.Replace('## remove-prior catalog revision 2 (win32-toolkit)', '## remove-prior catalog revision 99999999999 (win32-toolkit)'))
        if ($r.RemovePriorRevision -eq 0 -and $r.Shape -eq $c.S) { Ok "$($c.N): 'revision 99999999999' -> 0, no throw" } else { Bad "$($c.N) huge -> $($r.RemovePriorRevision)" }
    } catch { Bad "$($c.N) huge revision threw: $($_.Exception.Message)" }
    $r = Shape ($h.Replace('## remove-prior catalog revision 1 (win32-toolkit)', '## remove-prior catalog revision 2 (win32-toolkit)'))
    if ($r.RemovePriorRevision -eq 2) { Ok "$($c.N): 'revision 2' -> 2 (the number is read)" } else { Bad "$($c.N) rev 2 -> $($r.RemovePriorRevision)" }
}
try {
    $r = Get-Win32ToolkitDeployScriptShape -Content ''
    if ($r.RemovePriorRevision -eq 0 -and -not $r.PriorCheckFirst) { Ok "-Content '' -> RemovePriorRevision 0, PriorCheckFirst false, no throw" } else { Bad "-Content '' -> $($r.RemovePriorRevision)" }
} catch { Bad "RemovePriorRevision threw: $($_.Exception.Message)" }
# -- [12] GeneratorVersion 3 and the extension marker (lean deploy script PR 2) ---------------------------------
Write-Host '[12] GeneratorVersion 3: the loader names the generator and the toolkit extension version' -ForegroundColor Cyan
$p = Join-Path $TMP 'gv3.ps1'
[System.IO.File]::WriteAllText($p, $g42z, (New-Object System.Text.UTF8Encoding($true)))
$null = Set-PSADTDataDrivenScript -ScriptPath $p -InstallerType exe -WarningAction SilentlyContinue
$g3 = ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
$r = Shape $g3
if ($r.GeneratorVersion -eq 3 -and $r.ExtensionName -ceq 'PSAppDeployToolkit.Win32Toolkit' -and $r.ExtensionVersion -eq [version]'1.0.0' -and $r.Support -eq 'Supported') { Ok 'generated -> GeneratorVersion 3, ExtensionName PSAppDeployToolkit.Win32Toolkit, ExtensionVersion 1.0.0, Supported' } else { Bad "gv3 -> $($r.GeneratorVersion) $($r.ExtensionName) $($r.ExtensionVersion) $($r.Support)" }
$marker = '## win32-toolkit generator 3; extension PSAppDeployToolkit.Win32Toolkit 1.0.0'
$noMarker = $g3.Replace("$marker`n", '')
$r = Shape $noMarker
if ($noMarker -ne $g3 -and $r.GeneratorVersion -eq 2 -and $null -eq $r.ExtensionName -and $null -eq $r.ExtensionVersion -and $r.Support -eq 'Supported') { Ok 'the marker removed -> GeneratorVersion 2 (inline-block projects stay Supported)' } else { Bad "no marker -> $($r.GeneratorVersion) $($r.ExtensionName) $($r.Support)" }
$r = Shape ($noMarker + "`n$marker`n")
if ($r.GeneratorVersion -eq 2) { Ok 'the marker outside the loader block does not count -> GeneratorVersion 2' } else { Bad "marker outside -> $($r.GeneratorVersion)" }
$r = Shape ($g3.Replace($marker, '## win32-toolkit generator 4; extension PSAppDeployToolkit.Win32Toolkit 2.0.0'))
if ($r.GeneratorVersion -eq 4 -and $r.Support -eq 'Unsupported' -and $r.SupportReason -match 'newer win32-toolkit') { Ok 'generator 4 (a newer toolkit) -> Unsupported, "newer win32-toolkit"' } else { Bad "gen 4 -> $($r.GeneratorVersion) $($r.Support) '$($r.SupportReason)'" }
$r = Shape ($g3.Replace($marker, '## win32-toolkit generator 3; extension PSAppDeployToolkit.Win32Toolkit one'))
if ($r.GeneratorVersion -eq 2 -and $null -eq $r.ExtensionVersion) { Ok 'an unreadable extension version -> the marker does not count (GeneratorVersion 2)' } else { Bad "bad version -> $($r.GeneratorVersion) $($r.ExtensionVersion)" }
# The generator converts nothing in place: a GeneratorVersion 2 script is refused, the file left as it is.
$p2 = Join-Path $TMP 'gv2.ps1'
[System.IO.File]::WriteAllText($p2, $noMarker, (New-Object System.Text.UTF8Encoding($true)))
$h2 = (Get-FileHash -LiteralPath $p2).Hash
$fq = try { $null = Set-PSADTDataDrivenScript -ScriptPath $p2 -InstallerType exe -WarningAction SilentlyContinue; '' } catch { $_.FullyQualifiedErrorId }
if ($fq -eq 'W32T.UnsupportedTemplateShape' -and (Get-FileHash -LiteralPath $p2).Hash -eq $h2) { Ok 'the generator refuses a GeneratorVersion 2 script (W32T.UnsupportedTemplateShape), the file untouched' } else { Bad "gv2 regenerate -> '$fq'" }
Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'DeployScriptShape unit test PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
