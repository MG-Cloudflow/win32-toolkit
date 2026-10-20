<#
    Installer-identity PR 1 (spec 2.7): Get-Win32ToolkitSiblingInstaller, the sibling probe.

    One raw GET of a winget-pkgs *.installer.yaml, fail-open, an indentation-aware tuple reader, and a
    per-process memo. Invoke-WebRequest is SHADOWED (a call counter + a scripted responder), so the suite
    never touches the network. The manifests come from Tests\Fixtures\winget-manifests (public winget-pkgs
    data, MIT; two hand-made ones under synthetic\) and are only read.

    Optional live check (off by default, skipped offline): set W32T_PROBE_LIVE=1 to also GET the real
    Notepad++ 8.9.8.1 manifest once.

    Run:  pwsh -File Tests\SiblingProbe.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-WebRequest is shadowed: the suite never touches the network')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test case helpers')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitSiblingInstaller.ps1')

$fx = Join-Path $repo 'Tests\Fixtures\winget-manifests'
function Read-Fixture([string]$Rel) { Get-Content -LiteralPath (Join-Path $fx $Rel) -Raw -Encoding UTF8 }
$npp8981 = Read-Fixture 'Notepad++.Notepad++\8.9.8.1.installer.yaml'
$npp889  = Read-Fixture 'Notepad++.Notepad++\8.8.9.installer.yaml'
$pdn51   = Read-Fixture 'dotPDN.PaintDotNet\5.1.installer.yaml'
$tv      = Read-Fixture 'TeamViewer.TeamViewer\15.82.6.installer.yaml'
$quoted  = Read-Fixture 'synthetic\quoted-rootkeys.installer.yaml'
$appx    = Read-Fixture 'synthetic\appx-sibling.installer.yaml'

# --- Invoke-WebRequest shadow -------------------------------------------------------------------
function New-HttpError([int]$Code) {
    $msg = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Code)
    [Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: $Code.", $msg)
}
$script:calls     = 0
$script:lastUri   = $null
$script:lastArgs  = $null
$script:responder = { param($Uri) [pscustomobject]@{ StatusCode = 200; Content = $script:body } }
$script:body      = ''
function Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, [int]$TimeoutSec, [int]$MaximumRedirection, [switch]$SkipHttpErrorCheck)
    $script:calls++
    $script:lastUri  = $Uri
    $script:lastArgs = @{ TimeoutSec = $TimeoutSec; MaximumRedirection = $MaximumRedirection; ErrorAction = $PSBoundParameters['ErrorAction']; SkipHttpErrorCheck = [bool]$SkipHttpErrorCheck }
    $resp = & $script:responder $Uri
    # Like the real cmdlet: a non-2xx answer is a terminating error (one $Error record) unless -SkipHttpErrorCheck,
    # which returns it as a response (re-verification 2026-10-21, B1 r2.1; checked against a local HttpListener).
    if ($resp -and -not $SkipHttpErrorCheck -and ([int]$resp.StatusCode -lt 200 -or [int]$resp.StatusCode -gt 299)) {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new((New-HttpError ([int]$resp.StatusCode)),
            'WebCmdletWebResponseException', [System.Management.Automation.ErrorCategory]::InvalidOperation, $Uri))
    }
    $resp
}
function Use-Body([string]$Text) { $script:body = $Text; $script:responder = { param($Uri) [pscustomobject]@{ StatusCode = 200; Content = $script:body } } }
function Probe([hashtable]$Extra) {
    $p = @{ WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = 'x64'; NoMemo = $true }
    if ($Extra) { foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] } }
    Get-Win32ToolkitSiblingInstaller @p
}

