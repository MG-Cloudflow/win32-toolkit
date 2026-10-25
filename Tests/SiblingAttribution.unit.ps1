<#
    Installer-identity PR 3b (spec 2.14.6, 2.14.8 rule 1, SV1, SV16): ONE attribution text decides, in the capture
    guest and on the host, which new uninstall entry is the sibling installer's own registration.

      [1] the text: parses under Windows PowerShell 5.1, ASCII, no here-string, every variable it assigns named w32t*,
          LF only; the host function creates its scriptblock from exactly that text.
      [2] the SV1 cases: one primary by ProductCode (Notepad++ NSIS), with Edge / EdgeUpdate / WebView2 noise left
          Unattributed (a Microsoft publisher is never ranked for a non-Microsoft package); an Apps and Features name +
          publisher match (exact, and through {v}) -> High; entries inside a new root -> CoInstalled by path (the
          primary's root and another folder the capture created; a same-signer co-product in its own root, the Firefox
          maintenance service shape), outside every new root -> Unattributed; a OneDrive-style Microsoft root never
          ranked or co-installed for a non-Microsoft package; without a primary nothing is co-installed; name +
          publisher + folder + signer -> Medium on the host (folder: the tokenised DefaultInstallLocation, or the leaf of
          the captured root; a default that only shares the leaf is not enough), while the guest (no signer data) gives
          no primary; two at the same rank -> Ambiguous; no match -> NoPrimary; SystemComponent and publisher-less
          entries ignored; the package's own key -> SameKey.
      [3] guest and host agree: the text run in a Windows PowerShell 5.1 child gives the host's result for the same
          inputs - a High primary with co-installed and unattributed entries, and Medium by the tokenised default and by
          the captured root's leaf (skipped when 5.1 is absent).

    Run:  pwsh -File Tests\SiblingAttribution.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitSiblingAttributionScript.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitSiblingAttribution.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitPS51Syntax.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w32att_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
