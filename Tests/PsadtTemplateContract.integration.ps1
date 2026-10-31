<#
    PSADT template contract suite (spec 3.6 task 3; DOC-05, TST-05, analysis 9.3; SCF-03 double scaffold).

    Runs the real generation pipeline against the REAL PSAppDeployToolkit the selector picks (one process =
    one PSADT version; $env:W32T_PSADT_VERSION pins it) and asserts the generated-code contract (spec 5):

      * four projects scaffolded in ONE process with Create-PSADTProject -Force (EXE, MSI, MSIX, manual EXE):
        every scaffold succeeds and only one PSAppDeployToolkit copy is ever loaded (guarded import, SCF-03)
      * configured like the toolkit does it: Configure-PSADTForInstaller (EXE/MSI/MSIX, org template loaded)
        or Set-PSADTDataDrivenScript -ManualInstall + Apply-OrgTemplate (manual), with an org template that
        has all six hooks, an org logo and a valid PSAppDeployToolkit.Contoso extension module
      * per project: shape Psadt41 (4.1) / Psadt42ZeroConfig (4.2), GeneratorVersion 3 (lean deploy script PR 2:
        the loader marker names the toolkit extension); loader, session edits and ExitWithMsiCodes; exactly the
        blocks of the block plan per phase in canonical order (install / uninstall only for a non-MSI, msp only
        for an MSI on 4.2, tattoo, 5 org-ui, 6 hooks - last in Pre-*, first in Post-*); no PSADT default dialog
        outside toolkit blocks; the toolkit extension (PSAppDeployToolkit.Win32Toolkit, byte-identical to the
        shipped copy), the org extension module and the hook files copied; 0 warnings matching
        drift|anchor|pattern not found
      * Windows PowerShell 5.1 parse (Test-Win32ToolkitPS51Syntax) clean on the deploy script and on every
        generated guest/device script (install assertions, log collector, package runner, countdown, update
        assertions, targeted documentation, UpdateRequirement.ps1, org hooks, both extension modules)
      * no variable assigned inside a toolkit block collides with a PSADT exported variable or a PSADT
        environment-table variable (read-only on 4.2; GEN-06)
      * Assert-Win32ToolkitPackageReady -Stage Export passes with no warning (on a prerelease PSADT:
        exactly the one non-blocking prerelease warning)
      * the org logo replaced the PSADT logo New-ADTTemplate wrote: Assets\.iconsource = 'template' and
        Assets\AppIcon.png is the 64x64 org bitmap, not the bytes captured right after the scaffold
      * in a child powershell.exe (5.1): the bundled module imported by path, Initialize-ADTModule
        -ScriptDirectory <project>: Assets.Logo / Assets.Banner resolve to <project>\Assets\*.png (not Base64),
        so the effective logo is the org logo; the toolkit extension (its 10 functions) and the org extension
        module import next to it

    Scratch root %TEMP%\w32t-tc-<4 hex> (printed as 'SCRATCH: <path>'). With $env:W32T_KEEP_TEST_OUTPUT set the
    root is kept and printed as 'KEPT: <path>' (spec 6 step 4 parses everything under it with 5.1).

    Needs a supported PSAppDeployToolkit: none selected -> SKIP (exit 3), or FAIL (exit 1) when
    $env:W32T_REQUIRE_PSADT is set. Safety: Get-Win32ToolkitBasePath, Find-Module, Install-Module,
    Update-Module and Read-Host are shadowed to throw; nothing is installed; no generated deploy script,
    guest script or installer is ever executed (the 5.1 child only initialises the PSADT module).

    Run:  pwsh -File Tests\PsadtTemplateContract.integration.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'safety shadows: nothing may be installed or prompted')]
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

# Short scratch root (MAX_PATH, V57).
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-tc-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
Write-Host "SCRATCH: $scratch"

