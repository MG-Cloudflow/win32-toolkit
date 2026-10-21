<#
    Installer-identity PR 1, spec 2.10 / 3.4 (WP-2): the package download is pinned to an installer FAMILY.

      [1] Download-WingetApp without a pin (and with -InstallerType ''): the winget arguments are exactly the
          unpinned ones and no family helper is called (C-9). The winget shadow prints console lines like
          the real one: the result must still be ONE [bool] (winget's stdout goes to the host).
      [2] Download-WingetApp pinned: '--installer-type <t>' per tried type, in family order; winget's
          no-applicable answer (0x8A150010) moves on after removing only that attempt's files and one host line
          names the next type (none after the last type); a substitute
          type warns; every type no-applicable -> W32T.InstallerVariantUnavailable (tried types + both
          options, nothing left behind); any other exit code -> $false with no second attempt; a hostile id
          stays one argument; the new catch starts with the C-2 line.
      [3] Resolve-Win32ToolkitInstallerPin: parameter > continuity (anchored, by winget id only) >
          winget-default; the anchor's pin value (appx -> msix); version 'Unknown' -> one warning and no
          lookup; 'winget --version' read or ''; a failing lookup warns and falls back; K1 + file hygiene.
      [3b] rebuilding a version that is itself published or pinned (Get-Win32ToolkitSelfAnchor, real, over
          temp projects): it keeps its own technology ahead of an older anchor; a parameter pin stays a
          parameter pin; an unanchored self falls through; -InstallerType still wins (and warns when it
          switches the family); an unreadable AppConfig warns and anchors nothing.
      [4] Configure-PSADTForInstaller writes AppConfig.Source from the pin (builder shadowed), survives a
          throwing builder, lets a W32T error through, and its catch (K3) starts with the C-2 line.

    winget, the predecessor lookup and the Source builder are shadowed: no network, nothing installed, no
    winget call. Get-Win32ToolkitInstallerFamily and Test-Win32ToolkitWingetNoApplicableInstaller are real.

    Run:  pwsh -File Tests\WingetVariantPin.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows and case helpers')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'the winget shadow sets $LASTEXITCODE like a native command')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitWingetNoApplicableInstaller.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1')   # every winget download runs through it (C-9)
