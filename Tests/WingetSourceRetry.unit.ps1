<#
    A configured winget source that cannot authenticate (exit 0x8A150075, APPINSTALLER_CLI_ERROR_AUTHENTICATION_FAILED)
    failed EVERY 'winget download' without '--source' (field: a private REST source behind Microsoft Entra ID whose
    token expired; 'winget search'/'winget show' only leave such a source out and exit 0). Each download now runs
    through Invoke-Win32ToolkitWingetDownload, which retries it once with '--source winget'.

      [1] Invoke-Win32ToolkitWingetDownload: 0x8A150075 or 0x8A150076 -> one warning naming the code, the same arguments + '--source winget',
          the retry's exit code returned (0x8A150010 included), never a second retry; every other code (the other
          authentication codes too) -> one call, the code unchanged, no warning; arguments naming a source -> no retry;
          winget's console lines go to the host (one object out); a hostile id and an empty value stay one argument.
      [2] Download-WingetApp unpinned: the retry delivers the installer ($true, one [bool]); a failing retry reports
          the retry's code; other codes unchanged.
      [3] Download-WingetApp pinned: no-applicable on the retry still moves the family on, the next types ask
          '--source winget' directly (one warning), the attempt's files are removed; every type no-applicable ->
          W32T.InstallerVariantUnavailable; another code on the retry -> $false.
      [4] Download-OldVersionInstaller: -FamilyPin (retry, soft scope after the retry, all unavailable, plain error,
          Sandbox\OldVersion untouched on failure) and without it (dependency staging; the unpinned variant retry
          carries '--source winget' and warns about the source once); the result is ONE object (winget's lines no
          longer leak into it).
      [5] Source: the two download helpers no longer call winget themselves; the new file holds only its function,
          ASCII-only, no Invoke-Expression.

    winget is shadowed (no network, nothing installed, no source touched); the download helpers are the real ones.

    Run:  pwsh -File Tests\WingetSourceRetry.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'the winget shadow sets $LASTEXITCODE like a native command')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows and case helpers')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitWingetNoApplicableInstaller.ps1')
