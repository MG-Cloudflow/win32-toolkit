<#
    Integration test for the data-driven install/uninstall generation (Phase 1-2), on a REAL PSADT scaffold.

    Imports the module and runs inside its scope (spec C-5). Every project is scaffolded the way the toolkit
    does it - Create-PSADTProject -Force with the selected PSAppDeployToolkit (PSADT 4.2 therefore gets
    New-ADTTemplate -ZeroConfig) - and the data-driven generators run against a HOSTILE winget manifest and
    sandbox capture. The key security property: untrusted payloads land only in SupportFiles\AppConfig.json
    (data), never in the generated Invoke-AppDeployToolkit.ps1 (code).

      [1]-[6]  configure + data writers, patched structure, payloads only in data, detection rule
      [7]      org template: apostrophes round-trip; author and status message are DATA in AppConfig.json
      [8]-[10] update requirement rule (both registry views), MSI requirement, MSI tattoo detection
      [11]     the documentation wait takes exactly the expected capture
      [12]     drift (per detected shape): date-only miss -> $false; removed phase / marker / session anchor
               -> W32T.UnsupportedTemplateShape with the stable C-1 prefix and the file byte-identical;
               org re-apply byte-identical; Apply-OrgTemplate on an unpatched scaffold refused
      [13]     MSIX end to end
      [14]     MSI on a real scaffold: PSADT's Zero-Config block + the toolkit blocks; 'msp' iff 4.2
      [15]     Configure-PSADTForInstaller on an Unknown-shape script -> W32T.UnsupportedTemplateShape propagates

    Guards: before the "absent" checks of [3], [4] and [13] the suite asserts that the deploy script differs
    from the pristine scaffold and carries the Session:loader sentinel (an unpatched script would pass them).

    Needs a supported PSAppDeployToolkit (Select-Win32ToolkitPsadtModule; $env:W32T_PSADT_VERSION pins it).
    None selected -> SKIP (exit 3), or FAIL (exit 1) when $env:W32T_REQUIRE_PSADT is set.
    Never installs anything: Find-Module / Install-Module / Update-Module are shadowed to throw.
    Never runs a generated deploy script or an installer.

    Run:  pwsh -File Tests\DataDriven.integration.ps1
    See knowledge-base/designs/data-driven-generation.md and psadt-4.2-implementation-spec.md (3.6 task 2).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'safety shadows: nothing may be installed or prompted')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$mod = Import-Module (Join-Path $repo 'win32-toolkit.psd1') -Force -PassThru

# ---- C-5 self-skip: the selector decides (env pin > registry pin > newest in range) ----------------
$sel = & $mod { Select-Win32ToolkitPsadtModule }
if ($sel.Status -ne 'Selected') {
    if ($env:W32T_REQUIRE_PSADT) {
        Write-Host "FAIL: no supported PSAppDeployToolkit selected and W32T_REQUIRE_PSADT is set: $($sel.Reason)" -ForegroundColor Red
        exit 1
    }
    Write-Host "SKIP: no supported PSAppDeployToolkit selected: $($sel.Reason)" -ForegroundColor DarkYellow
    exit 3
}
Write-Host "PSAppDeployToolkit $($sel.VersionText) ($($sel.Module.Path))" -ForegroundColor DarkGray

