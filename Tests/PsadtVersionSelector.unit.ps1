<#
    Menu selectors: the PSAppDeployToolkit version screen (knowledge-base/designs/menu-selectors.md §3, P1-P8).

      [1] Get-Win32ToolkitPsadtChoice: no pin / newest x.y per installed minor / exact versions, from the data; out-of-range
          copies never offered; ResolvesTo equals what Select-Win32ToolkitPsadtModule gives for that value (a '4.2' that
          resolves to a newer prerelease says so); IsCurrent follows the saved value case-insensitively; one row for a
          version installed in two PSModulePath roots.
      [2] Get-Win32ToolkitPsadtGalleryVersion: PSGallery, -AllVersions, no -AllowPrerelease; only stable, in range, not
          installed; a version whose number an installed prerelease shares is a 'Replace' row; newest first; a failing
          Find-Module is a Problem text, never a throw.
      [3] Install-Win32ToolkitPsadtVersion: the one Install-Module call and its exact parameters; W32T.PsadtInstallRefused
          (and no install) for out of range, a prerelease, installed, a same-number copy without -Replace, and -Replace
          while this process has that number loaded; -WhatIf installs nothing.
      [4] Set-Win32ToolkitPsadtPreference: '' clears; installed values save; a missing, out-of-range or free-text value is
          refused (W32T.PsadtPreferenceRefused) with no write; -ErrorAction Stop reaches the writer; a blocked write reads
          back the old value (Ok $false); the environment pin is never touched.
      [5] The screen, driven with Spectre shadows: save a choice, the prerelease question, the env-pin and loaded-copy
          notes, the install flow, a pin that is not installed (PE3), the gallery failure; Settings dispatches 'psadt'.
      [6] Never Update-Module / Uninstall-Module / Import-Module PSAppDeployToolkit / Remove-Module (calls recorded across
          the suite) and file hygiene of the new files.

    Fake module roots live under %TEMP% and PSModulePath is replaced IN THIS PROCESS only, so the machine's real PSADT
    copies are invisible. $env:W32T_PSADT_VERSION is cleared and the registry is shadowed.

    Run:  pwsh -File Tests\PsadtVersionSelector.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
foreach ($f in 'Test-Win32ToolkitPsadtVersionSupported', 'Select-Win32ToolkitPsadtModule', 'ConvertTo-Win32ToolkitSafeText',
    'Get-Win32ToolkitPsadtChoice', 'Get-Win32ToolkitPsadtGalleryVersion', 'Install-Win32ToolkitPsadtVersion',
    'Set-Win32ToolkitPsadtPreference', 'Show-Win32ToolkitPsadtVersion', 'Show-Win32ToolkitSettings') {
    . (Join-Path $repo "Private\$f.ps1")
}

# -- Shadows: registry, gallery, installs, forbidden module commands --------------------------------------------------
$script:cfg = @{}
$script:blockWrites = $false
$script:writes = [System.Collections.Generic.List[object]]::new()
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$script:cfg[$Name])) { [string]$script:cfg[$Name] } else { $Default } }
function Set-Win32ToolkitConfigValue {
    [CmdletBinding()] param($Name, $Value)
    $script:writes.Add([pscustomobject]@{ Name = $Name; Value = $Value; ErrorAction = [string]$PSBoundParameters['ErrorAction'] })
    if (-not $script:blockWrites) { $script:cfg[$Name] = $Value }
}
$script:gallery = @()
$script:galleryThrows = $false
$script:findCalls = [System.Collections.Generic.List[object]]::new()
function Find-Module {
    [CmdletBinding()] param($Name, $Repository, [switch]$AllVersions, [switch]$AllowPrerelease)
    $script:findCalls.Add($PSBoundParameters)
    if ($script:galleryThrows) { throw "Unable to resolve package source 'https://www.powershellgallery.com/api/v2'.`e[31m" }
    foreach ($v in $script:gallery) { [pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = $v } }
}
$script:installCalls = [System.Collections.Generic.List[object]]::new()
$script:installRoot = $null
function Install-Module {
    [CmdletBinding()] param($Name, $Repository, $RequiredVersion, $Scope, [switch]$Force, [switch]$AllowClobber, [switch]$AllowPrerelease)
    $copy = @{}; foreach ($k in $PSBoundParameters.Keys) { $copy[$k] = $PSBoundParameters[$k] }
    $script:installCalls.Add($copy)
    if ($script:installRoot) { $null = MakeFakePsadt $script:installRoot ([string]$RequiredVersion) }
}
$script:forbidden = [System.Collections.Generic.List[string]]::new()
function Update-Module    { $script:forbidden.Add("Update-Module $args") }
function Uninstall-Module { $script:forbidden.Add("Uninstall-Module $args") }
function Remove-Module    { $script:forbidden.Add("Remove-Module $args") }
function Import-Module {
    [CmdletBinding()] param([Parameter(Position = 0)]$Name, [Parameter(ValueFromRemainingArguments)]$Rest)
    if ("$Name $Rest" -match 'PSAppDeployToolkit') { $script:forbidden.Add("Import-Module $Name") } else { Microsoft.PowerShell.Core\Import-Module $Name }
}
# The copy "loaded in this process": Get-Module -All returns $script:loadedFake; everything else is the real command.
$script:loadedFake = @()
function Get-Module {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [switch]$ListAvailable, [switch]$All)
    if ($All -and -not $ListAvailable) { return @($script:loadedFake) }
    Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
}

