<#
    Installer-identity PR 3 (spec 2.11 Publish; D23, D29, L17, L29, L40): what Publish-Win32ToolkitIntuneApp does for a
    package with prior-install rules.

      [1] Get-Win32ToolkitPriorConflict (Graph shadowed; the shadow refuses a $select of a property the base type
          microsoft.graph.mobileApp lacks, as Graph does with a 400): a Required app with a registry detection on
          ...\Uninstall\Notepad++ (either view) -> a warning naming it; an Available one -> none; a script detection
          that contains the path -> a warning; the next page is read; the newer rules list: a detection item on the
          path -> a warning, a requirement item -> none; Required apps whose listing has no detection rule (neither
          property, an empty detectionRules, a rules list of requirement items only) -> one 'could not read' result
          that counts them and names each (name and id; an Available one is neither counted nor named), at most 10
          named plus 'and N more'; an earlier version of the app recorded in
          Publications.json and still assigned Required -> PredecessorRequired; a Graph error -> one 'could not check'
          result; no Enforce rule -> no Graph call.
      [2] the L40 binding check (Assert-Win32ToolkitPriorInstallPackaged): project and Staging copy equal -> passes;
          a mode changed after Export -> W32T.PackageNotReady naming re-export; no Staging copy with rules -> refused;
          no rules anywhere -> nothing checked (even without a Staging copy).
      [3] Publish: the binding check runs before the -WhatIf gate (refused under -WhatIf too, no Graph call); -WhatIf
          with good rules -> the pilot warning and the prior-install exit codes (not for a Report-only set), no Graph call
          at all; a live publish -> the conflict read after the
          sign-in and before the app shell, its warning shown, the publish goes on; a Graph error there -> one warning,
          the app shell is still POSTed.

    Graph is fully shadowed; nothing reaches a tenant. Run:  pwsh -File Tests\PublishPriorConflict.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-WebRequest is shadowed: the suite never touches the network')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Publish-Win32ToolkitIntuneApp.ps1')
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

# == Graph shadows ====================================================================================
$script:calls = [System.Collections.Generic.List[string]]::new()
$script:pages = @{}
$script:graphThrows = $false
function Connect-Win32ToolkitGraph { param($TenantId) $null = $TenantId; $script:calls.Add('connect') }
function Get-MgContext { $script:calls.Add('context'); [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'test@contoso.com'; Scopes = @('DeviceManagementApps.ReadWrite.All'); ContextScope = 'Process'; AuthType = 'Delegated' } }
function Get-Win32ToolkitTenantInfo { $null }
function Get-Win32IntuneWinMetadata { param($IntuneWinPath) $null = $IntuneWinPath; $script:calls.Add('metadata'); [pscustomobject]@{ UnencryptedSize = 1MB; SizeEncrypted = 1MB; FileName = 'x.intunewin'; EncryptionInfo = @{} } }
# The properties of the BASE type microsoft.graph.mobileApp. Graph checks $select against it (isof() filters, it does not
# cast): a win32LobApp property such as detectionRules is a hard 400, the live error Find-Win32ToolkitIntuneApp records.
$script:mobileAppProps = @('id', 'displayName', 'description', 'publisher', 'largeIcon', 'createdDateTime', 'lastModifiedDateTime', 'isFeatured',
    'privacyInformationUrl', 'informationUrl', 'owner', 'developer', 'notes', 'uploadState', 'publishingState', 'isAssigned', 'roleScopeTagIds',
    'dependentAppCount', 'supersedingAppCount', 'supersededAppCount')
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    $null = $Body, $ContentType, $OutputType
    if ($Method -eq 'GET' -and $Uri -like '*mobileApps?*') {
        $script:calls.Add("list:$Uri")
        if ($script:graphThrows) { throw 'Graph said 403' }
        if ($Uri -match '[?&]\$select=([^&]*)') {
            foreach ($p in ($Matches[1] -split ',')) {
                if ($script:mobileAppProps -cnotcontains $p) { throw "Response status code does not indicate success: BadRequest (Bad Request). Could not find a property named '$p' on type 'microsoft.graph.mobileApp'." }
            }
        }
        if ($script:pages.ContainsKey($Uri)) { return $script:pages[$Uri] }
        return [pscustomobject]@{ value = @() }
    }
    if ($Method -eq 'POST' -and $Uri -match '/mobileApps$') { $script:calls.Add('post-app'); throw 'W32T_TEST_SENTINEL' }
    $script:calls.Add("other:$Method $Uri")
    [pscustomobject]@{ id = 'fake' }
}
function Get-Win32ToolkitProjectPsadtVersion { param([string]$ProjectPath) $null = $ProjectPath; [pscustomobject]@{ Prerelease = ''; VersionText = '4.1.8' } }
function Invoke-WebRequest { throw 'PublishPriorConflict: no network in this suite' }