$fail = & $mod {
    param($sel)
    $ErrorActionPreference = 'Stop'
    $script:W32TTestFail = 0
    function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
    function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:W32TTestFail++ }

    # ---- safety shadows (module scope, this process only) ----------------------------------------
    function script:Find-Module { throw 'TEST-BLOCKED: Find-Module (the suite never queries the gallery)' }
    function script:Install-Module { throw 'TEST-BLOCKED: Install-Module' }
    function script:Update-Module { throw 'TEST-BLOCKED: Update-Module' }
    function script:Get-Win32ToolkitBasePath { throw 'TEST-BLOCKED: real BasePath resolution' }
    function script:Read-Host { throw 'TEST-BLOCKED: Read-Host (the suite is non-interactive)' }
    $script:OrgTemplate = $null

    $is42 = $sel.Version -ge [version]'4.2.0'
    $expectShape = if ($is42) { 'Psadt42ZeroConfig' } else { 'Psadt41' }
    $prefix = 'Unsupported PSADT template shape: '
    $loaderSentinel = '## win32-toolkit:Session:loader (begin)'

    $INSTALL_PAYLOAD = "/S'; `$global:PWNED_INSTALL = `$true; #"
    $UNINST_PAYLOAD  = "/S'; `$global:PWNED_UNINST = `$true; #"
    $DISPLAYNAME     = "Evil'App `$(calc)"

    # Short scratch root (MAX_PATH, V57).
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-dd-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
    New-Item -ItemType Directory -Path $base -Force | Out-Null

    function New-Scaffold([string]$Name) {
        $ok = Create-PSADTProject -ProjectName $Name -ProjectPath $base -Force 6>$null 3>$null
        if ($ok -ne $true) { throw "Create-PSADTProject failed for '$Name'" }
        Join-Path $base $Name
    }
    function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
    function Write-Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true))) }
    function Test-SameContent([string]$Path, [byte[]]$Bytes) {
        $now = [System.IO.File]::ReadAllBytes($Path)
        ($now.Length -eq $Bytes.Length) -and (-not (Compare-Object $now $Bytes -SyncWindow 0))
    }
    # The text of one PSADT phase (4.2: the phase scriptblock; 4.1: the region inside *-ADTDeployment).
    function Get-PhaseText([string]$Content, [string]$Phase) {
        $s = Get-Win32ToolkitDeployScriptShape -Content $Content -IncludeLayout
        if (-not $s.Layout -or -not $s.Layout.Phases.ContainsKey($Phase)) { return '' }
        $pl = $s.Layout.Phases[$Phase]
        if ($pl.ContainsKey('Open')) { return $Content.Substring($pl.Open, $pl.Close - $pl.Open + 1) }
        return $Content.Substring($pl.RegionStart, $pl.RegionEnd - $pl.RegionStart)
    }
    # Runs a script block that must throw a W32T error; returns the ErrorRecord (or $null).
    function Get-W32TError([scriptblock]$Action) {
        try { & $Action; return $null } catch { return $_ }
    }

    try {
        Write-Host "[0] Scaffold with Create-PSADTProject -Force (expected shape $expectShape)" -ForegroundColor Cyan
        $proj = New-Scaffold 'App'
        $scriptPath = Join-Path $proj 'Invoke-AppDeployToolkit.ps1'
        $pristine = Read-Text $scriptPath
        $s0 = Get-Win32ToolkitDeployScriptShape -Path $scriptPath
        if ($s0.Shape -eq $expectShape -and $null -eq $s0.GeneratorVersion) { Ok "pristine scaffold is $($s0.Shape), unpatched" } else { Bad "pristine shape $($s0.Shape) / generator $($s0.GeneratorVersion)" }
        $bundled = Import-PowerShellDataFile -LiteralPath (Join-Path $proj 'PSAppDeployToolkit\PSAppDeployToolkit.psd1')
        if ([version]$bundled.ModuleVersion -eq $sel.Version) { Ok "bundled PSAppDeployToolkit $($bundled.ModuleVersion) = the selected module" } else { Bad "bundled $($bundled.ModuleVersion) vs selected $($sel.VersionText)" }

        $files = Join-Path $proj 'Files'
        New-Item -ItemType Directory -Path $files -Force | Out-Null
        Set-Content -Path (Join-Path $files 'EvilApp_x64_1.2.3.exe') -Value 'stub' -Encoding ASCII
        Set-Content -Path (Join-Path $files 'EvilApp.installer.yaml') -Encoding UTF8 -Value @"
PackageName: Evil'App
Publisher: O'Reilly
PackageVersion: 1.2.3
Architecture: x64
InstallerSwitches:
  Silent: $INSTALL_PAYLOAD
"@

        Write-Host "`n[1] Configure (install + patch)" -ForegroundColor Cyan
        $ok = Configure-PSADTForInstaller -ProjectPath $proj -AppInfo ([pscustomobject]@{ Name = 'EvilApp'; Version = '1.2.3'; Id = 'Evil.App' }) -Architecture 'x64' 6>$null
        if ($ok) { Ok 'Configure returned true' } else { Bad 'Configure failed' }
        $ps1 = Read-Text $scriptPath
        # GUARD for [3]/[4]: an unpatched script would pass every "absent" check below.
        if ($ps1 -cne $pristine -and $ps1.Contains($loaderSentinel)) { Ok 'GUARD: script differs from the pristine scaffold and carries the Session:loader sentinel' }
        else { Bad 'GUARD: deploy script was NOT patched (identical to the scaffold or no loader sentinel)' }

        $capture = @{
            NewRegistryKeys = @(
                @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\EvilApp'; KeyName = 'EvilApp'
                   Values = @{ DisplayName = $DISPLAYNAME
                               UninstallString = "`"C:\Program Files\EvilApp\unins000.exe`" $UNINST_PAYLOAD"
                               InstallLocation = 'C:\Program Files\EvilApp'
                               DisplayIcon = 'C:\Program Files\EvilApp\evil.exe,0' } },
                @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\evil.exe'; KeyName = 'evil.exe'; Values = @{} },
                @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\bad.exe'; KeyName = "bad'; calc.exe"; Values = @{} }
            )
            NewFiles = @( @{ Type = 'File'; Path = 'C:\Program Files\EvilApp\evil.exe' } )
            # Shape produced by the registry-diff NewPrograms derivation (replaces Win32_Product) -
            # present in the fixture to prove all writers tolerate the field end-to-end.
            NewPrograms = @( @{ Name = $DISPLAYNAME; DisplayName = $DISPLAYNAME; DisplayVersion = '1.2.3'; Publisher = "O'Reilly"
                                UninstallString = "`"C:\Program Files\EvilApp\unins000.exe`" $UNINST_PAYLOAD"
                                Path = 'C:\Program Files\EvilApp'; Source = 'UninstallRegistry' } )
        }
        $capPath = Join-Path $proj 'InstallationChanges_test.json'
        ($capture | ConvertTo-Json -Depth 8) | Set-Content -Path $capPath -Encoding UTF8

        Write-Host "`n[2] Data writers" -ForegroundColor Cyan
        $okU = Update-PSADTUninstallLogic -ProjectPath $proj -JsonFilePath $capPath 6>$null
        if ($okU) { Ok 'uninstall writer' } else { Bad 'uninstall writer' }
        $okP = Update-PSADTProcessesToClose -ProjectPath $proj -JsonFilePath $capPath 6>$null
        if ($okP) { Ok 'processes writer' } else { Bad 'processes writer' }

        Write-Host "`n[3] Patched script structure" -ForegroundColor Cyan
        $errs = $null; [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs) | Out-Null
        if (-not ($errs -and $errs.Count)) { Ok 'patched script parses (host)' } else { Bad "parse: $($errs[0].Message)" }
        $e51 = @(Test-Win32ToolkitPS51Syntax -Path $scriptPath)
        if ($e51.Count -eq 0) { Ok 'patched script parses under Windows PowerShell 5.1' } else { Bad "5.1 parse: $($e51 -join ' | ')" }
        $bytes = [System.IO.File]::ReadAllBytes($scriptPath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Ok 'deploy script written UTF-8 with BOM' } else { Bad 'deploy script has no UTF-8 BOM' }
        $ps1 = Read-Text $scriptPath
        $s1 = Get-Win32ToolkitDeployScriptShape -Content $ps1
        if ($s1.Shape -eq $expectShape -and $s1.GeneratorVersion -eq 2 -and $s1.Support -eq 'Supported') { Ok "shape kept ($($s1.Shape)), GeneratorVersion 2, Supported" } else { Bad "shape after patch: $($s1.Shape) / $($s1.GeneratorVersion) / $($s1.Support)" }
        if ($ps1.Contains('$appConfig =') -and $ps1.Contains('$w32tInstallDone = $false')) { Ok 'loader present (AppConfig + tattoo gate initialised)' } else { Bad 'no loader' }
        if ($ps1.Contains('## Data-driven install') -and $ps1.Contains('## Data-driven uninstall')) { Ok 'routines present' } else { Bad 'routines' }
        if (([regex]::Matches($ps1, '(?m)^\s*ExitWithMsiCodes = \$true\s*$')).Count -eq 1) { Ok 'ExitWithMsiCodes = $true added once (D13)' } else { Bad 'ExitWithMsiCodes line missing or duplicated' }
        foreach ($k in 'AppVendor = $appConfig.App.Vendor', 'AppName = $appConfig.App.Name', 'AppVersion = $appConfig.App.Version',
            'AppArch = $appConfig.App.Arch', 'AppScriptAuthor = $appConfig.App.ScriptAuthor', 'AppScriptDate = $appConfig.App.ScriptDate') {
            if ($ps1.Contains($k)) { Ok "session edit: $k" } else { Bad "session edit missing: $k" }
        }
        # Tattoo (spec 5.4 / 5.5): install writes it only after install-done; uninstall removes both views.
        $postInstall = Get-PhaseText $ps1 'Post-Install'
        $postUninstall = Get-PhaseText $ps1 'Post-Uninstall'
        $installText = Get-PhaseText $ps1 'Install'
        if ($postInstall.Contains('## win32-toolkit:Post-Install:tattoo (begin)') -and $postInstall.Contains('win32-toolkit install tattoo - records') -and
            $postInstall.Contains('if (-not $w32tInstallDone) {') -and
            $postInstall.Contains('Set-ADTRegistryKey -Key "HKLM:\SOFTWARE\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName" -Name ''Version'' -Value "$($appConfig.App.Version)" -Type ''String''') -and
            $postInstall.Contains('$w32tName = if ($appConfig.App.DisplayName) { $appConfig.App.DisplayName } else { $appConfig.App.Name }')) {
            Ok 'Post-Install tattoo block: DisplayName-driven, value-free, gated on $w32tInstallDone (5.4)'
        } else { Bad 'Post-Install tattoo block missing or changed' }
        if ($installText.Contains('## win32-toolkit:Install:install-done (begin)') -and $installText.Contains('$w32tInstallDone = $true')) { Ok 'Install phase ends with the install-done block' } else { Bad 'install-done block missing from the Install phase' }
        if ($postUninstall.Contains('## win32-toolkit:Post-Uninstall:tattoo (begin)') -and
            $postUninstall.Contains('Remove-ADTRegistryKey -Key $w32tTattooKey -Recurse') -and
            $postUninstall.Contains('Remove-ADTRegistryKey -Key $w32tTattooKey -Wow6432Node -Recurse') -and
            $postUninstall.Contains('[System.Environment]::Is64BitProcess')) {
            Ok 'Post-Uninstall tattoo block removes the key in both registry views (5.5, D5 legacy cleanup)'
        } else { Bad 'Post-Uninstall tattoo block missing or changed' }
        $msp = $installText.Contains('## win32-toolkit:Install:msp (begin)')
        if ($msp -eq $is42) { Ok "msp block present iff PSADT 4.2 (present: $msp)" } else { Bad "msp block present=$msp on $($sel.VersionText)" }

        Write-Host "`n[4] KEY PROOF: payloads only in data, never in code" -ForegroundColor Cyan
        if (-not $ps1.Contains($INSTALL_PAYLOAD)) { Ok 'install payload absent from .ps1' } else { Bad 'install payload LEAKED' }
        if (-not $ps1.Contains($UNINST_PAYLOAD)) { Ok 'uninstall payload absent from .ps1' } else { Bad 'uninstall payload LEAKED' }
        if (-not $ps1.Contains($DISPLAYNAME)) { Ok 'display name absent from .ps1' } else { Bad 'display name LEAKED' }
        if (-not $ps1.Contains("O'Reilly") -and -not $ps1.Contains("O''Reilly")) { Ok 'publisher absent from .ps1' } else { Bad 'publisher LEAKED' }

        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $proj
        if ($cfg.Installer.SilentArgs -eq $INSTALL_PAYLOAD) { Ok 'install payload stored as data' } else { Bad "install data [$($cfg.Installer.SilentArgs)]" }
        $exeU = @($cfg.Uninstall.Uninstallers) | Where-Object { $_.Type -eq 'exe' } | Select-Object -First 1
        if ($exeU.Args -eq $UNINST_PAYLOAD) { Ok 'uninstall payload stored as data' } else { Bad "uninstall data [$($exeU.Args)]" }
        if ($cfg.App.Vendor -eq "O'Reilly" -and $cfg.App.Name -eq "Evil'App") { Ok 'apostrophe metadata stored as data' } else { Bad 'metadata' }
        # Installer identity (PR 1, spec 2.6 / 3.4): Configure records AppConfig.Source as DATA (no pin -> winget-default).
        $src = $cfg.Source
        if ($src -and $src.SchemaVersion -eq '1.0' -and $src.PinnedBy -eq 'winget-default' -and $src.RequestedInstallerType -eq '' -and
            $src.InstallerType -eq 'exe' -and $src.Family -eq 'exe' -and $src.Architecture -eq 'x64') { Ok 'AppConfig.Source present: PinnedBy winget-default, exe (exe family), x64' }
        else { Bad "AppConfig.Source = $($src | ConvertTo-Json -Compress)" }
        if ($ps1 -notmatch '(?i)appConfig\.Source\b' -and -not $ps1.Contains('winget-default')) { Ok 'the deploy script never reads AppConfig.Source (data only)' } else { Bad 'AppConfig.Source referenced by the deploy script' }

        Write-Host "`n[5] Process-name validation" -ForegroundColor Cyan
        $procs = @($cfg.ProcessesToClose)
        if ($procs -contains 'evil') { Ok 'valid process kept' } else { Bad "procs=[$($procs -join ',')]" }
        if (-not ($procs | Where-Object { $_ -like '*calc*' -or $_ -like "*'*" })) { Ok 'malicious process rejected' } else { Bad 'bad proc leaked' }

        Write-Host "`n[6] Detection rule keys off the tattoo (installed + correct version)" -ForegroundColor Cyan
        # The org template normally supplies AppScriptAuthor; inject it here to exercise the rule.
        $cfg6 = Get-Win32ToolkitAppConfig -ProjectPath $proj
        $cfg6.App.ScriptAuthor = 'Contoso IT'
        Set-Win32ToolkitAppConfig -ProjectPath $proj -Config $cfg6 | Out-Null
        $rules = @(Get-Win32DetectionRules -ProjectPath $proj 6>$null)
        if ($rules.Count -eq 1 -and
            $rules[0]['detectionType'] -eq 'version' -and
            $rules[0]['operator'] -eq 'equal' -and
            $rules[0]['valueName'] -eq 'Version' -and
            $rules[0]['keyPath'] -eq "HKEY_LOCAL_MACHINE\SOFTWARE\Contoso IT\O'Reilly\Evil'App" -and
            $rules[0]['detectionValue'] -eq '1.2.3') {
            Ok 'registry version detection built from tattoo'
        } else { Bad "detection rule: $($rules[0] | ConvertTo-Json -Compress)" }

        Write-Host "`n[7] Apostrophes in org-template fields never break the generated files; author/status are DATA" -ForegroundColor Cyan
        $escTmpl = [pscustomobject]@{
            CompanyName            = "O'Reilly Media"
            DialogStyle            = 'Fluent'
            FluentAccentColor      = ''
            LogPath                = "C:\Logs\O'Brien"
            AppScriptAuthor        = "O'Brien IT"
            TemplateName           = 'EscTest'
            BalloonComplete        = [pscustomobject]@{ Install = "Installed O'Reilly"; Repair = "Repair's done"; Uninstall = "Removed O'Brien" }
            ProgressMessage        = [pscustomobject]@{ Install = "Installing O'Brien's app"; Repair = "Repairin'"; Uninstall = "Uninstallin'" }
            ProgressMessageDetail  = [pscustomobject]@{ Install = "It's working"; Repair = "almost'"; Uninstall = "bye'" }
            WelcomeDialog          = [pscustomobject]@{ Enabled = $false }
            ProgressDialog         = [pscustomobject]@{ Enabled = $true; StatusMessage = "It's installing"; StatusMessageDetail = "Please wait, it's almost done" }
            CompletionPrompt       = [pscustomobject]@{ Enabled = $false }
            UninstallWelcomeDialog = [pscustomobject]@{ Enabled = $false }
        }
        $okApply = Apply-OrgTemplate -ProjectPath $proj -Template $escTmpl 6>$null
        if ($okApply -eq $true) { Ok 'Apply-OrgTemplate returned true' } else { Bad 'Apply-OrgTemplate failed' }

        # config.psd1 + strings.psd1 must parse AND round-trip their apostrophe values
        try {
            $cfgData = Import-PowerShellDataFile -Path (Join-Path $proj 'Config\config.psd1')
            if ($cfgData.Toolkit.CompanyName -eq "O'Reilly Media" -and $cfgData.Toolkit.LogPath -eq "C:\Logs\O'Brien") { Ok 'config.psd1 parses + CompanyName/LogPath round-trip' } else { Bad "config values: [$($cfgData.Toolkit.CompanyName)] [$($cfgData.Toolkit.LogPath)]" }
        } catch { Bad "config.psd1 parse: $($_.Exception.Message)" }
        try {
            $strData = Import-PowerShellDataFile -Path (Join-Path $proj 'Strings\strings.psd1')
            if ($strData.BalloonTip.Complete.Install -eq "Installed O'Reilly" -and $strData.ProgressPrompt.Message.Install -eq "Installing O'Brien's app") { Ok 'strings.psd1 parses + balloon/progress round-trip' } else { Bad 'strings values did not round-trip' }
        } catch { Bad "strings.psd1 parse: $($_.Exception.Message)" }

        $errsB = $null; [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errsB) | Out-Null
        if (-not ($errsB -and $errsB.Count)) { Ok 'deploy script parses after branding' } else { Bad "parse: $($errsB[0].Message)" }
        $ps1b = Read-Text $scriptPath
        $cfg7 = Get-Win32ToolkitAppConfig -ProjectPath $proj
        if ($cfg7.App.ScriptAuthor -eq "O'Brien IT") { Ok 'author is DATA: AppConfig.App.ScriptAuthor round-trips' } else { Bad "App.ScriptAuthor = [$($cfg7.App.ScriptAuthor)]" }
        if ($cfg7.OrgUi.Progress.StatusMessage -eq "It's installing" -and $cfg7.OrgUi.Progress.Enabled -eq $true) { Ok 'status message is DATA: AppConfig.OrgUi.Progress.StatusMessage round-trips' } else { Bad "OrgUi.Progress = $($cfg7.OrgUi.Progress | ConvertTo-Json -Compress)" }
        if (-not $ps1b.Contains("O'Brien IT") -and -not $ps1b.Contains("O''Brien IT")) { Ok 'author literal absent from the deploy script' } else { Bad 'author literal spliced into the deploy script' }
        if (-not $ps1b.Contains("It's installing") -and -not $ps1b.Contains("It''s installing")) { Ok 'status message absent from the deploy script' } else { Bad 'status message spliced into the deploy script' }
        if ($ps1b.Contains('AppScriptAuthor = $appConfig.App.ScriptAuthor')) { Ok 'AppScriptAuthor still reads AppConfig after branding' } else { Bad 'AppScriptAuthor no longer data-driven' }
        $orgUiMissing = @('Pre-Install', 'Pre-Uninstall', 'Pre-Repair', 'Post-Install', 'Post-Repair' | Where-Object { -not $ps1b.Contains("## win32-toolkit:${_}:org-ui (begin)") })
        if ($orgUiMissing.Count -eq 0) { Ok 'org-ui blocks in the five dialog phases' } else { Bad "org-ui block missing in: $($orgUiMissing -join ', ')" }
        if (([regex]::Matches($ps1b, 'Set-ADTRegistryKey')).Count -eq 1 -and ([regex]::Matches($ps1b, [regex]::Escape('win32-toolkit install tattoo - records'))).Count -eq 1) { Ok 'tattoo survived org-template branding' } else { Bad 'tattoo clobbered by branding' }

        Write-Host "`n[8] Update requirement rule (presence check; hostile values escaped; both registry views)" -ForegroundColor Cyan
        $rr = Get-Win32ToolkitRequirementRule -ProjectPath $proj
        if ($rr -and $rr['@odata.type'] -eq '#microsoft.graph.win32LobAppPowerShellScriptRequirement' -and
            $rr['detectionType'] -eq 'integer' -and $rr['operator'] -eq 'equal' -and $rr['detectionValue'] -eq '1' -and
            $rr['runAsAccount'] -eq 'system') {
            Ok 'requirement rule shape (script requirement, integer/equal/1, system)'
        } else { Bad "requirement rule: $($rr | ConvertTo-Json -Compress)" }
        $rrScript = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rr['scriptContent']))
        $rrErrs = $null; [System.Management.Automation.Language.Parser]::ParseInput($rrScript, [ref]$null, [ref]$rrErrs) | Out-Null
        if (-not ($rrErrs -and $rrErrs.Count)) { Ok 'requirement script parses' } else { Bad "req parse: $($rrErrs[0].Message)" }
        if ($rrScript -notmatch [regex]::Escape($UNINST_PAYLOAD) -and $rrScript -notmatch 'PWNED' -and $rrScript -notmatch 'calc\.exe') {
            Ok 'no injection payload in requirement script (values escaped as data)'
        } else { Bad 'payload leaked into requirement script' }
        if ($rrScript -match 'Write-Output 1; exit 0' -and $rrScript -match 'ErrorActionPreference') { Ok 'presence logic + STDERR suppression present' } else { Bad 'presence/stderr logic missing' }
        if ($rrScript -notmatch '-like' -and $rrScript -match [regex]::Escape('$targets -contains $_.DisplayName') -and $rrScript -match 'Test-Path -LiteralPath') {
            Ok 'exact/literal presence only (no substring -like; -LiteralPath tattoo/product-code)'
        } else { Bad 'presence match not exact/literal' }
        # [7] wrote App.ScriptAuthor = "O'Brien IT" (the org template's author is DATA now).
        $cfg8 = Get-Win32ToolkitAppConfig -ProjectPath $proj
        $tail8 = "$($cfg8.App.ScriptAuthor)\$($cfg8.App.Vendor)\$($cfg8.App.DisplayName)" -replace "'", "''"
        if ($tail8 -eq "O''Brien IT\O''Reilly\Evil''App" -and
            $rrScript.Contains("Test-Path -LiteralPath 'HKLM:\SOFTWARE\$tail8'") -and $rrScript.Contains("Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\$tail8'")) {
            Ok 'tattoo checked in the 64-bit AND the WOW6432Node view (D5 transition), quotes escaped'
        } else { Bad 'requirement script does not check both tattoo views' }

        Write-Host "`n[9] MSI update requirement uses the UpgradeCode (stubbed MSI read)" -ForegroundColor Cyan
        $mproj = Join-Path $base 'MsiReq'
        New-Item -ItemType Directory -Path (Join-Path $mproj 'Files') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $mproj 'SupportFiles') -Force | Out-Null
        Set-Content -Path (Join-Path $mproj 'Files\stub.msi') -Value 'x'   # presence only; the read is stubbed
        $mcfg = [pscustomobject]@{ App = [pscustomobject]@{ Name = ''; Version = '1.0'; Vendor = '' }; Installer = [pscustomobject]@{ Type = 'msi'; FileName = 'stub.msi' } }
        [System.IO.File]::WriteAllText((Join-Path $mproj 'SupportFiles\AppConfig.json'), ($mcfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        $mrule = & {
            # Override the COM MSI reader for this block only, so no real .msi is needed.
            function Get-Win32ToolkitMsiProperty {
                param([string]$Path, [string]$Property)
                if ($Property -eq 'UpgradeCode') { return '{CDB13460-04DF-4708-A7FD-4CB4A0684605}' }
                if ($Property -eq 'ProductName') { return 'Stub MSI App' }
                return ''
            }
            Get-Win32ToolkitRequirementRule -ProjectPath $mproj
        }
        if ($mrule) { Ok 'MSI Zero-Config builds a rule (no abort)' } else { Bad 'MSI aborted despite UpgradeCode' }
        if ($mrule) {
            $ms = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mrule['scriptContent']))
            if ($ms -match 'RelatedProducts' -and $ms -match [regex]::Escape('{CDB13460-04DF-4708-A7FD-4CB4A0684605}')) { Ok 'RelatedProducts + real UpgradeCode embedded' } else { Bad 'UpgradeCode presence check missing' }
            if ($mrule['displayName'] -eq 'Stub MSI App is installed') { Ok 'displayName from MSI ProductName' } else { Bad "displayName: $($mrule['displayName'])" }
        }

        Write-Host "`n[10] MSI Zero-Config gets the tattoo + version detection via DisplayName" -ForegroundColor Cyan
        $msiP = Join-Path $base 'MsiTattoo'
        New-Item -ItemType Directory -Path (Join-Path $msiP 'SupportFiles') -Force | Out-Null
        $mtCfg = [pscustomobject]@{ App = [pscustomobject]@{ Vendor = 'Notepad++ Team'; Name = ''; DisplayName = 'Notepad++'; Version = '8.9.6.4'; ScriptAuthor = 'Contoso IT' } }
        [System.IO.File]::WriteAllText((Join-Path $msiP 'SupportFiles\AppConfig.json'), ($mtCfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $msiP 'Invoke-AppDeployToolkit.ps1') -Force   # deploy script carries the tattoo
        $mdet = @(Get-Win32DetectionRules -ProjectPath $msiP 6>$null)
        if ($mdet.Count -eq 1 -and $mdet[0]['detectionType'] -eq 'version' -and
            $mdet[0]['keyPath'] -eq 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso IT\Notepad++ Team\Notepad++' -and
            $mdet[0]['detectionValue'] -eq '8.9.6.4') {
            Ok 'MSI (empty Name) -> version tattoo rule via DisplayName'
        } else { Bad "MSI detection: $($mdet[0] | ConvertTo-Json -Compress)" }

        Write-Host "`n[11] Exact-path wait ignores decoy/stale captures" -ForegroundColor Cyan
        # A decoy capture that any glob would satisfy the wait with; the expected file describes FreshApp.
        $docDir = Join-Path $proj 'Documentation'
        New-Item -ItemType Directory -Path $docDir -Force | Out-Null
        $decoyCap = Join-Path $docDir 'InstallationChanges_00000000_000000.json'
        ([pscustomobject]@{ NewRegistryKeys = @([pscustomobject]@{
                        Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DecoyApp'; KeyName = 'DecoyApp'
                        Values = @{ DisplayName = 'DecoyApp'; UninstallString = '"C:\Program Files\Decoy\unins000.exe" /S' } }) } |
            ConvertTo-Json -Depth 8) | Set-Content $decoyCap -Encoding UTF8
        $freshCap2 = Join-Path $docDir 'InstallationChanges_99999999_999999.json'
        ([pscustomobject]@{ NewRegistryKeys = @([pscustomobject]@{
                        Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\FreshApp'; KeyName = 'FreshApp'
                        Values = @{ DisplayName = 'FreshApp'; UninstallString = '"C:\Program Files\Fresh\unins000.exe" /S' } }) } |
            ConvertTo-Json -Depth 8) | Set-Content $freshCap2 -Encoding UTF8
        (Get-Item $decoyCap).LastWriteTime = (Get-Date)   # decoy is even NEWER by time - exact path must still win
        $waitOk = Wait-ForDocumentationAndProcess -ProjectPath $proj -InstallerType exe -ExpectedJsonPath $freshCap2 6>$null
        if ($waitOk) { Ok 'wait satisfied by the exact expected file' } else { Bad 'exact-path wait failed' }
        $cfgW = Get-Win32ToolkitAppConfig -ProjectPath $proj
        if ($cfgW.Uninstall.AppName -eq 'FreshApp') { Ok 'AppConfig.Uninstall driven by the EXPECTED capture, not the decoy' } else { Bad "Uninstall.AppName = $($cfgW.Uninstall.AppName)" }

        Write-Host "`n[12] Template drift protection on the $expectShape layout (fail closed, C-1 wording)" -ForegroundColor Cyan
        $drift = New-Scaffold 'Drift'
        $driftPristine = Read-Text (Join-Path $drift 'Invoke-AppDeployToolkit.ps1')
        $script:W32TDriftN = 0
        function New-DriftCopy([string]$Text) {
            $script:W32TDriftN++
            $p = Join-Path $base ('D' + $script:W32TDriftN)
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            $f = Join-Path $p 'Invoke-AppDeployToolkit.ps1'
            Write-Text $f $Text
            $f
        }

        # (1) any scaffold date is handled (item-5 regression) + clean run has zero warnings + idempotent
        $dep1 = New-DriftCopy ([regex]::Replace($driftPristine, "AppScriptDate = '\d{4}-\d{2}-\d{2}'", "AppScriptDate = '2031-01-15'"))
        $r1 = Set-PSADTDataDrivenScript -ScriptPath $dep1 -WarningVariable wv1 -WarningAction SilentlyContinue
        $c1 = Read-Text $dep1
        if ($r1 -eq $true -and $c1.Contains('AppScriptDate = $appConfig.App.ScriptDate') -and -not $c1.Contains('2031-01-15')) { Ok 'any scaffold date -> data-driven (item-5 regression)' } else { Bad "date test: r=$r1" }
        if (-not $wv1) { Ok 'clean scaffold patches with zero warnings' } else { Bad "unexpected warnings: $($wv1 -join '; ')" }
        $b1 = [System.IO.File]::ReadAllBytes($dep1)
        $r1b = Set-PSADTDataDrivenScript -ScriptPath $dep1 -WarningVariable wv1b -WarningAction SilentlyContinue
        if ($r1b -eq $true -and -not $wv1b -and (Test-SameContent $dep1 $b1)) { Ok 'idempotent re-run: $true, no warnings, byte-identical' } else { Bad 're-run regressed' }

        # (2) date-only miss (the only NON-critical anchor) -> $false + named warning, file still written and valid
        $dep2 = New-DriftCopy ([regex]::Replace($driftPristine, "AppScriptDate = '\d{4}-\d{2}-\d{2}'", "AppScriptDate = 'today'"))
        $r2 = Set-PSADTDataDrivenScript -ScriptPath $dep2 -WarningVariable wv2 -WarningAction SilentlyContinue
        $c2 = Read-Text $dep2
        if ($r2 -eq $false -and (@($wv2) -match 'AppScriptDate')) { Ok 'date-only miss -> $false + warning naming AppScriptDate' } else { Bad "r2=$r2 wv=[$($wv2 -join ';')]" }
        $s2 = Get-Win32ToolkitDeployScriptShape -Content $c2
        if ($c2.Contains($loaderSentinel) -and $s2.Shape -eq $expectShape -and $s2.GeneratorVersion -eq 2 -and $s2.ParseErrors -eq 0) { Ok 'date-only miss still writes a valid, fully patched script' } else { Bad 'file not patched on a date-only miss' }

        # (3) critical drift -> W32T.UnsupportedTemplateShape, message starts with the C-1 prefix, file byte-identical
        $criticalCases = [ordered]@{
            'session anchor ($adtSession = @{) renamed' = { param($t) $t.Replace('$adtSession = @{', '$adtSessionDrifted = @{') }
            'DeployAppScriptVersion outside the range'  = { param($t) [regex]::Replace($t, "DeployAppScriptVersion = '[^']+'", "DeployAppScriptVersion = '4.3.0'") }
        }
        if ($is42) {
            $criticalCases['phase removed (New-Variable -Name Post-Repair renamed)'] = { param($t) $t.Replace('New-Variable -Name Post-Repair ', 'New-Variable -Name PostRepairGone ') }
            $criticalCases['Zero-Config block removed from Uninstall (Psadt42Default/Unknown)'] = {
                param($t)
                $sh = Get-Win32ToolkitDeployScriptShape -Content $t -IncludeLayout
                $pl = $sh.Layout.Phases['Uninstall']
                $body = $t.Substring($pl.Open, $pl.Close - $pl.Open + 1)
                $t.Substring(0, $pl.Open) + $body.Replace('if ($adtSession.UseDefaultMsi)', 'if ($false)') + $t.Substring($pl.Close + 1)
            }
        }
        else {
            $criticalCases['phase removed (Repair-ADTDeployment renamed)'] = { param($t) $t.Replace('function Repair-ADTDeployment', 'function Repair-ADTDeploymentGone') }
            $criticalCases['marker removed (## <Perform Post-Installation tasks here>)'] = { param($t) $t.Replace('## <Perform Post-Installation tasks here>', '## drifted away') }
            $criticalCases['marker duplicated (## <Perform Installation tasks here>)'] = { param($t) $t.Replace('## <Perform Installation tasks here>', "## <Perform Installation tasks here>`r`n    ## <Perform Installation tasks here>") }
        }
        foreach ($label in $criticalCases.Keys) {
            $mutated = & $criticalCases[$label] $driftPristine
            if ($mutated -ceq $driftPristine) { Bad "$label - the mutation did not apply (template changed?)"; continue }
            $dep3 = New-DriftCopy $mutated
            $before3 = [System.IO.File]::ReadAllBytes($dep3)
            $err3 = Get-W32TError { Set-PSADTDataDrivenScript -ScriptPath $dep3 -WarningAction SilentlyContinue }
            $msg3 = if ($err3) { $err3.Exception.Message } else { '' }
            if ($err3 -and $err3.FullyQualifiedErrorId -like 'W32T.UnsupportedTemplateShape*' -and $msg3.StartsWith($prefix) -and $msg3.TrimEnd().EndsWith('Nothing was changed.')) {
                Ok "$label -> W32T.UnsupportedTemplateShape ('$prefix...Nothing was changed.')"
            } else { Bad "$label -> $(if ($err3) { "$($err3.FullyQualifiedErrorId): $msg3" } else { 'no error' })" }
            if (Test-SameContent $dep3 $before3) { Ok "$label -> file byte-identical" } else { Bad "$label -> file was modified" }
        }

        # (4) org template: re-applying is byte-identical (deploy script, config.psd1, strings.psd1, AppConfig.json)
        $reFiles = @($scriptPath, (Join-Path $proj 'Config\config.psd1'), (Join-Path $proj 'Strings\strings.psd1'), (Join-Path $proj 'SupportFiles\AppConfig.json'))
        $reBefore = @{}; foreach ($f in $reFiles) { $reBefore[$f] = [System.IO.File]::ReadAllBytes($f) }
        $r4 = Apply-OrgTemplate -ProjectPath $proj -Template $escTmpl -WarningVariable wv4 -WarningAction SilentlyContinue 6>$null
        $changed = @($reFiles | Where-Object { -not (Test-SameContent $_ $reBefore[$_]) })
        if ($r4 -eq $true -and -not $wv4 -and $changed.Count -eq 0) { Ok 're-applying the org template: $true, no warnings, every file byte-identical' }
        else { Bad "re-apply: r=$r4 warnings=[$($wv4 -join ';')] changed=[$(@($changed | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')]" }

        # (5) org template on a deploy script this version did not generate -> refused before any write
        $p5 = Join-Path $base 'Unpatched'
        Copy-Item -LiteralPath $drift -Destination $p5 -Recurse
        $p5Files = @((Join-Path $p5 'Invoke-AppDeployToolkit.ps1'), (Join-Path $p5 'Config\config.psd1'), (Join-Path $p5 'Strings\strings.psd1'))
        $p5Before = @{}; foreach ($f in $p5Files) { $p5Before[$f] = [System.IO.File]::ReadAllBytes($f) }
        $err5 = Get-W32TError { Apply-OrgTemplate -ProjectPath $p5 -Template $escTmpl 6>$null }
        if ($err5 -and $err5.FullyQualifiedErrorId -like 'W32T.UnsupportedTemplateShape*' -and $err5.Exception.Message.StartsWith($prefix)) { Ok 'unpatched scaffold -> Apply-OrgTemplate refuses (W32T.UnsupportedTemplateShape, C-1 prefix)' }
        else { Bad "unpatched apply: $(if ($err5) { $err5.FullyQualifiedErrorId } else { 'no error' })" }
        if (@($p5Files | Where-Object { -not (Test-SameContent $_ $p5Before[$_]) }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $p5 'SupportFiles\AppConfig.json'))) {
            Ok 'refused apply wrote nothing (deploy script, config.psd1, strings.psd1 unchanged; no AppConfig.json)'
        } else { Bad 'refused apply changed files' }

        Write-Host "`n[13] MSIX end-to-end: configure -> identity uninstall -> patched blocks -> tattoo detection" -ForegroundColor Cyan
        $mxProj = New-Scaffold 'MsixApp'
        New-Item -ItemType Directory -Path (Join-Path $mxProj 'Files') -Force | Out-Null
        $mxPristine = Read-Text (Join-Path $mxProj 'Invoke-AppDeployToolkit.ps1')
        # Synthetic .msix (zip with a root AppxManifest.xml; hostile publisher)
        $mxMf = Join-Path $base 'mxmf'; New-Item -ItemType Directory -Path $mxMf -Force | Out-Null
        @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="Evil.Msix" Publisher="CN=O'Evil, O=&quot;Q&quot;" Version="2.0.0.0" />