# -- Spectre shadows: record what is shown, answer from queues ----------------------------------------------------------
$script:hostLines = [System.Collections.Generic.List[string]]::new()
$script:panels = [System.Collections.Generic.List[string]]::new()
$script:prompts = [System.Collections.Generic.List[object]]::new()
$script:picks = [System.Collections.Queue]::new()
$script:confirms = [System.Collections.Queue]::new()
$script:confirmTexts = [System.Collections.Generic.List[string]]::new()
function Clear-Host { }
function Write-SpectreRule { param([Parameter(ValueFromRemainingArguments)]$a) }
function Write-SpectreHost { param([Parameter(Position = 0)]$Message) $script:hostLines.Add([string]$Message) }
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) $script:panels.Add("$Header|$Data") }
$script:tableRows = [System.Collections.Generic.List[object]]::new()
function Format-SpectreTable { param([Parameter(ValueFromPipeline)]$InputObject, [Parameter(ValueFromRemainingArguments)]$a) process { $script:tableRows.Add($InputObject) } }
function Out-SpectreHost { param([Parameter(ValueFromPipeline)]$Data) process { } }
function Get-SpectreEscapedText { param($Text) $Text }
function Read-SpectrePause { param([Parameter(ValueFromRemainingArguments)]$a) }
function Read-SpectreConfirm {
    param($Message, $DefaultAnswer)
    $script:confirmTexts.Add("$Message|$DefaultAnswer")
    if ($script:confirms.Count -eq 0) { throw "unexpected question: $Message" }
    [bool]$script:confirms.Dequeue()
}
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, $PageSize)
    $script:prompts.Add([pscustomobject]@{ Message = $Message; Labels = @($Choices | ForEach-Object { $_.Label }) })
    if ($script:picks.Count -eq 0) { throw "unexpected menu: $Message" }
    $want = [string]$script:picks.Dequeue()
    $hit = @($Choices | Where-Object { $_.Label -like $want }) | Select-Object -First 1
    if (-not $hit) { throw "no choice like '$want' in: $(@($Choices | ForEach-Object { $_.Label }) -join ' | ')" }
    $hit
}
function Reset-Ui { $script:hostLines.Clear(); $script:panels.Clear(); $script:prompts.Clear(); $script:picks.Clear(); $script:confirms.Clear(); $script:confirmTexts.Clear() }
function Drive { param([string[]]$Picks, [bool[]]$Confirms = @())
    Reset-Ui
    foreach ($p in $Picks) { $script:picks.Enqueue($p) }
    foreach ($c in $Confirms) { $script:confirms.Enqueue($c) }
    $err = $null
    try { Show-Win32ToolkitPsadtVersion } catch { $err = $_ }
    [pscustomobject]@{ Error = $err; PicksLeft = $script:picks.Count; ConfirmsLeft = $script:confirms.Count }
}

