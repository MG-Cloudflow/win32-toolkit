<#
    Uninstall cleanup paths stay inside the app's own install folders (V1, S18, I-1, I-1b; spec 2.3, 2.4).

    THE BUG: Update-PSADTUninstallLogic turned the PARENT folder of every new file under '*Program Files*'
    into an uninstall cleanup path, and the data-driven uninstall deletes each one recursively as SYSTEM.
    A Firefox capture listed 'C:\Program Files (x86)' itself; a Git capture listed eight Edge / EdgeCore /
    EdgeUpdate / EdgeWebView folders that the Edge updater happened to create during the capture window.

    Covered here:
      [1]  Test-Win32ToolkitCleanupPath: every row of the spec 2.3 expected-reasons table (exact arrays,
           order included), Valid, Root, Explanation; roots with a trailing '\'; $null / '' paths.
      [2]  Get-Win32ToolkitInstallRoot + the capture derivation on git-edge-noise.json.
      [3]  ... on firefox-coinstalled.json (ProductCode / DisplayName / no primary key).
      [4]  ... on vendor-parent.json (UninstallerIcon containment rule).
      [5]  ... on default-install-location.json (manifest DefaultInstallLocation, HKCU key).
      [6]  malformed captures: empty result, never a throw.
      [7]  Update-PSADTUninstallLogic end to end on the fixtures (temp projects): InstallRoots and
           CleanupPaths, idempotent.
      [8]  Update-PSADTUninstallLogic, installer-identity PR 2 spec 2.1: the app's own uninstaller first
           (I-3), Uninstall.AppName from the primary entry (I-4), Uninstallers[].Kind from the winget
           manifest or the installer file's signature (B2 #1) kept only when the uninstall entry agrees,
           the '/S' rule for 'nullsoft' (L5), msi entries, no primary key, idempotent.
      [9]  every Get-Content in Get-Win32ToolkitInstallRoot.ps1 passes -Encoding.
      [10] C-4 / K1: the two new files are ASCII-only, define only their function, and every catch starts
           with the C-2 re-throw.

    Fixtures (Tests\Fixtures\captures\, hand-built synthetic InstallationChanges_*.json with only the
    NewFiles / NewRegistryKeys entries the cases need; generic product paths, no template or customer
    names; read-only - each case copies what it needs to %TEMP%):
      git-edge-noise.json            one HKLM key Git_is1 (InstallLocation 'C:\Program Files\Git\'), the
                                     Git folders, Edge / EdgeCore / EdgeUpdate / EdgeWebView folders created
                                     by an updater, a Start Menu folder, a guest temp folder, one Type
                                     Unknown entry, an EdgeUpdate client key (not an Uninstall key).
      firefox-coinstalled.json       keys 'Mozilla Firefox' (InstallLocation, uninstall\helper.exe,
                                     firefox.exe,0) and 'MozillaMaintenanceService' (no InstallLocation,
                                     uninstaller and icon in 'C:\Program Files (x86)\Mozilla Maintenance
                                     Service'); 12 Firefox folders and the two Maintenance Service folders;
                                     nothing at 'C:\Program Files (x86)' itself.
      vendor-parent.json             one key, no InstallLocation, uninstaller in 'C:\Program Files\Acme\
                                     Uninstall', DisplayIcon in 'C:\Program Files\Acme\App'.
      default-install-location.json  one HKLM MSI key with no folder information, one HKCU key with an
                                     InstallLocation, created 'C:\Program Files\Acme'.
      coinstalled-first.json         a co-installed key 'AcmeUpdater' (WOW6432Node) listed BEFORE the
                                     app's own key 'Acme Widget' (InstallLocation, uninstall.exe, no
                                     switch); synthetic names.
    The winget manifests the ProductCode / DefaultInstallLocation cases need, and the synthetic installer
    files (an NSIS or Inno Setup signature in zeros) of [8], are written by this suite into the temp
    project's Files\ folder.

    Nothing is installed, executed or deleted outside %TEMP%; nothing touches the network.

    Run:  pwsh -File Tests\CleanupPath.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$predicatePath = Join-Path $repo 'Private\Test-Win32ToolkitCleanupPath.ps1'
$rootPath      = Join-Path $repo 'Private\Get-Win32ToolkitInstallRoot.ps1'
. $predicatePath
. $rootPath
. (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitProductCode.ps1')
. (Join-Path $repo 'Private\Update-PSADTUninstallLogic.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerTechnology.ps1')   # Update-PSADTUninstallLogic -> installer signature (C-9)

$fixtures = Join-Path $PSScriptRoot 'Fixtures\captures'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32cp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))

function Read-Capture([string]$Name) { Get-Content -LiteralPath (Join-Path $fixtures $Name) -Raw -Encoding UTF8 | ConvertFrom-Json }
function Join-Reason($r) { @($r) -join ',' }