. (Join-Path $repo 'Private\Download-WingetApp.ps1')
. (Join-Path $repo 'Private\Resolve-Win32ToolkitInstallerPin.ps1')
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Configure-PSADTForInstaller.ps1')
# The rebuild self-anchor ([3b]) runs for real over temp projects: the helper and what it reads.
. (Join-Path $repo 'Private\Get-Win32ToolkitSelfAnchor.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitPublication.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitProjectSource.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32vp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $root -Force | Out-Null
function New-Dl { $p = Join-Path $root ('dl_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }

# Counts calls into the REAL family table (the unpinned path must not touch it, C-9).
$script:familyCalls = 0
$realFamily = ${function:Get-Win32ToolkitInstallerFamily}
function Get-Win32ToolkitInstallerFamily { $script:familyCalls++; & $realFamily @args }

# winget shadow: records every call; per call it pops the next exit code and runs the next "writer" (files it drops).
$script:calls = [System.Collections.Generic.List[object]]::new()
$script:exits = [System.Collections.Generic.Queue[int]]::new()
$script:writers = [System.Collections.Generic.Queue[scriptblock]]::new()
$script:versionOut = 'v1.29.380'
$script:versionThrows = $false
function winget {
    if ($args.Count -eq 1 -and $args[0] -eq '--version') {
        if ($script:versionThrows) { throw 'winget is not installed' }
        return $script:versionOut
    }
    $script:calls.Add(@($args))
    if ($script:writers.Count) { & $script:writers.Dequeue() }
    $global:LASTEXITCODE = if ($script:exits.Count) { $script:exits.Dequeue() } else { 0 }
    # Like the real winget, a download prints console lines on stdout. They must never reach the
    # function's output: @('Found ...', $false) would be truthy for the caller's 'if ($downloadSuccess)'.
    'Found Shadow [x]'
    'Downloading https://example.invalid/shadow'
}
function Reset-Winget([int[]]$Exits, [scriptblock[]]$Writers) {
    $script:calls.Clear(); $script:exits.Clear(); $script:writers.Clear(); $script:familyCalls = 0
    foreach ($e in $Exits) { $script:exits.Enqueue($e) }
    foreach ($w in $Writers) { $script:writers.Enqueue($w) }
}
$NOAPP = -1978335216            # 0x8A150010 APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER
$DLFAIL = 0x8A150008            # download failed (any other winget error)

function Expected([string]$Id, [string]$Dl) {
    @('download', '--id', $Id, '--download-directory', $Dl, '--accept-source-agreements', '--accept-package-agreements', '--architecture', 'x64')
}
function Same([object[]]$A, [object[]]$B) { ($A.Count -eq $B.Count) -and (-not (Compare-Object $A $B -SyncWindow 0 -CaseSensitive)) }

try {
    # == [1] unpinned ====================================================================================
    Write-Host '[1] Download-WingetApp without a pin: the unpinned winget arguments, no family helper' -ForegroundColor Cyan
    $dl = New-Dl
    Reset-Winget -Exits @(0) -Writers @({ Set-Content (Join-Path $dl 'Notepad++.msi') 'x' })
    $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -AppName 'Notepad++' -DownloadPath $dl -Architecture 'x64' 6>$null
    if ($r -eq $true -and $script:calls.Count -eq 1 -and (Same $script:calls[0] (Expected 'Notepad++.Notepad++' $dl))) { Ok 'no -InstallerType: one call, arguments = download --id --download-directory --accept-* --architecture (as before)' } else { Bad "r=$r calls=$($script:calls.Count) args=[$($script:calls[0] -join ' ')]" }
    if ($script:familyCalls -eq 0) { Ok 'no -InstallerType: Get-Win32ToolkitInstallerFamily is never called' } else { Bad "family helper called $script:familyCalls time(s)" }
    if ($r -is [bool] -and $r) { Ok 'unpinned success: the result is ONE [bool] $true (winget''s console lines went to the host, not the output)' } else { Bad "unpinned success result: [$(@($r) -join ' | ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @(0) -Writers @({ Set-Content (Join-Path $dl 'Notepad++.msi') 'x' })
    $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -AppName 'Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType '' -PinnedBy 'winget-default' -PinReason "winget's choice" 6>$null
    if ($r -eq $true -and $script:calls.Count -eq 1 -and (Same $script:calls[0] (Expected 'Notepad++.Notepad++' $dl)) -and $script:familyCalls -eq 0) { Ok "-InstallerType '': byte-identical arguments, no family helper (what Invoke passes for winget's choice)" } else { Bad "r=$r calls=$($script:calls.Count) family=$script:familyCalls args=[$($script:calls[0] -join ' ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @($NOAPP)
    $r = Download-WingetApp -AppId 'Some.App' -DownloadPath $dl -Architecture 'x64' -ErrorAction SilentlyContinue 6>$null
    if ($r -eq $false -and $script:calls.Count -eq 1) { Ok 'unpinned: no-applicable is a plain failure ($false), no retry, no W32T error' } else { Bad "r=$r calls=$($script:calls.Count)" }
    if ($r -is [bool] -and -not $r) { Ok 'unpinned failure: the result is ONE [bool] $false, so ''if ($downloadSuccess)'' is false' } else { Bad "unpinned failure result: [$(@($r) -join ' | ')]" }

    # == [2] pinned ======================================================================================
    Write-Host '[2] Download-WingetApp pinned to a family' -ForegroundColor Cyan
    $dl = New-Dl
    Reset-Winget -Exits @(0) -Writers @({ Set-Content (Join-Path $dl 'npp.msi') 'x' })
    $wv = $null
    $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -AppName 'Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType 'wix' -PinnedBy 'parameter' -PinReason 'requested' -WarningVariable wv -WarningAction SilentlyContinue 6>$null
    if ($r -eq $true -and $script:calls.Count -eq 1 -and (Same $script:calls[0] ((Expected 'Notepad++.Notepad++' $dl) + @('--installer-type', 'wix'))) -and -not $wv) { Ok "pin wix: one call with '--installer-type wix' appended, no warning" } else { Bad "r=$r calls=$($script:calls.Count) args=[$($script:calls[0] -join ' ')] warn=[$($wv -join ';')]" }
    if (-not ($script:calls[0] -contains '--scope')) { Ok "the package download never passes '--scope' (D30)" } else { Bad '--scope passed' }
    if ($r -is [bool] -and $r) { Ok 'pinned success: the result is ONE [bool] $true' } else { Bad "pinned success result: [$(@($r) -join ' | ')]" }

    # first type no-applicable (with a partial file), second type succeeds; a pre-existing file survives.
    $dl = New-Dl
    Set-Content (Join-Path $dl 'keep.txt') 'pre-existing'
    Reset-Winget -Exits @($NOAPP, 0) -Writers @({ Set-Content (Join-Path $dl 'partial.wix.tmp') 'x' }, { Set-Content (Join-Path $dl 'npp.msi') 'x' })
    $wv = $null
    $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType 'wix' -PinnedBy 'parameter' -PinReason 'requested' -WarningVariable wv -WarningAction SilentlyContinue 6>$null
    $types = @($script:calls | ForEach-Object { $_[-1] })
    if ($r -eq $true -and ($types -join ',') -eq 'wix,msi') { Ok 'no wix installer -> second attempt with msi (same family) -> $true' } else { Bad "r=$r types=[$($types -join ',')]" }
    if (-not (Test-Path -LiteralPath (Join-Path $dl 'partial.wix.tmp')) -and (Test-Path -LiteralPath (Join-Path $dl 'keep.txt')) -and (Test-Path -LiteralPath (Join-Path $dl 'npp.msi'))) { Ok "the first attempt's partial file is removed; the pre-existing file and the installer stay" } else { Bad "files: $((Get-ChildItem -LiteralPath $dl -Name) -join ', ')" }
    if (($wv -join ' ') -match '^Requested wix; winget offers msi for this version \(same technology family\) - using it\.$') { Ok 'substitute warning: "Requested wix; winget offers msi ... - using it."' } else { Bad "warning=[$($wv -join ';')]" }

    # The fallback step is announced on the host right after winget's own 'No applicable installer found' line
    # (re-verification 2026-10-21, B1: the raw winget line stood alone until the warning after the download).
    $dl = New-Dl
    Reset-Winget -Exits @($NOAPP, 0) -Writers @({}, { Set-Content (Join-Path $dl 'putty.msi') 'x' })
    $iv = $null
    $r = Download-WingetApp -AppId 'PuTTY.PuTTY' -AppName 'PuTTY' -DownloadPath $dl -Architecture 'x64' -InstallerType 'msi' -PinnedBy 'parameter' -PinReason 'requested' -InformationVariable iv -WarningAction SilentlyContinue 6>$null
    $hostLines = @($iv | ForEach-Object { "$($_.MessageData)" } | Where-Object { $_ -like 'winget offers no*' })
    if ($r -is [bool] -and $r -and $hostLines.Count -eq 1 -and
        $hostLines[0] -ceq "winget offers no 'msi' installer for PuTTY (PuTTY.PuTTY) (the line above is winget's); trying 'wix' (same technology family).") { Ok "pin msi, winget offers wix: one host line names both ('no ''msi'' ... trying ''wix''') and the result is still ONE [bool]" }
    else { Bad "fallback host line: r=[$(@($r) -join ' | ')] lines=[$($hostLines -join ' | ')]" }
    $dl = New-Dl
    Reset-Winget -Exits @(0) -Writers @({ Set-Content (Join-Path $dl 'putty.msi') 'x' })
    $iv = $null
    $null = Download-WingetApp -AppId 'PuTTY.PuTTY' -DownloadPath $dl -Architecture 'x64' -InstallerType 'msi' -InformationVariable iv 6>$null
    if (@($iv | Where-Object { "$($_.MessageData)" -like 'winget offers no*' }).Count -eq 0) { Ok 'the first type downloads -> no fallback line' } else { Bad 'a fallback line without a fallback' }

    # every type of the family no-applicable -> W32T.InstallerVariantUnavailable, nothing downloaded.
    $dl = New-Dl
    Reset-Winget -Exits @($NOAPP, $NOAPP, $NOAPP, $NOAPP) -Writers @({ Set-Content (Join-Path $dl 'a.tmp') 'x' }, {}, { Set-Content (Join-Path $dl 'c.tmp') 'x' }, {})
    $err = $null; $iv = $null
    try { $null = Download-WingetApp -AppId 'Notepad++.Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType 'nullsoft' -PinnedBy 'continuity' -PinReason 'kept from Notepad++_x64_8.8.9 (published)' -InformationVariable iv 6>$null } catch { $err = $_ }
    $types = @($script:calls | ForEach-Object { $_[-1] })
    $next = @($iv | ForEach-Object { "$($_.MessageData)" } | Where-Object { $_ -like 'winget offers no*' } | ForEach-Object { if ($_ -match "trying '([a-z]+)'") { $Matches[1] } })
    if (($next -join ',') -eq 'burn,inno,exe') { Ok "every type no-applicable: a host line per fallback step (burn, inno, exe), none after the last type (the W32T error explains)" } else { Bad "fallback lines name: [$($next -join ',')]" }
    if ($err -and $err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and $err.CategoryInfo.Category -eq 'ObjectNotFound') { Ok 'all no-applicable -> W32T.InstallerVariantUnavailable (ObjectNotFound)' } else { Bad "err=$($err.FullyQualifiedErrorId)" }
    if (($types -join ',') -eq 'nullsoft,burn,inno,exe') { Ok 'pin nullsoft tries the EXE family in order: nullsoft, burn, inno, exe' } else { Bad "types=[$($types -join ',')]" }
    $m = if ($err) { $err.Exception.Message } else { '' }
    if ($m -match '^winget offers no vendor EXE installer for Notepad\+\+\.Notepad\+\+ \(x64\); tried: nullsoft, burn, inno, exe\. ' -and
        $m -match 'pinned \(kept from Notepad\+\+_x64_8\.8\.9 \(published\)\)' -and $m -match 'Nothing was downloaded' -and
        $m -match '\(1\) skip this version' -and $m -match '\(2\) switch technology on purpose with -InstallerType' -and $m -match 'docs/packaging\.md, Installer technology') {
        Ok 'the message names the family, the tried types, the pin reason and both options'
    } else { Bad "message: $m" }
    if (@(Get-ChildItem -LiteralPath $dl -File -Recurse).Count -eq 0) { Ok 'nothing left in Files\ after the failed attempts' } else { Bad "left: $((Get-ChildItem -LiteralPath $dl -Name) -join ', ')" }
    $err2 = $null
    Reset-Winget -Exits @($NOAPP, $NOAPP)
    try { $null = Download-WingetApp -AppId 'Some.App' -DownloadPath (New-Dl) -Architecture 'x64' -InstallerType 'msi' 6>$null } catch { $err2 = $_ }
    if ($err2 -and $err2.Exception.Message -match 'winget offers no MSI installer for Some\.App \(x64\); tried: msi, wix\.') { Ok 'pin msi -> tried: msi, wix (MSI family label)' } else { Bad "msg=$($err2.Exception.Message)" }

    # any other exit code: a plain failure, no next type, no W32T error.
    $dl = New-Dl
    Reset-Winget -Exits @($DLFAIL, 0)
    $err = $null; $r = $null
    try { $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType 'wix' -ErrorAction SilentlyContinue 6>$null } catch { $err = $_ }
    if ($r -eq $false -and -not $err -and $script:calls.Count -eq 1) { Ok '0x8A150008 (download failed) -> $false, no second attempt, no W32T error (V30)' } else { Bad "r=$r err=$($err.FullyQualifiedErrorId) calls=$($script:calls.Count)" }
    if ($r -is [bool] -and -not $r) { Ok 'pinned failure: the result is ONE [bool] $false' } else { Bad "pinned failure result: [$(@($r) -join ' | ')]" }

    # exit 0 but no installer written (zip/portable): the existing check still applies.
    $dl = New-Dl
    Reset-Winget -Exits @(0)
    $r = Download-WingetApp -AppId 'Zip.App' -DownloadPath $dl -Architecture 'x64' -InstallerType 'exe' -ErrorAction SilentlyContinue 6>$null
    if ($r -eq $false) { Ok 'pinned: exit 0 without an installer file -> $false (installer-present check kept)' } else { Bad "r=$r" }

    # hostile id stays ONE argument.
    $dl = New-Dl
    $evil = "Evil.App'; calc.exe; #"
    Reset-Winget -Exits @(0) -Writers @({ Set-Content (Join-Path $dl 'a.exe') 'x' })
    $null = Download-WingetApp -AppId $evil -DownloadPath $dl -Architecture 'x64' -InstallerType 'inno' 6>$null
    if (@($script:calls[0]) -contains $evil -and @($script:calls[0]).Count -eq 11) { Ok 'a hostile id is passed as one argument (pinned path)' } else { Bad "args=[$($script:calls[0] -join '|')]" }

    # source: the new catch starts with the C-2 line; no Invoke-Expression.
    $dlFile = Join-Path $repo 'Private\Download-WingetApp.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($dlFile, [ref]$null, [ref]$null)
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    $pinTry = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match "'--installer-type'" }, $true))
    if ($pinTry.Count -eq 1 -and $pinTry[0].CatchClauses[0].Body.Statements[0].Extent.Text -ceq $c2) { Ok 'the pinned winget call''s catch starts with the C-2 re-throw (K1)' } else { Bad "pinned catches: $($pinTry.Count)" }
    $iex = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Invoke-Expression', 'iex') }, $true))
    if ($iex.Count -eq 0) { Ok 'no Invoke-Expression call' } else { Bad 'Invoke-Expression call found' }

    # == [3] Resolve-Win32ToolkitInstallerPin ============================================================
    Write-Host '[3] Resolve-Win32ToolkitInstallerPin: parameter > continuity > winget-default' -ForegroundColor Cyan
    $script:lookupCalls = 0; $script:lookupArgs = $null; $script:anchor = $null; $script:lookupThrows = $false
    function Get-Win32ToolkitPreviousProject {
        [CmdletBinding()]
        param($TemplateDirectory, $Version, $WingetId, $Vendor, $DisplayName, $ExcludePath, $TenantId)
        $script:lookupCalls++
        $script:lookupArgs = $PSBoundParameters
        if ($script:lookupThrows) { throw 'lookup exploded' }
        [pscustomobject]@{ Anchor = $script:anchor; HighestUnanchored = $null; Matches = @(); AmbiguousIds = @() }
    }
    function New-Anchor([string]$Type, [string]$Reason = 'published', [string]$Name = 'Notepad++_x64_8.8.9') {
        [pscustomobject]@{ Name = $Name; Template = 'Contoso'; Path = "C:\x\$Name"; Version = '8.8.9'; WingetId = 'Notepad++.Notepad++'; InstallerType = $Type
                           Family = (Get-Win32ToolkitInstallerFamily -Type $Type).Family; PinnedBy = 'winget-default'; Published = ($Reason -eq 'published')
                           Anchored = $true; AnchorReason = $Reason; MatchedBy = 'WingetId' }
    }
    $tpl = Join-Path $root 'Projects\Contoso'
    $call = { param([hashtable]$Extra) $a = @{ TemplateDirectory = $tpl; WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; ExcludePath = (Join-Path $tpl 'Notepad++_x64_8.9.8.1'); TenantId = 'tenant-1' }
                                       if ($Extra) { foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] } }
                                       Resolve-Win32ToolkitInstallerPin @a }

    $script:anchor = New-Anchor 'wix'
    $p = & $call @{ InstallerType = 'nullsoft' }
    if ($p.InstallerType -eq 'nullsoft' -and $p.PinnedBy -eq 'parameter' -and $p.Reason -eq 'requested' -and $p.Family -eq 'exe' -and $script:lookupCalls -eq 0) { Ok '-InstallerType wins over an anchored predecessor (parameter, requested, family exe; no lookup)' } else { Bad "pin=$($p | ConvertTo-Json -Compress -Depth 2) lookups=$script:lookupCalls" }
    if ($p.WingetClient -eq '1.29.380') { Ok "WingetClient = 'winget --version' without the leading v (1.29.380)" } else { Bad "client=[$($p.WingetClient)]" }

    $script:anchor = New-Anchor 'nullsoft'
    $p = & $call @{}
    if ($p.InstallerType -eq 'nullsoft' -and $p.PinnedBy -eq 'continuity' -and $p.Family -eq 'exe' -and $p.Reason -eq 'kept from Notepad++_x64_8.8.9 (published)' -and $p.Predecessor.Name -eq 'Notepad++_x64_8.8.9') { Ok "continuity: an anchored (published) predecessor's type is kept: 'kept from Notepad++_x64_8.8.9 (published)'" } else { Bad "pin=$($p | Select-Object InstallerType, PinnedBy, Family, Reason | ConvertTo-Json -Compress)" }
    $la = $script:lookupArgs
    if ($la['WingetId'] -eq 'Notepad++.Notepad++' -and $la['Version'] -eq '8.9.8.1' -and $la['TenantId'] -eq 'tenant-1' -and $la['ExcludePath'] -like '*Notepad++_x64_8.9.8.1' -and -not $la.ContainsKey('Vendor') -and -not $la.ContainsKey('DisplayName')) { Ok 'the lookup matches by winget id only (no Vendor/DisplayName, L1), with the tenant and the excluded new project' } else { Bad "lookup args: $(($la.Keys | ForEach-Object { "$_=$($la[$_])" }) -join '; ')" }

    $script:anchor = New-Anchor 'wix' 'pinned:parameter' 'Notepad++_x64_8.9.6'
    $p = & $call @{}
    if ($p.InstallerType -eq 'wix' -and $p.Reason -eq 'kept from Notepad++_x64_8.9.6 (pinned)') { Ok 'an explicitly pinned predecessor anchors too: (pinned)' } else { Bad "reason=$($p.Reason)" }

    $script:anchor = New-Anchor 'appx'
    $p = & $call @{}
    if ($p.InstallerType -eq 'msix' -and $p.Family -eq 'msix' -and $p.PinnedBy -eq 'continuity') { Ok 'an appx predecessor pins its PinValue msix (the ValidateSet has no appx)' } else { Bad "pin=$($p.InstallerType)/$($p.Family)" }

    $script:anchor = New-Anchor 'portable'
    $p = & $call @{}
    if ($p.InstallerType -eq '' -and $p.PinnedBy -eq 'winget-default') { Ok 'a predecessor with no pin value (portable) -> no pin, winget chooses' } else { Bad "pin=$($p.InstallerType)/$($p.PinnedBy)" }

    $script:anchor = $null
    $p = & $call @{}
    if ($p.InstallerType -eq '' -and $p.PinnedBy -eq 'winget-default' -and $p.Reason -eq "winget's choice" -and $null -eq $p.Predecessor -and $p.Family -eq '') { Ok "no anchor -> winget-default, '' (winget's choice)" } else { Bad "pin=$($p | Select-Object InstallerType, PinnedBy, Reason | ConvertTo-Json -Compress)" }

    $script:lookupCalls = 0
    $wv = $null
    $p = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $tpl -WingetId 'Git.Git' -Version 'Unknown' -WarningVariable wv -WarningAction SilentlyContinue
    if ($p.PinnedBy -eq 'winget-default' -and $script:lookupCalls -eq 0 -and @($wv).Count -eq 1 -and
        "$($wv[0])" -eq 'Installer-technology continuity was not checked before the download: the version is unknown. The identity checks after the download still compare it with earlier versions.') { Ok "-Version 'Unknown' -> one warning, no predecessor lookup, winget-default" } else { Bad "pinnedBy=$($p.PinnedBy) lookups=$script:lookupCalls warnings=[$($wv -join ' | ')]" }

    $script:lookupThrows = $true
    $wv = $null; $threw = $false
    try { $p = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $tpl -WingetId 'Git.Git' -Version '2.55.0' -WarningVariable wv -WarningAction SilentlyContinue } catch { $threw = $true }
    if (-not $threw -and $p.PinnedBy -eq 'winget-default' -and ($wv -join ' ') -match 'continuity could not be checked') { Ok 'a failing lookup -> one warning, winget-default, no throw (fail-open)' } else { Bad "threw=$threw pinnedBy=$($p.PinnedBy) warnings=[$($wv -join ';')]" }
    $script:lookupThrows = $false

    $script:versionOut = 'garbage output'
    $p = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $tpl -WingetId 'Git.Git' -Version '2.55.0'
    $script:versionOut = 'v1.29.380'
    $script:versionThrows = $true
    $p2 = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $tpl -WingetId 'Git.Git' -Version '2.55.0'
    $script:versionThrows = $false
    if ($p.WingetClient -eq '' -and $p2.WingetClient -eq '') { Ok "'winget --version' unreadable or failing -> WingetClient ''" } else { Bad "client=[$($p.WingetClient)] / [$($p2.WingetClient)]" }

    $rFile = Join-Path $repo 'Private\Resolve-Win32ToolkitInstallerPin.ps1'
    $errs = $null
    $rAst = [System.Management.Automation.Language.Parser]::ParseFile($rFile, [ref]$null, [ref]$errs)
    $catches = @($rAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    if ($catches.Count -ge 1 -and @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or $_.Body.Statements[0].Extent.Text -cne $c2 }).Count -eq 0) { Ok "K1: all $($catches.Count) catches of the new file start with the C-2 line" } else { Bad 'K1: a catch without the C-2 line' }
    $top = @($rAst.EndBlock.Statements)
    if (@($errs).Count -eq 0 -and $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and -not $rAst.ParamBlock -and -not $rAst.BeginBlock -and -not $rAst.ProcessBlock) { Ok 'the new file defines only its function (no top-level code)' } else { Bad 'top-level code in the new file' }
    if (@([System.IO.File]::ReadAllBytes($rFile) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the new file is ASCII-only' } else { Bad 'non-ASCII bytes' }

    # == [3b] rebuilding a version that is itself published or pinned ======================================
    # Create-PSADTProject deletes the old folder before the pin is resolved, and the predecessor lookup
    # excludes the project being built: Invoke-Win32Toolkit reads the self-anchor first and passes it.
    Write-Host '[3b] rebuild: a published / pinned version keeps its OWN technology (Get-Win32ToolkitSelfAnchor, -SelfAnchor)' -ForegroundColor Cyan
    function New-SelfProject([string]$Name, [string]$Type, [string]$PinnedBy, [string]$Tenant = '') {
        $sp = Join-Path $tpl $Name
        New-Item -ItemType Directory -Path (Join-Path $sp 'SupportFiles') -Force | Out-Null
        $src = [ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = ($Name -split '_')[-1]; InstallerType = $Type
                           Family = (Get-Win32ToolkitInstallerFamily -Type $Type).Family; PinnedBy = $PinnedBy; RequestedInstallerType = '' }
        $cfg = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Name = 'Notepad++'; Version = $src.Version }; Source = $src }
        [System.IO.File]::WriteAllText((Join-Path $sp 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        if ($Tenant) {
            New-Item -ItemType Directory -Path (Join-Path $sp 'Intune') -Force | Out-Null
            $entry = [ordered]@{ TenantId = $Tenant; AppId = '11111111-2222-3333-4444-555555555555'; DisplayName = 'Notepad++'; DisplayVersion = $src.Version; WingetId = 'Notepad++.Notepad++'; PublishedUtc = '2026-10-19T10:00:00Z' }
            [System.IO.File]::WriteAllText((Join-Path $sp 'Intune\Publications.json'), (ConvertTo-Json -InputObject @($entry) -Depth 4), [System.Text.UTF8Encoding]::new($false))
        }
        $sp
    }
    $selfPub = New-SelfProject 'Notepad++_x64_8.9.8.1' 'wix' 'winget-default' 'tenant-1'
    $sa = Get-Win32ToolkitSelfAnchor -ProjectPath $selfPub -TenantId 'tenant-1'
    if ($sa -and $sa.AnchorReason -eq 'published' -and $sa.InstallerType -eq 'wix' -and $sa.Name -eq 'Notepad++_x64_8.9.8.1' -and $sa.Published -and $sa.Path -eq $selfPub) { Ok 'a wix 8.9.8.1 published to this tenant is its own anchor (published, wix)' } else { Bad "self anchor: $($sa | ConvertTo-Json -Compress)" }
    if ($null -eq (Get-Win32ToolkitSelfAnchor -ProjectPath $selfPub -TenantId 'tenant-2')) { Ok 'published to another tenant only -> no self-anchor for this tenant (Dv4)' } else { Bad 'a publication to another tenant anchored' }

    $script:anchor = New-Anchor 'nullsoft' 'published' 'Notepad++_x64_8.9.7'
    $script:lookupCalls = 0
    $p = & $call @{ SelfAnchor = $sa }
    if ($p.InstallerType -eq 'wix' -and $p.Family -eq 'msi' -and $p.PinnedBy -eq 'continuity' -and $p.Reason -eq 'kept from Notepad++_x64_8.9.8.1 (published, rebuilt)' -and $p.Predecessor.Name -eq 'Notepad++_x64_8.9.8.1' -and $script:lookupCalls -eq 0) {
        Ok "rebuilding the published wix 8.9.8.1 next to a published nullsoft 8.9.7 keeps wix: 'kept from Notepad++_x64_8.9.8.1 (published, rebuilt)'"
    } else { Bad "pin=$($p | Select-Object InstallerType, Family, PinnedBy, Reason | ConvertTo-Json -Compress) lookups=$script:lookupCalls" }

    $selfPin = New-SelfProject 'Notepad++_x64_8.9.8.2' 'nullsoft' 'parameter'
    $sa2 = Get-Win32ToolkitSelfAnchor -ProjectPath $selfPin -TenantId 'tenant-1'
    $script:anchor = New-Anchor 'wix' 'published' 'Notepad++_x64_8.9.7'
    $p = & $call @{ SelfAnchor = $sa2 }
    if ($sa2.AnchorReason -eq 'pinned:parameter' -and $p.InstallerType -eq 'nullsoft' -and $p.PinnedBy -eq 'parameter' -and $p.Reason -eq 'kept from Notepad++_x64_8.9.8.2 (pinned, rebuilt)') {
        Ok "rebuilding a parameter-pinned nullsoft keeps nullsoft AND PinnedBy parameter (it still anchors later versions): '(pinned, rebuilt)'"
    } else { Bad "pin=$($p | Select-Object InstallerType, PinnedBy, Reason | ConvertTo-Json -Compress) self=$($sa2.AnchorReason)" }

    $script:anchor = New-Anchor 'nullsoft' 'published' 'Notepad++_x64_8.9.7'
    foreach ($case in @(@{ Pin = 'continuity'; Name = 'Notepad++_x64_8.9.9.1' }, @{ Pin = 'winget-default'; Name = 'Notepad++_x64_8.9.9.2' })) {
        $sa3 = Get-Win32ToolkitSelfAnchor -ProjectPath (New-SelfProject $case.Name 'wix' $case.Pin) -TenantId 'tenant-1'
        $script:lookupCalls = 0
        $p = & $call @{ SelfAnchor = $sa3 }
        if ($null -eq $sa3 -and $p.InstallerType -eq 'nullsoft' -and $p.PinnedBy -eq 'continuity' -and $p.Reason -eq 'kept from Notepad++_x64_8.9.7 (published)' -and $script:lookupCalls -eq 1) {
            Ok "an unanchored self ($($case.Pin), never published) -> no self-anchor; the published nullsoft 8.9.7 is kept as before"
        } else { Bad "$($case.Pin): self=$($sa3 | ConvertTo-Json -Compress) pin=$($p | Select-Object InstallerType, PinnedBy, Reason | ConvertTo-Json -Compress)" }
    }
    $p = & $call @{ SelfAnchor = [pscustomobject]@{ Name = 'Portable_x64_1.0'; InstallerType = 'portable'; PinnedBy = 'parameter'; AnchorReason = 'pinned:parameter' } }
    if ($p.InstallerType -eq 'nullsoft' -and $p.Reason -eq 'kept from Notepad++_x64_8.9.7 (published)') { Ok 'a self-anchor with no pin value (portable) falls through to the predecessor' } else { Bad "portable self -> $($p.InstallerType) / $($p.Reason)" }

    $wv = $null
    $p = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $tpl -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -InstallerType 'nullsoft' -SelfAnchor $sa -WarningVariable wv -WarningAction SilentlyContinue
    if ($p.InstallerType -eq 'nullsoft' -and $p.PinnedBy -eq 'parameter' -and $p.Reason -eq 'requested' -and @($wv).Count -eq 1 -and
        "$($wv[0])" -eq 'Rebuilding Notepad++_x64_8.9.8.1, which is published as wix (msi), with -InstallerType nullsoft (exe): devices that already have it get a second registration over one folder.') {
        Ok '-InstallerType still wins over the self-anchor, with one warning when it switches the family of a published version'
    } else { Bad "explicit over self: pin=$($p | Select-Object InstallerType, PinnedBy, Reason | ConvertTo-Json -Compress) warnings=[$($wv -join ' | ')]" }
    $wv = $null
    $p = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $tpl -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -InstallerType 'msi' -SelfAnchor $sa -WarningVariable wv -WarningAction SilentlyContinue
    if ($p.InstallerType -eq 'msi' -and @($wv).Count -eq 0) { Ok '-InstallerType msi on a wix self (same family) -> no warning' } else { Bad "same family warned: [$($wv -join ' | ')]" }

    $broken = Join-Path $tpl 'Broken_x64_1.0'
    New-Item -ItemType Directory -Path (Join-Path $broken 'SupportFiles') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $broken 'SupportFiles\AppConfig.json'), '{ corrupt json', [System.Text.UTF8Encoding]::new($false))
    $wv = $null; $threw = $false; $sb = 'unset'
    try { $sb = Get-Win32ToolkitSelfAnchor -ProjectPath $broken -WarningVariable wv -WarningAction SilentlyContinue } catch { $threw = $true }
    if (-not $threw -and $null -eq $sb -and @($wv).Count -eq 1 -and "$($wv[0])" -match 'it is rebuilt as if it were new\.$') { Ok 'an unreadable AppConfig.json -> one warning, no self-anchor (fail-open)' } else { Bad "broken: threw=$threw sb=$sb warnings=[$($wv -join ' | ')]" }
    $wv = $null
    $sm = Get-Win32ToolkitSelfAnchor -ProjectPath (Join-Path $tpl 'Missing_x64_1.0') -WarningVariable wv
    if ($null -eq $sm -and @($wv).Count -eq 0) { Ok 'no existing folder (a new project) -> $null, silently' } else { Bad 'missing folder' }

    $sFile = Join-Path $repo 'Private\Get-Win32ToolkitSelfAnchor.ps1'
    $errs = $null
    $sAst = [System.Management.Automation.Language.Parser]::ParseFile($sFile, [ref]$null, [ref]$errs)
    $sCatches = @($sAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $sTop = @($sAst.EndBlock.Statements)
    if (@($errs).Count -eq 0 -and $sCatches.Count -ge 1 -and @($sCatches | Where-Object { $_.Body.Statements[0].Extent.Text -cne $c2 }).Count -eq 0 -and
        $sTop.Count -eq 1 -and $sTop[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @([System.IO.File]::ReadAllBytes($sFile) | Where-Object { $_ -gt 127 }).Count -eq 0) {
        Ok 'Get-Win32ToolkitSelfAnchor.ps1: every catch starts with the C-2 line (K1), one function, ASCII-only'
    } else { Bad 'Get-Win32ToolkitSelfAnchor.ps1 hygiene' }
    $script:anchor = $null

    # == [4] Configure-PSADTForInstaller writes Source =====================================================
    Write-Host '[4] Configure-PSADTForInstaller records AppConfig.Source from the pin' -ForegroundColor Cyan
    function Get-YAMLInstallerInfo { param($FilesPath) $null }
    function Set-PSADTDataDrivenScript { param($ScriptPath, [switch]$ManualInstall) $true }
    function Update-PSADTMsixUninstallLogic { param($ProjectPath) $true }
    function Update-PSADTMsixProcessesToClose { param($ProjectPath) $true }
    $script:OrgTemplate = $null
    $script:builderArgs = $null; $script:builderMode = ''
    function Get-Win32ToolkitProjectSource {
        [CmdletBinding()]
        param($ProjectPath, [switch]$Rebuild, $Architecture, $PinnedBy, $RequestedInstallerType, $WingetClient)
        $script:builderArgs = $PSBoundParameters
        if ($script:builderMode -eq 'throw') { throw 'builder exploded' }
        if ($script:builderMode -eq 'w32t') { throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('fatal'), 'W32T.Test', [System.Management.Automation.ErrorCategory]::InvalidData, $null) }
        [pscustomobject]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; InstallerType = 'nullsoft'; Family = 'exe'
                           PinnedBy = $PinnedBy; RequestedInstallerType = $RequestedInstallerType; WingetClient = $WingetClient }
    }
    $proj = Join-Path $root 'Projects\Contoso\Notepad++_x64_8.9.8.1'
    New-Item -ItemType Directory -Path (Join-Path $proj 'Files'), (Join-Path $proj 'SupportFiles') -Force | Out-Null
    Set-Content (Join-Path $proj 'Files\npp.exe') 'x'; Set-Content (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') '# x'
    $app = [pscustomobject]@{ Name = 'Notepad++'; Version = '8.9.8.1'; Id = 'Notepad++.Notepad++' }
    function Invoke-Configure($Pin) {
        Remove-Item -LiteralPath (Join-Path $proj 'SupportFiles\AppConfig.json') -Force -ErrorAction SilentlyContinue
        $wv = $null; $ret = $null; $fq = ''
        $a = @{ ProjectPath = $proj; AppInfo = $app; Architecture = 'x64' }
        if ($Pin) { $a['InstallerPin'] = $Pin }
        try { $ret = Configure-PSADTForInstaller @a -WarningVariable wv -WarningAction SilentlyContinue 6>$null } catch { $fq = $_.FullyQualifiedErrorId }
        [pscustomobject]@{ Ret = $ret; Fqid = $fq; Warnings = @($wv); Cfg = (Get-Win32ToolkitAppConfig -ProjectPath $proj) }
    }

    $script:builderMode = ''
    $r = Invoke-Configure ([pscustomobject]@{ InstallerType = 'nullsoft'; Family = 'exe'; PinnedBy = 'parameter'; Predecessor = $null; WingetClient = '1.29.380'; Reason = 'requested' })
    $ba = $script:builderArgs
    if ($r.Ret -eq $true -and $ba['Rebuild'] -and $ba['PinnedBy'] -eq 'parameter' -and $ba['RequestedInstallerType'] -eq 'nullsoft' -and $ba['WingetClient'] -eq '1.29.380' -and $ba['Architecture'] -eq 'x64') { Ok 'parameter pin -> builder called with -Rebuild, PinnedBy parameter, RequestedInstallerType nullsoft, WingetClient, Architecture' } else { Bad "ret=$($r.Ret) args: $(($ba.Keys | ForEach-Object { "$_=$($ba[$_])" }) -join '; ')" }
    if ($r.Cfg.Source -and $r.Cfg.Source.PinnedBy -eq 'parameter' -and $r.Cfg.Source.RequestedInstallerType -eq 'nullsoft' -and $r.Cfg.Source.WingetClient -eq '1.29.380' -and $r.Cfg.Installer.Type -eq 'exe') { Ok 'AppConfig.Source is persisted next to App/Installer' } else { Bad "cfg: $($r.Cfg | ConvertTo-Json -Compress -Depth 4)" }

    $r = Invoke-Configure ([pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; PinnedBy = 'continuity'; Predecessor = $null; WingetClient = '1.29.380'; Reason = 'kept from x (published)' })
    if ($script:builderArgs['PinnedBy'] -eq 'continuity' -and $script:builderArgs['RequestedInstallerType'] -eq 'wix' -and $r.Cfg.Source.PinnedBy -eq 'continuity') { Ok 'continuity pin -> PinnedBy continuity, RequestedInstallerType wix' } else { Bad "pinnedBy=$($script:builderArgs['PinnedBy'])" }

    $r = Invoke-Configure ([pscustomobject]@{ InstallerType = ''; Family = ''; PinnedBy = 'winget-default'; Predecessor = $null; WingetClient = '1.29.380'; Reason = "winget's choice" })
    if ($script:builderArgs['PinnedBy'] -eq 'winget-default' -and $script:builderArgs['RequestedInstallerType'] -eq '' -and $script:builderArgs['WingetClient'] -eq '1.29.380') { Ok "winget-default pin -> PinnedBy winget-default, RequestedInstallerType '', the client still recorded" } else { Bad "args: $(($script:builderArgs.Keys | ForEach-Object { "$_=$($script:builderArgs[$_])" }) -join '; ')" }

    $r = Invoke-Configure $null
    if ($r.Ret -eq $true -and $script:builderArgs['PinnedBy'] -eq 'winget-default' -and $script:builderArgs['RequestedInstallerType'] -eq '' -and $script:builderArgs['WingetClient'] -eq '') { Ok "no pin -> winget-default, '', ''" } else { Bad "args: $(($script:builderArgs.Keys | ForEach-Object { "$_=$($script:builderArgs[$_])" }) -join '; ')" }

    $script:builderMode = 'throw'
    $r = Invoke-Configure ([pscustomobject]@{ InstallerType = 'nullsoft'; PinnedBy = 'parameter'; WingetClient = '1.29.380' })
    if ($r.Ret -eq $true -and -not $r.Fqid -and -not ($r.Cfg.PSObject.Properties.Name -contains 'Source') -and ($r.Warnings -join ' ') -match 'AppConfig\.Source\) could not be recorded: builder exploded' -and $r.Cfg.Installer.Type -eq 'exe') { Ok 'a throwing builder -> one warning, no Source, Configure still succeeds (K3)' } else { Bad "ret=$($r.Ret) fqid=$($r.Fqid) warnings=[$($r.Warnings -join ';')] keys=$($r.Cfg.PSObject.Properties.Name -join ',')" }

    $script:builderMode = 'w32t'
    $r = Invoke-Configure ([pscustomobject]@{ InstallerType = 'nullsoft'; PinnedBy = 'parameter'; WingetClient = '' })
    if ($r.Fqid -eq 'W32T.Test') { Ok 'a W32T error from the builder propagates (C-2)' } else { Bad "ret=$($r.Ret) fqid=$($r.Fqid)" }
    $script:builderMode = ''

    $cFile = Join-Path $repo 'Private\Configure-PSADTForInstaller.ps1'
    $cAst = [System.Management.Automation.Language.Parser]::ParseFile($cFile, [ref]$null, [ref]$null)
    $k3 = @($cAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and
                @($n.Body.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Get-Win32ToolkitProjectSource' }, $true)).Count }, $true)) |
          Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1
    if ($k3 -and $k3.CatchClauses.Count -eq 1 -and $k3.CatchClauses[0].Body.Statements[0].Extent.Text -ceq $c2 -and $k3.Extent.Text.Length -lt 1500) { Ok 'K3: the catch around Get-Win32ToolkitProjectSource starts with the C-2 line (its own try)' } else { Bad 'K3 catch' }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All WingetVariantPin tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail WingetVariantPin test(s) FAILED." -ForegroundColor Red
exit 1