# -- Fake PSADT copies ---------------------------------------------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('w32psel_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$null = New-Item -ItemType Directory -Path $work -Force
# <Root>\PSAppDeployToolkit\<base version>\ (a prerelease lives in its BASE-version folder, as PowerShellGet installs it).
function MakeFakePsadt([string]$Root, [string]$Version) {
    $base = $Version -replace '[-+].*$', ''
    $pre  = if ($Version -match '-(.+)$') { $Matches[1] } else { '' }
    $dir  = Join-Path $Root (Join-Path 'PSAppDeployToolkit' $base)
    $null = New-Item -ItemType Directory -Path $dir -Force
    $psData = if ($pre) { "@{ Prerelease = '$pre' }" } else { '@{ Tags = @(''fake'') }' }
    Set-Content -LiteralPath (Join-Path $dir 'PSAppDeployToolkit.psd1') -Encoding utf8 -Value (@(
            '@{', "    RootModule = 'PSAppDeployToolkit.psm1'", "    ModuleVersion = '$base'",
            "    GUID = '8c3c366b-8606-4576-9f2d-4051144f7ca2'", "    PrivateData = @{ PSData = $psData }", '}') -join "`r`n")
    Set-Content -LiteralPath (Join-Path $dir 'PSAppDeployToolkit.psm1') -Value '# fake' -Encoding utf8
    return $dir
}
$savedModulePath = $env:PSModulePath
$savedPin = $env:W32T_PSADT_VERSION
Remove-Item Env:W32T_PSADT_VERSION -ErrorAction SilentlyContinue