# A temp project: SupportFiles\AppConfig.json (App section), optional Files\x.installer.yaml, the capture
# copied to Documentation\.
function Build-TempProject {
    param([string]$Name, [string]$Capture, [string]$Manifest, [string]$DisplayName = '', [string]$AppName = 'App')
    $p = Join-Path $root $Name
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles'), (Join-Path $p 'Documentation') -Force | Out-Null
    $app = [ordered]@{ Name = $AppName; Version = '1.0' }
    if ($DisplayName) { $app.DisplayName = $DisplayName }
    $null = Set-Win32ToolkitAppConfig -ProjectPath $p -Config ([pscustomobject]@{ SchemaVersion = '1.0'; App = [pscustomobject]$app })
    if ($Manifest) {
        New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $p 'Files\x.installer.yaml'), $Manifest, (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($Capture) { Copy-Item -LiteralPath (Join-Path $fixtures $Capture) -Destination (Join-Path $p "Documentation\InstallationChanges_20260101_120000.json") }
    $p
}

# The spec 2.4 capture derivation (the same expression Update-PSADTUninstallLogic runs).
function Get-DerivedCleanup($ir) {
    $keep = @($ir.CreatedDirectories | Where-Object {
            (Test-Win32ToolkitCleanupPath -Path $_ -InstallRoot $ir.Roots -CreatedDirectory $ir.CreatedDirectories).Valid })
    @($keep | Where-Object { $d = $_; -not ($keep | Where-Object { $_ -ne $d -and ($d + '\').StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }) } | Sort-Object)
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # == [1] the predicate =============================================================================
    Write-Host '[1] Test-Win32ToolkitCleanupPath: the spec 2.3 expected-reasons table' -ForegroundColor Cyan
    $git = @('C:\Program Files\Git')
    $long = 'C:\Program Files\' + ('a' * 224)        # 241 characters
    $max  = 'C:\Program Files\Git\' + ('b' * 219)    # 240 characters, inside the root
    $rows = @(
        @{ P = 'C:\Program Files\Git'; R = '' }
        @{ P = 'C:\Program Files\Git\usr\bin'; R = '' }
        @{ P = 'c:\program files\GIT\x'; R = '' }
        @{ P = 'C:\Program Files (x86)'; R = 'ShellFolder,OutsideInstallRoot' }
        @{ P = 'C:\Program Files\GitHub\x'; R = 'OutsideInstallRoot' }
        @{ P = 'C:\Program Files (x86)\Microsoft\EdgeCore\152.0.4191.66'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\Program Files\Microsoft Update Health Tools'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\Program Files\WindowsPowerShell\Modules\X'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\Program Files\Common Files\Vendor'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\ProgramData\Package Cache\{11111111-2222-3333-4444-555555555555}'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\ProgramData\Application Data\X'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\ProgramData\Desktop'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\ProgramData\Documents\X'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\ProgramData\Start Menu\Programs\X'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\ProgramData\Templates\X'; R = 'DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\Users\x'; R = 'OutsideShellRoots,DeniedTree,OutsideInstallRoot' }
        @{ P = 'C:\Windows\Temp'; R = 'OutsideShellRoots,DeniedTree,OutsideInstallRoot' }
        @{ P = 'D:\Apps\X'; R = 'OutsideShellRoots,OutsideInstallRoot' }
        @{ P = 'C:\PROGRA~2\X'; R = 'NotCanonical' }
        @{ P = 'C:\Program Files (x86).\X'; R = 'NotCanonical' }
        @{ P = 'C:\a\..\b'; R = 'NotCanonical' }
        @{ P = 'C:/x'; R = 'NotCanonical' }
        @{ P = 'C:\x\*'; R = 'NotCanonical' }
        @{ P = 'C:\x:ads'; R = 'NotCanonical' }
        @{ P = 'C:\Program Files\Git\'; R = 'NotCanonical' }
        @{ P = '\\server\share\x'; R = 'NotCanonical' }
        @{ P = '\\?\C:\x'; R = 'NotCanonical' }
        @{ P = 'C:x'; R = 'NotCanonical' }
        @{ P = 'C:\Program Files\Acme\CON'; R = 'NotCanonical' }
        @{ P = 'C:\Program Files\Acme\nul.txt'; R = 'NotCanonical' }
        @{ P = 'C:\Program Files\ Acme'; R = 'NotCanonical' }
        @{ P = 'C:\Program Files\Acme '; R = 'NotCanonical' }
        @{ P = 'C:\Program Files\\Acme'; R = 'NotCanonical' }
        @{ P = "C:\Program Files\Ac`tme"; R = 'NotCanonical' }
        @{ P = "C:\Program Files\Acme$([char]0x202E)"; R = 'NotCanonical' }
        @{ P = 'C:\Program Files\[Acme]'; R = 'NotCanonical' }
        @{ P = $long; R = 'NotCanonical' }
        @{ P = $max; R = '' }
        @{ P = ''; R = 'NotCanonical' }
        @{ P = $null; R = 'NotCanonical' }
    )
    if ($long.Length -eq 241 -and $max.Length -eq 240) { Ok 'precondition: the length rows are 241 and 240 characters' } else { Bad "length rows: $($long.Length) / $($max.Length)" }
    foreach ($row in $rows) {
        $label = if ($null -eq $row.P) { '$null' } elseif ($row.P -eq '') { "''" } elseif ($row.P.Length -gt 70) { $row.P.Substring(0, 40) + "...($($row.P.Length) chars)" } else { $row.P }
        $t = $null
        try { $t = Test-Win32ToolkitCleanupPath -Path $row.P -InstallRoot $git }
        catch { Bad "$label -> threw: $($_.Exception.Message)"; continue }
        $wantValid = $row.R -eq ''
        $wantRoot  = if ($wantValid) { 'C:\Program Files\Git' } else { '' }
        if ((Join-Reason $t.Reasons) -ceq $row.R -and $t.Valid -eq $wantValid -and $t.Root -ceq $wantRoot -and $t.Reasons -is [string[]]) {
            Ok "$label -> [$($row.R)] Valid=$wantValid Root='$wantRoot'"
        }
        else { Bad "$label -> [$(Join-Reason $t.Reasons)] Valid=$($t.Valid) Root='$($t.Root)' (want [$($row.R)])" }
    }

    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files\Git' -InstallRoot @()
    if ((Join-Reason $t.Reasons) -ceq 'NoInstallRoot' -and -not $t.Valid) { Ok "-InstallRoot @() -> [NoInstallRoot]" } else { Bad "-InstallRoot @() -> [$(Join-Reason $t.Reasons)]" }
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files\Git' -InstallRoot $null
    if ((Join-Reason $t.Reasons) -ceq 'NoInstallRoot') { Ok "-InstallRoot `$null -> [NoInstallRoot] (no binding error)" } else { Bad "-InstallRoot `$null -> [$(Join-Reason $t.Reasons)]" }
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files\Git' -InstallRoot $git -CreatedDirectory @()
    if ((Join-Reason $t.Reasons) -ceq 'NotCreatedByInstall') { Ok "-CreatedDirectory @() -> [NotCreatedByInstall]" } else { Bad "-CreatedDirectory @() -> [$(Join-Reason $t.Reasons)]" }
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files\Git\bin' -InstallRoot $git -CreatedDirectory @('c:\program files\git\BIN\')
    if ($t.Valid) { Ok 'the created-check is case-insensitive and ignores a trailing \ on the created folder' } else { Bad "created-check: [$(Join-Reason $t.Reasons)]" }
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files (x86)' -InstallRoot $git -CreatedDirectory @('C:\Program Files\Git')
    if ((Join-Reason $t.Reasons) -ceq 'ShellFolder,OutsideInstallRoot,NotCreatedByInstall') { Ok 'all applicable reasons in order (ShellFolder, OutsideInstallRoot, NotCreatedByInstall)' } else { Bad "order: [$(Join-Reason $t.Reasons)]" }
    if ($t.Explanation -ceq "it is a Windows system folder itself; it is outside the app's own install folder(s): C:\Program Files\Git; the install capture did not create this folder") { Ok 'Explanation joins the texts with "; " and names the roots' } else { Bad "Explanation: $($t.Explanation)" }

    Write-Host '[1b] install roots: trailing \, invalid roots ignored, longest root wins' -ForegroundColor Cyan
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files\Git\usr\bin' -InstallRoot @('C:\Program Files\Git\')
    if ($t.Valid -and $t.Root -ceq 'C:\Program Files\Git') { Ok "a root with a trailing '\' is trimmed: Root = 'C:\Program Files\Git'" } else { Bad "trailing-\ root: [$(Join-Reason $t.Reasons)] Root='$($t.Root)'" }
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files (x86)\X' -InstallRoot @('C:\Program Files (x86)', 'C:\Windows', '', $null)
    if ((Join-Reason $t.Reasons) -ceq 'NoInstallRoot') { Ok 'invalid roots (a shell folder, Windows, blank, $null) are ignored -> [NoInstallRoot]' } else { Bad "invalid roots: [$(Join-Reason $t.Reasons)]" }
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Program Files\Acme\App\bin' -InstallRoot @('C:\Program Files\Acme', 'C:\Program Files\Acme\App')
    if ($t.Valid -and $t.Root -ceq 'C:\Program Files\Acme\App') { Ok 'the longest matching root is reported' } else { Bad "longest root: '$($t.Root)'" }
    $t = Test-Win32ToolkitCleanupPath 'C:\Program Files\GitHub' -InstallRoot $git
    if ((Join-Reason $t.Reasons) -ceq 'OutsideInstallRoot' -and $t.Explanation -match "outside the app's own install folder\(s\): C:\\Program Files\\Git$") { Ok "containment is separator-aware ('Git' does not contain 'GitHub')" } else { Bad "GitHub: [$(Join-Reason $t.Reasons)]" }

    Write-Host '[1c] -AsInstallRoot (rules 1-4 only)' -ForegroundColor Cyan
    foreach ($case in @(
            @{ P = 'C:\Program Files'; R = 'ShellFolder' }
            @{ P = 'C:\Program Files\Git'; R = '' }
            @{ P = 'C:\Users\x'; R = 'OutsideShellRoots,DeniedTree' }
            @{ P = 'C:\ProgramData\Microsoft\Windows'; R = 'DeniedTree' }
            @{ P = 'C:\PROGRA~1\Git'; R = 'NotCanonical' }
        )) {
        $t = Test-Win32ToolkitCleanupPath -Path $case.P -AsInstallRoot
        if ((Join-Reason $t.Reasons) -ceq $case.R -and $t.Valid -eq ($case.R -eq '')) { Ok "-AsInstallRoot $($case.P) -> [$($case.R)]" } else { Bad "-AsInstallRoot $($case.P) -> [$(Join-Reason $t.Reasons)]" }
    }

    Write-Host '[1d] result surface' -ForegroundColor Cyan
    $t = Test-Win32ToolkitCleanupPath -Path 'C:\Users\x' -InstallRoot $git -CreatedDirectory @()
    $names = @($t.PSObject.Properties.Name) -join ','
    if ($names -ceq 'Path,Valid,Reasons,Root,Explanation') { Ok 'result has exactly Path, Valid, Reasons, Root, Explanation' } else { Bad "result properties: $names" }
    $all = @($rows | ForEach-Object { (Test-Win32ToolkitCleanupPath -Path $_.P -InstallRoot $git -CreatedDirectory @()).Explanation })
    if (@([System.Text.Encoding]::UTF8.GetBytes(($all -join ' ')) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'every Explanation is ASCII' } else { Bad 'non-ASCII Explanation text' }
    $cmd = Get-Command Test-Win32ToolkitCleanupPath
    if ($cmd.DefaultParameterSet -eq 'Cleanup' -and @($cmd.ParameterSets.Name | Sort-Object) -join ',' -eq 'Cleanup,Root') { Ok 'parameter sets Cleanup (default) and Root' } else { Bad "sets: $(@($cmd.ParameterSets.Name) -join ',')" }

    # == [2] Git + Edge updater noise ==================================================================
    Write-Host '[2] git-edge-noise.json: one key -> OnlyKey; the Edge updater folders never become cleanup paths' -ForegroundColor Cyan
    $cap = Read-Capture 'git-edge-noise.json'
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap -DisplayName 'Git'
    if ($ir.PrimaryBy -ceq 'OnlyKey' -and (@($ir.PrimaryKeys) -join ',') -ceq 'Git_is1') { Ok 'PrimaryBy OnlyKey, PrimaryKeys = Git_is1' } else { Bad "PrimaryBy '$($ir.PrimaryBy)' keys $(@($ir.PrimaryKeys) -join ',')" }
    if ((@($ir.Roots) -join '|') -ceq 'C:\Program Files\Git') { Ok "Roots = [C:\Program Files\Git] (InstallLocation 'C:\Program Files\Git\' trimmed)" } else { Bad "Roots = $(@($ir.Roots) -join ' | ')" }
    if (@($ir.Rejected).Count -eq 0) { Ok 'nothing rejected (the EdgeUpdate client key is not an Uninstall key)' } else { Bad "Rejected: $(@($ir.Rejected | ForEach-Object { $_.Candidate }) -join ' | ')" }
    if (@($ir.CreatedDirectories).Count -eq 13 -and @($ir.CreatedDirectories) -notcontains 'C:\Program Files\Git\mingw64') { Ok '13 created folders; the Type Unknown entry is ignored' } else { Bad "CreatedDirectories ($(@($ir.CreatedDirectories).Count)): $(@($ir.CreatedDirectories) -join ' | ')" }
    $derived = Get-DerivedCleanup $ir
    if (($derived -join '|') -ceq 'C:\Program Files\Git') { Ok 'derived CleanupPaths = [C:\Program Files\Git] (top-most only)' } else { Bad "derived: $($derived -join ' | ')" }
    $edge = @($ir.CreatedDirectories | Where-Object { $_ -like '*\Microsoft\Edge*' })
    $edgeValid = @($edge | Where-Object { (Test-Win32ToolkitCleanupPath -Path $_ -InstallRoot $ir.Roots -CreatedDirectory $ir.CreatedDirectories).Valid })
    if ($edge.Count -eq 6 -and $edgeValid.Count -eq 0) { Ok 'every one of the 6 Edge / EdgeCore / EdgeUpdate / EdgeWebView folders is rejected' } else { Bad "Edge folders: $($edge.Count), valid: $($edgeValid -join ' | ')" }
    if ($ir.Roots -is [string[]] -and $ir.CreatedDirectories -is [string[]] -and $ir.PrimaryKeys -is [string[]]) { Ok 'Roots, CreatedDirectories and PrimaryKeys are [string[]]' } else { Bad 'result types' }
    $names = @($ir.PSObject.Properties.Name) -join ','
    if ($names -ceq 'Roots,Rejected,CreatedDirectories,PrimaryKeys,PrimaryBy') { Ok 'result has exactly Roots, Rejected, CreatedDirectories, PrimaryKeys, PrimaryBy' } else { Bad "result properties: $names" }

    # == [3] Firefox + co-installed Maintenance Service ================================================
    Write-Host '[3] firefox-coinstalled.json: the primary key only; the co-installed service folder is left alone' -ForegroundColor Cyan
    $cap = Read-Capture 'firefox-coinstalled.json'
    foreach ($manifestCase in @(
            @{ Label = 'ProductCode: Mozilla Firefox'; Text = "PackageIdentifier: Mozilla.Firefox`r`nInstallers:`r`n- Architecture: x64`r`n  InstallerType: nullsoft`r`n  ProductCode: Mozilla Firefox`r`n" }
            @{ Label = "ProductCode: 'Mozilla Firefox' (quoted)"; Text = "PackageIdentifier: Mozilla.Firefox`nInstallers:`n- Architecture: x64`n  ProductCode: 'Mozilla Firefox'`n" }
        )) {
        $proj = Build-TempProject -Name ('ff' + [guid]::NewGuid().ToString('N').Substring(0, 4)) -Manifest $manifestCase.Text
        $ir = Get-Win32ToolkitInstallRoot -Capture $cap -ProjectPath $proj -DisplayName ''
        $coInstalled = @($ir.Rejected | Where-Object { $_.Candidate -ceq 'MozillaMaintenanceService' -and $_.Origin -ceq 'CoInstalled' })
        if ($ir.PrimaryBy -ceq 'ProductCode' -and (@($ir.PrimaryKeys) -join ',') -ceq 'Mozilla Firefox') { Ok "$($manifestCase.Label) -> PrimaryBy ProductCode, key 'Mozilla Firefox'" } else { Bad "$($manifestCase.Label) -> PrimaryBy '$($ir.PrimaryBy)' keys $(@($ir.PrimaryKeys) -join ',')" }
        if ((@($ir.Roots) -join '|') -ceq 'C:\Program Files\Mozilla Firefox' -and $coInstalled.Count -eq 1) { Ok 'Roots = [C:\Program Files\Mozilla Firefox]; MozillaMaintenanceService rejected as CoInstalled' } else { Bad "Roots $(@($ir.Roots) -join ' | '); rejected $(@($ir.Rejected | ForEach-Object { "$($_.Candidate) ($($_.Origin))" }) -join ' | ')" }
        $derived = Get-DerivedCleanup $ir
        if (($derived -join '|') -ceq 'C:\Program Files\Mozilla Firefox') { Ok 'derived CleanupPaths = [C:\Program Files\Mozilla Firefox]' } else { Bad "derived: $($derived -join ' | ')" }
        if (@($ir.Roots) + $derived -notcontains 'C:\Program Files (x86)') { Ok "'C:\Program Files (x86)' is never a root or a cleanup path" } else { Bad "'C:\Program Files (x86)' leaked" }
    }

    $ir = Get-Win32ToolkitInstallRoot -Capture $cap -DisplayName 'Mozilla Firefox'
    if ($ir.PrimaryBy -ceq 'DisplayName' -and (@($ir.Roots) -join '|') -ceq 'C:\Program Files\Mozilla Firefox' -and @($ir.Rejected | Where-Object { $_.Origin -ceq 'CoInstalled' }).Count -eq 1) {
        Ok "no manifest, -DisplayName 'Mozilla Firefox' -> PrimaryBy DisplayName, the same root, the service CoInstalled"
    } else { Bad "DisplayName rule: '$($ir.PrimaryBy)' roots $(@($ir.Roots) -join ' | ')" }
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap -DisplayName '   '
    $unidentified = @($ir.Rejected | Where-Object { $_.Origin -ceq 'Unidentified' })
    if ($ir.PrimaryBy -ceq '' -and @($ir.Roots).Count -eq 0 -and $unidentified.Count -eq 2 -and @(Get-DerivedCleanup $ir).Count -eq 0) { Ok 'no manifest, blank -DisplayName -> no root, both keys Unidentified, CleanupPaths = []' }
    else { Bad "no primary: '$($ir.PrimaryBy)' roots $(@($ir.Roots) -join ' | ') unidentified $($unidentified.Count)" }
    $proj = Build-TempProject -Name 'ffOther' -Manifest "Installers:`n- ProductCode: '{11111111-2222-3333-4444-555555555555}'`n"
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap -ProjectPath $proj -DisplayName 'Mozilla Firefox'
    if ($ir.PrimaryBy -ceq 'DisplayName') { Ok 'a manifest ProductCode that matches no key falls through to the DisplayName rule' } else { Bad "fall-through: '$($ir.PrimaryBy)'" }

    # == [4] vendor parent =============================================================================
    Write-Host '[4] vendor-parent.json: an ancestor above the uninstaller and the icon is never a root' -ForegroundColor Cyan
    $cap = Read-Capture 'vendor-parent.json'
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap
    $anc = @($ir.Rejected | Where-Object { $_.Origin -ceq 'UninstallerIcon' -and (Join-Reason $_.Reasons) -ceq 'AncestorAboveBoth' })
    if ($ir.PrimaryBy -ceq 'OnlyKey' -and @($ir.Roots).Count -eq 0 -and $anc.Count -eq 1 -and @(Get-DerivedCleanup $ir).Count -eq 0) { Ok 'split layout (Acme\Uninstall + Acme\App) -> no root, Rejected UninstallerIcon AncestorAboveBoth, CleanupPaths = []' }
    else { Bad "vendor parent: roots $(@($ir.Roots) -join ' | '); rejected $(@($ir.Rejected | ForEach-Object { "$($_.Candidate) ($($_.Origin): $(Join-Reason $_.Reasons))" }) -join ' | ')" }

    $cap.NewRegistryKeys[0].Values.UninstallString = '"C:\Program Files\Acme\App\uninst\u.exe" /S'
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap
    if ((@($ir.Roots) -join '|') -ceq 'C:\Program Files\Acme\App' -and @($ir.Rejected).Count -eq 0) { Ok 'uninstaller below the icon folder -> root = the icon folder C:\Program Files\Acme\App' } else { Bad "nested: roots $(@($ir.Roots) -join ' | ')" }
    if ((Get-DerivedCleanup $ir) -join '|' -ceq 'C:\Program Files\Acme\App') { Ok 'derived CleanupPaths = [C:\Program Files\Acme\App] (the vendor folder Acme stays)' } else { Bad "nested derived: $((Get-DerivedCleanup $ir) -join ' | ')" }
    $cap.NewRegistryKeys[0].Values.UninstallString = 'C:\Program Files\Acme\App\uninst\u.exe /S'
    $cap.NewRegistryKeys[0].Values.DisplayIcon = '"C:\Program Files\Acme\App\app.exe",0'
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap
    if ((@($ir.Roots) -join '|') -ceq 'C:\Program Files\Acme\App') { Ok 'unquoted uninstaller + quoted icon with an index -> the same root' } else { Bad "unquoted: roots $(@($ir.Roots) -join ' | ')" }
    $cap.NewRegistryKeys[0].Values.DisplayIcon = $null
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap
    if ((@($ir.Roots) -join '|') -ceq 'C:\Program Files\Acme\App\uninst') { Ok 'only the uninstaller -> its folder' } else { Bad "uninstaller only: roots $(@($ir.Roots) -join ' | ')" }
    $cap.NewRegistryKeys[0].Values.UninstallString = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap
    if (@($ir.Roots).Count -eq 0 -and @($ir.Rejected).Count -eq 0) { Ok 'MsiExec /X and no icon -> no candidate at all' } else { Bad "msiexec: roots $(@($ir.Roots) -join ' | ')" }
    $cap.NewRegistryKeys[0].Values.UninstallString = '"C:\Program Files\Microsoft\Acme\unins000.exe"'
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap
    $denied = @($ir.Rejected | Where-Object { $_.Origin -ceq 'UninstallerIcon' -and (Join-Reason $_.Reasons) -ceq 'DeniedTree' })
    if (@($ir.Roots).Count -eq 0 -and $denied.Count -eq 1) { Ok 'a candidate that fails -AsInstallRoot is Rejected with its reasons (DeniedTree)' } else { Bad "denied candidate: roots $(@($ir.Roots) -join ' | ')" }

    # == [5] DefaultInstallLocation + HKCU ===============================================================
    Write-Host '[5] default-install-location.json: manifest DefaultInstallLocation, only when created; HKCU never a root' -ForegroundColor Cyan
    $cap = Read-Capture 'default-install-location.json'
    $dilManifest = "PackageIdentifier: Acme.Tool`nInstallers:`n- Architecture: x64`n  InstallationMetadata:`n    DefaultInstallLocation: '%ProgramFiles%\Acme'`n"
    $proj = Build-TempProject -Name 'dil' -Manifest $dilManifest
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap -ProjectPath $proj
    if ((@($ir.Roots) -join '|') -ceq 'C:\Program Files\Acme' -and $ir.PrimaryBy -ceq 'OnlyKey') { Ok "'%ProgramFiles%\Acme' + created C:\Program Files\Acme -> root (the HKLM MSI key is the only key; it has no folder)" } else { Bad "DIL: roots $(@($ir.Roots) -join ' | ') by '$($ir.PrimaryBy)'" }
    if ((Get-DerivedCleanup $ir) -join '|' -ceq 'C:\Program Files\Acme') { Ok 'derived CleanupPaths = [C:\Program Files\Acme]' } else { Bad "DIL derived: $((Get-DerivedCleanup $ir) -join ' | ')" }
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap
    if (@($ir.Roots).Count -eq 0) { Ok 'without the manifest -> no root (the HKCU key InstallLocation is never used)' } else { Bad "HKCU: roots $(@($ir.Roots) -join ' | ')" }
    $capNoDir = Read-Capture 'default-install-location.json'
    $capNoDir.NewFiles = @($capNoDir.NewFiles | Where-Object { $_.Path -ne 'C:\Program Files\Acme' })
    $ir = Get-Win32ToolkitInstallRoot -Capture $capNoDir -ProjectPath $proj
    if (@($ir.Roots).Count -eq 0) { Ok 'the same manifest without the created folder -> not a root (manifest data is not authoritative)' } else { Bad "DIL not created: roots $(@($ir.Roots) -join ' | ')" }
    foreach ($tok in @(
            @{ V = '"%ProgramW6432%\Acme\"'; Want = 'C:\Program Files\Acme' }
            @{ V = '%LOCALAPPDATA%\Acme'; Want = '' }
            @{ V = '%ProgramFilesX%\Acme'; Want = '' }
            @{ V = 'C:\Program Files\Acme'; Want = '' }
            @{ V = '%ProgramFiles%'; Want = '' }
        )) {
        $p2 = Build-TempProject -Name ('tok' + [guid]::NewGuid().ToString('N').Substring(0, 4)) -Manifest "Installers:`n- InstallationMetadata:`n    DefaultInstallLocation: $($tok.V)`n"
        $capTok = Read-Capture 'default-install-location.json'
        $capTok.NewFiles += [pscustomobject]@{ Path = 'C:\Program Files'; Type = 'Directory' }
        $ir = Get-Win32ToolkitInstallRoot -Capture $capTok -ProjectPath $p2
        if ((@($ir.Roots) -join '|') -ceq $tok.Want) { Ok "DefaultInstallLocation $($tok.V) -> [$($tok.Want)]" } else { Bad "DefaultInstallLocation $($tok.V) -> [$(@($ir.Roots) -join ' | ')]" }
    }
    $ir = Get-Win32ToolkitInstallRoot -Capture $cap -ProjectPath (Join-Path $root 'does-not-exist')
    if (@($ir.Roots).Count -eq 0 -and $ir.PrimaryBy -ceq 'OnlyKey') { Ok 'a project without Files\ -> no manifest, no error' } else { Bad 'missing Files\ folder' }

    # == [6] malformed captures ========================================================================
    Write-Host '[6] malformed captures -> empty result, never a throw' -ForegroundColor Cyan
    $hkcuOnly = [pscustomobject]@{
        NewFiles        = @([pscustomobject]@{ Path = 'C:\Program Files\Acme'; Type = 'Directory' })
        NewRegistryKeys = @([pscustomobject]@{ Path = 'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Acme'; Values = [pscustomobject]@{ DisplayName = 'Acme'; InstallLocation = 'C:\Program Files\Acme' } })
    }
    $hklmSub = [pscustomobject]@{
        NewRegistryKeys = @([pscustomobject]@{ Path = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Acme\Sub'; Values = [pscustomobject]@{ InstallLocation = 'C:\Program Files\Acme' } })
    }
    $hashCapture = @{
        NewFiles        = @(@{ Path = 'C:\Program Files\Acme\'; Type = 'Directory' })
        NewRegistryKeys = @(@{ Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Acme'; Values = @{ InstallLocation = '"C:\Program Files (x86)\Acme"' } })
    }
    $cases = @(
        @{ Label = 'HKCU uninstall key only'; Capture = $hkcuOnly; Roots = ''; Created = 1 }
        @{ Label = 'a sub-key below an Uninstall key'; Capture = $hklmSub; Roots = ''; Created = 0 }
        @{ Label = 'no NewRegistryKeys, NewFiles a string'; Capture = [pscustomobject]@{ NewFiles = 'C:\Program Files\Acme' }; Roots = ''; Created = 0 }
        @{ Label = 'NewRegistryKeys a string, NewFiles numbers'; Capture = [pscustomobject]@{ NewRegistryKeys = 'oops'; NewFiles = @(1, 2, $null) }; Roots = ''; Created = 0 }
        @{ Label = 'a key whose Values is a string'; Capture = [pscustomobject]@{ NewRegistryKeys = @([pscustomobject]@{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\X'; Values = 'v' }) }; Roots = ''; Created = 0 }
        @{ Label = '$null capture'; Capture = $null; Roots = ''; Created = 0 }
        @{ Label = 'a string capture'; Capture = 'not a capture'; Roots = ''; Created = 0 }
        @{ Label = 'an empty object'; Capture = [pscustomobject]@{}; Roots = ''; Created = 0 }
        @{ Label = 'hashtables (HKLM short form, WOW6432Node, quoted InstallLocation)'; Capture = $hashCapture; Roots = 'C:\Program Files (x86)\Acme'; Created = 1 }
    )
    foreach ($case in $cases) {
        $ir = $null
        try { $ir = Get-Win32ToolkitInstallRoot -Capture $case.Capture }
        catch { Bad "$($case.Label) -> threw: $($_.Exception.Message)"; continue }
        if ((@($ir.Roots) -join '|') -ceq $case.Roots -and @($ir.CreatedDirectories).Count -eq $case.Created -and $ir.Roots -is [string[]]) { Ok "$($case.Label) -> roots [$($case.Roots)], $($case.Created) created folder(s), no throw" }
        else { Bad "$($case.Label) -> roots [$(@($ir.Roots) -join ' | ')], created $(@($ir.CreatedDirectories).Count)" }
    }

    # == [7] Update-PSADTUninstallLogic end to end ======================================================
    Write-Host '[7] Update-PSADTUninstallLogic on the fixtures: InstallRoots + allowlisted CleanupPaths, idempotent' -ForegroundColor Cyan
    $e2e = @(
        @{ Name = 'e2eGit'; Capture = 'git-edge-noise.json'; Manifest = ''; DisplayName = 'Git'; Roots = 'C:\Program Files\Git'; Cleanup = 'C:\Program Files\Git'; Uninstallers = 1 }
        @{ Name = 'e2eFirefox'; Capture = 'firefox-coinstalled.json'; Manifest = "Installers:`n- ProductCode: Mozilla Firefox`n"; DisplayName = ''; Roots = 'C:\Program Files\Mozilla Firefox'; Cleanup = 'C:\Program Files\Mozilla Firefox'; Uninstallers = 2 }
        @{ Name = 'e2eFirefoxByName'; Capture = 'firefox-coinstalled.json'; Manifest = ''; DisplayName = 'Mozilla Firefox'; Roots = 'C:\Program Files\Mozilla Firefox'; Cleanup = 'C:\Program Files\Mozilla Firefox'; Uninstallers = 2 }
        @{ Name = 'e2eVendor'; Capture = 'vendor-parent.json'; Manifest = ''; DisplayName = ''; Roots = ''; Cleanup = ''; Uninstallers = 1 }
        @{ Name = 'e2eDil'; Capture = 'default-install-location.json'; Manifest = $dilManifest; DisplayName = ''; Roots = 'C:\Program Files\Acme'; Cleanup = 'C:\Program Files\Acme'; Uninstallers = 1 }
    )
    foreach ($case in $e2e) {
        $proj = Build-TempProject -Name $case.Name -Capture $case.Capture -Manifest $case.Manifest -DisplayName $case.DisplayName -AppName 'App'
        $json = Join-Path $proj 'Documentation\InstallationChanges_20260101_120000.json'
        $verbose = @()
        $okRun = Update-PSADTUninstallLogic -ProjectPath $proj -JsonFilePath $json -Verbose 4>&1 6>$null 3>$null | ForEach-Object {
            if ($_ -is [System.Management.Automation.VerboseRecord]) { $verbose += $_.Message } else { $_ }
        }
        $cfgFile = Join-Path $proj 'SupportFiles\AppConfig.json'
        $first = [System.IO.File]::ReadAllText($cfgFile)
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $proj
        $un = $cfg.Uninstall
        $hasRoots = $un.PSObject.Properties.Name -contains 'InstallRoots'
        if ($okRun -eq $true -and $hasRoots -and (@($un.InstallRoots) -join '|') -ceq $case.Roots) { Ok "$($case.Name): Uninstall.InstallRoots = [$($case.Roots)]" } else { Bad "$($case.Name): ok=$okRun InstallRoots=[$(@($un.InstallRoots) -join ' | ')]" }
        if ((@($un.CleanupPaths) -join '|') -ceq $case.Cleanup) { Ok "$($case.Name): Uninstall.CleanupPaths = [$($case.Cleanup)]" } else { Bad "$($case.Name): CleanupPaths = [$(@($un.CleanupPaths) -join ' | ')]" }
        $outside = @(@($un.CleanupPaths) | Where-Object { $p = $_; -not @(@($un.InstallRoots) | Where-Object { ($p + '\').StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count })
        if ($outside.Count -eq 0) { Ok "$($case.Name): every cleanup path is equal to or below an install root" } else { Bad "$($case.Name): outside the roots: $($outside -join ' | ')" }
        if (@($un.Uninstallers).Count -eq $case.Uninstallers -and $cfg.App.Name -ceq 'App') { Ok "$($case.Name): the uninstallers ($($case.Uninstallers)) and the App section are kept" } else { Bad "$($case.Name): uninstallers $(@($un.Uninstallers).Count); App '$($cfg.App.Name)'" }
        if ($first -match '"InstallRoots":\s*\[' -and $first -match '"CleanupPaths":\s*\[') { Ok "$($case.Name): InstallRoots and CleanupPaths are JSON arrays" } else { Bad "$($case.Name): not arrays in the JSON" }
        if (@($verbose | Where-Object { $_ -match '^Cleanup paths: \d+ created folder\(s\)' }).Count -eq 1) { Ok "$($case.Name): one verbose line with the count of folders not kept and the rejected keys" } else { Bad "$($case.Name): verbose: $($verbose -join ' | ')" }
        $null = Update-PSADTUninstallLogic -ProjectPath $proj -JsonFilePath $json 6>$null 3>$null
        if ([System.IO.File]::ReadAllText($cfgFile) -ceq $first) { Ok "$($case.Name): idempotent (the second run writes the same AppConfig.json)" } else { Bad "$($case.Name): the second run changed AppConfig.json" }
    }
    $v = @($verbose) -join ' '
    $proj = Build-TempProject -Name 'e2eFfVerbose' -Capture 'firefox-coinstalled.json' -Manifest "Installers:`n- ProductCode: Mozilla Firefox`n"
    $verbose = @(Update-PSADTUninstallLogic -ProjectPath $proj -JsonFilePath (Join-Path $proj 'Documentation\InstallationChanges_20260101_120000.json') -Verbose 4>&1 6>$null 3>$null |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
    if (@($verbose | Where-Object { $_ -match '2 created folder\(s\)' -and $_ -match 'MozillaMaintenanceService \(CoInstalled\)' }).Count -eq 1) { Ok 'the verbose line names the 2 folders not kept and the co-installed key' } else { Bad "verbose: $($verbose -join ' | ') $v" }

    # == [7b] silent switch by installer technology (test campaign 2026-10-21, S12-F2) ==================
    Write-Host '[7b] an EXE uninstaller with no switch gets its technology''s silent switch (catalog), never captured text' -ForegroundColor Cyan
    function Invoke-Uninstallers([string]$Tech, [hashtable[]]$Keys) {
        $p = Build-TempProject -Name ('sw' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -DisplayName 'Mozilla Firefox'
        if ($Tech) {
            $c = Get-Win32ToolkitAppConfig -ProjectPath $p
            $c | Add-Member -NotePropertyName Source -NotePropertyValue ([pscustomobject]@{ InstallerType = $Tech }) -Force
            $null = Set-Win32ToolkitAppConfig -ProjectPath $p -Config $c
        }
        $j = Join-Path $p 'Documentation\InstallationChanges_20260101_120000.json'
        @{ NewRegistryKeys = @($Keys | ForEach-Object { @{ Path = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($_.Key)"; Values = $_.Values } }); NewFiles = @() } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $j -Encoding UTF8
        $w = $null
        $null = Update-PSADTUninstallLogic -ProjectPath $p -JsonFilePath $j -WarningVariable w -WarningAction SilentlyContinue 6>$null
        $first = [System.IO.File]::ReadAllText((Join-Path $p 'SupportFiles\AppConfig.json'))
        $null = Update-PSADTUninstallLogic -ProjectPath $p -JsonFilePath $j -WarningAction SilentlyContinue 6>$null
        [pscustomobject]@{ Un = @((Get-Win32ToolkitAppConfig -ProjectPath $p).Uninstall.Uninstallers); Warnings = @($w | ForEach-Object { "$_" }); Same = ([System.IO.File]::ReadAllText((Join-Path $p 'SupportFiles\AppConfig.json')) -ceq $first) }
    }
    $ffKeys = @(
        @{ Key = 'Mozilla Firefox'; Values = @{ DisplayName = 'Mozilla Firefox (x64 en-US)'; UninstallString = '"C:\Program Files\Mozilla Firefox\uninstall\helper.exe"' } }
        @{ Key = 'MozillaMaintenanceService'; Values = @{ DisplayName = 'Mozilla Maintenance Service'; UninstallString = '"C:\Program Files (x86)\Mozilla Maintenance Service\uninstall.exe"' } })
    $r = Invoke-Uninstallers 'nullsoft' $ffKeys
    if ($r.Un.Count -eq 2 -and @($r.Un | Where-Object { $_.Args -cne '/S' }).Count -eq 0 -and $r.Warnings.Count -eq 0) { Ok "nullsoft (Firefox): helper.exe and the service uninstaller get '/S'" } else { Bad "nullsoft: $(@($r.Un | ForEach-Object { "$($_.Path) [$($_.Args)]" }) -join ' ; ') warn=$($r.Warnings -join ' | ')" }
    if ($r.Same) { Ok 'idempotent (the second run writes the same AppConfig.json)' } else { Bad 'not idempotent' }
    $r = Invoke-Uninstallers 'inno' @(@{ Key = 'Git_is1'; Values = @{ DisplayName = 'Git'; UninstallString = '"C:\Program Files\Git\unins000.exe"' } })
    if ($r.Un.Count -eq 1 -and $r.Un[0].Args -ceq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART') { Ok 'inno: the Inno Setup silent switches' } else { Bad "inno: [$($r.Un[0].Args)]" }
    $r = Invoke-Uninstallers 'nullsoft' @(@{ Key = 'Acme'; Values = @{ DisplayName = 'Acme'; UninstallString = '"C:\Program Files\Acme\uninstall.exe"'; QuietUninstallString = '"C:\Program Files\Acme\uninstall.exe" /S /quietmode' } })
    if ($r.Un.Count -eq 1 -and $r.Un[0].Args -ceq '/S /quietmode') { Ok 'a QuietUninstallString keeps its own arguments' } else { Bad "quiet: [$($r.Un[0].Args)]" }
    $r = Invoke-Uninstallers 'nullsoft' @(@{ Key = 'Acme2'; Values = @{ DisplayName = 'Acme'; UninstallString = '"C:\Program Files\Acme\uninstall.exe" /S /D=x' } })
    if ($r.Un.Count -eq 1 -and $r.Un[0].Args -ceq '/S /D=x') { Ok 'captured arguments are never replaced' } else { Bad "captured args: [$($r.Un[0].Args)]" }
    foreach ($t in @('', 'burn')) {
        $r = Invoke-Uninstallers $t $ffKeys[0..0]
        if ($r.Un.Count -eq 1 -and $r.Un[0].Args -ceq '' -and @($r.Warnings | Where-Object { $_ -match 'helper\.exe have no silent switch' -and $_ -match 'would show its UI as SYSTEM' }).Count -eq 1) { Ok "technology '$t': Args stay empty, one warning names helper.exe" } else { Bad "tech '$t': [$($r.Un[0].Args)] warn=$($r.Warnings -join ' | ')" }
    }

    # == [8] primary first, AppName, Kind, '/S' (installer-identity PR 2 spec 2.1) =====================
    Write-Host '[8] the app''s own uninstaller first, its own name, Kind from the manifest or the installer file, the /S rule' -ForegroundColor Cyan
    $nsisSig = [byte[]](0xEF, 0xBE, 0xAD, 0xDE) + [System.Text.Encoding]::ASCII.GetBytes('NullsoftInst')
    $innoSig = [System.Text.Encoding]::ASCII.GetBytes('rDlPtS02')
    # A temp project: optional Source.InstallerType (-Tech), optional manual installer Files\x.exe (-Signature
    # 'nsis' | 'inno' | 'none': 'MZ' + zeros, the signature at a valid offset), the capture = a fixture
    # (-Capture) or HKLM Uninstall keys (-Keys @{ Key; Values }). Runs Update-PSADTUninstallLogic twice.
    function Invoke-UninstallCase {
        param([string]$Tech, [hashtable[]]$Keys, [string]$Capture, [string]$Signature, [string]$DisplayName = '')
        $p = Build-TempProject -Name ('u8' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Capture $Capture -DisplayName $DisplayName
        $c = Get-Win32ToolkitAppConfig -ProjectPath $p
        if ($Tech) { $c | Add-Member -NotePropertyName Source -NotePropertyValue ([pscustomobject]@{ InstallerType = $Tech }) -Force }
        if ($Signature) {
            $c | Add-Member -NotePropertyName Installer -NotePropertyValue ([pscustomobject]@{ Type = 'exe'; FileName = 'x.exe'; SilentArgs = '/q' }) -Force
            New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
            $bytes = [byte[]]::new(8192); $bytes[0] = 0x4D; $bytes[1] = 0x5A
            if ($Signature -eq 'nsis') { [Array]::Copy($nsisSig, 0, $bytes, 1028, 16) }
            if ($Signature -eq 'inno') { [Array]::Copy($innoSig, 0, $bytes, 3000, 8) }
            [System.IO.File]::WriteAllBytes((Join-Path $p 'Files\x.exe'), $bytes)
        }
        $null = Set-Win32ToolkitAppConfig -ProjectPath $p -Config $c
        $j = Join-Path $p 'Documentation\InstallationChanges_20260101_120000.json'
        if ($Keys) {
            @{ NewRegistryKeys = @($Keys | ForEach-Object { @{ Path = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($_.Key)"; Values = $_.Values } }); NewFiles = @() } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $j -Encoding UTF8
        }
        $verbose = @(); $info = @(); $w = $null
        $null = Update-PSADTUninstallLogic -ProjectPath $p -JsonFilePath $j -Verbose -WarningVariable w -WarningAction SilentlyContinue 4>&1 6>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.VerboseRecord]) { $verbose += $_.Message }
            elseif ($_ -is [System.Management.Automation.InformationRecord]) { $info += [string]$_.MessageData }
        }
        $file = Join-Path $p 'SupportFiles\AppConfig.json'
        $first = [System.IO.File]::ReadAllText($file)
        $null = Update-PSADTUninstallLogic -ProjectPath $p -JsonFilePath $j -WarningAction SilentlyContinue 6>$null
        $un = (Get-Win32ToolkitAppConfig -ProjectPath $p).Uninstall
        [pscustomobject]@{
            Un       = @($un.Uninstallers)
            AppName  = [string]$un.AppName
            Warnings = @($w | ForEach-Object { "$_" })
            Verbose  = $verbose
            Info     = $info
            Json     = $first
            Same     = ([System.IO.File]::ReadAllText($file) -ceq $first)
        }
    }
    # 'Path [Args] Kind' of every uninstaller, for the failure text.
    function Show-Un($r) { @($r.Un | ForEach-Object { "$($_.Type) $($_.Path) [$($_.Args)] Kind='$($_.Kind)'" }) -join ' ; ' }
    function Get-Mismatch($r) { @($r.Verbose | Where-Object { $_ -match '^Uninstall: the installer technology .* does not match' }) }

    # (a) Firefox + co-installed Maintenance Service, nullsoft from the winget manifest
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Capture 'firefox-coinstalled.json' -DisplayName 'Mozilla Firefox'
    if ($r.Un.Count -eq 2 -and $r.Un[0].Path -ceq 'C:\Program Files\Mozilla Firefox\uninstall\helper.exe' -and $r.Un[0].Kind -ceq 'nullsoft' -and $r.Un[0].Args -ceq '/S') { Ok "(a) Uninstallers[0] = the Firefox helper.exe, Kind 'nullsoft', Args '/S'" } else { Bad "(a) $(Show-Un $r)" }
    if ($r.Un.Count -eq 2 -and $r.Un[1].Path -like '*Mozilla Maintenance Service\uninstall.exe' -and $r.Un[1].Kind -ceq '' -and $r.Un[1].Args -ceq '/S') { Ok "(a) Uninstallers[1] = the co-installed Maintenance Service, Kind '' (its switch from the technology, as before)" } else { Bad "(a) [1]: $(Show-Un $r)" }
    if ($r.AppName -ceq 'Mozilla Firefox (x64 en-US)') { Ok "(a) Uninstall.AppName = the primary entry's DisplayName, not the last key's (I-4)" } else { Bad "(a) AppName '$($r.AppName)'" }
    if (@([regex]::Matches($r.Json, '"Kind":')).Count -eq 2) { Ok '(a) every uninstaller object carries Kind in AppConfig.json' } else { Bad "(a) Kind properties: $(@([regex]::Matches($r.Json, '"Kind":')).Count)" }
    if (@($r.Verbose | Where-Object { $_ -ceq "Uninstall: installer technology 'nullsoft' (winget manifest); primary uninstall key(s): Mozilla Firefox." }).Count -eq 1 -and (Get-Mismatch $r).Count -eq 0) { Ok '(a) one verbose line names the technology, its source and the primary key; no mismatch line' } else { Bad "(a) verbose: $($r.Verbose -join ' | ')" }
    if (@($r.Info | Where-Object { $_ -match 'technology: nullsoft\)$' }).Count -eq 1) { Ok "(a) the host line ends with ', technology: nullsoft'" } else { Bad "(a) host line: $($r.Info -join ' | ')" }
    if ($r.Same -and $r.Warnings.Count -eq 0) { Ok '(a)(g) idempotent (the second run writes the same AppConfig.json), no warning' } else { Bad "(a) same=$($r.Same) warnings=$($r.Warnings -join ' | ')" }

    # (b) a co-installed key captured BEFORE the app's own key (I-3)
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Capture 'coinstalled-first.json' -DisplayName 'Acme Widget'
    if ($r.Un.Count -eq 2 -and $r.Un[0].Path -ceq 'C:\Program Files\Acme Widget\uninstall.exe' -and $r.Un[0].Kind -ceq 'nullsoft' -and $r.Un[0].Args -ceq '/S' -and
        $r.Un[1].Path -ceq 'C:\Program Files (x86)\Acme Updater\uninstall.exe' -and $r.Un[1].Kind -ceq '') { Ok "(b) the app's own uninstaller is written first although its key was captured second (I-3)" } else { Bad "(b) $(Show-Un $r)" }
    if ($r.AppName -ceq 'Acme Widget 2.0' -and $r.Same) { Ok "(b) AppName 'Acme Widget 2.0'; idempotent" } else { Bad "(b) AppName '$($r.AppName)' same=$($r.Same)" }
    $r = Invoke-UninstallCase -Capture 'coinstalled-first.json' -DisplayName 'Acme Widget'
    if ($r.Un.Count -eq 2 -and $r.Un[0].Path -ceq 'C:\Program Files\Acme Widget\uninstall.exe' -and @($r.Un | Where-Object { $_.Kind -cne '' }).Count -eq 0 -and $r.Un[0].Args -ceq '') { Ok "(b) no technology: still primary first, every Kind '', no switch invented" } else { Bad "(b) no tech: $(Show-Un $r)" }

    # (c) manual app: the technology from the installer file's signature (B2 #1)
    $acmeKey = @{ Key = 'AcmeTool'; Values = @{ DisplayName = 'Acme Tool'; UninstallString = '"C:\Program Files\Acme Tool\uninstall.exe"' } }
    $acmeInno = @{ Key = 'AcmeTool_is1'; Values = @{ DisplayName = 'Acme Tool'; UninstallString = '"C:\Program Files\Acme Tool\unins000.exe"' } }
    $r = Invoke-UninstallCase -Signature 'nsis' -Keys $acmeKey
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq 'nullsoft' -and $r.Un[0].Args -ceq '/S' -and $r.Warnings.Count -eq 0) { Ok "(c) no Source, NSIS signature in Files\x.exe -> Kind 'nullsoft', Args '/S', no no-switch warning" } else { Bad "(c) nsis: $(Show-Un $r) warn=$($r.Warnings -join ' | ')" }
    if (@($r.Verbose | Where-Object { $_ -ceq "Uninstall: installer technology 'nullsoft' (installer file signature); primary uninstall key(s): AcmeTool." }).Count -eq 1 -and $r.Same) { Ok '(c) the verbose line says the technology came from the installer file signature; idempotent' } else { Bad "(c) verbose: $($r.Verbose -join ' | ')" }
    $r = Invoke-UninstallCase -Signature 'inno' -Keys $acmeInno
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq 'inno' -and $r.Un[0].Args -ceq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -and $r.Warnings.Count -eq 0) { Ok "(c) Inno Setup signature + an '_is1' key -> Kind 'inno', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'" } else { Bad "(c) inno: $(Show-Un $r) warn=$($r.Warnings -join ' | ')" }
    $r = Invoke-UninstallCase -Signature 'none' -Keys $acmeKey
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $r.Un[0].Args -ceq '' -and @($r.Warnings | Where-Object { $_ -match 'uninstall\.exe have no silent switch' -and $_ -match "\('unknown'\)" }).Count -eq 1) { Ok "(c) no signature -> Args '', Kind '', the existing no-switch warning" } else { Bad "(c) none: $(Show-Un $r) warn=$($r.Warnings -join ' | ')" }
    $r = Invoke-UninstallCase -Tech 'exe' -Signature 'nsis' -Keys $acmeKey
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq 'nullsoft' -and $r.Un[0].Args -ceq '/S') { Ok "(c) a winget 'exe' label + an NSIS signature -> Kind 'nullsoft' (Dv4)" } else { Bad "(c) exe label: $(Show-Un $r)" }
    $r = Invoke-UninstallCase -Tech 'burn' -Signature 'nsis' -Keys $acmeKey
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $r.Un[0].Args -ceq '' -and @($r.Warnings | Where-Object { $_ -match "\('burn'\)" }).Count -eq 1) { Ok "(c) a winget label other than exe ('burn') is never overridden by the file; the warning still names it" } else { Bad "(c) burn: $(Show-Un $r) warn=$($r.Warnings -join ' | ')" }

    # (d) the '/S' rule for nullsoft (L5)
    foreach ($case in @(
            @{ Args = '/allusers'; Want = '/S /allusers' }
            @{ Args = '/allusers /S'; Want = '/allusers /S' }
            @{ Args = '/s'; Want = '/S /s' }
            @{ Args = '/S /D=x'; Want = '/S /D=x' }
        )) {
        $r = Invoke-UninstallCase -Tech 'nullsoft' -Keys @(@{ Key = 'Acme'; Values = @{ DisplayName = 'Acme'; UninstallString = "`"C:\Program Files\Acme\uninstall.exe`" $($case.Args)" } })
        if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq 'nullsoft' -and $r.Un[0].Args -ceq $case.Want) { Ok "(d) nullsoft '$($case.Args)' -> '$($case.Want)'" } else { Bad "(d) '$($case.Args)': $(Show-Un $r)" }
    }
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Keys @(@{ Key = 'Acme'; Values = @{ DisplayName = 'Acme'; UninstallString = '"C:\Program Files\Acme\uninstall.exe"'; QuietUninstallString = '"C:\Program Files\Acme\uninstall.exe" /quiet' } })
    if ($r.Un.Count -eq 1 -and $r.Un[0].Args -ceq '/S /quiet') { Ok "(d) a QuietUninstallString without '/S' gets '/S' prepended too" } else { Bad "(d) quiet: $(Show-Un $r)" }

    # (e) no primary key -> every Kind ''
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Capture 'firefox-coinstalled.json'
    if ($r.Un.Count -eq 2 -and @($r.Un | Where-Object { $_.Kind -cne '' }).Count -eq 0 -and $r.Un[0].Path -like '*Mozilla Firefox\uninstall\helper.exe' -and @($r.Un | Where-Object { $_.Args -cne '/S' }).Count -eq 0) { Ok "(e) PrimaryBy '' -> every Kind '', capture order, the technology switch as before" } else { Bad "(e) $(Show-Un $r)" }
    if ($r.AppName -ceq 'Mozilla Maintenance Service' -and @($r.Verbose | Where-Object { $_ -match "primary uninstall key\(s\): none\.$" }).Count -eq 1) { Ok '(e) no primary key -> AppName keeps the last DisplayName; the verbose line says none' } else { Bad "(e) AppName '$($r.AppName)' verbose=$($r.Verbose -join ' | ')" }

    # (f) msi entries carry Kind ''
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Keys @(@{ Key = 'AcmeMsi'; Values = @{ DisplayName = 'Acme'; UninstallString = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}' } })
    if ($r.Un.Count -eq 1 -and $r.Un[0].Type -ceq 'msi' -and $r.Un[0].PSObject.Properties['Kind'] -and $r.Un[0].Kind -ceq '' -and $r.Same) { Ok "(f) a primary msi uninstaller carries Kind '' (idempotent)" } else { Bad "(f) $(Show-Un $r)" }

    # (h) capture corroboration (spec 2.1 step 3)
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Capture 'git-edge-noise.json' -DisplayName 'Git'
    $mm = @(Get-Mismatch $r)
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $r.Un[0].Args -ceq '/SILENT') { Ok "(h) Git_is1 + a nullsoft label -> Kind '', Args '/SILENT' unchanged (no '/S')" } else { Bad "(h) git+nullsoft: $(Show-Un $r)" }
    if ($mm.Count -eq 1 -and $mm[0] -ceq "Uninstall: the installer technology 'nullsoft' (winget manifest) does not match the app's uninstall entry 'Git_is1' (an Inno Setup entry): its uninstaller gets no technology switch.") { Ok '(h) exactly one verbose line names Git_is1 and "an Inno Setup entry"' } else { Bad "(h) mismatch lines: $($mm -join ' | ')" }
    $r = Invoke-UninstallCase -Tech 'inno' -Capture 'git-edge-noise.json' -DisplayName 'Git'
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq 'inno' -and $r.Un[0].Args -ceq '/SILENT' -and (Get-Mismatch $r).Count -eq 0) { Ok "(h) Git_is1 + inno -> Kind 'inno' (captured '/SILENT' kept)" } else { Bad "(h) git+inno: $(Show-Un $r)" }
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Keys @(@{ Key = 'AcmeInno'; Values = @{ DisplayName = 'Acme'; UninstallString = '"C:\Program Files\Acme\uninstall.exe" /x'; 'Inno Setup: App Path' = 'C:\Program Files\Acme' } })
    $mm = @(Get-Mismatch $r)
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $r.Un[0].Args -ceq '/x' -and $mm.Count -eq 1 -and $mm[0] -match "'AcmeInno' \(an Inno Setup entry\)") { Ok "(h) no '_is1' but an 'Inno Setup: App Path' value + nullsoft -> Kind '', no '/S'" } else { Bad "(h) app path: $(Show-Un $r) $($mm -join ' | ')" }
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Keys @(@{ Key = 'AcmeWi'; Values = @{ DisplayName = 'Acme'; UninstallString = '"C:\Program Files\Acme\uninstall.exe" /x'; WindowsInstaller = 1 } })
    $mm = @(Get-Mismatch $r)
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $r.Un[0].Args -ceq '/x' -and $mm.Count -eq 1 -and $mm[0] -match "'AcmeWi' \(a Windows Installer entry\)") { Ok "(h) WindowsInstaller 1 + nullsoft -> Kind ''" } else { Bad "(h) WindowsInstaller: $(Show-Un $r) $($mm -join ' | ')" }
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Keys @(@{ Key = 'AcmeUnins'; Values = @{ DisplayName = 'Acme'; UninstallString = '"C:\Program Files\Acme\unins000.exe"' } })
    $mm = @(Get-Mismatch $r)
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $r.Un[0].Args -ceq '' -and $mm.Count -eq 1 -and $mm[0] -match "\(an Inno Setup uninstaller name\)" -and
        @($r.Warnings | Where-Object { $_ -match 'unins000\.exe have no silent switch' }).Count -eq 1) { Ok "(h) unins000.exe (no args) + nullsoft -> Kind '', Args '' (default withheld), the no-switch warning" } else { Bad "(h) unins000: $(Show-Un $r) $($mm -join ' | ') warn=$($r.Warnings -join ' | ')" }
    $r = Invoke-UninstallCase -Tech 'inno' -Signature 'nsis' -Keys $acmeKey
    $mm = @(Get-Mismatch $r)
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $r.Un[0].Args -ceq '' -and $mm.Count -eq 1 -and $mm[0] -match "'AcmeTool' \(not an Inno Setup entry\)" -and $r.Warnings.Count -eq 1) { Ok "(h) inno label on a key without '_is1' / 'Inno Setup: App Path' -> Kind '', default withheld, the no-switch warning" } else { Bad "(h) inno relabelled: $(Show-Un $r) $($mm -join ' | ') warn=$($r.Warnings -join ' | ')" }
    $r = Invoke-UninstallCase -Signature 'inno' -Keys $acmeKey
    $mm = @(Get-Mismatch $r)
    if ($r.Un.Count -eq 1 -and $r.Un[0].Kind -ceq '' -and $mm.Count -eq 1 -and $mm[0] -match "'inno' \(installer file signature\)") { Ok '(h) a signature that the entry contradicts names its source (installer file signature)' } else { Bad "(h) signature mismatch: $(Show-Un $r) $($mm -join ' | ')" }
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Keys @(@{ Key = "Ac$([char]7)me_is1"; Values = @{ DisplayName = 'Acme'; UninstallString = '"C:\Program Files\Acme\unins000.exe" /SILENT' } })
    $mm = @(Get-Mismatch $r)
    if ($mm.Count -eq 1 -and $mm[0].Contains("'Ac?me_is1'") -and -not $mm[0].Contains([string][char]7)) { Ok '(h) a control character in the key name prints as ? in the verbose line' } else { Bad "(h) sanitised: $($mm -join ' | ')" }
    $r = Invoke-UninstallCase -Tech 'nullsoft' -Capture 'firefox-coinstalled.json' -DisplayName 'Mozilla Firefox'
    if ($r.Un[0].Kind -ceq 'nullsoft' -and (Get-Mismatch $r).Count -eq 0) { Ok "(h) firefox-coinstalled.json + nullsoft stays Kind 'nullsoft' (= (a))" } else { Bad "(h) firefox: $(Show-Un $r)" }

    # == [9] encoding guard ============================================================================
    Write-Host '[9] every Get-Content in Get-Win32ToolkitInstallRoot.ps1 passes -Encoding' -ForegroundColor Cyan
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($rootPath, [ref]$null, [ref]$null)
    $reads = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-Content', 'gc', 'cat', 'type') }, $true))
    $noEnc = @($reads | Where-Object { -not ($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Encoding' }) })
    if ($reads.Count -ge 1 -and $noEnc.Count -eq 0) { Ok "$($reads.Count) Get-Content call(s), all with -Encoding" } else { Bad "Get-Content without -Encoding: $($noEnc | ForEach-Object { $_.Extent.Text })" }

    # == [10] C-4 / K1 =================================================================================
    Write-Host '[10] the new files: ASCII-only, one function each, every catch starts with the C-2 re-throw' -ForegroundColor Cyan
    foreach ($file in $predicatePath, $rootPath) {
        $leaf = Split-Path $file -Leaf
        if (@([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok "$leaf is ASCII-only" } else { Bad "$leaf has non-ASCII bytes" }
        $errs = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
        $top = @($fileAst.EndBlock.Statements)
        if (-not ($errs -and $errs.Count) -and $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and -not $fileAst.BeginBlock -and -not $fileAst.ProcessBlock) { Ok "$leaf parses and defines only its function (no top-level code)" } else { Bad "$leaf top-level statements: $($top.Count)" }
        $catches = @($fileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $bad = @($catches | Where-Object { -not $_.Body.Statements.Count -or $_.Body.Statements[0].Extent.Text -cne "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }" })
        if ($catches.Count -ge 1 -and $bad.Count -eq 0) { Ok "$leaf - $($catches.Count) catch(es), each starts with the C-2 line" } else { Bad "$leaf catches without the C-2 line: $($bad.Count) of $($catches.Count)" }
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All CleanupPath tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail CleanupPath test(s) FAILED." -ForegroundColor Red; exit 1 }