</Package>
'@ | Set-Content -Path (Join-Path $mxMf 'AppxManifest.xml') -Encoding UTF8
        Compress-Archive -Path (Join-Path $mxMf 'AppxManifest.xml') -DestinationPath (Join-Path $base 'mx.zip') -Force
        Move-Item (Join-Path $base 'mx.zip') (Join-Path $mxProj 'Files\EvilMsix.msix') -Force

        $okMx = Configure-PSADTForInstaller -ProjectPath $mxProj -AppInfo ([pscustomobject]@{ Name = 'Evil Msix'; Version = '2.0.0'; Id = 'Evil.Msix' }) -Architecture 'x64' 6>$null
        if ($okMx) { Ok 'Configure succeeded for msix' } else { Bad 'Configure failed' }
        $mxCfg = Get-Win32ToolkitAppConfig -ProjectPath $mxProj
        if ($mxCfg.Installer.Type -eq 'msix' -and $mxCfg.Installer.SilentArgs -eq '') { Ok 'Installer.Type=msix, SilentArgs empty' } else { Bad "installer: $($mxCfg.Installer | ConvertTo-Json -Compress)" }
        $mxU = @($mxCfg.Uninstall.Uninstallers)[0]
        if ($mxU.Type -eq 'msix' -and $mxU.PackageName -eq 'Evil.Msix') { Ok 'identity uninstall written at CONFIGURE time (capture-independent)' } else { Bad "uninstall: $($mxU | ConvertTo-Json -Compress)" }

        $mxScript = Join-Path $mxProj 'Invoke-AppDeployToolkit.ps1'
        $mxPs1 = Read-Text $mxScript
        # GUARD for the "absent" checks below.
        if ($mxPs1 -cne $mxPristine -and $mxPs1.Contains($loaderSentinel)) { Ok 'GUARD: msix deploy script patched (differs from the scaffold, loader sentinel)' } else { Bad 'GUARD: msix deploy script NOT patched' }
        $errsMx = $null; [System.Management.Automation.Language.Parser]::ParseFile($mxScript, [ref]$null, [ref]$errsMx) | Out-Null
        if (-not ($errsMx -and $errsMx.Count)) { Ok 'patched msix deploy script parses' } else { Bad "parse: $($errsMx[0].Message)" }
        if ($mxPs1 -match 'Add-AppxProvisionedPackage' -and $mxPs1 -match 'IsSystem') { Ok 'install block: SYSTEM provisioning + interactive Add-AppxPackage branch' } else { Bad 'msix install branch missing' }
        if ($mxPs1 -match 'Remove-AppxPackage' -and $mxPs1 -match [regex]::Escape('Where-Object { $_.Name -eq $u.PackageName }')) { Ok 'uninstall block: exact-Name Remove-AppxPackage' } else { Bad 'msix uninstall branch missing' }
        if ($mxPs1 -notmatch [regex]::Escape('O''Evil') -and $mxPs1 -notmatch 'Evil\.Msix') { Ok 'identity values only in AppConfig.json, never in the .ps1 (data-vs-code)' } else { Bad 'identity leaked into code' }

        # G1: provisioning without -Regions silently no-ops (DISM: "provisioned only if it is pinned to
        # start layout") -> Intune reports Installed and no user ever gets the app.
        if ($mxPs1 -match [regex]::Escape("-Regions 'all'")) { Ok "G1: Add-AppxProvisionedPackage passes -Regions 'all' (else provisioning silently no-ops)" }
        else { Bad "G1: -Regions 'all' missing from the provisioning call" }
        # G3: no Add-AppxPackage fallback under SYSTEM - it would register the app into SYSTEM's own
        # profile, throw nothing, and let the tattoo report a successful install of an app nobody has.
        if ($mxPs1 -match [regex]::Escape('Add-AppxProvisionedPackage -Online -PackagePath $installerPath -SkipLicense -Regions ''all'' -ErrorAction Stop')) {
            Ok 'G3: provisioning uses -ErrorAction Stop (Appx cmdlets error non-terminating by default)'
        } else { Bad 'G3: provisioning call is not -ErrorAction Stop' }
        $sysBranch = [regex]::Match($mxPs1, '(?s)IsSystem\)\s*\{(.*?)\}\s*else\s*\{')
        # Strip comment lines first - the block's own comment explains why the fallback was removed and
        # names the cmdlet, which would otherwise match here. 'Add-AppxProvisionedPackage' does not
        # contain 'Add-AppxPackage' as a substring, so the provisioning call cannot false-positive.
        $sysCode = if ($sysBranch.Success) { (($sysBranch.Groups[1].Value -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n" } else { '' }
        if ($sysBranch.Success -and $sysCode -notmatch 'Add-AppxPackage') {
            Ok 'G3: the SYSTEM branch has NO Add-AppxPackage fallback (would register into the SYSTEM profile)'
        } else { Bad 'G3: SYSTEM branch still falls back to Add-AppxPackage' }
        if ($sysCode -match 'throw') { Ok 'G3: a provisioning failure rethrows (fails the deployment loudly)' } else { Bad 'G3: provisioning failure does not rethrow' }
        # G5: $uninstallSuccess was computed and never read - every uninstaller could fail and the
        # script still returned 0, so Intune recorded a successful uninstall of an app still installed.
        if ($mxPs1 -match [regex]::Escape('if (-not $uninstallSuccess -and')) { Ok 'G5: uninstall throws when no uninstaller reported success' }
        else { Bad 'G5: failed uninstall still returns success' }
        # G5 must not throw on codes that MEAN success: 1605 = product not installed (already gone - the
        # goal state holds), 1641/3010 = removed + reboot initiated/required. Both loops share one set.
        if ($mxPs1 -match [regex]::Escape('$w32tUninstallOk = @(0, 1605, 1641, 3010)')) { Ok 'G5: success codes include 1605/1641/3010 (no false uninstall failure)' }
        else { Bad 'G5: success-code set missing or wrong' }
        if (([regex]::Matches($mxPs1, [regex]::Escape('-in $w32tUninstallOk'))).Count -eq 2) { Ok 'G5: both uninstall loops share the same success set (cannot drift)' }
        else { Bad 'G5: the two loops do not share the success set' }
        if ($mxPs1 -notmatch [regex]::Escape('-in @(0, 3010)')) { Ok 'G5: no stale narrow success check remains' } else { Bad 'G5: a stale @(0,3010) check survives' }

        # Tattoo detection: inject ScriptAuthor+Vendor (no org template in this harness)
        $mxCfg2 = Get-Win32ToolkitAppConfig -ProjectPath $mxProj
        $mxCfg2.App.ScriptAuthor = 'Contoso IT'; $mxCfg2.App.Vendor = 'Evil Vendor'
        Set-Win32ToolkitAppConfig -ProjectPath $mxProj -Config $mxCfg2 | Out-Null
        $mxDet = @(Get-Win32DetectionRules -ProjectPath $mxProj 6>$null)
        if ($mxDet.Count -eq 1 -and $mxDet[0]['detectionType'] -eq 'version') { Ok 'msix project gets the tattoo version detection rule' } else { Bad "detection: $($mxDet[0] | ConvertTo-Json -Compress)" }

        Write-Host "`n[14] MSI on a real scaffold: PSADT's Zero-Config block + the toolkit blocks" -ForegroundColor Cyan
        $msiProj = New-Scaffold 'MsiZc'
        New-Item -ItemType Directory -Path (Join-Path $msiProj 'Files') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $msiProj 'Files\stub.msi'), [byte[]](0xD0, 0xCF, 0x11, 0xE0))
        $msiPristine = Read-Text (Join-Path $msiProj 'Invoke-AppDeployToolkit.ps1')
        $okMsi = Configure-PSADTForInstaller -ProjectPath $msiProj -AppInfo ([pscustomobject]@{ Name = 'Stub MSI App'; Version = '2.0.0'; Id = 'Stub.Msi' }) -Architecture 'x64' -WarningVariable wvMsi -WarningAction SilentlyContinue 6>$null
        if ($okMsi -eq $true -and -not $wvMsi) { Ok 'Configure returned true without warnings' } else { Bad "Configure: r=$okMsi warnings=[$($wvMsi -join ';')]" }
        $msiCfg = Get-Win32ToolkitAppConfig -ProjectPath $msiProj
        if ($msiCfg.Installer.Type -eq 'msi' -and [string]::IsNullOrEmpty([string]$msiCfg.App.Name) -and $msiCfg.App.DisplayName -eq 'Stub MSI App') { Ok 'App.Name empty (Zero-Config stays enabled), DisplayName set, Installer.Type msi' }
        else { Bad "AppConfig: $($msiCfg.App | ConvertTo-Json -Compress)" }
        $msiPs1 = Read-Text (Join-Path $msiProj 'Invoke-AppDeployToolkit.ps1')
        if ($msiPs1 -cne $msiPristine -and $msiPs1.Contains($loaderSentinel)) { Ok 'GUARD: MSI deploy script patched (loader sentinel)' } else { Bad 'GUARD: MSI deploy script not patched' }
        $mi = Get-PhaseText $msiPs1 'Install'
        $mu = Get-PhaseText $msiPs1 'Uninstall'
        $zcI = $mi.IndexOf('if ($adtSession.UseDefaultMsi)')
        if ($zcI -ge 0 -and $mi.Contains('Start-ADTMsiProcess') -and $mi.Contains('## win32-toolkit:Install:install (begin)') -and $mi.Contains('## win32-toolkit:Install:install-done (begin)')) {
            Ok "Install phase: PSADT's Zero-Config MSI block AND the toolkit install/install-done blocks (V7)"
        } else { Bad 'Install phase lacks the Zero-Config block or the toolkit blocks' }
        if ($zcI -ge 0 -and $zcI -lt $mi.IndexOf('## win32-toolkit:Install:install (begin)')) { Ok 'Zero-Config block runs before the toolkit install block' } else { Bad 'Zero-Config block not ahead of the toolkit block' }
        if ($mu.Contains('if ($adtSession.UseDefaultMsi)') -and $mu.Contains('Start-ADTMsiProcess') -and $mu.Contains('## win32-toolkit:Uninstall:uninstall (begin)')) {
            Ok "Uninstall phase: PSADT's Zero-Config MSI block AND the toolkit uninstall block"
        } else { Bad 'Uninstall phase lacks the Zero-Config block or the toolkit block' }
        $mspHere = $mi.Contains('## win32-toolkit:Install:msp (begin)')
        if ($mspHere -eq $is42) { Ok "msp block (4.1.8 MSP parity) present iff PSADT 4.2 (present: $mspHere)" } else { Bad "msp present=$mspHere on $($sel.VersionText)" }
        if ($is42 -and $mspHere) {
            if ($mi.Contains('Start-ADTMsiProcess -Action Patch -FilePath $w32tMsp.FullName') -and $mi.IndexOf('## win32-toolkit:Install:msp (begin)') -gt $zcI) { Ok 'msp block patches DefaultMspFiles after the Zero-Config install' } else { Bad 'msp block text/order' }
        }
        $sMsi = Get-Win32ToolkitDeployScriptShape -Content $msiPs1
        $e51m = @(Test-Win32ToolkitPS51Syntax -Path (Join-Path $msiProj 'Invoke-AppDeployToolkit.ps1'))
        if ($sMsi.Shape -eq $expectShape -and $sMsi.GeneratorVersion -eq 2 -and $sMsi.ParseErrors -eq 0 -and $e51m.Count -eq 0) { Ok 'MSI script: shape kept, GeneratorVersion 2, host + 5.1 parse clean' } else { Bad "MSI script: $($sMsi.Shape)/$($sMsi.GeneratorVersion)/$($sMsi.ParseErrors) 5.1=[$($e51m -join ' | ')]" }

        Write-Host "`n[15] Critical abort: Configure-PSADTForInstaller on an Unknown-shape script propagates the W32T error" -ForegroundColor Cyan
        $abort = Join-Path $base 'Abort'
        Copy-Item -LiteralPath $drift -Destination $abort -Recurse
        $abortScript = Join-Path $abort 'Invoke-AppDeployToolkit.ps1'
        Write-Text $abortScript ($driftPristine.Replace('$adtSession = @{', '$adtSessionDrifted = @{'))
        if ((Get-Win32ToolkitDeployScriptShape -Path $abortScript).Shape -eq 'Unknown') { Ok 'mutated scaffold is shape Unknown' } else { Bad 'mutation did not produce an Unknown shape' }
        New-Item -ItemType Directory -Path (Join-Path $abort 'Files') -Force | Out-Null
        Set-Content -Path (Join-Path $abort 'Files\abort_x64_1.0.exe') -Value 'stub' -Encoding ASCII
        $abortBefore = [System.IO.File]::ReadAllBytes($abortScript)
        $err15 = Get-W32TError { Configure-PSADTForInstaller -ProjectPath $abort -AppInfo ([pscustomobject]@{ Name = 'Abort'; Version = '1.0'; Id = 'Abort.App' }) -Architecture 'x64' 6>$null 3>$null }
        if ($err15 -and $err15.FullyQualifiedErrorId -like 'W32T.UnsupportedTemplateShape*' -and $err15.Exception.Message.StartsWith($prefix)) { Ok 'W32T.UnsupportedTemplateShape propagates out of Configure (not downgraded to $false)' }
        else { Bad "Configure on Unknown shape: $(if ($err15) { "$($err15.FullyQualifiedErrorId): $($err15.Exception.Message)" } else { 'no error (returned normally)' })" }
        if (Test-SameContent $abortScript $abortBefore) { Ok 'the Unknown-shape deploy script is byte-identical' } else { Bad 'the Unknown-shape deploy script was modified' }
    }
    catch {
        Bad "unexpected error: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
    }
    finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }

    $script:W32TTestFail
} $sel

Write-Host ''
if ($fail -eq 0) { Write-Host "Data-driven integration test PASSED (PSAppDeployToolkit $($sel.VersionText))" -ForegroundColor Green; exit 0 }
Write-Host "$fail check(s) FAILED (PSAppDeployToolkit $($sel.VersionText))" -ForegroundColor Red
exit 1