# --- [1] URL ------------------------------------------------------------------------------------
Write-Host '[1] URL builder (escaped segments, lower-case first letter folder)' -ForegroundColor Cyan
Use-Body $npp8981
$r = Probe @{ PackagedType = 'wix' }
$expUrl = 'https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/n/Notepad%2B%2B/Notepad%2B%2B/8.9.8.1/Notepad%2B%2B.Notepad%2B%2B.installer.yaml'
if ($r.Url -ceq $expUrl -and $script:lastUri -ceq $expUrl) { Ok "URL = $expUrl" } else { Bad "URL = $($r.Url) / requested $($script:lastUri)" }
if ($script:lastArgs.TimeoutSec -eq 10 -and $script:lastArgs.MaximumRedirection -eq 0 -and "$($script:lastArgs.ErrorAction)" -eq 'Stop' -and $script:lastArgs.SkipHttpErrorCheck) {
    Ok 'one GET with -TimeoutSec 10 -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop'
} else { Bad "GET args: $($script:lastArgs | ConvertTo-Json -Compress)" }
$r2 = Probe @{ WingetId = 'dotPDN.PaintDotNet'; Version = '5.1'; BaseUri = 'https://mirror.invalid/m/' }
if ($r2.Url -ceq 'https://mirror.invalid/m/d/dotPDN/PaintDotNet/5.1/dotPDN.PaintDotNet.installer.yaml') { Ok '-BaseUri (https, trailing / tolerated)' } else { Bad "BaseUri URL = $($r2.Url)" }