$base = Join-Path ([IO.Path]::GetTempPath()) ('w32ppc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
$listUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')&`$expand=assignments"

function Entry([string]$Mode = 'Enforce', [string]$Key = 'Notepad++') {
    [ordered]@{ Id = 'nsis-x64'; Kind = 'ArpKey'; Mode = $Mode; Key = $Key; View = 'Native'; Publisher = 'Notepad++ Team'; DisplayName = 'Notepad++ (64-bit x64)'; DisplayNameTemplate = ''
        VersionMin = '8.8.9'; VersionMax = '8.9.9'; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Notepad++'
        MainExe = 'notepad++.exe'; ProcessNames = @('notepad++'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' }
}
# <base>\Projects\T\<name> (+ Staging copy + .intunewin), as Export leaves them.
function New-PubProject {
    param([string]$Name, [object[]]$Entries, [switch]$NoStaging, [string]$Version = '8.9.9', [switch]$NoPrior)
    $p = Join-Path $base "Projects\T\$Name"
    foreach ($d in 'SupportFiles', 'Files', 'Documentation') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    $cfg = [ordered]@{ SchemaVersion = '1.0'
        App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = 'Notepad++'; DisplayName = 'Notepad++'; Version = $Version; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.msi'; SilentArgs = '' }
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = $Version; InstallerType = 'wix'; Family = 'msi'; Architecture = 'x64'; PinnedBy = 'winget-default'; ProductCode = $PC }
        OwnIdentity = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' } }
    if (-not $NoPrior) { $cfg['PriorInstalls'] = [ordered]@{ SchemaVersion = '1.0'; Entries = @($Entries) } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'Files\npp.msi'), 'stub', $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), '## win32-toolkit install tattoo - records the installed version (test stub)', $utf8)
    if (-not $NoStaging) {
        $s = Join-Path $base "Staging\T\$Name\SupportFiles"
        $null = New-Item -ItemType Directory -Path $s -Force
        Copy-Item -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json') -Destination $s -Force
    }
    $iwDir = Join-Path $base 'IntuneWin\T'
    $null = New-Item -ItemType Directory -Path $iwDir -Force
    $iw = Join-Path $iwDir "$Name.intunewin"
    [IO.File]::WriteAllText($iw, 'stub', $utf8)
    [pscustomobject]@{ Project = $p; IntuneWin = $iw }
}
function Set-Mode([string]$P, [string]$Mode) {
    $f = Join-Path $P 'SupportFiles\AppConfig.json'
    $c = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    $c.PriorInstalls.Entries[0].Mode = $Mode
    [IO.File]::WriteAllText($f, ($c | ConvertTo-Json -Depth 8), $utf8)
}
function App([string]$Id, [string]$Name, [string]$Intent, [object[]]$Rules) {
    [pscustomobject]@{ id = $Id; displayName = $Name; detectionRules = @($Rules); assignments = @(if ($Intent) { [pscustomobject]@{ intent = $Intent } }) }
}
# An app as the listing may also carry it: only the newer rules list (-NewRules), or no detection rules at all (neither).
function AppOther([string]$Id, [string]$Name, [string]$Intent, [object[]]$NewRules, [switch]$NoRules) {
    $a = [ordered]@{ id = $Id; displayName = $Name; assignments = @(if ($Intent) { [pscustomobject]@{ intent = $Intent } }) }
    if (-not $NoRules) { $a['rules'] = @($NewRules) }
    [pscustomobject]$a
}
function Invoke-Publish($Proj, [switch]$DryRun) {
    $script:calls.Clear()
    $err = $null; $w = $null
    try { Publish-Win32ToolkitIntuneApp -ProjectPath $Proj.Project -IntuneWinPath $Proj.IntuneWin -WhatIf:$DryRun -Confirm:$false -ErrorAction Stop -WarningVariable w 3>$null 6>$null | Out-Null }
    catch { if ("$($_.Exception.Message)" -notmatch 'W32T_TEST_SENTINEL') { $err = $_ } }
    [pscustomobject]@{ Error = $err; Warnings = @($w | ForEach-Object { "$_" }); Calls = @($script:calls) }
}

try {
    # == [1] ===================================================================================================
    Write-Host '[1] Get-Win32ToolkitPriorConflict' -ForegroundColor Cyan
    $pr = New-PubProject 'Notepad++_x64_8.9.9' @((Entry))
    $reg = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryDetection'; keyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\notepad++'; valueName = 'DisplayVersion' }
    $scr = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptDetection'; scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++") { "x" }')) }
    $next = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$skiptoken=abc'
    $nppKey = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'
    $ruleReq = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'requirement'; keyPath = $nppKey; valueName = 'DisplayVersion' }
    $ruleFile = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppFileSystemRule'; ruleType = 'detection'; path = 'C:\Program Files\Npp Updater'; fileOrFolderName = 'upd.exe' }
    $ruleDet = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'detection'; keyPath = $nppKey; valueName = 'DisplayVersion' }
    $script:pages = @{
        $listUri = [pscustomobject]@{ value = @((App 'aaaaaaaa-0000-0000-0000-000000000001' 'Notepad++ (vendor)' 'required' @($reg)), (App 'aaaaaaaa-0000-0000-0000-000000000002' 'Notepad++ portable' 'available' @($reg))); '@odata.nextLink' = $next }
        $next    = [pscustomobject]@{ value = @((App 'aaaaaaaa-0000-0000-0000-000000000003' "Npp script`e[31m" 'required' @($scr)), (App 'aaaaaaaa-0000-0000-0000-000000000004' 'Other' 'required' @([pscustomobject]@{ keyPath = 'HKLM\SOFTWARE\Other' })),
                (AppOther 'aaaaaaaa-0000-0000-0000-000000000005' 'Npp updater (requirement only)' 'required' @($ruleReq, $ruleFile)),
                (AppOther 'aaaaaaaa-0000-0000-0000-000000000006' 'Npp (rules list)' 'required' @($ruleDet)),
                (AppOther 'aaaaaaaa-0000-0000-0000-000000000007' 'No rules listed' 'required' -NoRules),
                (AppOther 'aaaaaaaa-0000-0000-0000-000000000008' 'No rules, available' 'available' -NoRules),
                (App 'aaaaaaaa-0000-0000-0000-000000000009' 'Empty detectionRules' 'required' @()),
                (AppOther 'aaaaaaaa-0000-0000-0000-00000000000a' 'Requirement rules only' 'required' @($ruleReq))) }
    }
    $script:calls.Clear()
    $c = @(Get-Win32ToolkitPriorConflict -ProjectPath $pr.Project)
    $names = @($c | Where-Object Kind -eq 'DetectsPrior' | ForEach-Object DisplayName)
    if (@($c | Where-Object { $_.Kind -eq 'DetectsPrior' -and $_.DisplayName -eq 'Notepad++ (vendor)' -and $_.Message -match 'assigned Required' -and $_.Message -match '69110' }).Count -eq 1) { Ok 'a Required app with a registry detection on ...\Uninstall\Notepad++ (WOW6432Node view, other case) -> a warning naming it' } else { Bad "registry: $($c | ConvertTo-Json -Compress)" }
    if ($names -notcontains 'Notepad++ portable' -and $names -notcontains 'Other') { Ok 'an Available app, and a Required app detecting something else -> none' } else { Bad "names: $($names -join ',')" }
    if (@($c | Where-Object { $_.Kind -eq 'DetectsPrior' -and $_.AppId -like '*0003' -and -not $_.DisplayName.Contains([string][char]0x1B) }).Count -eq 1) { Ok 'a script detection that contains the path -> a warning (on the next page; the name made safe)' } else { Bad "script: $($c | ConvertTo-Json -Compress)" }
    if (@($script:calls | Where-Object { $_ -like 'list:*' }).Count -eq 2 -and $script:calls[0] -ceq "list:$listUri") { Ok 'one constant query, then the @odata.nextLink page' } else { Bad "calls: $($script:calls -join ' | ')" }
    if (@($script:calls | Where-Object { $_ -match '\$select=' }).Count -eq 0 -and @($c | Where-Object { $_.Message -match 'Could not check' }).Count -eq 0) { Ok 'no $select of a win32LobApp property (Graph answers that with a 400 on the base type mobileApp)' } else { Bad "select: $($c | ConvertTo-Json -Compress)" }
    if ($names -contains 'Npp (rules list)' -and $names -notcontains 'Npp updater (requirement only)') { Ok 'the newer rules list: a detection item on the path -> a warning; a requirement item -> none' } else { Bad "rules list: $($names -join ',')" }
    $unread = @($c | Where-Object { $_.Kind -eq 'Unchecked' })
    if ($unread.Count -eq 1 -and $unread[0].Message -match '^Could not read the detection rules of 3 Required Win32 app' -and $unread[0].Message -match 'Notepad\+\+') { Ok "Required apps listed without a detection rule (no property, an empty detectionRules, requirement rules only) -> one 'could not read' result counting all 3 (an Available one is not counted)" } else { Bad "unreadable: $($c | ConvertTo-Json -Compress)" }
    $um = if ($unread.Count -eq 1) { [string]$unread[0].Message } else { '' }
    if ($um.Contains("'No rules listed' (aaaaaaaa-0000-0000-0000-000000000007)") -and $um.Contains("'Empty detectionRules' (aaaaaaaa-0000-0000-0000-000000000009)") -and $um.Contains("'Requirement rules only' (aaaaaaaa-0000-0000-0000-00000000000a)") -and
        -not $um.Contains('000000000008') -and -not $um.Contains('No rules, available') -and $um -notmatch ' more\b') { Ok "the 'could not read' result names each unreadable Required app (name and id), not the Available one" } else { Bad "unreadable names: $um" }
    $keepPages = $script:pages
    $script:pages = @{ $listUri = [pscustomobject]@{ value = @(1..12 | ForEach-Object { AppOther ('bbbbbbbb-0000-0000-0000-{0:d12}' -f $_) "Unread $_" 'required' -NoRules }) } }
    $um = [string](@(Get-Win32ToolkitPriorConflict -ProjectPath $pr.Project) | Where-Object Kind -eq 'Unchecked' | Select-Object -First 1).Message
    $script:pages = $keepPages
    if ($um -match '^Could not read the detection rules of 12 Required' -and $um.Contains("'Unread 1' (bbbbbbbb-0000-0000-0000-000000000001)") -and $um.Contains("'Unread 10' (bbbbbbbb-0000-0000-0000-000000000010)") -and
        -not $um.Contains("'Unread 11'") -and $um.Contains('and 2 more')) { Ok "12 unreadable Required apps -> the first 10 named, then 'and 2 more'" } else { Bad "unreadable cap: $um" }
    $old = New-PubProject 'Notepad++_x64_8.9.8.1' @() -Version '8.9.8.1' -NoStaging
    $null = New-Item -ItemType Directory -Path (Join-Path $old.Project 'Intune') -Force
    [IO.File]::WriteAllText((Join-Path $old.Project 'Intune\Publications.json'), '[{"TenantId":"tenant-1","AppId":"aaaaaaaa-0000-0000-0000-000000000001","WingetId":"Notepad++.Notepad++"}]', $utf8)
    $c = @(Get-Win32ToolkitPriorConflict -ProjectPath $pr.Project)
    if (@($c | Where-Object { $_.Kind -eq 'PredecessorRequired' -and $_.Message -match 'Notepad\+\+_x64_8\.9\.8\.1' -and $_.Message -match 'unassign' }).Count -eq 1) { Ok 'an earlier version recorded in Publications.json and still assigned Required -> PredecessorRequired (D29)' } else { Bad "predecessor: $($c | ConvertTo-Json -Compress)" }
    $script:graphThrows = $true
    $c = @(Get-Win32ToolkitPriorConflict -ProjectPath $pr.Project)
    $script:graphThrows = $false
    if ($c.Count -eq 1 -and $c[0].Kind -eq 'Unchecked' -and $c[0].Message -match 'Could not check' -and $c[0].Message -match '403') { Ok "a Graph error -> one 'could not check' result (fail-open)" } else { Bad "error: $($c | ConvertTo-Json -Compress)" }
    $blk = New-PubProject 'Block_x64_1.0' @((Entry 'Block'))
    $script:calls.Clear()
    $c = @(Get-Win32ToolkitPriorConflict -ProjectPath $blk.Project)
    if ($c.Count -eq 0 -and $script:calls.Count -eq 0) { Ok 'no Enforce rule -> no Graph call' } else { Bad "block: $($script:calls -join ' | ')" }

    # == [2] ===================================================================================================
    Write-Host '[2] the L40 binding check' -ForegroundColor Cyan
    $err = $null
    try { $s = Assert-Win32ToolkitPriorInstallPackaged -ProjectPath $pr.Project -IntuneWinPath $pr.IntuneWin } catch { $err = $_ }
    if (-not $err -and $s -eq (Join-Path $base 'Staging\T\Notepad++_x64_8.9.9')) { Ok 'project and Staging copy equal -> passes (Staging found from the .intunewin)' } else { Bad "equal: $err $s" }
    Set-Mode $pr.Project 'Block'
    $err = $null
    try { $null = Assert-Win32ToolkitPriorInstallPackaged -ProjectPath $pr.Project -IntuneWinPath $pr.IntuneWin } catch { $err = $_ }
    if ($err.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and "$($err.Exception.Message)" -match '^Prior install: the prior-install rules changed after Export' -and "$($err.Exception.Message)" -match 'Re-export') { Ok 'a mode changed after Export -> W32T.PackageNotReady naming re-export' } else { Bad "changed: $err" }
    Set-Mode $pr.Project 'Enforce'
    $ns = New-PubProject 'NoStage_x64_1.0' @((Entry)) -NoStaging
    $err = $null
    try { $null = Assert-Win32ToolkitPriorInstallPackaged -ProjectPath $ns.Project -IntuneWinPath $ns.IntuneWin } catch { $err = $_ }
    if ($err.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and "$($err.Exception.Message)" -match 'Staging copy .* is missing') { Ok 'rules and no Staging copy -> refused' } else { Bad "no staging: $err" }
    $none = New-PubProject 'None_x64_1.0' -NoPrior -NoStaging
    $err = $null
    try { $s = Assert-Win32ToolkitPriorInstallPackaged -ProjectPath $none.Project -IntuneWinPath $none.IntuneWin } catch { $err = $_ }
    if (-not $err -and $s -eq '') { Ok 'no rules anywhere -> nothing checked (no Staging copy needed)' } else { Bad "none: $err" }

    # == [3] ===================================================================================================
    Write-Host '[3] Publish-Win32ToolkitIntuneApp' -ForegroundColor Cyan
    Set-Mode $pr.Project 'Block'
    $r = Invoke-Publish $pr -DryRun
    Set-Mode $pr.Project 'Enforce'
    if ($r.Error.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and $r.Calls.Count -eq 0) { Ok 'rules changed after Export -> refused under -WhatIf too, before any Graph call' } else { Bad "whatif changed: $($r.Error) calls=$($r.Calls -join ' | ')" }
    $r = Invoke-Publish $pr -DryRun
    # Live rows OP-EXPORT, GOAL-EXPORT (round 2): the advisory's PRIOR-ENFORCE-PILOT row and Publish's own line said the same
    # reminder twice per call. Once now: Publish prints its own line only when the advisory did not print that row.
    $pilot = @($r.Warnings | Where-Object { $_ -match 'removes another install of the app' -and $_ -match 'pilot group' -and $_ -match 'RemovePriorDisabled' -and $_ -match 'HKLM\\SOFTWARE\\Contoso IT\\win32-toolkit' })
    if (-not $r.Error -and $r.Calls.Count -eq 0 -and $pilot.Count -eq 1) { Ok '-WhatIf with current rules -> the pilot reminder once (kill switch under the ScriptAuthor key), no Graph call at all' } else { Bad "whatif: $($r.Error) calls=$($r.Calls -join ' | ') warnings=$($r.Warnings -join ' | ')" }
    # The advisory already shown in this run scope (Export, then Publish): Publish's own line is the reminder.
    $script:W32TAdvisoryRun = @{ ([System.IO.Path]::GetFullPath($pr.Project).TrimEnd('\')) = $true }
    $r2 = Invoke-Publish $pr -DryRun
    $script:W32TAdvisoryRun = $null
    if (-not $r2.Error -and @($r2.Warnings | Where-Object { $_ -match '^''Notepad\+\+'' removes another install' -and $_ -match 'Enforce prior-install rule' -and $_ -match 'pilot group' }).Count -eq 1) { Ok 'the advisory already shown in this run: Publish''s own pilot line is printed (once)' } else { Bad "scoped: $($r2.Warnings -join ' | ')" }
    $dry = @(Publish-Win32ToolkitIntuneApp -ProjectPath $pr.Project -IntuneWinPath $pr.IntuneWin -WhatIf -Confirm:$false 3>$null 6>&1 | ForEach-Object { "$_" })
    $codesLine = @($dry | Where-Object { $_ -match '^WhatIf: the app would report the prior-install exit codes 69101, 69102, 69105, 69106, 69107, 69108, 69109, 69110, 69111, 69112 as failed \(1618 stays retry\)\.$' })
    $reportOnly = New-PubProject 'Report_x64_1.0' @((Entry 'Report'))
    $dryReport = @(Publish-Win32ToolkitIntuneApp -ProjectPath $reportOnly.Project -IntuneWinPath $reportOnly.IntuneWin -WhatIf -Confirm:$false 3>$null 6>&1 | ForEach-Object { "$_" })
    if ($codesLine.Count -eq 1 -and @($dryReport | Where-Object { $_ -match 'prior-install exit codes' }).Count -eq 0) { Ok '-WhatIf names the prior-install exit codes registered as failed (an Enforce rule); a Report-only set does not' } else { Bad "codes line: $($dry -join ' | ') // $($dryReport -join ' | ')" }
    $r = Invoke-Publish $pr
    $iList =[array]::IndexOf($r.Calls, ($r.Calls | Where-Object { $_ -like 'list:*' } | Select-Object -First 1)); $iConnect = [array]::IndexOf($r.Calls, 'connect'); $iPost = [array]::IndexOf($r.Calls, 'post-app')
    if (-not $r.Error -and $iConnect -ge 0 -and $iList -gt $iConnect -and $iPost -gt $iList -and @($r.Warnings | Where-Object { $_ -match "Notepad\+\+ \(vendor\)" -and $_ -match 'detects the prior install' }).Count -eq 1) { Ok 'live: the conflict read after the sign-in and before the app shell; its warning shown; the publish goes on' } else { Bad "live: $($r.Error) calls=$($r.Calls -join ' | ') warnings=$($r.Warnings -join ' | ')" }
    $script:graphThrows = $true
    $r = Invoke-Publish $pr
    $script:graphThrows = $false
    if (-not $r.Error -and $r.Calls -contains 'post-app' -and @($r.Warnings | Where-Object { $_ -match 'Could not check the tenant' }).Count -eq 1) { Ok 'a Graph error in the conflict read -> one warning, the app shell is still POSTed' } else { Bad "graph error: $($r.Error) calls=$($r.Calls -join ' | ')" }
    $r = Invoke-Publish $blk
    if (-not $r.Error -and @($r.Calls | Where-Object { $_ -like 'list:*' }).Count -eq 0 -and $r.Calls -contains 'post-app' -and @($r.Warnings | Where-Object { $_ -match 'Enforce prior-install rule' }).Count -eq 0) { Ok 'Block rules only -> no conflict read, no pilot line from Publish' } else { Bad "block publish: $($r.Error) calls=$($r.Calls -join ' | ')" }

    # == [4] ===================================================================================================
    # Live rows OP-EXPORT / GOAL-EXPORT: Publish -AsUpdate -WhatIf rewrote SupportFiles\UpdateRequirement.ps1 in the raw
    # project, a file the Hyper-V proof is bound to (SupportFilesSha256): a dry run could revoke a proof. Now the copy is
    # written only past the -WhatIf gate.
    Write-Host '[4] Publish -AsUpdate: the requirement copy only past the -WhatIf gate' -ForegroundColor Cyan
    function Get-Win32ToolkitMsiProperty { param([string]$Path, [string]$Property) $null = $Path, $Property; '' }
    $reqCopy = Join-Path $pr.Project 'SupportFiles\UpdateRequirement.ps1'
    Remove-Item -LiteralPath $reqCopy -Force -ErrorAction SilentlyContinue
    $err = $null
    try { Publish-Win32ToolkitIntuneApp -ProjectPath $pr.Project -IntuneWinPath $pr.IntuneWin -AsUpdate -WhatIf -Confirm:$false -ErrorAction Stop 3>$null 6>$null | Out-Null } catch { $err = $_ }
    if (-not $err -and -not (Test-Path -LiteralPath $reqCopy)) { Ok '-AsUpdate -WhatIf: no SupportFiles\UpdateRequirement.ps1 written (the dry run changes nothing the proof is bound to)' } else { Bad "whatif wrote the copy: err=$err exists=$(Test-Path -LiteralPath $reqCopy)" }
    $err = $null
    try { Publish-Win32ToolkitIntuneApp -ProjectPath $pr.Project -IntuneWinPath $pr.IntuneWin -AsUpdate -Confirm:$false -ErrorAction Stop 3>$null 6>$null | Out-Null }
    catch { if ("$($_.Exception.Message)" -notmatch 'W32T_TEST_SENTINEL') { $err = $_ } }
    $copyText = if (Test-Path -LiteralPath $reqCopy) { [IO.File]::ReadAllText($reqCopy) } else { '' }
    if (-not $err -and $copyText -match 'win32-toolkit update requirement') { Ok '-AsUpdate past the gate: the copy is written (before the app shell)' } else { Bad "live: err=$err copy='$copyText'" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PublishPriorConflict tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PublishPriorConflict test(s) FAILED." -ForegroundColor Red; exit 1 }