$fail = & $mod {
    param($sel, $scratch, $repo)
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
    $script:W32TTemplateRoot = Join-Path $scratch 'Templates\Contoso'
    function script:Get-Win32ToolkitTemplateAssetFolder { param([string]$TemplateName, [string]$BasePath) $script:W32TTemplateRoot }
    $script:SandboxFeatureEnabled = $true   # New-TargetedDocumentation: skip the DISM feature probe

    $is42 = $sel.Version -ge [version]'4.2.0'
    $expectShape = if ($is42) { 'Psadt42ZeroConfig' } else { 'Psadt41' }
    $driftPattern = 'drift|anchor|pattern not found'

    # ---- scratch org template: six hooks, an org logo, a valid extension module ------------------
    $tplRoot = $script:W32TTemplateRoot
    foreach ($d in 'Hooks', 'Assets', 'PSAppDeployToolkit.Contoso') { New-Item -ItemType Directory -Path (Join-Path $tplRoot $d) -Force | Out-Null }
    $hookFiles = 'PreInstall.ps1', 'PostInstall.ps1', 'PreUninstall.ps1', 'PostUninstall.ps1', 'PreRepair.ps1', 'PostRepair.ps1'
    foreach ($h in $hookFiles) {
        [System.IO.File]::WriteAllText((Join-Path $tplRoot "Hooks\$h"), "Write-ADTLogEntry -Message 'Contoso org hook $h ran'`r`n", (New-Object System.Text.UTF8Encoding($true)))
    }
    Add-Type -AssemblyName System.Drawing
    $orgLogoColor = [System.Drawing.Color]::FromArgb(255, 20, 90, 160)
    $bmp = New-Object System.Drawing.Bitmap 64, 64
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear($orgLogoColor); $g.Dispose()
    $bmp.Save((Join-Path $tplRoot 'Assets\AppIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $ext = Join-Path $tplRoot 'PSAppDeployToolkit.Contoso'
    [System.IO.File]::WriteAllText((Join-Path $ext 'PSAppDeployToolkit.Contoso.psd1'), (@(
                '@{'
                "    RootModule = 'PSAppDeployToolkit.Contoso.psm1'"
                "    ModuleVersion = '1.0.0'"
                "    GUID = '0f6b8a2e-5c1d-4e7a-9b3f-2d4c6e8a1b05'"
                "    Author = 'Contoso IT'"
                "    FunctionsToExport = @('Get-ContosoGreeting')"
                "    RequiredModules = @(@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0' })"
                '}') -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText((Join-Path $ext 'PSAppDeployToolkit.Contoso.psm1'),
        "function Get-ContosoGreeting { 'Hello from Contoso' }`r`nExport-ModuleMember -Function Get-ContosoGreeting`r`n", (New-Object System.Text.UTF8Encoding($true)))

    $script:OrgTemplate = [pscustomobject]@{
        TemplateSchemaVersion  = '4.0'; TemplateName = 'Contoso'; CompanyName = "Contoso O'Brien IT"; AppScriptAuthor = 'Contoso Packaging'
        TenantId               = ''; DialogStyle = 'Fluent'; FluentAccentColor = ''; LogPath = 'C:\Windows\Logs\Contoso'; LanguageOverride = ''
        ProgressMessage        = [pscustomobject]@{ Install = 'Contoso is installing...'; Repair = 'Contoso is repairing...'; Uninstall = 'Contoso is removing...' }
        ProgressMessageDetail  = [pscustomobject]@{ Install = 'Please wait.'; Repair = 'Please wait.'; Uninstall = 'Please wait.' }
        BalloonComplete        = [pscustomobject]@{ Install = 'Installed.'; Repair = 'Repaired.'; Uninstall = 'Removed.' }
        WelcomeDialog          = [pscustomobject]@{ Enabled = $true; AllowDefer = $true; DeferTimes = 3; CheckDiskSpace = $false; PersistPrompt = $true; BlockExecution = $true; CloseProcessesCountdown = 180; CustomText = $false }
        UninstallWelcomeDialog = [pscustomobject]@{ Enabled = $true; CloseProcessesCountdown = 60; PersistPrompt = $false; BlockExecution = $false }
        ProgressDialog         = [pscustomobject]@{ Enabled = $true; StatusMessage = 'Contoso is installing your app'; StatusMessageDetail = '' }
        CompletionPrompt       = [pscustomobject]@{ Enabled = $true; Message = 'The installation has completed successfully.'; ButtonRightText = 'OK' }
        Hooks                  = [pscustomobject]@{ Enabled = $true; FailureAction = 'Fail' }
        ExtensionModule        = $true
        CustomAssets           = $true
        DocFooter              = ''
    }

    # ---- helpers ---------------------------------------------------------------------------------
    function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
    function Get-PhaseText([string]$Content, $Shape, [string]$Phase) {
        $pl = $Shape.Layout.Phases[$Phase]
        if (-not $pl) { return '' }
        if ($pl.ContainsKey('Open')) { return $Content.Substring($pl.Open + 1, $pl.Close - $pl.Open - 1) }
        return $Content.Substring($pl.RegionStart, $pl.RegionEnd - $pl.RegionStart)
    }
    # Code left in a text once whole-line comments are dropped (PSADT 4.1 regions also hold its
    # '## <Perform ... tasks here>' markers and the '##====' / '## MARK:' banners of the next phase).
    function Get-CodeOnly([string]$Text) { [regex]::Replace($Text, '(?m)^[ \t]*#[^\r\n]*(?=\r?$)', '').Trim() }

    # Canonical toolkit blocks per phase (spec 2.6 slot table; 5.2-5.5), narrowed by the block plan (lean deploy script
    # PR 2): an MSI gets no install and no uninstall block (PSADT's Zero-Config block does both) and the msp block only
    # on 4.2; an EXE / MSIX gets install + uninstall; a manual app gets manual-install. Install / Uninstall are set per kind.
    $expectAuto = [ordered]@{
        'Session'        = @('loader')
        'Pre-Install'    = @('prior-check', 'org-ui', 'hook', 'remove-prior')
        'Install'        = @()
        'Post-Install'   = @('hook', 'tattoo', 'org-ui')
        'Pre-Uninstall'  = @('org-ui', 'hook')
        'Uninstall'      = @()
        'Post-Uninstall' = @('hook', 'tattoo')
        'Pre-Repair'     = @('org-ui', 'hook')
        'Repair'         = @()
        'Post-Repair'    = @('hook', 'org-ui')
    }

    $projectsDir = Join-Path $scratch 'Projects\Contoso'
    New-Item -ItemType Directory -Path $projectsDir -Force | Out-Null
    $cases = @(
        @{ Name = 'TcExe_x64_1.2.3'; Kind = 'exe' }
        @{ Name = 'TcMsi_x64_2.0.0'; Kind = 'msi' }
        @{ Name = 'TcMsix_x64_3.0.0'; Kind = 'msix' }
        @{ Name = 'TcManual_x64_4.0.0'; Kind = 'manual' }
    )
    $projects = [ordered]@{}
    # The PSADT logo New-ADTTemplate writes to <proj>\Assets\AppIcon.png, per project ([1]); [5] proves the
    # org logo replaced it (otherwise the effective logo would silently stay the PSADT default).
    $scaffoldLogo = @{}

    try {
        Write-Host "[1] Four scaffolds in ONE process with Create-PSADTProject -Force (SCF-03), expected shape $expectShape" -ForegroundColor Cyan
        foreach ($case in $cases) {
            $wvCreate = $null
            $okCreate = Create-PSADTProject -ProjectName $case.Name -ProjectPath $projectsDir -Force -WarningVariable wvCreate -WarningAction SilentlyContinue 6>$null
            $unexpected = @($wvCreate | Where-Object { "$_" -notmatch 'PRERELEASE' })
            if ($okCreate -eq $true -and $unexpected.Count -eq 0) { Ok "$($case.Name): scaffolded" }
            else { Bad "$($case.Name): Create-PSADTProject returned $okCreate; warnings [$(@($wvCreate) -join ' | ')]" }
            $projects[$case.Name] = Join-Path $projectsDir $case.Name
            $scaffoldLogo[$case.Name] = $null
            $scaffoldLogoPath = Join-Path $projects[$case.Name] 'Assets\AppIcon.png'
            if (Test-Path -LiteralPath $scaffoldLogoPath) { $scaffoldLogo[$case.Name] = [System.IO.File]::ReadAllBytes($scaffoldLogoPath) }
        }
        $loaded = @(Get-Module -Name PSAppDeployToolkit -All | Where-Object { $_.ModuleBase } | Select-Object -ExpandProperty ModuleBase -Unique)
        if ($loaded.Count -eq 1) { Ok "one PSAppDeployToolkit copy loaded for all four scaffolds ($($loaded[0]))" } else { Bad "PSAppDeployToolkit copies loaded: $($loaded -join ', ')" }
        if ($sel.IsPrerelease) {
            $loadedPre = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $loaded[0] 'PSAppDeployToolkit.psd1')).PrivateData.PSData.Prerelease
            if ($loadedPre -eq $sel.Prerelease) { Ok "the loaded copy is the selected prerelease ($($sel.VersionText))" } else { Bad "loaded prerelease '$loadedPre' vs selected $($sel.VersionText)" }
        }

        Write-Host "`n[2] Configure each project the way the toolkit does" -ForegroundColor Cyan
        $warn = @{}
        foreach ($case in $cases) {
            $proj = $projects[$case.Name]
            $files = Join-Path $proj 'Files'
            New-Item -ItemType Directory -Path $files -Force | Out-Null
            $wv = $null; $wv2 = $null; $r = $null
            switch ($case.Kind) {
                'exe' {
                    [System.IO.File]::WriteAllBytes((Join-Path $files 'TcExe_x64_1.2.3.exe'), [byte[]](0x4D, 0x5A, 0, 0))
                    Set-Content -LiteralPath (Join-Path $files 'Contoso.TcExe.installer.yaml') -Encoding UTF8 -Value @"
PackageIdentifier: Contoso.TcExe
PackageVersion: 1.2.3
PackageName: Tc Exe App
Publisher: Contoso Ltd
InstallerSwitches:
  Silent: /S /NORESTART
"@
                    $r = Configure-PSADTForInstaller -ProjectPath $proj -AppInfo ([pscustomobject]@{ Name = 'Tc Exe App'; Version = '1.2.3'; Id = 'Contoso.TcExe' }) -Architecture 'x64' -WarningVariable wv -WarningAction SilentlyContinue 6>$null
                }
                'msi' {
                    [System.IO.File]::WriteAllBytes((Join-Path $files 'TcMsi_x64_2.0.0.msi'), [byte[]](0xD0, 0xCF, 0x11, 0xE0))
                    $r = Configure-PSADTForInstaller -ProjectPath $proj -AppInfo ([pscustomobject]@{ Name = 'Tc Msi App'; Version = '2.0.0'; Id = 'Contoso.TcMsi' }) -Architecture 'x64' -WarningVariable wv -WarningAction SilentlyContinue 6>$null
                }
                'msix' {
                    $mf = Join-Path $scratch 'msixmf'
                    New-Item -ItemType Directory -Path $mf -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $mf 'AppxManifest.xml') -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="Contoso.TcMsix" Publisher="CN=Contoso" Version="3.0.0.0" />
</Package>
'@
                    Compress-Archive -Path (Join-Path $mf 'AppxManifest.xml') -DestinationPath (Join-Path $scratch 'mx.zip') -Force
                    Move-Item -LiteralPath (Join-Path $scratch 'mx.zip') -Destination (Join-Path $files 'TcMsix.msix') -Force
                    $r = Configure-PSADTForInstaller -ProjectPath $proj -AppInfo ([pscustomobject]@{ Name = 'Tc Msix App'; Version = '3.0.0'; Id = 'Contoso.TcMsix' }) -Architecture 'x64' -WarningVariable wv -WarningAction SilentlyContinue 6>$null
                }
                'manual' {
                    # Mirrors New-Win32ToolkitManualApp for an EXE without silent switches (a hard app).
                    [System.IO.File]::WriteAllBytes((Join-Path $files 'TcManual_x64_4.0.0.exe'), [byte[]](0x4D, 0x5A, 0, 0))
                    $cfgM = Get-Win32ToolkitAppConfig -ProjectPath $proj
                    $cfgM | Add-Member -NotePropertyName App -NotePropertyValue ([pscustomobject]@{ Vendor = 'Contoso Ltd'; Name = 'Tc Manual App'; DisplayName = 'Tc Manual App'; Version = '4.0.0'; Arch = 'x64'; ScriptAuthor = ''; ScriptDate = (Get-Date -Format 'yyyy-MM-dd'); Description = ''; InformationUrl = '' }) -Force
                    $cfgM | Add-Member -NotePropertyName Installer -NotePropertyValue ([pscustomobject]@{ Type = 'exe'; FileName = 'TcManual_x64_4.0.0.exe'; SilentArgs = '' }) -Force
                    $cfgM | Add-Member -NotePropertyName ProcessesToClose -NotePropertyValue @() -Force
                    Set-Win32ToolkitAppConfig -ProjectPath $proj -Config $cfgM | Out-Null
                    $r1 = Set-PSADTDataDrivenScript -ScriptPath (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') -ManualInstall -WarningVariable wv -WarningAction SilentlyContinue
                    $r2 = Apply-OrgTemplate -ProjectPath $proj -Template $script:OrgTemplate -WarningVariable wv2 -WarningAction SilentlyContinue 6>$null
                    $r = ($r1 -eq $true) -and ($r2 -eq $true)
                    $wv = @($wv) + @($wv2)
                }
            }
            $warn[$case.Name] = @($wv | Where-Object { $_ } | ForEach-Object { "$_" })
            if ($r -eq $true) { Ok "$($case.Name) ($($case.Kind)): configured" } else { Bad "$($case.Name) ($($case.Kind)): configure returned $r; warnings [$($warn[$case.Name] -join ' | ')]" }
            $driftW = @($warn[$case.Name] | Where-Object { $_ -match $driftPattern })
            if ($driftW.Count -eq 0) { Ok "$($case.Name): 0 warnings matching '$driftPattern'" } else { Bad "$($case.Name): drift/anchor warnings [$($driftW -join ' | ')]" }
        }

        # Variables PSADT owns, from the host's loaded copy (the 5.1 child adds the environment table).
        $psadtVars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($m in @(Get-Module -Name PSAppDeployToolkit -All)) { foreach ($k in @($m.ExportedVariables.Keys)) { [void]$psadtVars.Add($k) } }

        # 5.1 probe (value-free; the project path travels in an environment variable).
        $probe = Join-Path $scratch 'probe51.ps1'
        [System.IO.File]::WriteAllText($probe, (@(
                    '$ErrorActionPreference = ''Stop'''
                    '$r = @{ Ok = $false; Ps = [string]$PSVersionTable.PSVersion; Logo = ''''; Banner = ''''; EnvKeys = @(); ModuleVars = @(); ExtensionOk = $false; W32TCommands = 0; Error = '''' }'
                    'try {'
                    '    $proj = $env:W32T_TC_PROJECT'
                    '    Import-Module -Name (Join-Path $proj ''PSAppDeployToolkit\PSAppDeployToolkit.psd1'')'
                    '    Initialize-ADTModule -ScriptDirectory $proj'
                    '    $cfg = Get-ADTConfig'
                    '    foreach ($k in ''Logo'', ''Banner'') { $v = [string]$cfg.Assets.$k; if ($v.Length -gt 300) { $v = ''<BASE64 '' + $v.Length + '' chars>'' }; $r[$k] = $v }'
                    '    $envTable = Get-ADTEnvironmentTable'
                    '    # 4.1.x: a dictionary; 4.2: a PSAppDeployToolkit.Foundation.EnvironmentTable object (one property per variable).'
                    '    if ($envTable -is [System.Collections.IDictionary]) { $r.EnvKeys = @($envTable.Keys | ForEach-Object { [string]$_ }) }'
                    '    else { $r.EnvKeys = @($envTable.PSObject.Properties | ForEach-Object { [string]$_.Name }) }'
                    '    $r.ModuleVars = @((Get-Module -Name PSAppDeployToolkit).ExportedVariables.Keys | ForEach-Object { [string]$_ })'
                    '    Import-Module -Name (Join-Path $proj ''PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psd1'')'
                    '    $r.ExtensionOk = ((Get-ContosoGreeting) -eq ''Hello from Contoso'')'
                    '    Import-Module -Name (Join-Path $proj ''PSAppDeployToolkit.Win32Toolkit\PSAppDeployToolkit.Win32Toolkit.psd1'')'
                    '    $r.W32TCommands = @(Get-Command -Module PSAppDeployToolkit.Win32Toolkit).Count'
                    '    $r.Ok = $true'
                    '} catch { $r.Error = [string]$_.Exception.Message }'
                    '''W32T-RESULT:'' + ($r | ConvertTo-Json -Compress -Depth 3)') -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        $ps51 = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $ps51)) { Bad "Windows PowerShell 5.1 not found at $ps51 - the 5.1 checks cannot run" }

        foreach ($case in $cases) {
            $proj = $projects[$case.Name]
            $manual = $case.Kind -eq 'manual'
            Write-Host "`n[3] $($case.Name) ($($case.Kind)): generated deploy script" -ForegroundColor Cyan
            $scriptPath = Join-Path $proj 'Invoke-AppDeployToolkit.ps1'
            $c = Read-Text $scriptPath
            $shape = Get-Win32ToolkitDeployScriptShape -Content $c -IncludeLayout
            if ($shape.Shape -eq $expectShape -and $shape.GeneratorVersion -eq 3 -and $shape.Support -eq 'Supported' -and $shape.ParseErrors -eq 0 -and $shape.HasTattoo -and
                $shape.ExtensionName -eq 'PSAppDeployToolkit.Win32Toolkit' -and $shape.ExtensionVersion -eq (Get-Win32ToolkitDeployExtension).Version) {
                Ok "shape $($shape.Shape), GeneratorVersion 3 (extension PSAppDeployToolkit.Win32Toolkit $($shape.ExtensionVersion)), Supported, host parse clean, tattoo"
            } else { Bad "shape $($shape.Shape) / gen $($shape.GeneratorVersion) / $($shape.Support) / parse $($shape.ParseErrors) / tattoo $($shape.HasTattoo) ($($shape.Reason))" }
            if (@($shape.Layout.BlockIssues).Count -eq 0) { Ok 'every toolkit block is well-formed and inside its phase' } else { Bad "block issues: $(@($shape.Layout.BlockIssues | ForEach-Object { $_.Message }) -join '; ')" }
            $bytes = [System.IO.File]::ReadAllBytes($scriptPath)
            if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Ok 'UTF-8 with BOM' } else { Bad 'deploy script has no UTF-8 BOM' }

            # Loader + session edits + ExitWithMsiCodes (5.1).
            $sessionOk = $true
            foreach ($k in '$appConfig = if (Test-Path -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json")', '$w32tInstallDone = $false',
                'AppVendor = $appConfig.App.Vendor', 'AppName = $appConfig.App.Name', 'AppVersion = $appConfig.App.Version', 'AppArch = $appConfig.App.Arch',
                'AppProcessesToClose = @($appConfig.ProcessesToClose | Where-Object { $_ })', 'AppScriptDate = $appConfig.App.ScriptDate',
                'AppScriptAuthor = $appConfig.App.ScriptAuthor') {
                if (-not $c.Contains($k)) { $sessionOk = $false; Bad "missing: $k" }
            }
            if ($sessionOk) { Ok 'Session:loader + every $adtSession edit present' }
            if (([regex]::Matches($c, '(?m)^\s*ExitWithMsiCodes = \$true\s*$')).Count -eq 1) { Ok 'ExitWithMsiCodes = $true once (D13)' } else { Bad 'ExitWithMsiCodes = $true missing or duplicated' }

            # Exactly the expected toolkit blocks per phase, in canonical order.
            $expect = [ordered]@{}
            foreach ($k in $expectAuto.Keys) { $expect[$k] = @($expectAuto[$k]) }
            $expect['Install'] = switch ($case.Kind) {
                'msi' { @(if ($is42) { 'msp' }) + @('install-done') }
                'manual' { @('manual-install', 'install-done') }
                default { @('install', 'install-done') }
            }
            $expect['Uninstall'] = @(if ($case.Kind -ne 'msi') { 'uninstall' })
            $blocks = @($shape.Layout.Blocks)
            foreach ($phase in $expect.Keys) {
                $got = @($blocks | Where-Object { $_.Phase -eq $phase } | Sort-Object Start | ForEach-Object { $_.Slot })
                if (($got -join ',') -ceq (@($expect[$phase]) -join ',')) { Ok "$phase blocks: [$($got -join ', ')]" }
                else { Bad "$phase blocks: [$($got -join ', ')], expected [$(@($expect[$phase]) -join ', ')]" }
            }
            if (@($blocks | Where-Object { $_.Slot -eq 'org-ui' }).Count -eq 5) { Ok '5 org-ui blocks' } else { Bad 'org-ui block count is not 5' }
            if (@($blocks | Where-Object { $_.Slot -eq 'hook' }).Count -eq 6) { Ok '6 hook blocks' } else { Bad 'hook block count is not 6' }
            # Hooks: last in Pre-Uninstall and Pre-Repair, first in every Post-* phase (D10). Installer-identity PR 3: in
            # Pre-Install only the remove-prior block follows the hook (the D10 hook-last contract, amended).
            foreach ($phase in 'Pre-Install', 'Pre-Uninstall', 'Pre-Repair') {
                $pt = Get-PhaseText $c $shape $phase
                $hookEnd = [regex]::Match($pt, "(?m)^[ \t]*## win32-toolkit:${phase}:hook \(end\)[^\r\n]*")
                $after = if ($hookEnd.Success) { $pt.Substring($hookEnd.Index + $hookEnd.Length) } else { 'x' }
                if ($phase -eq 'Pre-Install') {
                    $rp = [regex]::Match($after, '(?s)^\s*## win32-toolkit:Pre-Install:remove-prior \(begin\)[^\r\n]*\r?\n.*?## win32-toolkit:Pre-Install:remove-prior \(end\)[^\r\n]*')
                    if ($hookEnd.Success -and $rp.Success -and -not (Get-CodeOnly $after.Substring($rp.Index + $rp.Length))) { Ok 'Pre-Install: only the remove-prior block follows the hook block' }
                    else { Bad 'Pre-Install: code other than the remove-prior block follows the hook block' }
                }
                elseif ($hookEnd.Success -and -not (Get-CodeOnly $after)) { Ok "$phase hook block is the last code of the phase" }
                else { Bad "$phase hook block is not the last code of the phase" }
            }
            # The remove-prior pair (installer-identity PR 3): the catalog's revision (3 since lean deploy script PR 3) and the
            # dialog-order guard.
            if ($shape.RemovePriorRevision -eq (Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision) -and $shape.PriorCheckFirst) { Ok "RemovePriorRevision $($shape.RemovePriorRevision) (the catalog's), PriorCheckFirst (prior-check before the org dialogs, no default dialog left)" }
            else { Bad "RemovePriorRevision $($shape.RemovePriorRevision), PriorCheckFirst $($shape.PriorCheckFirst)" }
            foreach ($phase in 'Post-Install', 'Post-Uninstall', 'Post-Repair') {
                $pt = Get-PhaseText $c $shape $phase
                $hookBegin = [regex]::Match($pt, "(?m)^[ \t]*## win32-toolkit:${phase}:hook \(begin\)")
                $lead = if ($hookBegin.Success) { Get-CodeOnly $pt.Substring(0, $hookBegin.Index) } else { 'x' }
                if ($hookBegin.Success -and -not $lead) { Ok "$phase hook block is the first code of the phase" }
                else { Bad "$phase hook block is not the first code of the phase" }
            }
            if ($c.Contains("if (Test-Path -LiteralPath `$orgHookScript) { . `$orgHookScript }") -and -not $c.Contains('Org hook PreInstall.ps1 failed (continuing)')) {
                Ok "hook blocks dot-source the hook (FailureAction 'Fail': no try/catch wrapper)"
            } else { Bad 'hook block body is not the Fail variant' }
            # The Install phase of a manual project keeps operator space between manual-install and install-done.
            if ($manual) {
                if ($c.Contains('## MANUAL APP: write your install code BETWEEN this block and the ''install-done'' block below.')) { Ok 'manual-install note present' } else { Bad 'manual-install note missing' }
                if (-not $c.Contains('## win32-toolkit:Install:install (begin)')) { Ok 'no data-driven install block in a manual project' } else { Bad 'data-driven install block in a manual project' }
            }
            # MSI: PSADT's own Zero-Config block stays in Install and Uninstall (V7 guard).
            foreach ($phase in 'Install', 'Uninstall') {
                $pt = Get-PhaseText $c $shape $phase
                if ($pt.Contains('if ($adtSession.UseDefaultMsi)') -and $pt.Contains('Start-ADTMsiProcess')) { Ok "$phase keeps PSADT's Zero-Config MSI block" } else { Bad "$phase lost PSADT's Zero-Config MSI block" }
            }

            # No PSADT default dialog (or its $saiwParams) outside toolkit blocks - comments are ignored (AST).
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($c, [ref]$null, [ref]$null)
            $inBlock = { param($off) @($blocks | Where-Object { $off -ge $_.Start -and $off -lt $_.End }).Count -gt 0 }
            $dialogs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^Show-ADTInstallation(Welcome|Progress|Prompt)$' }, $true) |
                    Where-Object { -not (& $inBlock $_.Extent.StartOffset) })
            $saiw = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'saiwParams' }, $true) |
                    Where-Object { -not (& $inBlock $_.Extent.StartOffset) })
            if ($dialogs.Count -eq 0 -and $saiw.Count -eq 0) { Ok 'no PSADT default dialog left outside toolkit blocks' }
            else { Bad "default dialogs outside blocks: $(@($dialogs + $saiw | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Extent.Text.Split("`n")[0])" }) -join ' | ')" }

            # Org template side effects: extension module, hook files, assets, AppConfig policy.
            if (Test-Path -LiteralPath (Join-Path $proj 'PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psd1')) { Ok 'extension module copied (PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psd1)' } else { Bad 'extension module not copied' }
            # The toolkit extension: copied next to the script, byte-identical to the shipped copy (lean deploy script PR 2).
            $extSame = $true
            foreach ($ef in 'PSAppDeployToolkit.Win32Toolkit.psd1', 'PSAppDeployToolkit.Win32Toolkit.psm1') {
                $src = Join-Path $repo "DeployExtension\PSAppDeployToolkit.Win32Toolkit\$ef"
                $dst = Join-Path $proj "PSAppDeployToolkit.Win32Toolkit\$ef"
                if (-not (Test-Path -LiteralPath $dst) -or (Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash) { $extSame = $false }
            }
            if ($extSame) { Ok 'toolkit extension copied (PSAppDeployToolkit.Win32Toolkit), byte-identical to the shipped copy' } else { Bad 'toolkit extension missing or differs from the shipped copy' }
            $missingHooks = @($hookFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $proj "SupportFiles\OrgHooks\$_")) })
            if ($missingHooks.Count -eq 0) { Ok 'all six hook files copied to SupportFiles\OrgHooks' } else { Bad "hook files missing: $($missingHooks -join ', ')" }
            $cfg = Get-Win32ToolkitAppConfig -ProjectPath $proj
            if ($cfg.OrgUi -and $cfg.OrgUi.Welcome.Enabled -eq $true -and $cfg.OrgUi.Welcome.CloseProcessesCountdown -eq 180 -and $cfg.OrgUi.Completion.Enabled -eq $true -and $cfg.App.ScriptAuthor -eq 'Contoso Packaging') {
                Ok 'AppConfig: OrgUi policy and App.ScriptAuthor written as data'
            } else { Bad "AppConfig OrgUi/App: $($cfg.OrgUi | ConvertTo-Json -Compress -Depth 4)" }
            if (-not $c.Contains('Contoso Packaging') -and -not $c.Contains('Contoso is installing your app') -and -not $c.Contains("O'Brien") -and -not $c.Contains("O''Brien")) {
                Ok 'no org-template value spliced into the deploy script'
            } else { Bad 'an org-template value was spliced into the deploy script' }
            $expectType = switch ($case.Kind) { 'msi' { 'msi' } 'msix' { 'msix' } default { 'exe' } }
            if ($cfg.Installer.Type -eq $expectType) { Ok "Installer.Type = $expectType" } else { Bad "Installer.Type = $($cfg.Installer.Type)" }

            # No toolkit-block assignment target collides with a PSADT-owned variable.
            $assigned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -or $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
                if (-not (& $inBlock $n.Extent.StartOffset)) { continue }
                $target = if ($n -is [System.Management.Automation.Language.ForEachStatementAst]) { $n.Variable } else { $n.Left }
                foreach ($v in @($target.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | Select-Object -First 1)) {
                    [void]$assigned.Add(($v.VariablePath.UserPath -replace '^(script|global|local|private):', ''))
                }
            }

            Write-Host "`n[4] $($case.Name): generated guest/device scripts parse under Windows PowerShell 5.1" -ForegroundColor Cyan
            $gen = [System.Collections.Generic.List[string]]::new()
            $gen.Add($scriptPath)
            foreach ($step in @(
                    @{ Name = 'New-InstallAssertionScript'; Run = { New-InstallAssertionScript -ProjectPath $proj } }
                    @{ Name = 'New-LogCollectorScript'; Run = { New-LogCollectorScript -ProjectPath $proj } }
                    @{ Name = 'New-Win32ToolkitPackageRunnerScript'; Run = { New-Win32ToolkitPackageRunnerScript -ProjectPath $proj } }
                    @{ Name = 'New-CountdownScript'; Run = { New-CountdownScript -ProjectPath $proj } }
                    @{ Name = 'New-UpdateAssertionScript'; Run = { New-UpdateAssertionScript -ProjectPath $proj } }
                    @{ Name = 'New-TargetedDocumentation -SkipLaunch'; Run = { New-TargetedDocumentation -ProjectPath $proj -ProjectName $case.Name -AppInfo ([pscustomobject]@{ Name = $case.Name; Version = '1.0'; Id = $case.Name }) -SkipLaunch } }
                    @{ Name = 'Get-Win32ToolkitRequirementRule'; Run = { Get-Win32ToolkitRequirementRule -ProjectPath $proj } })) {
                try {
                    $items = @(& $step.Run 3>&1 6>$null)
                    $wvG = @($items | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                    $out = @($items | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
                    if ($out.Count -eq 0 -or ($out.Count -eq 1 -and $out[0] -is [bool] -and -not $out[0])) { Bad "$($step.Name) produced nothing (warnings: $($wvG -join ' | '))" }
                    elseif (@($wvG | Where-Object { "$_" -match $driftPattern }).Count) { Bad "$($step.Name) warned: $($wvG -join ' | ')" }
                } catch { Bad "$($step.Name) threw: $($_.Exception.Message)" }
            }
            foreach ($dir in 'Sandbox', 'SupportFiles') {
                $d = Join-Path $proj $dir
                if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Recurse -File -Include '*.ps1', '*.psm1' | ForEach-Object { $gen.Add($_.FullName) } }
            }
            Get-ChildItem -LiteralPath (Join-Path $proj 'PSAppDeployToolkit.Contoso') -File -Filter '*.psm1' -ErrorAction SilentlyContinue | ForEach-Object { $gen.Add($_.FullName) }
            Get-ChildItem -LiteralPath (Join-Path $proj 'PSAppDeployToolkit.Win32Toolkit') -File -Filter '*.psm1' -ErrorAction SilentlyContinue | ForEach-Object { $gen.Add($_.FullName) }
            foreach ($expected in 'Sandbox\InstallAssertions.ps1', 'Sandbox\CollectLogs.ps1', 'Sandbox\Invoke-PsadtPackage.ps1', 'Sandbox\Countdown.ps1',
                'SupportFiles\TargetedDocumentationScript.ps1', 'SupportFiles\UpdateRequirement.ps1') {
                if (-not (Test-Path -LiteralPath (Join-Path $proj $expected))) { Bad "expected generated script missing: $expected" }
            }
            $bad51 = 0
            foreach ($f in ($gen | Select-Object -Unique)) {
                $e51 = @(Test-Win32ToolkitPS51Syntax -Path $f)
                if ($e51.Count) { $bad51++; Bad "5.1 parse: $($f.Substring($proj.Length + 1)): $($e51 -join ' | ')" }
            }
            if ($bad51 -eq 0) { Ok "$(@($gen | Select-Object -Unique).Count) scripts parse under 5.1 (deploy script, Sandbox\*, SupportFiles\*, both extension modules)" }

            Write-Host "`n[5] $($case.Name): packaging gate and the PSADT module on Windows PowerShell 5.1" -ForegroundColor Cyan
            try {
                $ready = Assert-Win32ToolkitPackageReady -ProjectPath $proj -Stage Export -WarningVariable wvR -WarningAction SilentlyContinue
                # A prerelease PSADT (e.g. 4.2.0-rc2) adds exactly one non-blocking prerelease warning (F-05);
                # a stable one adds none. Anything else is a contract break.
                $expectWarn = @($ready.Warnings | Where-Object { $sel.IsPrerelease -and $_ -match 'a PRERELEASE' -and $_ -match [regex]::Escape("PSAppDeployToolkit $($sel.VersionText)") })
                $otherWarn  = @($ready.Warnings | Where-Object { $expectWarn -notcontains $_ })
                $wantPre    = if ($sel.IsPrerelease) { 1 } else { 0 }
                if ($ready.Ready -and $ready.Shape -eq $expectShape -and $expectWarn.Count -eq $wantPre -and $otherWarn.Count -eq 0) {
                    Ok "Assert-Win32ToolkitPackageReady -Stage Export: Ready, $($ready.VersionText), $(if ($wantPre) { 'only the prerelease warning' } else { 'no warning' })"
                }
                else { Bad "Assert: Ready=$($ready.Ready) shape=$($ready.Shape) prerelease=$($sel.IsPrerelease) warnings=[$(@($ready.Warnings) -join ' | ')]" }
            } catch { Bad "Assert-Win32ToolkitPackageReady threw: $($_.Exception.Message)" }

            # The effective logo is the ORG logo, not the PSADT one New-ADTTemplate wrote (DOC-05, TST-05). No
            # winget icon step runs here, so the template logo is the stamped base (Add-Win32ToolkitTemplateAssets).
            $logoWant = Join-Path $proj 'Assets\AppIcon.png'
            $iconSource = Get-Win32ToolkitIconSource -ProjectPath $proj
            $logoNow = $null
            if (Test-Path -LiteralPath $logoWant) { $logoNow = [System.IO.File]::ReadAllBytes($logoWant) }
            $logoW = 0; $logoH = 0; $logoArgb = 0; $logoErr = ''
            if ($null -ne $logoNow) {
                try {
                    $ms = [System.IO.MemoryStream]::new($logoNow)
                    try {
                        $bm = [System.Drawing.Bitmap]::new($ms)
                        try { $logoW = $bm.Width; $logoH = $bm.Height; $logoArgb = $bm.GetPixel(32, 32).ToArgb() } finally { $bm.Dispose() }
                    } finally { $ms.Dispose() }
                } catch { $logoErr = $_.Exception.Message }
            }
            $fromScaffold = $null -ne $logoNow -and $null -ne $scaffoldLogo[$case.Name] -and [System.Linq.Enumerable]::SequenceEqual([byte[]]$logoNow, [byte[]]$scaffoldLogo[$case.Name])
            if ($iconSource -eq 'template' -and $null -ne $logoNow -and -not $fromScaffold -and $logoW -eq 64 -and $logoH -eq 64 -and $logoArgb -eq $orgLogoColor.ToArgb()) {
                Ok "org logo applied: Assets\.iconsource = 'template', Assets\AppIcon.png is the 64x64 org bitmap (not the scaffold's PSADT logo)"
            } else { Bad "org logo not applied: iconsource [$iconSource], AppIcon.png present $($null -ne $logoNow), same bytes as the scaffold $fromScaffold, decoded ${logoW}x${logoH} ARGB 0x$('{0:X8}' -f $logoArgb) $logoErr" }

            $env:W32T_TC_PROJECT = $proj
            $raw = & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe 2>&1
            Remove-Item Env:\W32T_TC_PROJECT -ErrorAction SilentlyContinue
            $line = @($raw | ForEach-Object { "$_" } | Where-Object { $_.StartsWith('W32T-RESULT:') }) | Select-Object -Last 1
            if (-not $line) { Bad "5.1 probe produced no result: $(@($raw) -join ' | ')"; continue }
            $res = $line.Substring('W32T-RESULT:'.Length) | ConvertFrom-Json
            if (-not $res.Ok) { Bad "5.1 probe failed (PS $($res.Ps)): $($res.Error)"; continue }
            $bannerWant = Join-Path $proj 'Assets\Banner.Classic.png'
            if ($res.Logo -eq $logoWant -and (Test-Path -LiteralPath $logoWant)) { Ok "5.1 ($($res.Ps)): Assets.Logo = <project>\Assets\AppIcon.png (not Base64)" } else { Bad "5.1: Assets.Logo = [$($res.Logo)]" }
            if ($res.Banner -eq $bannerWant -and (Test-Path -LiteralPath $bannerWant)) { Ok '5.1: Assets.Banner = <project>\Assets\Banner.Classic.png (not Base64)' } else { Bad "5.1: Assets.Banner = [$($res.Banner)]" }
            if ($res.ExtensionOk) { Ok '5.1: the org extension module imports next to the bundled PSADT (<Dir>\<Dir>.psd1)' } else { Bad '5.1: the org extension module did not import' }
            if ($res.W32TCommands -eq 10) { Ok '5.1: the toolkit extension imports next to the bundled PSADT (10 functions)' } else { Bad "5.1: the toolkit extension exported $($res.W32TCommands) functions, expected 10" }
            $envNames = @($res.EnvKeys | Where-Object { $_ })
            $owned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($k in @($psadtVars) + $envNames + @($res.ModuleVars)) { if ($k) { [void]$owned.Add([string]$k) } }
            $clash = @($assigned | Where-Object { $owned.Contains($_) })
            if ($envNames.Count -lt 50) { Bad "5.1: the PSADT environment table yielded only $($envNames.Count) variable names - the collision check would be vacuous" }
            # Since lean deploy script PR 3 the blocks assign only the loader's $appConfig / $w32tInstallDone and the hooks' $orgHookScript.
            elseif ($assigned.Count -lt 3) { Bad "only $($assigned.Count) toolkit-block assignments found - the collision check would be vacuous" }
            elseif ($clash.Count -eq 0) { Ok "no toolkit-block variable ($($assigned.Count)) collides with a PSADT variable ($($owned.Count): exported + environment table)" }
            else { Bad "toolkit-block variables colliding with PSADT variables: [$($clash -join ', ')] (PSADT names known: $($owned.Count))" }
            # The same check on the toolkit extension's functions (lean deploy script PR 2): their variables are function-local
            # in the module, so a clash could not break a deployment today; a clash still means a confusing log or a later bug.
            $extPath = Join-Path $proj 'PSAppDeployToolkit.Win32Toolkit\PSAppDeployToolkit.Win32Toolkit.psm1'
            $extAst = [System.Management.Automation.Language.Parser]::ParseFile($extPath, [ref]$null, [ref]$null)
            $extAssigned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $extAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -or $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
                $target = if ($n -is [System.Management.Automation.Language.ForEachStatementAst]) { $n.Variable } else { $n.Left }
                foreach ($v in @($target.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | Select-Object -First 1)) {
                    [void]$extAssigned.Add(($v.VariablePath.UserPath -replace '^(script|global|local|private):', ''))
                }
            }
            $extClash = @($extAssigned | Where-Object { $owned.Contains($_) })
            if ($extAssigned.Count -lt 5) { Bad "only $($extAssigned.Count) toolkit-extension assignments found - the collision check would be vacuous" }
            elseif ($extClash.Count -eq 0) { Ok "no toolkit-extension variable ($($extAssigned.Count)) collides with a PSADT variable" }
            else { Bad "toolkit-extension variables colliding with PSADT variables: [$($extClash -join ', ')]" }
        }
    }
    catch {
        Bad "unexpected error: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
    }

    $script:W32TTestFail
} $sel $scratch $repo

if ($env:W32T_KEEP_TEST_OUTPUT) {
    Write-Host "KEPT: $scratch"
}
else {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host "PSADT template contract PASSED (PSAppDeployToolkit $($sel.VersionText))" -ForegroundColor Green; exit 0 }
Write-Host "$fail check(s) FAILED (PSAppDeployToolkit $($sel.VersionText))" -ForegroundColor Red
exit 1