try {
    $rootA = Join-Path $work 'a'; $rootB = Join-Path $work 'b'; $rootC = Join-Path $work 'c'
    $null = MakeFakePsadt $rootA '4.2.0-rc2'
    $null = MakeFakePsadt $rootA '4.1.8'
    foreach ($v in '4.2.0', '4.1.8', '4.3.0') { $null = MakeFakePsadt $rootB $v }
    $env:PSModulePath = "$rootA;$rootB"

    # ============================== [1] choices ==============================
    Write-Host '[1] Get-Win32ToolkitPsadtChoice: rows from the data, ResolvesTo, IsCurrent' -ForegroundColor Cyan
    $sel = Select-Win32ToolkitPsadtModule
    $rows = @(Get-Win32ToolkitPsadtChoice -Selection $sel -SavedValue '')
    $got = ($rows | ForEach-Object { "$($_.Kind):$($_.Value)>$($_.ResolvesTo)" }) -join ' | '
    $want = 'Default:>4.2.0 | Minor:4.2>4.2.0 | Minor:4.1>4.1.8 | Exact:4.2.0>4.2.0 | Exact:4.2.0-rc2>4.2.0-rc2 | Exact:4.1.8>4.1.8'
    if ($got -eq $want) { Ok "rows: $got (4.3.0 never offered; 4.1.8 in two roots = one row)" } else { Bad "rows: $got (want $want)" }
    $rc = $rows | Where-Object { $_.Value -eq '4.2.0-rc2' }
    if ($rc.IsPrerelease -and $rc.Label -eq 'Exactly 4.2.0-rc2 (prerelease: testing only)') { Ok 'a prerelease is marked testing only' } else { Bad "prerelease row: $($rc.Label)" }
    if (@($rows | Where-Object IsCurrent).Count -eq 1 -and ($rows | Where-Object IsCurrent).Kind -eq 'Default') { Ok 'saved "" marks the Default row' } else { Bad 'IsCurrent for ""' }
    $cur = @(Get-Win32ToolkitPsadtChoice -Selection $sel -SavedValue '4.2.0-RC2') | Where-Object IsCurrent
    if (@($cur).Count -eq 1 -and $cur.Value -eq '4.2.0-rc2') { Ok 'saved 4.2.0-RC2 marks the rc2 row (case-insensitive)' } else { Bad 'IsCurrent case-insensitive' }
    $cur = @(Get-Win32ToolkitPsadtChoice -Selection $sel -SavedValue '4.1') | Where-Object IsCurrent
    if (@($cur).Count -eq 1 -and $cur.Kind -eq 'Minor' -and $cur.Value -eq '4.1') { Ok 'saved 4.1 marks the 4.1.x row' } else { Bad 'IsCurrent 4.1' }
    $cur = @(Get-Win32ToolkitPsadtChoice -Selection $sel -SavedValue '4.1.7') | Where-Object IsCurrent
    if (@($cur).Count -eq 0) { Ok 'a saved value that is not offered marks nothing' } else { Bad 'IsCurrent for a missing pin' }

    # A newer prerelease: '4.2' and no pin resolve to it, exactly as the selector does.
    $null = MakeFakePsadt $rootC '4.2.1-rc1'
    $env:PSModulePath = "$rootA;$rootB;$rootC"
    $sel = Select-Win32ToolkitPsadtModule
    $rows = @(Get-Win32ToolkitPsadtChoice -Selection $sel -SavedValue '')
    $agree = $true
    foreach ($r in $rows) {
        $s = if ($r.Kind -eq 'Default') { Select-Win32ToolkitPsadtModule } else { Select-Win32ToolkitPsadtModule -PreferredVersion $r.Value }
        if ($s.VersionText -ne $r.ResolvesTo) { $agree = $false; Bad "$($r.Kind) '$($r.Value)' resolves to $($r.ResolvesTo), the selector gives $($s.VersionText)" }
    }
    if ($agree) { Ok "ResolvesTo equals Select-Win32ToolkitPsadtModule for all $($rows.Count) rows" }
    if (($rows | Where-Object { $_.Value -eq '4.2' }).ResolvesTo -eq '4.2.1-rc1') { Ok "'4.2' says it resolves to the newer prerelease 4.2.1-rc1" } else { Bad "'4.2' resolves to $(($rows | Where-Object { $_.Value -eq '4.2' }).ResolvesTo)" }
    $empty = @(Get-Win32ToolkitPsadtChoice -Selection ([pscustomobject]@{ Candidates = @() }) -SavedValue '')
    if ($empty.Count -eq 1 -and $empty[0].Kind -eq 'Default' -and $empty[0].ResolvesTo -eq '') { Ok 'nothing installed: only the Default row' } else { Bad "empty: $($empty.Count) rows" }
    Remove-Item -LiteralPath $rootC -Recurse -Force
    $env:PSModulePath = "$rootA;$rootB"

    # ============================== [2] gallery ==============================
    Write-Host '[2] Get-Win32ToolkitPsadtGalleryVersion: stable, in range, not installed, Replace rows' -ForegroundColor Cyan
    $rootD = Join-Path $work 'd'
    $null = MakeFakePsadt $rootD '4.1.8'
    $null = MakeFakePsadt $rootD '4.2.0-rc2'
    $rootE = Join-Path $work 'e'; $null = New-Item -ItemType Directory -Path $rootE -Force
    $env:PSModulePath = "$rootD;$rootE"
    $sel = Select-Win32ToolkitPsadtModule
    $script:gallery = @('4.0.9', '4.1.8', '4.1.9', '4.2.0', '4.2.1', '4.3.0', '4.2.2-beta1', '4.1.9')
    $script:findCalls.Clear()
    $g = Get-Win32ToolkitPsadtGalleryVersion -Candidates $sel.Candidates
    $got = ($g.Versions | ForEach-Object { "$($_.Kind):$($_.VersionText)$(if ($_.Replaces) { "<$($_.Replaces)" })" }) -join ' | '
    if ($null -eq $g.Problem -and $got -eq 'Install:4.2.1 | Replace:4.2.0<4.2.0-rc2 | Install:4.1.9') { Ok "versions: $got" } else { Bad "versions: $got (Problem $($g.Problem))" }
    $fc = $script:findCalls[0]
    if ($script:findCalls.Count -eq 1 -and $fc['Repository'] -eq 'PSGallery' -and $fc['AllVersions'] -and -not $fc.ContainsKey('AllowPrerelease') -and $fc['Name'] -eq 'PSAppDeployToolkit') { Ok 'one Find-Module: PSGallery, -AllVersions, no -AllowPrerelease' } else { Bad "Find-Module calls: $($script:findCalls.Count) $($fc | Out-String)" }
    $script:galleryThrows = $true
    $g = $null; $err = $null
    try { $g = Get-Win32ToolkitPsadtGalleryVersion -Candidates $sel.Candidates } catch { $err = $_ }
    if (-not $err -and $g.Problem -match '^Could not reach PowerShell Gallery' -and @($g.Versions).Count -eq 0 -and $g.Problem -notmatch "`e") { Ok "gallery failure: a sanitized Problem, no throw ($($g.Problem))" } else { Bad "gallery failure: $err / $($g.Problem)" }
    $script:galleryThrows = $false

    # ============================== [3] install ==============================
    Write-Host '[3] Install-Win32ToolkitPsadtVersion: one call, exact parameters, refusals' -ForegroundColor Cyan
    $script:installRoot = $rootE
    $tryInstall = { param($V, [switch]$Replace)
        $script:installCalls.Clear(); $e = $null; $r = $null
        try { $r = Install-Win32ToolkitPsadtVersion -Version $V -Replace:$Replace } catch { $e = $_ }
        [pscustomobject]@{ Err = $e; Result = $r; Calls = $script:installCalls.Count }
    }
    foreach ($case in @(
            @{ V = '4.3.0'; Why = 'out of range' }, @{ V = '4.2.1-rc1'; Why = 'a prerelease' }, @{ V = '4.1.8'; Why = 'already installed' },
            @{ V = '4.2.0'; Why = 'the rc2 folder without -Replace' }, @{ V = 'latest'; Why = 'free text' })) {
        $x = & $tryInstall $case.V
        if ($x.Err -and $x.Err.FullyQualifiedErrorId -like 'W32T.PsadtInstallRefused*' -and $x.Calls -eq 0) { Ok "refused, nothing installed: $($case.V) ($($case.Why)): $($x.Err.Exception.Message)" } else { Bad "$($case.V): err=$($x.Err) calls=$($x.Calls)" }
    }
    $script:loadedFake = @([pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = [version]'4.2.0'; ModuleBase = (Join-Path $rootD 'PSAppDeployToolkit\4.2.0') })
    $x = & $tryInstall '4.2.0' -Replace
    if ($x.Err -and $x.Err.FullyQualifiedErrorId -like 'W32T.PsadtInstallRefused*' -and $x.Err.Exception.Message -match 'new PowerShell session' -and $x.Calls -eq 0) { Ok "Replace refused while this process has 4.2.0-rc2 loaded" } else { Bad "Replace while loaded: $($x.Err) calls=$($x.Calls)" }
    $script:loadedFake = @()
    $x = & $tryInstall '4.2.1'
    $call = if ($x.Calls) { $script:installCalls[0] } else { @{} }
    $paramsOk = $call['Name'] -eq 'PSAppDeployToolkit' -and $call['Repository'] -eq 'PSGallery' -and $call['RequiredVersion'] -eq '4.2.1' -and
        $call['Scope'] -eq 'CurrentUser' -and $call['Force'] -and $call['AllowClobber'] -and -not $call.ContainsKey('AllowPrerelease') -and [string]$call['ErrorAction'] -eq 'Stop'
    if (-not $x.Err -and $x.Calls -eq 1 -and $paramsOk) { Ok 'one Install-Module: PSAppDeployToolkit, PSGallery, -RequiredVersion 4.2.1, CurrentUser, -Force -AllowClobber, -ErrorAction Stop' } else { Bad "install 4.2.1: err=$($x.Err) calls=$($x.Calls) $($call | Out-String)" }
    if ($x.Result -and $x.Result.Status -eq 'Selected' -and $x.Result.VersionText -eq '4.2.1') { Ok 'returns the selection after the install (4.2.1 now newest)' } else { Bad "result: $($x.Result.Status) $($x.Result.VersionText)" }
    $x = & $tryInstall '4.2.0' -Replace
    if (-not $x.Err -and $x.Calls -eq 1) { Ok 'Replace of the rc2 folder installs when nothing has it loaded' } else { Bad "Replace: $($x.Err) calls=$($x.Calls)" }
    $script:installCalls.Clear()
    $r = Install-Win32ToolkitPsadtVersion -Version '4.1.9' -WhatIf
    if ($null -eq $r -and $script:installCalls.Count -eq 0) { Ok '-WhatIf installs nothing' } else { Bad "-WhatIf: calls=$($script:installCalls.Count)" }

    # ============================== [4] save ==============================
    Write-Host '[4] Set-Win32ToolkitPsadtPreference: checked, written with -ErrorAction Stop, read back' -ForegroundColor Cyan
    $env:PSModulePath = "$rootA;$rootB"
    $script:cfg = @{}; $script:writes.Clear()
    foreach ($v in '4.1', '4.1.8', '4.2.0-RC2', '') {
        $r = Set-Win32ToolkitPsadtPreference -Value $v
        $w = $script:writes[$script:writes.Count - 1]
        if ($r.Ok -and $r.Saved -eq $v -and $w.Name -eq 'PreferredPsadtVersion' -and $w.Value -eq $v -and $w.ErrorAction -eq 'Stop') { Ok "'$v' saved and read back (-ErrorAction Stop)" } else { Bad "'$v': Ok=$($r.Ok) Saved='$($r.Saved)' write=$($w | Out-String)" }
    }
    $script:cfg['PreferredPsadtVersion'] = '4.1.8'
    foreach ($v in '4.1.7', '4.3.0', 'latest', '4.2;Remove-Item', '4.3') {
        $script:writes.Clear(); $e = $null
        try { $null = Set-Win32ToolkitPsadtPreference -Value $v } catch { $e = $_ }
        if ($e -and $e.FullyQualifiedErrorId -like 'W32T.PsadtPreferenceRefused*' -and $script:writes.Count -eq 0 -and $script:cfg['PreferredPsadtVersion'] -eq '4.1.8') { Ok "'$v' refused, nothing written" } else { Bad "'$v': err=$e writes=$($script:writes.Count)" }
    }
    $script:blockWrites = $true
    $r = Set-Win32ToolkitPsadtPreference -Value '4.2.0'
    if (-not $r.Ok -and $r.Saved -eq '4.1.8' -and $r.Requested -eq '4.2.0') { Ok 'a blocked write reads back the old value (Ok $false)' } else { Bad "blocked: Ok=$($r.Ok) Saved=$($r.Saved)" }
    $script:blockWrites = $false
    $env:W32T_PSADT_VERSION = '4.1.8'
    $null = Set-Win32ToolkitPsadtPreference -Value '4.2.0'
    if ($env:W32T_PSADT_VERSION -eq '4.1.8') { Ok 'the environment pin is untouched' } else { Bad 'the env pin changed' }
    Remove-Item Env:W32T_PSADT_VERSION

    # ============================== [5] the screen ==============================
    Write-Host '[5] Show-Win32ToolkitPsadtVersion, driven' -ForegroundColor Cyan
    $env:PSModulePath = "$rootA;$rootB"
    $script:cfg = @{}
    $x = Drive -Picks 'Exactly 4.1.8', 'Back'
    if (-not $x.Error -and $x.PicksLeft -eq 0 -and $script:cfg['PreferredPsadtVersion'] -eq '4.1.8' -and $script:panels -match '^Saved\|New projects get PSADT 4\.1\.8\.') { Ok 'choosing "Exactly 4.1.8" saves it and says what new projects get' } else { Bad "save: $($x.Error) left=$($x.PicksLeft) cfg=$($script:cfg['PreferredPsadtVersion']) panels=$($script:panels -join ' || ')" }
    $labels = $script:prompts[0].Labels
    if (($labels -contains 'Use the newest supported version (no pin) - now 4.2.0 (saved)') -and ($labels -contains 'Always the newest installed 4.1.x - now 4.1.8') -and ($labels -contains 'Install another supported version from PowerShell Gallery') -and ($labels[-1] -eq 'Back')) { Ok "menu labels: $($labels -join ' | ')" } else { Bad "labels: $($labels -join ' | ')" }
    # The folder is pre-wrapped at '\' to the width its column gets (live check 2026-10-29: a long OneDrive module path
    # squeezed the other columns to '...'); joined again it is the folder.
    $bufW = 0; try { $bufW = [int]$Host.UI.RawUI.BufferSize.Width } catch { $bufW = 0 }; if ($bufW -le 0) { $bufW = 120 }
    $deep = Join-Path $work ('very-long-folder-name-for-the-wrap-check\' * 4).TrimEnd('\')
    $null = MakeFakePsadt $deep '4.1.9'
    $env:PSModulePath = "$rootA;$rootB;$deep"
    $script:tableRows.Clear()
    $x = Drive -Picks 'Back'
    $row = $script:tableRows | Where-Object { $_.Version -eq '4.1.9' }
    $folderW = [Math]::Max(20, $bufW - 16 - 'Version'.Length - 'Supported'.Length - 'prerelease'.Length - 'ignored'.Length - 1)
    $lines = @(([string]$row.Folder) -split "`n")
    $want = Join-Path $deep 'PSAppDeployToolkit\4.1.9'
    if (-not $x.Error -and $lines.Count -gt 1 -and @($lines | Where-Object { $_.Length -gt $folderW }).Count -eq 0 -and ($lines -join '') -eq $want -and $lines[0].EndsWith('\')) { Ok "the folder is wrapped at '\' to $folderW columns ($($lines.Count) lines) and joins back to the path" } else { Bad "folder wrap: $($x.Error) width $folderW lines $($lines | ForEach-Object { $_.Length })" }
    # The saved pin is 4.1.8 here (the save above): exactly one row, the first 4.1.8 in PSModulePath order, is in use.
    $inUse = @($script:tableRows | Where-Object { $_.Status -eq '[green]in use[/]' })
    if ($inUse.Count -eq 1 -and $inUse[0].Version -eq '4.1.8' -and $inUse[0].Folder -like "$rootA*" -and ($script:tableRows | Where-Object { $_.Version -eq '4.3.0' }).Status -eq '[grey]ignored[/]') { Ok 'Status: exactly the copy new projects get is "in use" (pin 4.1.8, the first root), an unsupported one "ignored"' } else { Bad "status: $(($script:tableRows | ForEach-Object { "$($_.Version)=$($_.Status)" }) -join ' ')" }
    Remove-Item -LiteralPath (Join-Path $work 'very-long-folder-name-for-the-wrap-check') -Recurse -Force
    $env:PSModulePath = "$rootA;$rootB"
    $x = Drive -Picks 'Exactly 4.1.8 (saved)', 'Back'
    if (-not $x.Error -and ($script:hostLines -match 'already your saved choice') -and ($script:hostLines -match "Why:.*pinned by PreferredPsadtVersion '4\.1\.8'")) { Ok 'the saved choice is marked; choosing it again changes nothing; the why line names the registry pin' } else { Bad "again: $($x.Error) $($script:hostLines -join ' || ')" }
    $x = Drive -Picks 'Exactly 4.2.0-rc2*', 'Back' -Confirms $false
    if (-not $x.Error -and $script:cfg['PreferredPsadtVersion'] -eq '4.1.8' -and ($script:confirmTexts -match 'prerelease.*\|n$')) { Ok 'a prerelease asks first (default No); No saves nothing' } else { Bad "prerelease: $($x.Error) cfg=$($script:cfg['PreferredPsadtVersion']) q=$($script:confirmTexts -join ' || ')" }
    $env:W32T_PSADT_VERSION = '4.2.0'
    $x = Drive -Picks 'Back'
    if (-not $x.Error -and ($script:hostLines -match "pinned by .env:W32T_PSADT_VERSION = '4\.2\.0' in this window") -and ($script:hostLines -match 'This window keeps the variable until you close it')) { Ok 'an env pin: the why line and the note' } else { Bad "env: $($script:hostLines -join ' || ')" }
    Remove-Item Env:W32T_PSADT_VERSION
    $script:loadedFake = @([pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = [version]'4.2.0'; ModuleBase = (Join-Path $rootA 'PSAppDeployToolkit\4.2.0') })
    $x = Drive -Picks 'Back'
    if (-not $x.Error -and ($script:hostLines -match 'Loaded in this window: 4\.2\.0-rc2.*') -and ($script:hostLines -match 'Start a new PowerShell session to use 4\.1\.8')) { Ok 'a loaded copy that differs: keep it in this window, start a new session' } else { Bad "loaded: $($script:hostLines -join ' || ')" }
    $script:loadedFake = @()

    # Install flow: a new 4.2.1 becomes the newest; the pin 4.1.8 hides it, so the screen offers to use it.
    $rootF = Join-Path $work 'f'; $null = New-Item -ItemType Directory -Path $rootF -Force
    $env:PSModulePath = "$rootA;$rootB;$rootF"
    $script:installRoot = $rootF
    $script:gallery = @('4.1.8', '4.2.0', '4.2.1')
    $script:installCalls.Clear()
    $x = Drive -Picks 'Install another supported version*', 'Install 4.2.1', 'Back' -Confirms $true, $true
    if (-not $x.Error -and $x.PicksLeft -eq 0 -and $x.ConfirmsLeft -eq 0 -and $script:installCalls.Count -eq 1 -and $script:installCalls[0]['RequiredVersion'] -eq '4.2.1' -and $script:cfg['PreferredPsadtVersion'] -eq '4.2.1') { Ok 'install flow: list, confirm, one Install-Module, "Use 4.2.1 for new projects?" saves it' } else { Bad "install flow: $($x.Error) left=$($x.PicksLeft)/$($x.ConfirmsLeft) calls=$($script:installCalls.Count) cfg=$($script:cfg['PreferredPsadtVersion'])" }
    if (($script:confirmTexts[0] -match '^Install PSAppDeployToolkit 4\.2\.1 for your Windows account\?.*\|n$') -and ($script:confirmTexts[1] -match '^Use 4\.2\.1 for new projects\?\|y$')) { Ok 'install question default No; use-it question default Yes' } else { Bad "questions: $($script:confirmTexts -join ' || ')" }
    $vlabels = $script:prompts[1].Labels
    if (($vlabels -join '|') -eq 'Install 4.2.1|Back') { Ok "only installable versions are offered: $($vlabels -join ' | ')" } else { Bad "version labels: $($vlabels -join ' | ')" }
    $x = Drive -Picks 'Install another supported version*', 'Back' -Confirms @()
    if (-not $x.Error -and ($script:panels -match '^Nothing to install\|')) { Ok 'everything installed: "Nothing to install"' } else { Bad "nothing: $($x.Error) $($script:panels -join ' || ')" }
    $script:galleryThrows = $true
    $x = Drive -Picks 'Install another supported version*', 'Back'
    if (-not $x.Error -and ($script:panels -match '^Gallery not reachable\|')) { Ok 'gallery failure: a panel, the screen goes on' } else { Bad "gallery fail: $($x.Error)" }
    $script:galleryThrows = $false

    # PE3: a registry pin that is not installed; the gallery has it.
    Remove-Item -LiteralPath $rootF -Recurse -Force; $null = New-Item -ItemType Directory -Path $rootF -Force
    $script:cfg['PreferredPsadtVersion'] = '4.1.9'
    $script:gallery = @('4.1.9')
    $script:installCalls.Clear()
    $x = Drive -Picks 'Install the pinned version 4.1.9', 'Back' -Confirms $true
    if (-not $x.Error -and ($script:hostLines -match '^\[red\]New projects cannot start now:') -and $script:installCalls.Count -eq 1 -and $script:installCalls[0]['RequiredVersion'] -eq '4.1.9' -and $script:cfg['PreferredPsadtVersion'] -eq '4.1.9') { Ok 'a missing pin: red line, "Install the pinned version" installs it, the pin stays' } else { Bad "PE3: $($x.Error) calls=$($script:installCalls.Count) $($script:hostLines -join ' || ')" }

    # Settings dispatches the new item, and its label says what new projects get.
    $script:cfg = @{}
    $script:psadtScreen = 0
    function Show-Win32ToolkitPsadtVersion { $script:psadtScreen++ }
    function Get-Win32ToolkitHyperVTarget { param([switch]$NoThrow) [pscustomobject]@{ VMName = 'win32tk-golden'; CheckpointName = 'clean-base'; Problem = $null } }
    Reset-Ui; $script:picks.Enqueue('PSAppDeployToolkit version*'); $script:picks.Enqueue('Back to main menu')
    Show-Win32ToolkitSettings -BasePath 'C:\Win32Apps'
    $sl = $script:prompts[0].Labels
    if ($script:psadtScreen -eq 1 -and ($sl -contains 'PSAppDeployToolkit version: 4.2.0 (newest installed)') -and ($sl -contains 'Hyper-V test VM: win32tk-golden / clean-base (backend / choose / provision / reset / remove)')) { Ok "Settings: $($sl -join ' | ')" } else { Bad "Settings labels: $($sl -join ' | ') screen=$($script:psadtScreen)" }

    # ============================== [6] never ==============================
    Write-Host '[6] no Update-/Uninstall-/Import-/Remove-Module of PSADT; file hygiene' -ForegroundColor Cyan
    if ($script:forbidden.Count -eq 0) { Ok 'no forbidden module command was called in the whole suite' } else { Bad "forbidden: $($script:forbidden -join '; ')" }
    foreach ($f in 'Get-Win32ToolkitPsadtChoice', 'Get-Win32ToolkitPsadtGalleryVersion', 'Install-Win32ToolkitPsadtVersion', 'Set-Win32ToolkitPsadtPreference', 'Show-Win32ToolkitPsadtVersion') {
        $path = Join-Path $repo "Private\$f.ps1"
        $text = Get-Content -LiteralPath $path -Raw
        $code = [regex]::Replace($text, '(?s)<#.*?#>', '')
        $code = ($code -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
        $bad = @()
        if ($code -match '\bUpdate-Module\b|\bUninstall-Module\b|\bRemove-Module\b|\bImport-Module\b|-AllowPrerelease') { $bad += 'a forbidden module command in code' }
        if ($text -match '[^\x00-\x7F]') { $bad += 'non-ASCII' }
        if ($errors.Count -or $fns.Count -ne 1 -or $fns[0].Name -ne $f) { $bad += "parse/function ($($errors.Count) errors, $($fns.Count) functions)" }
        if ($bad.Count -eq 0) { Ok "$f.ps1: one function, ASCII, no forbidden command" } else { Bad "$f.ps1: $($bad -join '; ')" }
    }
}
finally {
    $env:PSModulePath = $savedModulePath
    if ($null -ne $savedPin) { $env:W32T_PSADT_VERSION = $savedPin } else { Remove-Item Env:W32T_PSADT_VERSION -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -gt 0) { Write-Host "FAILED: $fail" -ForegroundColor Red; exit 1 }
Write-Host 'All PSADT version selector checks passed.' -ForegroundColor Green
exit 0