. (Join-Path $repo 'Private\Download-WingetApp.ps1')
. (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineSilentArgs.ps1')
. (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
. (Join-Path $repo 'Private\Get-YAMLInstallerInfo.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitCachedInstaller.ps1')
. (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\ConvertFrom-Win32ToolkitWingetManifest.ps1')   # C-9: Download-OldVersionInstaller reads the downloaded switches with it
function Get-Win32ToolkitPipelineCacheRoot { $null }   # no pipeline cache in this suite

$AUTH   = -1978335115   # 0x8A150075 APPINSTALLER_CLI_ERROR_AUTHENTICATION_FAILED
$AUTHI  = -1978335114   # 0x8A150076 APPINSTALLER_CLI_ERROR_AUTHENTICATION_INTERACTIVE_REQUIRED (also retried, S7)
$NOAPP  = -1978335216   # 0x8A150010 APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER
$DLFAIL = -1978335224   # 0x8A150008 download failed
$NOPKG  = -1978335212   # 0x8A150014 no applications found

# winget shadow: records every call; per call it pops the next exit code and runs the next writer (files it drops);
# with no queued code it succeeds and writes an installer + manifest into --download-directory.
$script:calls   = [System.Collections.Generic.List[object]]::new()
$script:exits   = [System.Collections.Generic.Queue[int]]::new()
$script:writers = [System.Collections.Generic.Queue[scriptblock]]::new()
function Write-Download([string]$Dir, [string]$Type = 'nullsoft', [string]$Scope = 'machine') {
    $ext = if ($Type -in @('msi', 'wix')) { 'msi' } else { 'exe' }
    [System.IO.File]::WriteAllBytes((Join-Path $Dir "app.$ext"), [byte[]](5..60))
    Set-Content -LiteralPath (Join-Path $Dir 'Acme.App.installer.yaml') -Encoding UTF8 -Value @(
        'PackageIdentifier: Acme.App', 'PackageVersion: 1.2.3', 'Installers:', '- Architecture: x64', "  InstallerType: $Type", "  Scope: $Scope",
        '  InstallerLocale: en-US', '  InstallerSwitches:', '    Silent: /S')
}
function winget {
    $a = [string[]]$args
    $script:calls.Add($a)
    $code = if ($script:exits.Count) { $script:exits.Dequeue() } else { 0 }
    if ($script:writers.Count) { & $script:writers.Dequeue() $a }
    elseif ($code -eq 0) {
        $dir = $a[[array]::IndexOf($a, '--download-directory') + 1]
        $ti = [array]::IndexOf($a, '--installer-type'); $si = [array]::IndexOf($a, '--scope')
        Write-Download -Dir $dir -Type $(if ($ti -ge 0) { $a[$ti + 1] } else { 'nullsoft' }) -Scope $(if ($si -ge 0) { $a[$si + 1] } else { 'machine' })
    }
    $global:LASTEXITCODE = $code
    # Like the real winget, a download prints console lines on stdout: they must never reach a caller's output.
    'Found Shadow [x]'
    'Downloading https://example.invalid/shadow'
}
function Reset-Winget([int[]]$Exits, [scriptblock[]]$Writers) {
    $script:calls.Clear(); $script:exits.Clear(); $script:writers.Clear()
    foreach ($e in $Exits) { $script:exits.Enqueue($e) }
    foreach ($w in $Writers) { $script:writers.Enqueue($w) }
}
function Has($a, $flag) { [array]::IndexOf([string[]]$a, $flag) -ge 0 }
function ValueOf($a, $flag) { $i = [array]::IndexOf([string[]]$a, $flag); if ($i -ge 0) { $a[$i + 1] } else { $null } }
function Same([object[]]$A, [object[]]$B) { ($A.Count -eq $B.Count) -and (-not (Compare-Object $A $B -SyncWindow 0 -CaseSensitive)) }
$srcWinget = @('--source', 'winget')

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32src_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $root -Force | Out-Null
function New-Dl { $p = Join-Path $root ('dl_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }

try {
    # == [1] the helper ===================================================================================
    Write-Host '[1] Invoke-Win32ToolkitWingetDownload' -ForegroundColor Cyan
    if (0x8A150075 -eq $AUTH -and 0x8A150010 -eq $NOAPP) { Ok '0x8A150075 is -1978335115 as a PowerShell literal and an exit code (APPINSTALLER_CLI_ERROR_AUTHENTICATION_FAILED)' } else { Bad 'constant' }
    $base = @('download', '--id', 'Acme.App', '--download-directory', 'C:\x', '--accept-source-agreements', '--accept-package-agreements')

    Reset-Winget -Exits @(0) -Writers @({})
    $wv = $null
    $out = @(Invoke-Win32ToolkitWingetDownload -ArgumentList $base -Label 'Acme (Acme.App)' -WarningVariable wv -WarningAction SilentlyContinue)
    if ($out.Count -eq 1 -and $out[0].ExitCode -eq 0 -and $out[0].SourceFallback -eq $false -and $script:calls.Count -eq 1 -and (Same $script:calls[0] $base) -and @($wv).Count -eq 0) { Ok 'exit 0: one call with the arguments as given, ExitCode 0, SourceFallback false, no warning' }
    else { Bad "exit 0: out=$($out.Count) calls=$($script:calls.Count) warn=$(@($wv).Count)" }
    if ($out.Count -eq 1 -and $out[0] -is [pscustomobject]) { Ok "winget's console lines go to the host: the output is ONE object" } else { Bad "output: [$($out -join ' | ')]" }

    Reset-Winget -Exits @($AUTH, 0) -Writers @({}, {})
    $wv = $null
    $r = Invoke-Win32ToolkitWingetDownload -ArgumentList $base -Label 'Acme (Acme.App)' -WarningVariable wv -WarningAction SilentlyContinue
    if ($script:calls.Count -eq 2 -and (Same $script:calls[0] $base) -and (Same $script:calls[1] ($base + $srcWinget)) -and $r.ExitCode -eq 0 -and $r.SourceFallback -eq $true) { Ok "0x8A150075 -> the same arguments once more + '--source winget' -> ExitCode 0, SourceFallback true" }
    else { Bad "auth retry: calls=$(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ') r=$($r | ConvertTo-Json -Compress)" }
    $w = if (@($wv).Count) { "$($wv[0])" } else { '' }
    if (@($wv).Count -eq 1 -and $w -match '^winget could not download Acme \(Acme\.App\): a configured winget source failed to authenticate \(0x8A150075' -and $w -match "Retrying once from the 'winget' source only \(--source winget\)") { Ok 'exactly one warning naming the package, 0x8A150075 and --source winget' }
    else { Bad "warning: [$($wv -join ' | ')]" }

    Reset-Winget -Exits @($AUTH, $NOAPP) -Writers @({}, {})
    $r = Invoke-Win32ToolkitWingetDownload -ArgumentList $base -WarningAction SilentlyContinue
    if ($r.ExitCode -eq $NOAPP -and $r.SourceFallback -and (Test-Win32ToolkitWingetNoApplicableInstaller -ExitCode $r.ExitCode)) { Ok "retry answers 0x8A150010 -> that code is returned (the no-applicable classification still works)" } else { Bad "noapp on retry: $($r | ConvertTo-Json -Compress)" }

    Reset-Winget -Exits @($AUTH, $AUTH, 0) -Writers @({}, {}, {})
    $r = Invoke-Win32ToolkitWingetDownload -ArgumentList $base -WarningAction SilentlyContinue
    if ($script:calls.Count -eq 2 -and $r.ExitCode -eq $AUTH -and $r.SourceFallback) { Ok 'the retry fails to authenticate too -> its code, never a second retry' } else { Bad "double auth: calls=$($script:calls.Count) r=$($r | ConvertTo-Json -Compress)" }

    # 0x8A150076 (interactive authentication required): the same private source answers it instead of 0x75 depending
    # on its sign-in token (test campaign 2026-10-21, S7-F1/S10-F1) -> the same single retry, the warning names 0x76.
    if (0x8A150076 -eq $AUTHI) { Ok '0x8A150076 is -1978335114 (APPINSTALLER_CLI_ERROR_AUTHENTICATION_INTERACTIVE_REQUIRED)' } else { Bad 'constant 0x76' }
    Reset-Winget -Exits @($AUTHI, 0) -Writers @({}, {})
    $wv = $null
    $r = Invoke-Win32ToolkitWingetDownload -ArgumentList $base -Label 'Acme (Acme.App)' -WarningVariable wv -WarningAction SilentlyContinue
    if ($script:calls.Count -eq 2 -and (Same $script:calls[1] ($base + $srcWinget)) -and $r.ExitCode -eq 0 -and $r.SourceFallback -eq $true) { Ok "0x8A150076 -> the same arguments once more + '--source winget' -> ExitCode 0, SourceFallback true" }
    else { Bad "0x76 retry: calls=$(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ') r=$($r | ConvertTo-Json -Compress)" }
    $w = if (@($wv).Count) { "$($wv[0])" } else { '' }
    if (@($wv).Count -eq 1 -and $w -match 'failed to authenticate \(0x8A150076' -and $w -notmatch '0x8A150075' -and $w -match '--source winget') { Ok 'one warning naming the code that occurred (0x8A150076)' } else { Bad "0x76 warning: [$($wv -join ' | ')]" }
    foreach ($pair in @(@($AUTHI, $AUTHI), @($AUTHI, $AUTH), @($AUTH, $AUTHI))) {
        Reset-Winget -Exits @($pair[0], $pair[1], 0) -Writers @({}, {}, {})
        $r = Invoke-Win32ToolkitWingetDownload -ArgumentList $base -WarningAction SilentlyContinue
        if ($script:calls.Count -eq 2 -and $r.ExitCode -eq $pair[1] -and $r.SourceFallback) { Ok ("0x{0:X8} then 0x{1:X8} -> the retry's code, never a second retry" -f $pair[0], $pair[1]) } else { Bad "pair $($pair -join ','): calls=$($script:calls.Count) r=$($r | ConvertTo-Json -Compress)" }
    }

    foreach ($code in @($NOAPP, $DLFAIL, $NOPKG, 0x8A150073, 0x8A150074, 0x8A150077, 0x8A150078, 1, -1)) {
        Reset-Winget -Exits @($code, 0) -Writers @({}, {})
        $wv = $null
        $r = Invoke-Win32ToolkitWingetDownload -ArgumentList $base -WarningVariable wv -WarningAction SilentlyContinue
        if ($script:calls.Count -eq 1 -and $r.ExitCode -eq $code -and -not $r.SourceFallback -and @($wv).Count -eq 0) { Ok ("{0} (0x{0:X8}) -> one call, the code unchanged, no warning" -f $code) } else { Bad "$code -> calls=$($script:calls.Count) r=$($r | ConvertTo-Json -Compress) warn=$(@($wv).Count)" }
    }

    foreach ($named in @(@('--source', 'msstore'), @('-s', 'CloudFlow'), @('--source', 'winget'))) {
        Reset-Winget -Exits @($AUTH, 0) -Writers @({}, {})
        $wv = $null
        $r = Invoke-Win32ToolkitWingetDownload -ArgumentList ($base + $named) -WarningVariable wv -WarningAction SilentlyContinue
        if ($script:calls.Count -eq 1 -and $r.ExitCode -eq $AUTH -and -not $r.SourceFallback -and @($wv).Count -eq 0) { Ok "arguments already naming a source ($($named -join ' ')) -> no retry, no warning" } else { Bad "named source $($named -join ' '): calls=$($script:calls.Count)" }
    }

    $evil = "Evil.App'; calc.exe; #"
    Reset-Winget -Exits @($AUTH, 0) -Writers @({}, {})
    $null = Invoke-Win32ToolkitWingetDownload -ArgumentList @('download', '--id', $evil, '--locale', '') -WarningAction SilentlyContinue
    if ($script:calls.Count -eq 2 -and (Same $script:calls[1] @('download', '--id', $evil, '--locale', '', '--source', 'winget'))) { Ok 'a hostile id and an empty value stay single arguments, on the retry too' } else { Bad "args: $(@($script:calls | ForEach-Object { $_ -join '|' }) -join ' || ')" }

    # == [2] Download-WingetApp, unpinned ==================================================================
    Write-Host '[2] Download-WingetApp without a pin' -ForegroundColor Cyan
    $dl = New-Dl
    Reset-Winget -Exits @($AUTH, 0) -Writers @({}, { Set-Content (Join-Path $dl 'npp.exe') 'x' })
    $wv = $null
    $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -AppName 'Notepad++' -DownloadPath $dl -Architecture 'x64' -WarningVariable wv -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 6>$null
    if ($r -is [bool] -and $r -and $script:calls.Count -eq 2 -and -not (Has $script:calls[0] '--source') -and (ValueOf $script:calls[1] '--source') -eq 'winget') { Ok "0x8A150075 -> retried with '--source winget' -> `$true (ONE [bool])" }
    else { Bad "unpinned retry: r=[$(@($r) -join ' | ')] calls=$(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ')" }
    if (@($wv).Count -eq 1 -and "$($wv[0])" -match 'Notepad\+\+ \(Notepad\+\+\.Notepad\+\+\).*0x8A150075') { Ok 'one warning, naming Notepad++ (Notepad++.Notepad++)' } else { Bad "warnings: [$($wv -join ' | ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @($AUTHI, 0) -Writers @({}, { Set-Content (Join-Path $dl 'putty.msi') 'x' })
    $wv = $null
    $r = Download-WingetApp -AppId 'PuTTY.PuTTY' -AppName 'PuTTY' -DownloadPath $dl -Architecture 'x64' -WarningVariable wv -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 6>$null
    if ($r -is [bool] -and $r -and $script:calls.Count -eq 2 -and (ValueOf $script:calls[1] '--source') -eq 'winget' -and @($wv | Where-Object { "$_" -match '0x8A150076' }).Count -eq 1) { Ok "0x8A150076 (S7: PuTTY after an earlier 0x75 retry) -> retried with '--source winget' -> `$true" }
    else { Bad "unpinned 0x76: r=[$(@($r) -join ' | ')] calls=$(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ') warn=[$($wv -join ' | ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @($AUTH, $NOPKG) -Writers @({}, {})
    $ev = $null
    $r = Download-WingetApp -AppId 'Private.Only' -DownloadPath $dl -Architecture 'x64' -ErrorAction SilentlyContinue -ErrorVariable ev -WarningAction SilentlyContinue 6>$null
    if ($r -is [bool] -and -not $r -and $script:calls.Count -eq 2 -and "$($ev[0])" -match "^winget download exited with code $NOPKG \(0x8A150014\) for Private\.Only" -and "$($ev[0])" -notmatch 'sign-in') { Ok 'the retry fails (package only in the private source) -> $false, the error names the retry''s code (decimal and hex), no sign-in hint for 0x8A150014' }
    else { Bad "retry fails: r=$r calls=$($script:calls.Count) err=[$($ev -join ' | ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @($AUTHI, $AUTHI) -Writers @({}, {})
    $ev = $null
    $r = Download-WingetApp -AppId 'Private.Only' -DownloadPath $dl -Architecture 'x64' -ErrorAction SilentlyContinue -ErrorVariable ev -WarningAction SilentlyContinue 6>$null
    if ($r -eq $false -and "$($ev[0])" -like "winget download exited with code $AUTHI (0x8A150076) for Private.Only — no usable installer was downloaded. A configured winget source needs a sign-in*re-running fails the same way*") { Ok 'Download-WingetApp: 0x8A150076 after the retry -> hex code + "re-running fails the same way" sign-in hint' } else { Bad "auth hint: [$($ev -join ' | ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @($DLFAIL, 0) -Writers @({}, {})
    $wv = $null; $ev = $null
    $r = Download-WingetApp -AppId 'Some.App' -DownloadPath $dl -Architecture 'x64' -ErrorAction SilentlyContinue -ErrorVariable ev -WarningVariable wv -WarningAction SilentlyContinue 6>$null
    if ($r -eq $false -and $script:calls.Count -eq 1 -and @($wv).Count -eq 0 -and "$($ev[0])" -match "code $DLFAIL ") { Ok 'another code (0x8A150008) -> $false after one call, no warning (unchanged)' } else { Bad "other: r=$r calls=$($script:calls.Count)" }

    # == [3] Download-WingetApp, pinned ====================================================================
    Write-Host '[3] Download-WingetApp pinned to a family' -ForegroundColor Cyan
    $dl = New-Dl
    Set-Content (Join-Path $dl 'keep.txt') 'pre-existing'
    Reset-Winget -Exits @($AUTH, $NOAPP, 0) -Writers @({}, { Set-Content (Join-Path $dl 'partial.tmp') 'x' }, { Set-Content (Join-Path $dl 'npp-burn.exe') 'x' })
    $wv = $null
    $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType 'nullsoft' -PinnedBy 'parameter' -PinReason 'requested' -WarningVariable wv -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 6>$null
    $seen = @($script:calls | ForEach-Object { '{0}/{1}' -f (ValueOf $_ '--installer-type'), (ValueOf $_ '--source') })
    if ($r -is [bool] -and $r -and ($seen -join ',') -eq 'nullsoft/,nullsoft/winget,burn/winget') { Ok "nullsoft: 0x8A150075 -> nullsoft --source winget: no applicable -> burn asks --source winget directly -> `$true" }
    else { Bad "pinned: r=$r seen=$($seen -join ',')" }
    if (-not (Test-Path -LiteralPath (Join-Path $dl 'partial.tmp')) -and (Test-Path -LiteralPath (Join-Path $dl 'keep.txt')) -and (Test-Path -LiteralPath (Join-Path $dl 'npp-burn.exe'))) { Ok "the no-applicable retry's files are removed; the pre-existing file and the installer stay" } else { Bad "files: $((Get-ChildItem -LiteralPath $dl -Name) -join ', ')" }
    $authW = @($wv | Where-Object { "$_" -match '0x8A150075' })
    if ($authW.Count -eq 1 -and @($wv | Where-Object { "$_" -match '^Requested nullsoft; winget offers burn' }).Count -eq 1) { Ok 'one source warning for the whole download (plus the usual substitute warning)' } else { Bad "warnings: [$($wv -join ' | ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @($AUTH, $NOAPP, $NOAPP, $NOAPP, $NOAPP)
    $err = $null; $wv = $null
    try { $null = Download-WingetApp -AppId 'Notepad++.Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType 'nullsoft' -PinnedBy 'parameter' -PinReason 'requested' -WarningVariable wv -WarningAction SilentlyContinue 6>$null } catch { $err = $_ }
    $seen = @($script:calls | ForEach-Object { '{0}/{1}' -f (ValueOf $_ '--installer-type'), (ValueOf $_ '--source') })
    if ($err -and $err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and ($seen -join ',') -eq 'nullsoft/,nullsoft/winget,burn/winget,inno/winget,exe/winget' -and $err.Exception.Message -match 'tried: nullsoft, burn, inno, exe\.') { Ok 'every type no-applicable after the retry -> W32T.InstallerVariantUnavailable (tried: nullsoft, burn, inno, exe)' }
    else { Bad "unavailable: fqid=$($err.FullyQualifiedErrorId) seen=$($seen -join ',')" }
    if (@($wv | Where-Object { "$_" -match '0x8A150075' }).Count -eq 1) { Ok 'still one source warning' } else { Bad "warnings: [$($wv -join ' | ')]" }

    $dl = New-Dl
    Reset-Winget -Exits @($AUTH, $DLFAIL, 0)
    $err = $null; $r = $null
    try { $r = Download-WingetApp -AppId 'Notepad++.Notepad++' -DownloadPath $dl -Architecture 'x64' -InstallerType 'wix' -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 6>$null } catch { $err = $_ }
    if ($r -is [bool] -and -not $r -and -not $err -and $script:calls.Count -eq 2) { Ok 'another code on the retry (0x8A150008) -> $false, no next type, no W32T error' } else { Bad "retry other: r=$r err=$($err.FullyQualifiedErrorId) calls=$($script:calls.Count)" }

    # == [4] Download-OldVersionInstaller ==================================================================
    Write-Host '[4] Download-OldVersionInstaller' -ForegroundColor Cyan
    $proj = Join-Path $root 'proj'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $ovDir = Join-Path $proj 'Sandbox\OldVersion'

    Reset-Winget -Exits @($AUTH, 0)
    $wv = $null; $out = @(); $err = $null
    try { $out = @(Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -InstallerType nullsoft -FamilyPin -WarningVariable wv -WarningAction SilentlyContinue 6>$null) } catch { $err = $_; Bad "threw: $($err.Exception.Message)" }
    $r = if ($out.Count) { $out[-1] } else { $null }
    if ($out.Count -eq 1 -and $r.InstallerName -eq 'app.exe' -and $r.ManifestInstallerType -eq 'nullsoft' -and (@($r.TriedTypes) -join ',') -eq 'nullsoft' -and $script:calls.Count -eq 2 -and (ValueOf $script:calls[1] '--source') -eq 'winget' -and (ValueOf $script:calls[1] '--installer-type') -eq 'nullsoft') { Ok "-FamilyPin: 0x8A150075 -> nullsoft again with '--source winget' -> the baseline (ONE object, no winget lines)" }
    else { Bad "familypin retry: out=$($out.Count) calls=$(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ')" }
    if (@($wv | Where-Object { "$_" -match "^winget could not download 'Acme\.App' v1\.2\.3: .*0x8A150075" }).Count -eq 1) { Ok "one warning naming 'Acme.App' v1.2.3" } else { Bad "warnings: [$($wv -join ' | ')]" }
    $snapshot = { @(Get-ChildItem -LiteralPath $ovDir -Force -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ';' }
    $before = & $snapshot

    Reset-Winget -Exits @($AUTH, $NOAPP, 0)
    $wv = $null; $r = $null
    try { $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -Scope user -InstallerType inno -FamilyPin -WarningVariable wv -WarningAction SilentlyContinue 6>$null } catch { Bad "threw: $($_.Exception.Message)" }
    $seen = @($script:calls | ForEach-Object { '{0}/{1}/{2}' -f (ValueOf $_ '--installer-type'), (ValueOf $_ '--scope'), (ValueOf $_ '--source') })
    if (($seen -join ',') -eq 'inno/user/,inno/user/winget,inno//winget' -and $r.ScopeRelaxed -eq $true -and $r.ManifestInstallerType -eq 'inno') { Ok 'soft scope after the retry: inno/user, inno/user --source winget (no applicable), inno --source winget -> ScopeRelaxed' }
    else { Bad "soft scope: seen=$($seen -join ',') relaxed=$($r.ScopeRelaxed)" }
    if (@($wv | Where-Object { "$_" -match '0x8A150075' }).Count -eq 1 -and @($wv | Where-Object { "$_" -match 'has no user-scope inno installer' }).Count -eq 1) { Ok 'one source warning and the usual scope warning' } else { Bad "warnings: [$($wv -join ' | ')]" }
    $before = & $snapshot

    Reset-Winget -Exits @($AUTH, $NOAPP, $NOAPP, $NOAPP, $NOAPP)
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.0' -ProjectPath $proj -Architecture x64 -InstallerType nullsoft -FamilyPin -WarningAction SilentlyContinue 6>$null } catch { $err = $_ }
    $seen = @($script:calls | ForEach-Object { '{0}/{1}' -f (ValueOf $_ '--installer-type'), (ValueOf $_ '--source') })
    if ($err -and $err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and ($seen -join ',') -eq 'nullsoft/,nullsoft/winget,burn/winget,inno/winget,exe/winget') { Ok '-FamilyPin, every type no-applicable after the retry -> W32T.InstallerVariantUnavailable' }
    else { Bad "familypin unavailable: fqid=$($err.FullyQualifiedErrorId) seen=$($seen -join ',')" }
    if ((& $snapshot) -eq $before -and -not (Test-Path -LiteralPath "$ovDir.attempt")) { Ok 'Sandbox\OldVersion left exactly as it was; no staging folder left' } else { Bad 'OldVersion changed or staging folder left' }

    Reset-Winget -Exits @($AUTH, $DLFAIL)
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.0' -ProjectPath $proj -InstallerType nullsoft -FamilyPin -WarningAction SilentlyContinue 6>$null } catch { $err = $_ }
    if ($err -and $err.FullyQualifiedErrorId -notlike 'W32T.*' -and $err.Exception.Message -eq "winget download exited with code $DLFAIL (0x8A150008) for 'Acme.App' v1.0." -and $script:calls.Count -eq 2 -and (& $snapshot) -eq $before) { Ok "-FamilyPin, another code on the retry -> the plain error with the retry's code, OldVersion untouched" }
    else { Bad "familypin other: $($err.Exception.Message) calls=$($script:calls.Count)" }

    # Without -FamilyPin: dependency staging (latest, no pins) and the old variant-pin path.
    $depDir = Join-Path $proj 'Sandbox\Dependencies\Acme.Dep'
    Reset-Winget -Exits @($AUTH, 0)
    $wv = $null; $out = @()
    try { $out = @(Download-OldVersionInstaller -AppId 'Acme.Dep' -ProjectPath $proj -DestinationDir $depDir -WarningVariable wv -WarningAction SilentlyContinue 6>$null) } catch { Bad "threw: $($_.Exception.Message)" }
    if ($out.Count -eq 1 -and $out[0].InstallerName -eq 'app.exe' -and $script:calls.Count -eq 2 -and (Same $script:calls[1] ($script:calls[0] + $srcWinget)) -and @($wv | Where-Object { "$_" -match "'Acme\.Dep' the latest version: .*0x8A150075" }).Count -eq 1) { Ok "dependency staging (no -Version, no pins): retried with '--source winget', ONE object out, one warning" }
    else { Bad "dependency: out=$($out.Count) calls=$(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ') warn=[$($wv -join ' | ')]" }

    Reset-Winget -Exits @($AUTH, 1, 0)
    $wv = $null; $r = $null
    try { $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Architecture x64 -Scope machine -InstallerType msi -WarningVariable wv -WarningAction SilentlyContinue 6>$null } catch { Bad "threw: $($_.Exception.Message)" }
    $c = $script:calls
    if ($c.Count -eq 3 -and -not (Has $c[0] '--source') -and (ValueOf $c[1] '--source') -eq 'winget' -and (Has $c[1] '--installer-type') -and (ValueOf $c[2] '--source') -eq 'winget' -and -not (Has $c[2] '--installer-type') -and -not (Has $c[2] '--scope') -and $r.UsedFallback -eq $true) { Ok "variant pins: 0x8A150075 -> pinned + '--source winget' fails -> the unpinned retry keeps '--source winget' (UsedFallback)" }
    else { Bad "variant: calls=$(@($c | ForEach-Object { $_ -join ' ' }) -join ' || ') used=$($r.UsedFallback)" }
    if (@($wv | Where-Object { "$_" -match '0x8A150075' }).Count -eq 1 -and @($wv | Where-Object { "$_" -match '^Pinned download' }).Count -eq 1) { Ok 'one source warning and the usual variant-fallback warning' } else { Bad "warnings: [$($wv -join ' | ')]" }

    Reset-Winget -Exits @($DLFAIL)
    $err = $null; $wv = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.Dep' -ProjectPath $proj -DestinationDir $depDir -WarningVariable wv -WarningAction SilentlyContinue 6>$null } catch { $err = $_ }
    if ($err -and $err.Exception.Message -eq "winget download exited with code $DLFAIL (0x8A150008) for 'Acme.Dep' the latest version." -and $script:calls.Count -eq 1 -and @($wv).Count -eq 0) { Ok 'another code without pins -> the plain error after one call (unchanged)' } else { Bad "other: $($err.Exception.Message) calls=$($script:calls.Count)" }

    # An authentication code that survives the retry (the package lives only in the private source) is NOT transient:
    # the message names the code in hex and says a re-run fails the same way (test campaign 2026-10-21, S7-F2).
    Reset-Winget -Exits @($AUTH, $AUTHI)
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.Dep' -ProjectPath $proj -DestinationDir $depDir -WarningAction SilentlyContinue 6>$null } catch { $err = $_ }
    if ($err -and $err.Exception.Message -like "winget download exited with code $AUTHI (0x8A150076) for 'Acme.Dep' the latest version. A configured winget source needs a sign-in*re-running fails the same way*never signs in or changes sources.") { Ok 'Download-OldVersionInstaller: 0x8A150076 after the retry -> hex code + sign-in hint' } else { Bad "auth hint (old version): $($err.Exception.Message)" }

    # == [5] source hygiene ================================================================================
    Write-Host '[5] Source' -ForegroundColor Cyan
    foreach ($rel in @('Private\Download-WingetApp.ps1', 'Private\Download-OldVersionInstaller.ps1')) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $rel), [ref]$null, [ref]$null)
        $direct = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'winget' }, $true))
        $helper = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Win32ToolkitWingetDownload' }, $true))
        if ($direct.Count -eq 0 -and $helper.Count -ge 2) { Ok "$rel runs no winget itself: $($helper.Count) calls through Invoke-Win32ToolkitWingetDownload" } else { Bad "$rel : direct winget $($direct.Count), helper $($helper.Count)" }
    }
    $hFile = Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1'
    $errs = $null
    $hAst = [System.Management.Automation.Language.Parser]::ParseFile($hFile, [ref]$null, [ref]$errs)
    $top = @($hAst.EndBlock.Statements)
    $iex = @($hAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Invoke-Expression', 'iex') }, $true))
    if (@($errs).Count -eq 0 -and $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and -not $hAst.ParamBlock -and $iex.Count -eq 0 -and
        @([System.IO.File]::ReadAllBytes($hFile) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the new file defines only its function, ASCII-only, no Invoke-Expression' }
    else { Bad 'new file hygiene' }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All WingetSourceRetry tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail WingetSourceRetry test(s) FAILED." -ForegroundColor Red
exit 1