function Cand([hashtable]$O) {
    $c = [ordered]@{ Key = ''; View = 'Native'; DisplayName = ''; DisplayVersion = ''; Publisher = ''; SystemComponent = $false; InstallLocation = ''; UninstallerPath = ''; InstallDir = ''; UninstallerSignerSubject = ''; MainSignerSubject = '' }
    foreach ($k in $O.Keys) { $c[$k] = $O[$k] }
    [pscustomobject]$c
}
$npp = Cand @{ Key = 'Notepad++'; DisplayName = 'Notepad++ (64-bit x64)'; DisplayVersion = '8.9.8.1'; Publisher = 'Notepad++ Team'; InstallLocation = 'C:\Program Files\Notepad++'; UninstallerPath = 'C:\Program Files\Notepad++\uninstall.exe'; InstallDir = '%ProgramFiles%\Notepad++' }
$edge = Cand @{ Key = 'Microsoft Edge Update'; DisplayName = 'Microsoft Edge Update'; DisplayVersion = '1.3.195.43'; Publisher = 'Microsoft Corporation'; View = 'Wow6432'; InstallLocation = 'C:\Program Files (x86)\Microsoft\EdgeUpdate' }
$webview = Cand @{ Key = 'Microsoft EdgeWebView'; DisplayName = 'Microsoft Edge WebView2 Runtime'; DisplayVersion = '131.0'; Publisher = 'Microsoft Corporation'; View = 'Wow6432'; InstallLocation = 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application' }
$nppManifest = [pscustomobject]@{ ProductCodes = @('Notepad++'); Afe = @(); PackageName = 'Notepad++'; Publisher = 'Notepad++ Team'; DefaultInstallLocation = '%ProgramFiles%\Notepad++' }
$roots = @('C:\Program Files\Notepad++', 'C:\Program Files (x86)\Microsoft\EdgeUpdate')
function Keys($List) { (@($List | ForEach-Object { "$($_.Key)|$($_.View)" }) | Sort-Object) -join ',' }

try {
    # == [1] the text =======================================================================================
    Write-Host '[1] the attribution text' -ForegroundColor Cyan
    $text = Get-Win32ToolkitSiblingAttributionScript
    $file = Join-Path $tmp 'attribution.ps1'
    [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($true))
    $e51 = @(Test-Win32ToolkitPS51Syntax -Path $file)
    $errs = $null; $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    if ($e51.Count -eq 0 -and @($errs).Count -eq 0) { Ok 'parses under PowerShell 7 and Windows PowerShell 5.1 (the 5.1 check is fail-open when 5.1 is absent)' } else { Bad "parse: $($e51 -join ' | ') $(@($errs).Count)" }
    if (-not ($text.ToCharArray() | Where-Object { [int]$_ -gt 127 }) -and $text -notmatch "@'|@`"" -and -not $text.Contains("`r")) { Ok 'ASCII, no here-string, LF only' } else { Bad 'text hygiene' }
    $assigned = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object { $_.Left.Extent.Text -replace '^\[[^\]]+\]', '' -replace '\..*$', '' -replace '\[.*$', '' } | Sort-Object -Unique)
    $loopVars = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable.Extent.Text } | Sort-Object -Unique)
    $paramVars = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { $_.Name.Extent.Text })
    $badNames = @($assigned + $loopVars + @($paramVars | Where-Object { $_ -notin '$Candidates', '$Manifest', '$Own', '$PackagePublisher', '$NewRoots' }) | Where-Object { $_ -notlike '$w32t*' })
    if ($badNames.Count -eq 0) { Ok 'every assigned, loop and inner parameter variable is named w32t* (no collision with the guest script or a deploy script)' } else { Bad "names: $($badNames -join ', ')" }
    $hostSrc = [IO.File]::ReadAllText((Join-Path $repo 'Private\Get-Win32ToolkitSiblingAttribution.ps1'))
    if ($hostSrc -match '\[scriptblock\]::Create\(\(Get-Win32ToolkitSiblingAttributionScript\)\)' -and $hostSrc -notmatch 'w32tScRank|Medium.*=') { Ok 'the host creates its scriptblock from the catalog text (no second implementation)' } else { Bad 'host source' }

    # == [2] the SV1 cases ==================================================================================
    Write-Host '[2] the SV1 cases' -ForegroundColor Cyan
    $a = Get-Win32ToolkitSiblingAttribution -Candidates @($npp, $edge, $webview) -Manifest $nppManifest -Own @{ ArpKeys = @(@{ Key = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'; View = 'Native' }) } -PackagePublisher 'Notepad++ Team' -NewRoots $roots
    if ($a.Primary -eq 'Notepad++' -and $a.PrimaryView -eq 'Native' -and $a.Rank -eq 'High' -and $a.Reason -eq 'ProductCode' -and -not $a.SameKey) { Ok "Notepad++ NSIS: the key equals the manifest's ProductCode -> primary, High" } else { Bad "npp: $($a | ConvertTo-Json -Compress)" }
    if ((Keys $a.Unattributed) -eq 'Microsoft Edge Update|Wow6432,Microsoft EdgeWebView|Wow6432' -and @($a.CoInstalled).Count -eq 0) { Ok 'Edge / EdgeUpdate / WebView2 noise: Unattributed (another root), never ranked' } else { Bad "noise: co=$(Keys $a.CoInstalled) un=$(Keys $a.Unattributed)" }
    $ms = Get-Win32ToolkitSiblingAttribution -Candidates @($edge) -Manifest ([pscustomobject]@{ ProductCodes = @('Microsoft Edge Update') }) -PackagePublisher 'Contoso'
    $ms2 = Get-Win32ToolkitSiblingAttribution -Candidates @($edge) -Manifest ([pscustomobject]@{ ProductCodes = @('Microsoft Edge Update') }) -PackagePublisher 'Microsoft Corporation'
    if ($ms.Primary -eq '' -and $ms2.Primary -eq 'Microsoft Edge Update') { Ok 'a Microsoft publisher is ranked only for a Microsoft package' } else { Bad "ms: $($ms.Primary) / $($ms2.Primary)" }

    $foo = Cand @{ Key = '{AAAA}'; DisplayName = 'Foo 1.3'; DisplayVersion = '1.3'; Publisher = 'Foo Inc'; InstallLocation = 'C:\Program Files\Foo'; UninstallerPath = 'C:\Program Files\Foo\unins000.exe' }
    $afeExact = Get-Win32ToolkitSiblingAttribution -Candidates @($foo) -Manifest ([pscustomobject]@{ Afe = @([pscustomobject]@{ DisplayName = 'Foo 1.3'; Publisher = 'Foo Inc'; DisplayVersion = '1.3' }) })
    $afeTpl = Get-Win32ToolkitSiblingAttribution -Candidates @($foo) -Manifest ([pscustomobject]@{ Afe = @([pscustomobject]@{ DisplayName = 'Foo 1.2'; Publisher = 'Foo Inc'; DisplayVersion = '1.2' }) })
    $afePub = Get-Win32ToolkitSiblingAttribution -Candidates @($foo) -Manifest ([pscustomobject]@{ Afe = @([pscustomobject]@{ DisplayName = 'Foo 1.3'; Publisher = 'Bar Inc'; DisplayVersion = '1.3' }) })
    if ($afeExact.Rank -eq 'High' -and $afeExact.Reason -eq 'AppsAndFeatures' -and $afeTpl.Rank -eq 'High' -and $afePub.Primary -eq '' -and $afePub.Reason -eq 'NoPrimary') { Ok 'Apps and Features DisplayName + Publisher -> High (exact, and through {v}); another publisher -> no primary' } else { Bad "afe: $($afeExact.Rank)/$($afeTpl.Rank)/$($afePub.Reason)" }

    $updater = Cand @{ Key = 'Foo Updater'; DisplayName = 'Foo Updater'; DisplayVersion = '2.0'; Publisher = 'Foo Inc'; UninstallerPath = 'C:\Program Files\Foo\updater\uninstall.exe' }
    $residue = Cand @{ Key = 'FooHelper'; DisplayName = 'Foo helper'; DisplayVersion = '1.0'; Publisher = 'Somebody'; InstallLocation = 'C:\Program Files\Foo\helper' }
    $other = Cand @{ Key = 'Other'; DisplayName = 'Other'; DisplayVersion = '1'; Publisher = 'Other Ltd'; InstallLocation = 'C:\Program Files\Other' }
    $outside = Cand @{ Key = 'Outside'; DisplayName = 'Outside'; DisplayVersion = '1'; Publisher = 'Outside Ltd'; InstallLocation = 'C:\Program Files\Common Files\Outside' }
    $co = Get-Win32ToolkitSiblingAttribution -Candidates @($foo, $updater, $residue, $other, $outside) -Manifest ([pscustomobject]@{ ProductCodes = @('{AAAA}') }) -NewRoots @('C:\Program Files\Foo', 'C:\Program Files\Other')
    if ($co.Primary -eq '{AAAA}' -and (Keys $co.CoInstalled) -eq 'Foo Updater|Native,FooHelper|Native,Other|Native' -and (Keys $co.Unattributed) -eq 'Outside|Native') { Ok "entries inside a new root -> CoInstalled by path (the primary's root, and another folder the capture created); outside every new root -> Unattributed" } else { Bad "co: $($co | ConvertTo-Json -Compress -Depth 3)" }

    # SV1 fixture: a same-signer co-product in ITS OWN new root (the design's Firefox example: the Mozilla Maintenance
    # Service under its own Program Files (x86) folder) is installed alongside the primary, not unattributed.
    $ff = Cand @{ Key = 'Mozilla Firefox'; DisplayName = 'Mozilla Firefox (x64 en-US)'; DisplayVersion = '131.0'; Publisher = 'Mozilla'; InstallLocation = 'C:\Program Files\Mozilla Firefox'; UninstallerPath = 'C:\Program Files\Mozilla Firefox\uninstall\helper.exe'; InstallDir = '%ProgramFiles%\Mozilla Firefox\uninstall' }
    $mms = Cand @{ Key = 'MozillaMaintenanceService'; DisplayName = 'Mozilla Maintenance Service'; DisplayVersion = '131.0'; Publisher = 'Mozilla'; View = 'Wow6432'; UninstallerPath = 'C:\Program Files (x86)\Mozilla Maintenance Service\Uninstall.exe' }
    # SV1 fixture: a OneDrive-style Microsoft root created during the capture (noise of the guest) is never ranked and
    # never co-installed for a non-Microsoft package, even when its key equals a manifest code.
    $od = Cand @{ Key = 'OneDriveSetup.exe'; DisplayName = 'Microsoft OneDrive'; DisplayVersion = '26.153'; Publisher = 'Microsoft Corporation'; InstallLocation = 'C:\Program Files\Microsoft OneDrive'; UninstallerPath = 'C:\Program Files\Microsoft OneDrive\26.153\OneDriveSetup.exe' }
    $ffRoots = @('C:\Program Files\Mozilla Firefox', 'C:\Program Files (x86)\Mozilla Maintenance Service', 'C:\Program Files\Microsoft OneDrive')
    $ffm = [pscustomobject]@{ ProductCodes = @('Mozilla Firefox', 'OneDriveSetup.exe') }
    $fa = Get-Win32ToolkitSiblingAttribution -Candidates @($ff, $mms, $od) -Manifest $ffm -PackagePublisher 'Mozilla' -NewRoots $ffRoots
    if ($fa.Primary -eq 'Mozilla Firefox' -and (Keys $fa.CoInstalled) -eq 'MozillaMaintenanceService|Wow6432' -and (Keys $fa.Unattributed) -eq 'OneDriveSetup.exe|Native') { Ok 'same-signer co-product in its own new root -> CoInstalled; a OneDrive-style Microsoft root -> Unattributed (never ranked, never co-installed)' } else { Bad "firefox: $($fa | ConvertTo-Json -Compress -Depth 3)" }
    $faMs = Get-Win32ToolkitSiblingAttribution -Candidates @($ff, $mms, $od) -Manifest $ffm -PackagePublisher 'Microsoft Corporation' -NewRoots $ffRoots
    if ($faMs.Primary -eq '' -and $faMs.Reason -eq 'Ambiguous' -and @($faMs.CoInstalled).Count -eq 0 -and (Keys $faMs.Unattributed) -eq 'Mozilla Firefox|Native,MozillaMaintenanceService|Wow6432,OneDriveSetup.exe|Native') { Ok 'for a Microsoft package the Microsoft entry is ranked too (two High -> Ambiguous); without a primary nothing is co-installed' } else { Bad "ms package: $($faMs | ConvertTo-Json -Compress -Depth 3)" }

    $ws = Cand @{ Key = 'Wireshark'; DisplayName = 'Wireshark 4.6.9 x64'; DisplayVersion = '4.6.9'; Publisher = 'The Wireshark developer community, https://www.wireshark.org'; InstallDir = '%ProgramFiles%\Wireshark'; UninstallerPath = 'C:\Program Files\Wireshark\uninstall-wireshark.exe'; UninstallerSignerSubject = 'CN=Wireshark Foundation, O=Wireshark Foundation' }
    $wsManifest = [pscustomobject]@{ ProductCodes = @(); Afe = @(); PackageName = 'Wireshark'; Publisher = 'The Wireshark developer community, https://www.wireshark.org'; DefaultInstallLocation = '%ProgramFiles%\Wireshark'; InstallerSignerSubject = 'CN=Wireshark Foundation, O=Wireshark Foundation' }
    $med = Get-Win32ToolkitSiblingAttribution -Candidates @($ws) -Manifest $wsManifest
    $guestWs = $ws.PSObject.Copy(); $guestWs.UninstallerSignerSubject = ''
    $guestManifest = $wsManifest.PSObject.Copy(); $guestManifest.InstallerSignerSubject = ''
    $medGuest = Get-Win32ToolkitSiblingAttribution -Candidates @($guestWs) -Manifest $guestManifest
    $otherSigner = Get-Win32ToolkitSiblingAttribution -Candidates @($ws) -Manifest ($wsManifest.PSObject.Copy() | ForEach-Object { $_.InstallerSignerSubject = 'CN=Someone Else'; $_ })
    if ($med.Rank -eq 'Medium' -and $med.Reason -eq 'PackageNameSigner' -and $medGuest.Primary -eq '' -and $otherSigner.Primary -eq '') { Ok 'name + publisher + DefaultInstallLocation + signer -> Medium on the host; the guest (no signer data) and another signer -> no primary' } else { Bad "medium: $($med.Rank)/$($medGuest.Primary)/$($otherSigner.Primary)" }
    # The folder half of Medium (spec 2.14.8 rule 1): InstallDir = the TOKENISED DefaultInstallLocation, or the leaf of the
    # captured new root that holds the entry; a DefaultInstallLocation that only shares the leaf is another folder.
    $withDefault = { param([string]$D) $m = $wsManifest.PSObject.Copy(); $m.DefaultInstallLocation = $D; $m }
    $tok1 = Get-Win32ToolkitSiblingAttribution -Candidates @($ws) -Manifest (& $withDefault 'C:/Program Files/Wireshark/')
    $tok2 = Get-Win32ToolkitSiblingAttribution -Candidates @($ws) -Manifest (& $withDefault '%ProgramW6432%\Wireshark')
    $byRoot = Get-Win32ToolkitSiblingAttribution -Candidates @($ws) -Manifest (& $withDefault '') -NewRoots @('C:\Program Files\Wireshark')
    $wsVendor = $ws.PSObject.Copy(); $wsVendor.InstallDir = '%ProgramFiles%\Vendor\Wireshark'; $wsVendor.UninstallerPath = 'C:\Program Files\Vendor\Wireshark\uninstall-wireshark.exe'
    $leafOnly = Get-Win32ToolkitSiblingAttribution -Candidates @($wsVendor) -Manifest $wsManifest -NewRoots @('C:\Program Files\Vendor')
    $noFolder = Get-Win32ToolkitSiblingAttribution -Candidates @($ws) -Manifest (& $withDefault '')
    if ($tok1.Rank -eq 'Medium' -and $tok2.Rank -eq 'Medium' -and $byRoot.Rank -eq 'Medium' -and $leafOnly.Primary -eq '' -and $noFolder.Primary -eq '') {
        Ok "Medium folder: 'C:/Program Files/Wireshark/' and '%ProgramW6432%\Wireshark' tokenised to %ProgramFiles%\Wireshark; no DefaultInstallLocation -> the captured root's leaf; a default that only shares the leaf, or no folder evidence -> no primary"
    } else { Bad "medium folder: $($tok1.Rank)/$($tok2.Rank)/$($byRoot.Rank)/[$($leafOnly.Primary)]/[$($noFolder.Primary)]" }

    $twin = Cand @{ Key = 'Notepad++ (2)'; DisplayName = 'x'; Publisher = 'Notepad++ Team'; DisplayVersion = '1' }
    $amb = Get-Win32ToolkitSiblingAttribution -Candidates @($npp, $twin) -Manifest ([pscustomobject]@{ ProductCodes = @('Notepad++', 'Notepad++ (2)') })
    $none = Get-Win32ToolkitSiblingAttribution -Candidates @($other) -Manifest $nppManifest
    if ($amb.Primary -eq '' -and $amb.Reason -eq 'Ambiguous' -and $none.Primary -eq '' -and $none.Reason -eq 'NoPrimary' -and (Keys $amb.Unattributed) -eq 'Notepad++ (2)|Native,Notepad++|Native') { Ok 'two at the best rank -> Ambiguous (both Unattributed); nothing ranked -> NoPrimary' } else { Bad "amb: $($amb | ConvertTo-Json -Compress -Depth 3)" }

    $sys = Cand @{ Key = 'Notepad++'; DisplayName = 'Notepad++'; Publisher = 'Notepad++ Team'; SystemComponent = $true }
    $nopub = Cand @{ Key = 'Notepad++'; DisplayName = 'Notepad++'; Publisher = '  ' }
    $ign = Get-Win32ToolkitSiblingAttribution -Candidates @($sys, $nopub) -Manifest $nppManifest
    if ($ign.Primary -eq '' -and @($ign.Unattributed).Count -eq 0) { Ok 'SystemComponent and publisher-less entries are not candidates at all' } else { Bad "ignored: $($ign | ConvertTo-Json -Compress -Depth 3)" }
    $same = Get-Win32ToolkitSiblingAttribution -Candidates @($npp) -Manifest $nppManifest -Own @{ ArpKeys = @(@{ Key = 'Notepad++'; View = 'Native' }) }
    if ($same.Primary -eq 'Notepad++' -and $same.SameKey) { Ok "the primary is one of the package's own keys -> SameKey (no proposal later)" } else { Bad "same key: $($same | ConvertTo-Json -Compress)" }

    # == [3] guest and host agree ===========================================================================
    Write-Host '[3] the same text in a Windows PowerShell 5.1 child' -ForegroundColor Cyan
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51)) { Write-Host '  SKIP: Windows PowerShell 5.1 is not installed' -ForegroundColor Yellow }
    else {
        $plugin = Cand @{ Key = 'Notepad++ Plugin Admin'; DisplayName = 'Plugin Admin'; DisplayVersion = '1.5'; Publisher = 'Notepad++ Team'; UninstallerPath = 'C:\Program Files\Notepad++\plugins\Config\uninst.exe' }
        $svc = Cand @{ Key = 'Notepad++ Service'; DisplayName = 'Notepad++ Service'; DisplayVersion = '1.0'; Publisher = 'Notepad++ Team'; View = 'Wow6432'; UninstallerPath = 'C:\Program Files (x86)\Notepad++ Service\uninst.exe' }
        $wsOut = Cand @{ Key = 'Npcap'; DisplayName = 'Npcap'; DisplayVersion = '1.80'; Publisher = 'Nmap Project'; InstallLocation = 'C:\Program Files\Common Files\Npcap' }
        $sets = @(
            @{ Expect = 'Notepad++|High|ProductCode|False|Notepad++ Plugin Admin,Notepad++ Service|Microsoft Edge Update,Microsoft EdgeWebView'
                Data = [ordered]@{ Candidates = @($npp, $edge, $webview, $plugin, $svc); Manifest = $nppManifest; Own = @{ ArpKeys = @() }; PackagePublisher = 'Notepad++ Team'; NewRoots = @($roots + 'C:\Program Files (x86)\Notepad++ Service') } }
            @{ Expect = 'Wireshark|Medium|PackageNameSigner|False||Npcap'
                Data = [ordered]@{ Candidates = @($ws, $wsOut); Manifest = (& $withDefault 'C:/Program Files/Wireshark'); Own = @{ ArpKeys = @() }; PackagePublisher = ''; NewRoots = @('C:\Program Files\Wireshark') } }
            @{ Expect = 'Wireshark|Medium|PackageNameSigner|False||'
                Data = [ordered]@{ Candidates = @($ws); Manifest = (& $withDefault ''); Own = @{ ArpKeys = @() }; PackagePublisher = ''; NewRoots = @('C:\Program Files\Wireshark') } }
        )
        $runner = Join-Path $tmp 'run51.ps1'
        [IO.File]::WriteAllText($runner, ("param([string]`$Text, [string]`$Data)`r`n`$d = Get-Content -LiteralPath `$Data -Raw | ConvertFrom-Json`r`n. ([scriptblock]::Create([IO.File]::ReadAllText(`$Text)))`r`n" +
                "`$r = & `$w32tScAttribute @(`$d.Candidates) `$d.Manifest `$d.Own `$d.PackagePublisher @(`$d.NewRoots)`r`n" +
                "'{0}|{1}|{2}|{3}|{4}|{5}' -f `$r.Primary, `$r.Rank, `$r.Reason, `$r.SameKey, ((@(`$r.CoInstalled | ForEach-Object { `$_.Key }) | Sort-Object) -join ','), ((@(`$r.Unattributed | ForEach-Object { `$_.Key }) | Sort-Object) -join ',')`r`n"), [Text.UTF8Encoding]::new($true))
        $i = 0
        foreach ($set in $sets) {
            $i++
            $data = $set.Data
            $dataFile = Join-Path $tmp "data$i.json"
            [IO.File]::WriteAllText($dataFile, ($data | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
            $guestLine = (& $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Text $file -Data $dataFile 2>&1 | Select-Object -Last 1) -as [string]
            $h = Get-Win32ToolkitSiblingAttribution -Candidates $data.Candidates -Manifest $data.Manifest -Own $data.Own -PackagePublisher $data.PackagePublisher -NewRoots $data.NewRoots
            $hostLine = '{0}|{1}|{2}|{3}|{4}|{5}' -f $h.Primary, $h.Rank, $h.Reason, $h.SameKey, ((@($h.CoInstalled | ForEach-Object Key) | Sort-Object) -join ','), ((@($h.Unattributed | ForEach-Object Key) | Sort-Object) -join ',')
            if ($guestLine -ceq $hostLine -and $hostLine -ceq $set.Expect) { Ok "5.1 child and host agree: $hostLine" } else { Bad "set $i guest [$guestLine] host [$hostLine] expected [$($set.Expect)]" }
        }
    }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingAttribution tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingAttribution test(s) FAILED." -ForegroundColor Red; exit 1 }