# --- [2] Invalid input: no request ---------------------------------------------------------------
Write-Host '[2] Invalid id / version / BaseUri -> Unavailable/InvalidId with NO request' -ForegroundColor Cyan
$before = $script:calls
$invalid = @(
    @{ WingetId = 'a/../b' }, @{ WingetId = 'NoDotsAtAll' }, @{ WingetId = 'has space.App' }, @{ WingetId = 'Bad%2F.App' },
    @{ WingetId = 'a.b.c.d.e.f.g.h.i' }, @{ WingetId = ('x' * 33) + '.App' },
    @{ Version = '..' }, @{ Version = 'Unknown' }, @{ Version = 'unknown' }, @{ Version = '1/2' }, @{ Version = '1..2' }, @{ Version = '' },
    @{ Version = ' ' }, @{ Version = '1.0#frag' }, @{ BaseUri = 'http://raw.githubusercontent.com/x' }, @{ BaseUri = 'file:///C:/x' }
)
foreach ($c in $invalid) {
    $o = Probe $c
    $label = ($c.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ' '
    if ($o.Status -eq 'Unavailable' -and $o.Reason -eq 'InvalidId') { Ok "$label -> Unavailable/InvalidId" } else { Bad "$label -> $($o.Status)/$($o.Reason)" }
}
$sk = Probe @{ WingetId = '' }
if ($sk.Status -eq 'Skipped' -and $sk.Reason -eq 'NoWingetId') { Ok "WingetId '' -> Skipped/NoWingetId" } else { Bad "WingetId '' -> $($sk.Status)/$($sk.Reason)" }
if ($script:calls -eq $before) { Ok 'none of them made a request' } else { Bad "$($script:calls - $before) request(s) made for invalid input" }

# --- [3] Notepad++ 8.9.8.1 x64 packaged wix ------------------------------------------------------
Write-Host '[3] Notepad++ 8.9.8.1 x64, packaged wix -> one testable nullsoft sibling' -ForegroundColor Cyan
Use-Body $npp8981
$r = Probe @{ PackagedType = 'wix' }
if ($r.Status -eq 'Ok' -and $r.Reason -eq '' -and @($r.Tuples).Count -eq 7) { Ok 'Status Ok, 7 tuples (every architecture)' } else { Bad "Status $($r.Status)/$($r.Reason), tuples $(@($r.Tuples).Count)" }
if ($r.PackagedFamily -eq 'msi' -and $r.PackagedType -eq 'wix' -and $r.SchemaVersion -eq '1.0' -and -not $r.FromMemo) { Ok 'PackagedType wix, PackagedFamily msi, SchemaVersion 1.0, not from memo' } else { Bad "header: $($r.PackagedType)/$($r.PackagedFamily)/$($r.SchemaVersion)/$($r.FromMemo)" }
$s = @($r.Siblings)
if ($s.Count -eq 1 -and $s[0].EffectiveType -eq 'nullsoft' -and $s[0].Family -eq 'exe' -and $s[0].ProductCode -ceq 'Notepad++' -and
    $s[0].Scope -eq 'machine' -and $s[0].Testable -and $s[0].Registers -and $s[0].PinValue -eq 'nullsoft' -and $s[0].Architecture -eq 'x64' -and -not $s[0].ZipWrapped) {
    Ok "Siblings = nullsoft / exe / ProductCode 'Notepad++' / machine, testable, PinValue nullsoft"
} else { Bad "Siblings = $($s | ConvertTo-Json -Compress)" }
$nr = @($r.NotRegistering)
if ($nr.Count -eq 1 -and $nr[0].EffectiveType -eq 'portable' -and $nr[0].InstallerType -eq 'zip') { Ok 'NotRegistering = zip/portable' } else { Bad "NotRegistering = $($nr | ConvertTo-Json -Compress)" }
if (@($r.SameFamilyOther).Count -eq 0) { Ok 'SameFamilyOther = none' } else { Bad "SameFamilyOther = $($r.SameFamilyOther | ConvertTo-Json -Compress)" }
$wixTuple = @($r.Tuples | Where-Object { $_.Architecture -eq 'x64' -and $_.InstallerType -eq 'wix' })
if ($wixTuple.Count -eq 1 -and $wixTuple[0].ProductCode -ceq '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}' -and $wixTuple[0].RegisteredType -eq '') {
    Ok "the quoted wix ProductCode is unquoted; an AFE block without InstallerType sets no RegisteredType"
} else { Bad "wix tuple = $($wixTuple | ConvertTo-Json -Compress)" }
$noPt = Probe @{}
$fams = (@($noPt.Siblings) | ForEach-Object { "$($_.EffectiveType)/$($_.Family)" }) -join ','
if ($fams -eq 'wix/msi,nullsoft/exe') { Ok "no -PackagedType -> every registering technology for x64, highest precedence first ($fams)" } else { Bad "no -PackagedType siblings = $fams" }
$x86 = Probe @{ Architecture = 'x86'; PackagedType = 'nullsoft' }
if (@($x86.Siblings).Count -eq 0 -and @($x86.NotRegistering).Count -eq 1) { Ok 'x86, packaged nullsoft -> no sibling (the MSI is x64 only)' } else { Bad "x86 siblings = $($x86.Siblings | ConvertTo-Json -Compress)" }

# --- [4] Notepad++ 8.8.9 ------------------------------------------------------------------------
Write-Host '[4] Notepad++ 8.8.9 x64, packaged nullsoft -> no sibling' -ForegroundColor Cyan
Use-Body $npp889
$r = Probe @{ Version = '8.8.9'; PackagedType = 'nullsoft' }
if ($r.Status -eq 'Ok' -and @($r.Siblings).Count -eq 0 -and @($r.SameFamilyOther).Count -eq 0) { Ok 'no sibling, no same-family other' } else { Bad "8.8.9 -> $($r.Status) siblings $(@($r.Siblings).Count)" }

# --- [5] Paint.NET 5.1: root zip inherited, AFE registered type ---------------------------------
Write-Host '[5] Paint.NET 5.1 x64, packaged wix -> the zipped EXE registers as wix: no sibling' -ForegroundColor Cyan
Use-Body $pdn51
$r = Probe @{ WingetId = 'dotPDN.PaintDotNet'; Version = '5.1'; PackagedType = 'wix' }
$t = @($r.Tuples | Where-Object Architecture -eq 'x64')
if ($t.Count -eq 2 -and ($t | Where-Object { $_.InstallerType -ne 'zip' }).Count -eq 0) { Ok 'root-level InstallerType zip is inherited by every item' } else { Bad "x64 tuples = $($t | ConvertTo-Json -Compress)" }
if (@($r.Tuples | Where-Object { $_.Scope -ne 'machine' }).Count -eq 0) { Ok 'root-level Scope machine is inherited by every item' } else { Bad 'root Scope not inherited' }
$exeItem = $t | Where-Object NestedInstallerType -eq 'exe'
if ($exeItem.RegisteredType -eq 'wix' -and $exeItem.Family -eq 'msi' -and $exeItem.EffectiveType -eq 'exe' -and $exeItem.ZipWrapped -and -not $exeItem.Testable -and $exeItem.PinValue -eq '') {
    Ok 'the zip/exe item: RegisteredType wix (from AppsAndFeaturesEntries), Family msi, zip-wrapped, untestable'
} else { Bad "zip/exe item = $($exeItem | ConvertTo-Json -Compress)" }
$wixItem = $t | Where-Object NestedInstallerType -eq 'wix'
if ($wixItem.RegisteredType -eq '' -and $wixItem.Family -eq 'msi' -and $wixItem.ProductCode -ceq '{16E65739-A4D3-46A6-AB40-08B009FE9729}') { Ok 'the zip/wix item: Family msi, own ProductCode (AFE ProductCode ignored)' } else { Bad "zip/wix item = $($wixItem | ConvertTo-Json -Compress)" }
if (@($r.Siblings).Count -eq 0 -and @($r.SameFamilyOther).Count -eq 0) { Ok 'no sibling and no same-family other (one registration)' } else { Bad "siblings $($r.Siblings | ConvertTo-Json -Compress) / sfo $($r.SameFamilyOther | ConvertTo-Json -Compress)" }
$arm = @($r.Tuples | Where-Object Architecture -eq 'arm64')
if ($arm.Count -eq 2 -and ($arm | Where-Object NestedInstallerType -eq 'exe').RegisteredType -eq 'wix') { Ok 'arm64 items parsed the same way' } else { Bad "arm64 = $($arm | ConvertTo-Json -Compress)" }

# --- [6] TeamViewer 15.82.6: zip-wrapped wix next to nullsoft -----------------------------------
Write-Host '[6] TeamViewer 15.82.6 x64, packaged nullsoft -> one zip-wrapped (untestable) wix sibling' -ForegroundColor Cyan
Use-Body $tv
$r = Probe @{ WingetId = 'TeamViewer.TeamViewer'; Version = '15.82.6'; PackagedType = 'nullsoft' }
$s = @($r.Siblings)
if ($s.Count -eq 1 -and $s[0].EffectiveType -eq 'wix' -and $s[0].ZipWrapped -and -not $s[0].Testable -and $s[0].PinValue -eq '' -and
    $s[0].Family -eq 'msi' -and $s[0].Registers -and $s[0].Scope -eq 'machine' -and $s[0].ProductCode -ceq '{13455B46-1688-4F29-BB85-6F8B2BBAFF16}') {
    Ok "Siblings = wix (zip-wrapped), Family msi, not Testable, PinValue '', root Scope inherited"
} else { Bad "Siblings = $($s | ConvertTo-Json -Compress)" }
if (@($r.SameFamilyOther).Count -eq 0) { Ok 'no same-family other' } else { Bad 'unexpected SameFamilyOther' }

# --- [7] Hand-made fixtures ---------------------------------------------------------------------
Write-Host '[7] Quoted values, root keys, an indented list, comments; an appx sibling' -ForegroundColor Cyan
Use-Body $quoted
$r = Probe @{ WingetId = 'Contoso.QuotedRoot'; Version = '2.0.1'; PackagedType = 'nullsoft' }
if ($r.Status -eq 'Ok' -and @($r.Tuples).Count -eq 3) { Ok 'indented Installers: list -> 3 tuples' } else { Bad "quoted: $($r.Status) $(@($r.Tuples).Count) tuples" }
$ns = @($r.Tuples | Where-Object InstallerType -eq 'nullsoft')
if ($ns.Count -eq 1 -and $ns[0].Scope -eq 'machine' -and $ns[0].Locale -ceq 'en-US' -and $ns[0].ProductCode -ceq 'Contoso QuotedRoot') {
    Ok 'a quoted value with a trailing comment is read; root Scope and quoted root InstallerLocale are inherited'
} else { Bad "nullsoft tuple = $($ns | ConvertTo-Json -Compress)" }
$s = @($r.Siblings)
if ($s.Count -eq 1 -and $s[0].EffectiveType -eq 'wix' -and $s[0].Scope -eq 'user' -and $s[0].ProductCode -ceq '{11111111-2222-3333-4444-555555555555}' -and $s[0].RegisteredType -eq '') {
    Ok "the item's own quoted Scope overrides the root; quoted GUID unquoted; an AFE block without InstallerType is ignored"
} else { Bad "quoted siblings = $($s | ConvertTo-Json -Compress)" }
$inno = @($r.Tuples | Where-Object InstallerType -eq 'inno')
if ($inno.Count -eq 1 -and $inno[0].Architecture -eq 'x86' -and $inno[0].Scope -eq 'machine') { Ok "single-quoted 'inno' item read" } else { Bad "inno tuple = $($inno | ConvertTo-Json -Compress)" }

Use-Body $appx
$r = Probe @{ WingetId = 'Contoso.AppxSibling'; Version = '3.1.0'; PackagedType = 'exe' }
$s = @($r.Siblings)
if ($s.Count -eq 1 -and $s[0].EffectiveType -eq 'appx' -and $s[0].Family -eq 'msix' -and $s[0].Testable -and $s[0].PinValue -eq 'msix') { Ok 'appx sibling -> Family msix, testable, PinValue msix' } else { Bad "appx siblings = $($s | ConvertTo-Json -Compress)" }

# --- [8] Fail-open: every failure is a status, never a throw ------------------------------------
Write-Host '[8] 404 / network / 429 / timeout / too large / parse -> Unavailable with a reason, never a throw' -ForegroundColor Cyan
# The thrown HTTP errors below are what Invoke-WebRequest raised before -SkipHttpErrorCheck (kept: the catch still
# classifies an HttpResponseException); [8b] covers the responses the real cmdlet returns now.
$failures = @(
    @{ Label = '404 (thrown)';              Resp = { param($Uri) throw (New-HttpError 404) };                                                   Exp = 'NotFound' },
    @{ Label = 'HttpRequestException (DNS)'; Resp = { param($Uri) throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }; Exp = 'Network' },
    @{ Label = '429 Too Many Requests (thrown)'; Resp = { param($Uri) throw (New-HttpError 429) };                                              Exp = 'Network' },
    @{ Label = '500 (thrown)';              Resp = { param($Uri) throw (New-HttpError 500) };                                                   Exp = 'Network' },
    @{ Label = 'TaskCanceledException';     Resp = { param($Uri) throw [System.Threading.Tasks.TaskCanceledException]::new('The request was canceled due to the configured HttpClient.Timeout of 10 seconds elapsing.') }; Exp = 'Timeout' },
    @{ Label = 'TimeoutException (inner)';  Resp = { param($Uri) throw [System.Net.Http.HttpRequestException]::new('timed out', [System.TimeoutException]::new('t')) }; Exp = 'Timeout' },
    @{ Label = '3 MB body';                 Resp = { param($Uri) [pscustomobject]@{ StatusCode = 200; Content = ('#' * (3MB)) } };              Exp = 'TooLarge' },
    @{ Label = '3 MB byte[] body';          Resp = { param($Uri) [pscustomobject]@{ StatusCode = 200; Content = [byte[]]::new(3MB) } };          Exp = 'TooLarge' },
    @{ Label = 'not a manifest';            Resp = { param($Uri) [pscustomobject]@{ StatusCode = 200; Content = "<html>rate limited</html>`nInstallers: []" } }; Exp = 'Parse' },
    @{ Label = 'a 302 answered as a response'; Resp = { param($Uri) [pscustomobject]@{ StatusCode = 302; Content = '' } };                       Exp = 'Network' }
)
foreach ($c in $failures) {
    $script:responder = $c.Resp
    $threw = $false
    try { $o = Probe @{ PackagedType = 'wix' } } catch { $threw = $true; $o = $null }
    if (-not $threw -and $o.Status -eq 'Unavailable' -and $o.Reason -eq $c.Exp -and @($o.Siblings).Count -eq 0) { Ok "$($c.Label) -> Unavailable/$($c.Exp), no throw" }
    else { Bad "$($c.Label) -> threw=$threw $($o.Status)/$($o.Reason)" }
}
$threw = $false
try { $o = Probe @{ PackagedType = 'wix' } -ErrorAction Stop } catch { $threw = $true }
if (-not $threw) { Ok 'no throw under -ErrorAction Stop either' } else { Bad 'threw under -ErrorAction Stop' }
$script:responder = { param($Uri) [pscustomobject]@{ StatusCode = 200; Content = [System.Text.Encoding]::UTF8.GetBytes($npp8981) } }
$o = Probe @{ PackagedType = 'wix' }
if ($o.Status -eq 'Ok' -and @($o.Siblings).Count -eq 1) { Ok 'a byte[] body is decoded as UTF-8 and parsed' } else { Bad "byte[] body -> $($o.Status)/$($o.Reason)" }

# [8b] re-verification 2026-10-21, B1 r2.1: GitHub answered 429 on a passing PuTTY build, which left a
# WebCmdletWebResponseException in $Error (and 2 entries in Invoke-Win32Toolkit -ErrorVariable). With
# -SkipHttpErrorCheck an HTTP error status is a response: classified, and no error record anywhere.
Write-Host '[8b] 404 / 429 / 500 answered as responses (-SkipHttpErrorCheck) -> classified, no $Error record, -ErrorVariable empty' -ForegroundColor Cyan
foreach ($c in @(@(404, 'NotFound'), @(429, 'Network'), @(500, 'Network'))) {
    $script:httpCode  = $c[0]
    $script:responder = { param($Uri) [pscustomobject]@{ StatusCode = $script:httpCode; Content = '' } }
    $errBefore = $Error.Count
    $probeErr  = $null
    $threw     = $false
    $o = $null
    try { $o = Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x64 -PackagedType wix -NoMemo -ErrorVariable probeErr }
    catch { $threw = $true }
    if (-not $threw -and $o.Status -eq 'Unavailable' -and $o.Reason -eq $c[1] -and $Error.Count -eq $errBefore -and @($probeErr).Count -eq 0) {
        Ok "$($c[0]) response -> Unavailable/$($c[1]); `$Error unchanged, -ErrorVariable empty"
    } else { Bad "$($c[0]) response -> threw=$threw $($o.Status)/$($o.Reason), new `$Error records $($Error.Count - $errBefore) [$(@($Error | Select-Object -First ($Error.Count - $errBefore) | ForEach-Object { $_.FullyQualifiedErrorId }) -join ' | ')], -ErrorVariable $(@($probeErr).Count)" }
}
# A failure without a response (DNS) is still caught and classified; it leaves its one record by design.
$script:responder = { param($Uri) throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }
$errBefore = $Error.Count
$o = Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x64 -PackagedType wix -NoMemo
if ($o.Reason -eq 'Network' -and $Error.Count -eq $errBefore + 1) { Ok 'a DNS failure (no response) is still classified Network and keeps its one $Error record (by design)' } else { Bad "DNS: $($o.Reason), new `$Error records $($Error.Count - $errBefore)" }

# --- [9] Hostile manifest values are sanitised --------------------------------------------------
Write-Host '[9] A manifest value with ESC and U+202E comes back sanitised' -ForegroundColor Cyan
$esc = [char]0x1B; $rlo = [char]0x202E
$hostile = @"
PackageIdentifier: Evil.App
PackageVersion: 1.0
Installers:
- Architecture: x64
  InstallerType: wix
  ProductCode: '{11111111-2222-3333-4444-555555555555}'
- Architecture: x64
  InstallerType: nullsoft
  ProductCode: 'Evil${esc}[2J${rlo}exe.txt'
  Scope: machine
ManifestType: installer
"@
Use-Body $hostile
$o = Probe @{ WingetId = 'Evil.App'; Version = '1.0'; PackagedType = 'wix' }
$pc = @($o.Siblings)[0].ProductCode
if ($pc -ceq 'Evil?[2J?exe.txt') { Ok "ProductCode -> '$pc' (ESC and U+202E replaced)" } else { Bad "ProductCode not sanitised: $([int[]][char[]]$pc -join ',')" }
$longVal = 'A' * 400
Use-Body ("PackageIdentifier: Long.App`nInstallers:`n- Architecture: x64`n  InstallerType: nullsoft`n  ProductCode: $longVal`n")
$o = Probe @{ WingetId = 'Long.App'; Version = '1.0'; PackagedType = 'wix' }
if (@($o.Siblings)[0].ProductCode.Length -eq 128) { Ok 'manifest values are capped at 128 characters' } else { Bad "ProductCode length $(@($o.Siblings)[0].ProductCode.Length)" }

# --- [10] Memo (L20) ----------------------------------------------------------------------------
Write-Host '[10] Per-process memo: one GET per id/version/arch, failures retried after 5 minutes' -ForegroundColor Cyan
$script:W32TSiblingProbeMemo = $null
Use-Body $npp8981
$before = $script:calls
$m1 = Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x64 -PackagedType wix
$m2 = Get-Win32ToolkitSiblingInstaller -WingetId 'notepad++.notepad++' -Version '8.9.8.1' -Architecture X64 -PackagedType nullsoft
if ($script:calls - $before -eq 1) { Ok 'two calls (different -PackagedType, different case) -> one request' } else { Bad "$($script:calls - $before) requests" }
if (-not $m1.FromMemo -and $m2.FromMemo) { Ok 'the second result is FromMemo' } else { Bad "FromMemo: $($m1.FromMemo) / $($m2.FromMemo)" }
$s1 = (@($m1.Siblings) | ForEach-Object EffectiveType) -join ','
$s2 = (@($m2.Siblings) | ForEach-Object EffectiveType) -join ','
if ($s1 -eq 'nullsoft' -and $s2 -eq 'wix') { Ok 'Siblings recomputed per call from the memoised tuples (wix -> nullsoft; nullsoft -> wix)' } else { Bad "siblings: '$s1' / '$s2'" }
if ($m2.ProbedUtc -eq $m1.ProbedUtc) { Ok 'a memo hit keeps the original ProbedUtc' } else { Bad 'ProbedUtc changed on a memo hit' }
$m3 = Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x86 -PackagedType nullsoft
if ($script:calls - $before -eq 2 -and -not $m3.FromMemo) { Ok 'another architecture is another memo key' } else { Bad 'arch not part of the memo key' }
$okKey = @($script:W32TSiblingProbeMemo.Keys | Where-Object { $_ -like '*|x64' })[0]
$script:W32TSiblingProbeMemo[$okKey].CachedUtc = [datetime]::UtcNow.AddHours(-5)
$before = $script:calls
$null = Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x64 -PackagedType wix
if ($script:calls -eq $before) { Ok 'an Ok entry lives for the process (still a hit hours later)' } else { Bad 'Ok entry expired' }

$script:responder = { param($Uri) throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }
$before = $script:calls
$n1 = Get-Win32ToolkitSiblingInstaller -WingetId 'Down.App' -Version '1.0' -Architecture x64
$n2 = Get-Win32ToolkitSiblingInstaller -WingetId 'Down.App' -Version '1.0' -Architecture x64
if ($script:calls - $before -eq 1 -and $n1.Reason -eq 'Network' -and $n2.Reason -eq 'Network' -and $n2.FromMemo) { Ok 'a Network failure is reused within 5 minutes (no second GET)' } else { Bad "network memo: $($script:calls - $before) requests, FromMemo $($n2.FromMemo)" }
$netKey = @($script:W32TSiblingProbeMemo.Keys | Where-Object { $_ -like '*|down.app|*' })[0]
$script:W32TSiblingProbeMemo[$netKey].CachedUtc = [datetime]::UtcNow.AddMinutes(-6)
$n3 = Get-Win32ToolkitSiblingInstaller -WingetId 'Down.App' -Version '1.0' -Architecture x64
if ($script:calls - $before -eq 2 -and -not $n3.FromMemo) { Ok 'after 5 minutes (simulated clock) the failing GET is retried' } else { Bad "retry: $($script:calls - $before) requests" }

$script:responder = { param($Uri) throw (New-HttpError 404) }
$before = $script:calls
$null = Get-Win32ToolkitSiblingInstaller -WingetId 'Gone.App' -Version '1.0' -Architecture x64
$nfKey = @($script:W32TSiblingProbeMemo.Keys | Where-Object { $_ -like '*|gone.app|*' })[0]
$script:W32TSiblingProbeMemo[$nfKey].CachedUtc = [datetime]::UtcNow.AddMinutes(-60)
$nf2 = Get-Win32ToolkitSiblingInstaller -WingetId 'Gone.App' -Version '1.0' -Architecture x64
if ($script:calls - $before -eq 1 -and $nf2.FromMemo -and $nf2.Reason -eq 'NotFound') { Ok 'a NotFound entry lives for the process' } else { Bad "NotFound memo: $($script:calls - $before) requests" }

$before = $script:calls
$null = Get-Win32ToolkitSiblingInstaller -WingetId 'Gone.App' -Version '1.0' -Architecture x64 -NoMemo
if ($script:calls - $before -eq 1) { Ok '-NoMemo always requests' } else { Bad '-NoMemo used the memo' }

# The first call in a process (no memo variable yet) leaves no VariableNotFound record (campaign F4).
Remove-Variable -Name W32TSiblingProbeMemo -Scope Script -ErrorAction Ignore
Use-Body $npp8981
$errBefore = $Error.Count
$probeErr = $null
$fm = Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x64 -PackagedType wix -ErrorVariable probeErr
if ($fm.Status -eq 'Ok' -and $script:W32TSiblingProbeMemo -is [hashtable] -and @($probeErr).Count -eq 0 -and $Error.Count -eq $errBefore) {
    Ok 'a first call without a memo variable writes no error record ($Error and -ErrorVariable stay empty)'
} else { Bad "first call: status $($fm.Status), -ErrorVariable $(@($probeErr).Count), new `$Error records $($Error.Count - $errBefore): $(@($probeErr)[0])" }
$script:W32TSiblingProbeMemo = $null

# --- [11] Source hygiene: no code execution, no YAML module, K1 -----------------------------------
Write-Host '[11] Source checks: nothing executed, no YAML module, every catch starts with the C-2 line, ASCII-only' -ForegroundColor Cyan
$file = Join-Path $repo 'Private\Get-Win32ToolkitSiblingInstaller.ps1'
$text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
if ($text -notmatch 'Invoke-Expression|ConvertFrom-Yaml|powershell-yaml|\biex\b') { Ok 'no Invoke-Expression / ConvertFrom-Yaml / powershell-yaml' } else { Bad 'the probe references a code-execution or YAML-module sink' }
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
$catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
if ($catches.Count -ge 1 -and $badCatch.Count -eq 0) { Ok "$($catches.Count) catch clause(s), each starts with the C-2 line (K1)" } else { Bad "catch without the C-2 line at line $($badCatch[0].Extent.StartLineNumber)" }
$webCalls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WebRequest' }, $true))
if ($webCalls.Count -eq 1) { Ok 'exactly one Invoke-WebRequest call site' } else { Bad "$($webCalls.Count) Invoke-WebRequest call sites" }
# B1 r2.1: the call site passes -SkipHttpErrorCheck, and the real cmdlet of this host (floor 7.4) has it.
$skipArg = @($webCalls | ForEach-Object { $_.CommandElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SkipHttpErrorCheck' })
if ($webCalls.Count -eq 1 -and $skipArg.Count -eq 1) { Ok 'the Invoke-WebRequest call passes -SkipHttpErrorCheck (an HTTP error status is a response, not an error record)' } else { Bad 'the Invoke-WebRequest call does not pass -SkipHttpErrorCheck' }
if ((Get-Command -Name 'Microsoft.PowerShell.Utility\Invoke-WebRequest' -CommandType Cmdlet).Parameters.ContainsKey('SkipHttpErrorCheck')) { Ok "the host's real Invoke-WebRequest has -SkipHttpErrorCheck" } else { Bad "the host's Invoke-WebRequest has no -SkipHttpErrorCheck" }
if (@([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the probe file is ASCII-only' } else { Bad 'the probe file has non-ASCII bytes' }

# --- [12] Optional live check (off by default) ----------------------------------------------------
Write-Host '[12] Optional live GET (set W32T_PROBE_LIVE=1)' -ForegroundColor Cyan
if ([string]$env:W32T_PROBE_LIVE -eq '1') {
    Remove-Item -Path Function:\Invoke-WebRequest
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $live = Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x64 -PackagedType wix -NoMemo
    if ($live.Status -eq 'Ok' -and (@($live.Siblings) | ForEach-Object EffectiveType) -contains 'nullsoft') { Ok "live: Ok, nullsoft sibling ($($sw.ElapsedMilliseconds) ms)" }
    elseif ($live.Status -eq 'Unavailable') { Write-Host "  SKIP: live probe unavailable ($($live.Reason)) - offline host" -ForegroundColor DarkGray }
    else { Bad "live: $($live.Status)/$($live.Reason)" }
} else { Write-Host '  SKIP: W32T_PROBE_LIVE is not 1 (no network in the default run)' -ForegroundColor DarkGray }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingProbe tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingProbe test(s) FAILED." -ForegroundColor Red; exit 1 }
