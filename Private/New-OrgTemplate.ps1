function New-OrgTemplate {
    [CmdletBinding()]
    param(
        [PSCustomObject]$ExistingTemplate = $null,
        [string]$TemplateName = '',
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) { $BasePath = Get-Win32ToolkitBasePath }
    $templateFolder = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates
    if (-not (Test-Path $templateFolder)) {
        New-Item -ItemType Directory -Path $templateFolder -Force | Out-Null
    }

    # PsadtVersion is informational only: the PSADT version the selector would use for NEW projects when
    # the template was saved (ORG-14). It is never used to decide anything - a project's real version is
    # derived on demand from its bundled module (Get-Win32ToolkitProjectPsadtVersion). On a fresh machine
    # PSADT is not installed yet (it is pulled in later, during packaging), so a missing or unsupported
    # PSADT, or a selector failure, must give 'unknown' and never block the wizard (issue #49).
    $psadtVer = 'unknown'
    try {
        $psadtSel = Select-Win32ToolkitPsadtModule
        if ($psadtSel -and $psadtSel.Status -eq 'Selected' -and $psadtSel.VersionText) { $psadtVer = [string]$psadtSel.VersionText }
    }
    catch { Write-Verbose "PSADT version for the template not determined: $($_.Exception.Message)" }

    Write-Host ''
    Write-Host '=== Organisation Template Wizard ===' -ForegroundColor Cyan
    Write-Host 'Press Enter on any prompt to keep the default value.' -ForegroundColor DarkGray
    # Editing pre-fills every answer, so Enter keeps the CURRENT value and cannot empty an optional one.
    $editing = $null -ne $ExistingTemplate
    if ($editing) { Write-Host "Editing: Enter keeps the current value. Type '-' to clear an optional value (prompts that show '-' = ...)." -ForegroundColor DarkGray }
    Write-Host ''

    # Optional values (tenant pin, accent, language, progress overrides, Intune texts) pass -Clear: a typed
    # '-' returns ''. When editing, their label's "(blank = X)" becomes "(Enter = keep, '-' = X)"; when
    # creating, the default is already empty, so blank still does what the label says.
    function Read-TV {
        param([string]$P, [string]$D = '', [switch]$Clear)
        if ($Clear -and $editing) { $P = $P -replace '\(blank ?= ?([^)]*)\)$', '(Enter = keep, ''-'' = $1)' }
        $s = if ($D) { "[$D] " } else { '' }
        $v = Read-Host "$P $s"
        if ([string]::IsNullOrWhiteSpace($v)) { $D }
        elseif ($Clear -and $v.Trim() -eq '-') { '' }
        else { $v.Trim() }
    }
    # Read-TB's hint variable must not be called $d: variable names are case-insensitive, so '$d = "n"'
    # overwrote the [bool]$D parameter with [bool]'n' = $true and Enter turned every default into "yes".
    function Read-TB { param([string]$P, [bool]$D) $yn=if($D){'y'}else{'n'}; $v=Read-Host "$P (y/n) [$yn]"; if([string]::IsNullOrWhiteSpace($v)){$D}else{$v.Trim() -in @('y','Y','yes','Yes','1','true','True')} }
    function Read-TI { param([string]$P, [int]$D) $v=Read-Host "$P [$D]"; if([string]::IsNullOrWhiteSpace($v)){$D}else{$n=0;if([int]::TryParse($v.Trim(),[ref]$n)){$n}else{$D}} }

    # D9 / SWP-05: text PSADT expands at runtime, and the close-apps countdowns, are validated as they are
    # typed (Test-Win32ToolkitOrgTemplateText). Each violation is printed and the question is asked again.
    # A value pre-filled from an existing template is validated the same way; once it has been rejected
    # the prompt offers the built-in default ($F) instead, so Enter always has a valid way out.
    function Read-TText {
        param([string]$P, [string]$Field, $D, [string]$F = '', [switch]$Clear)
        $def = if ($null -eq $D) { $F } else { [string]$D }
        while ($true) {
            # A '-' clear gives '', which is still validated (an empty field is "not set": always legal).
            $v = Read-TV $P $def -Clear:$Clear
            $issues = @(Test-Win32ToolkitOrgTemplateText -Field $Field -Value $v)
            if ($issues.Count -eq 0) { return $v }
            foreach ($i in $issues) { Write-Host "  $($i.Message)" -ForegroundColor DarkYellow }
            if (@(Test-Win32ToolkitOrgTemplateText -Field $Field -Value $def).Count -gt 0) { $def = $F }
        }
    }
    function Read-TCountdown {
        param([string]$P, [string]$Field, $D, [int]$F)
        $def = if ($null -eq $D) { $F } else { $D }
        while ($true) {
            $v = Read-Host "$P [$def]"
            $raw = if ([string]::IsNullOrWhiteSpace($v)) { $def } else { $v.Trim() }
            $issues = @(Test-Win32ToolkitOrgTemplateText -Field $Field -Value $raw)
            if ($issues.Count -eq 0) { return [int]$raw }
            foreach ($i in $issues) { Write-Host "  $($i.Message)" -ForegroundColor DarkYellow }
            if (@(Test-Win32ToolkitOrgTemplateText -Field $Field -Value $def).Count -gt 0) { $def = $F }
        }
    }

    Write-Host '--- A: Identity ---' -ForegroundColor Yellow
    $defaultTemplateName = if ($TemplateName) { $TemplateName } else { ${ExistingTemplate}?.TemplateName ?? 'Default' }
    $templateName = Read-TV 'Template name'                                    $defaultTemplateName
    $companyName  = Read-TText 'Company name (shown in dialog subtitles)'      'CompanyName' (${ExistingTemplate}?.CompanyName) 'Your Organisation IT'
    $scriptAuthor = Read-TV 'App script author'                                (${ExistingTemplate}?.AppScriptAuthor ?? 'IT Packaging Team')
    # Pinning the tenant is what lets publish REFUSE the wrong customer. Without it the toolkit cannot
    # know which tenant is correct and can only warn.
    Write-Host '  Pin this template to a customer tenant so publishing to the wrong one is refused.' -ForegroundColor DarkGray
    $unpin = if ($editing) { "'-'" } else { 'Blank' }
    Write-Host "  Tenant GUID or domain (e.g. contoso.onmicrosoft.com). $unpin = unpinned (not recommended)." -ForegroundColor DarkGray
    $tenantId     = Read-TV 'Intune tenant (blank = unpinned)'                 (${ExistingTemplate}?.TenantId ?? '') -Clear

    Write-Host ''; Write-Host '--- B: Branding & dialog style ---' -ForegroundColor Yellow
    # DialogStyle (B2): Fluent = modern v4 look; Classic = v3-style dialogs (uses Banner.Classic.png).
    $dialogStyle = Read-TV 'Dialog style — Fluent or Classic'                    (${ExistingTemplate}?.DialogStyle       ?? 'Fluent')
    if ($dialogStyle -notin @('Fluent','Classic')) {
        Write-Host "  '$dialogStyle' is not valid — using 'Fluent'." -ForegroundColor DarkYellow
        $dialogStyle = 'Fluent'
    }
    $accentColor = Read-TV 'Fluent accent hex e.g. 0xFF0078D7 (blank=default)' (${ExistingTemplate}?.FluentAccentColor ?? '') -Clear
    if (-not [string]::IsNullOrWhiteSpace($accentColor)) {
        $accentNorm = ConvertTo-Win32ToolkitAccentLiteral -Value $accentColor
        if ($accentNorm) { $accentColor = $accentNorm }
        else { Write-Host "  '$accentColor' is not a valid hex colour — ignoring (PSADT default accent). Use 0xAARRGGBB, #RRGGBB, or RRGGBB." -ForegroundColor DarkYellow; $accentColor = '' }
    }
    # Only $envName (PSADT), $env:Name and ${env:Name} variables are allowed (PSADT refuses $(...)).
    $logPath     = Read-TText 'Log path' 'LogPath'                              (${ExistingTemplate}?.LogPath) '$envWinDir\Logs\Software'
    # LanguageOverride (C1): pin all PSADT dialogs to one UI language (e.g. nl, fr-FR, de).
    # Blank = auto-detect the signed-in user's language on-device (works under SYSTEM). PSADT expands this
    # config value too, so only a culture name is accepted (Test-Win32ToolkitOrgTemplateText rule Language).
    $languageOverride = Read-TText 'Force dialog language e.g. nl / fr-FR (blank=auto-detect)' 'LanguageOverride' (${ExistingTemplate}?.LanguageOverride) '' -Clear

    Write-Host ''; Write-Host '--- C: Progress Messages ---' -ForegroundColor Yellow
    Write-Host '  Dialog text must not contain a backtick or a $ followed by a name, {, (, : or ? (PSADT expands it).' -ForegroundColor DarkGray
    $pMsgI = Read-TText 'Progress message - Install'   'ProgressMessage.Install'   (${ExistingTemplate}?.ProgressMessage?.Install)   'Installation in progress. Please wait...'
    $pMsgR = Read-TText 'Progress message - Repair'    'ProgressMessage.Repair'    (${ExistingTemplate}?.ProgressMessage?.Repair)    'Repair in progress. Please wait...'
    $pMsgU = Read-TText 'Progress message - Uninstall' 'ProgressMessage.Uninstall' (${ExistingTemplate}?.ProgressMessage?.Uninstall) 'Uninstallation in progress. Please wait...'
    $pDtlI = Read-TText 'Progress detail - Install'    'ProgressMessageDetail.Install'   (${ExistingTemplate}?.ProgressMessageDetail?.Install)   'This window will close automatically when the installation is complete.'
    $pDtlR = Read-TText 'Progress detail - Repair'     'ProgressMessageDetail.Repair'    (${ExistingTemplate}?.ProgressMessageDetail?.Repair)    'This window will close automatically when the repair is complete.'
    $pDtlU = Read-TText 'Progress detail - Uninstall'  'ProgressMessageDetail.Uninstall' (${ExistingTemplate}?.ProgressMessageDetail?.Uninstall) 'This window will close automatically when the uninstallation is complete.'

    Write-Host ''; Write-Host '--- C: Balloon Notifications ---' -ForegroundColor Yellow
    $balI = Read-TText 'Balloon complete - Install'   'BalloonComplete.Install'   (${ExistingTemplate}?.BalloonComplete?.Install)   'Installation complete.'
    $balR = Read-TText 'Balloon complete - Repair'    'BalloonComplete.Repair'    (${ExistingTemplate}?.BalloonComplete?.Repair)    'Repair complete.'
    $balU = Read-TText 'Balloon complete - Uninstall' 'BalloonComplete.Uninstall' (${ExistingTemplate}?.BalloonComplete?.Uninstall) 'Uninstallation complete.'

    Write-Host ''; Write-Host '--- D: Install Welcome Dialog ---' -ForegroundColor Yellow
    $wEnabled    = Read-TB 'Show Welcome dialog on install'              (${ExistingTemplate}?.WelcomeDialog?.Enabled              ?? $true)
    $wDefer      = Read-TB 'Allow deferral'                              (${ExistingTemplate}?.WelcomeDialog?.AllowDefer           ?? $true)
    $wDeferTimes = Read-TI 'Max deferrals'                               (${ExistingTemplate}?.WelcomeDialog?.DeferTimes           ?? 3)
    $wDisk       = Read-TB 'Check disk space'                            (${ExistingTemplate}?.WelcomeDialog?.CheckDiskSpace       ?? $false)
    $wPersist    = Read-TB 'Persist prompt (user cannot ignore)'         (${ExistingTemplate}?.WelcomeDialog?.PersistPrompt        ?? $true)
    $wBlock      = Read-TB 'Block app re-launch during install'          (${ExistingTemplate}?.WelcomeDialog?.BlockExecution       ?? $true)
    $wCountdown  = Read-TCountdown 'Auto-close countdown seconds (0=off, max 86400)' 'WelcomeDialog.CloseProcessesCountdown' (${ExistingTemplate}?.WelcomeDialog?.CloseProcessesCountdown) 180
    $wCustomText = Read-TB 'Show custom text from strings.psd1'          (${ExistingTemplate}?.WelcomeDialog?.CustomText           ?? $false)

    Write-Host ''; Write-Host '--- D: Uninstall Welcome Dialog ---' -ForegroundColor Yellow
    Write-Host '  (shown only when processes need closing before uninstall)' -ForegroundColor DarkGray
    $uwEnabled   = Read-TB 'Show Welcome dialog on uninstall'            (${ExistingTemplate}?.UninstallWelcomeDialog?.Enabled              ?? $true)
    $uwCountdown = Read-TCountdown 'Auto-close countdown seconds (0=off, max 86400)' 'UninstallWelcomeDialog.CloseProcessesCountdown' (${ExistingTemplate}?.UninstallWelcomeDialog?.CloseProcessesCountdown) 60
    $uwPersist   = Read-TB 'Persist prompt'                              (${ExistingTemplate}?.UninstallWelcomeDialog?.PersistPrompt         ?? $false)
    $uwBlock     = Read-TB 'Block app re-launch during uninstall'        (${ExistingTemplate}?.UninstallWelcomeDialog?.BlockExecution        ?? $false)

    Write-Host ''; Write-Host '--- D: Progress Dialog ---' -ForegroundColor Yellow
    $prEnabled = Read-TB  'Show Progress dialog'                                         (${ExistingTemplate}?.ProgressDialog?.Enabled             ?? $true)
    $prStatus  = Read-TText 'Override status message (blank = use strings.psd1)'           'ProgressDialog.StatusMessage'       (${ExistingTemplate}?.ProgressDialog?.StatusMessage) '' -Clear
    $prDetail  = Read-TText 'Override detail text, Fluent only (blank = use strings.psd1)' 'ProgressDialog.StatusMessageDetail' (${ExistingTemplate}?.ProgressDialog?.StatusMessageDetail) '' -Clear

    Write-Host ''; Write-Host '--- D: Completion Prompt (Post-Install) ---' -ForegroundColor Yellow
    $cpEnabled = Read-TB 'Show completion prompt after install'  (${ExistingTemplate}?.CompletionPrompt?.Enabled         ?? $false)
    $cpMessage = Read-TText 'Completion message' 'CompletionPrompt.Message'       (${ExistingTemplate}?.CompletionPrompt?.Message)         'The installation has completed successfully.'
    $cpButton  = Read-TText 'Button label'       'CompletionPrompt.ButtonRightText' (${ExistingTemplate}?.CompletionPrompt?.ButtonRightText) 'OK'

    Write-Host ''; Write-Host '--- E: Org scripts & extension module (A1/A3) ---' -ForegroundColor Yellow
    $tplFolder = Join-Path $templateFolder $templateName
    Write-Host "  Hook scripts run in every packaged app's deploy phases. Drop .ps1 files in:" -ForegroundColor DarkGray
    Write-Host "    $tplFolder\Hooks\{PreInstall,PostInstall,PreUninstall,PostUninstall,PreRepair,PostRepair}.ps1" -ForegroundColor DarkGray
    Write-Host '  They run on-device under Windows PowerShell 5.1 — keep them 5.1-safe.' -ForegroundColor DarkGray
    $hooksEnabled = Read-TB 'Enable org hook scripts'                    (${ExistingTemplate}?.Hooks?.Enabled ?? $false)
    $hooksFailure = if ($hooksEnabled) {
        $fa = Read-TV 'On hook error — Fail (stop the deploy) or Continue' (${ExistingTemplate}?.Hooks?.FailureAction ?? 'Fail')
        if ($fa -notin @('Fail','Continue')) { Write-Host "  '$fa' invalid — using 'Fail'." -ForegroundColor DarkYellow; 'Fail' } else { $fa }
    } else { (${ExistingTemplate}?.Hooks?.FailureAction ?? 'Fail') }
    Write-Host "  An org extension module (shared functions for your hooks) lives in:" -ForegroundColor DarkGray
    Write-Host "    $tplFolder\PSAppDeployToolkit.<YourOrg>\  (auto-imported by PSADT in every project)" -ForegroundColor DarkGray
    $extModule = Read-TB 'Ship an org PSADT extension module'            (${ExistingTemplate}?.ExtensionModule ?? $false)
    if ($extModule) {
        # D11 (ORG-04 / SWP-01): PSADT 4.2 imports the module from <Folder>\<Folder>.psd1, so a psm1-only
        # folder or a Save-Module '1.0.0\' layout fails EVERY deployment (exit 60001). Applying the template
        # refuses such a module (Add-Win32ToolkitOrgHooks); here we explain the rule and, when the module
        # folder already exists, check it now so the operator can fix it before packaging.
        Write-Host '  The folder must contain a module manifest named exactly like it, e.g.' -ForegroundColor DarkGray
        Write-Host '    PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psd1' -ForegroundColor DarkGray
        Write-Host '  whose RootModule (e.g. PSAppDeployToolkit.Contoso.psm1) exists in the same folder.' -ForegroundColor DarkGray
        Write-Host '  PSADT 4.2 imports that .psd1: a .psm1-only folder or a Save-Module 1.0.0\ layout fails every deployment.' -ForegroundColor DarkGray
        Write-Host '  A RequiredModules entry for PSAppDeployToolkit must be valid for Windows PowerShell 5.1 and must not pin a version.' -ForegroundColor DarkGray
        # The same project-independent rules as Assert-Win32ToolkitOrgExtensionModule (same texts), so the operator
        # learns now what applying the template would refuse (TUI audit G4).
        $extDirs = @(Get-ChildItem -LiteralPath $tplFolder -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^PSAppDeployToolkit\..+' })
        $range = $script:PsadtSupportedRange
        foreach ($ed in $extDirs) {
            foreach ($finding in @(Get-Win32ToolkitOrgExtensionLayoutFinding -ModuleFolder $ed)) {
                Write-Warning "Org extension module '$($finding.Folder)' cannot be used: $($finding.Why) Applying this template will fail until you fix it."
            }
            # The version range (Dv15): the bundled PSADT is not known yet, but a pin, a cap or a minimum above the
            # range's floor fails every project of the other supported version. One warning per entry.
            if (-not $range -or -not $range.Min) { Write-Verbose 'PSADT supported range not set: the RequiredModules version rule is skipped.'; continue }
            $manifest = $null
            try { $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $ed.FullName "$($ed.Name).psd1") -ErrorAction Stop }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Org extension module '$($ed.Name)': manifest not read for the version rule ($($_.Exception.Message))"
                continue
            }
            foreach ($req in @($manifest['RequiredModules'])) {
                if ($null -eq $req -or $req -isnot [hashtable] -or [string]$req['ModuleName'] -ne 'PSAppDeployToolkit') { continue }
                # An entry Windows PowerShell 5.1 rejects is already a finding above.
                try { $null = [Microsoft.PowerShell.Commands.ModuleSpecification]::new($req) }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    continue
                }
                $given = (@($req.Keys | Where-Object { $_ -ne 'ModuleName' } | Sort-Object | ForEach-Object { "$_ = '$($req[$_])'" }) -join '; ')
                $fix = "Declare ModuleVersion = '$($range.Min)' (a minimum) or no version."
                if ($req.ContainsKey('RequiredVersion') -or $req.ContainsKey('MaximumVersion')) {
                    Write-Warning "Org extension module '$($ed.Name)' pins PSAppDeployToolkit ($given): win32-toolkit builds $($range.Display) projects side by side, so projects that bundle a version outside it fail every deployment. $fix"
                }
                elseif ($req.ContainsKey('ModuleVersion')) {
                    $v = $null
                    if ([version]::TryParse([string]$req['ModuleVersion'], [ref]$v) -and $v -gt [version]$range.Min) {
                        Write-Warning "Org extension module '$($ed.Name)' requires PSAppDeployToolkit $v or later ($given): win32-toolkit builds $($range.Display) projects side by side, so projects that bundle a PSAppDeployToolkit older than $v fail every deployment. $fix"
                    }
                }
            }
        }
    }
    Write-Host "  Org branding: drop AppIcon.png (dialogs + Intune tile fallback) and Banner.Classic.png in:" -ForegroundColor DarkGray
    Write-Host "    $tplFolder\Assets\" -ForegroundColor DarkGray
    $customAssets = Read-TB 'Ship org branding assets (logo / banner)'   (${ExistingTemplate}?.CustomAssets ?? $false)
    if ($hooksEnabled -or $extModule -or $customAssets) {
        if (-not (Test-Path $tplFolder)) { New-Item -ItemType Directory -Path $tplFolder -Force | Out-Null }
        if ($hooksEnabled  -and -not (Test-Path (Join-Path $tplFolder 'Hooks')))  { New-Item -ItemType Directory -Path (Join-Path $tplFolder 'Hooks')  -Force | Out-Null }
        if ($customAssets  -and -not (Test-Path (Join-Path $tplFolder 'Assets'))) { New-Item -ItemType Directory -Path (Join-Path $tplFolder 'Assets') -Force | Out-Null }
        Write-Host "  ✓ Prepared $tplFolder — add your files there, then re-run the pipeline." -ForegroundColor DarkGreen
    }

    Write-Host ''; Write-Host '--- F: Intune publish defaults (D2/D3) ---' -ForegroundColor Yellow
    $idMinOS   = Read-TV 'Minimum Windows release (e.g. 1607, 22H2)'      (${ExistingTemplate}?.IntuneDefaults?.MinimumWindowsRelease ?? '1607')
    $idRestart = Read-TV 'Device restart behavior (suppress/allow/force/basedOnReturnCode)' (${ExistingTemplate}?.IntuneDefaults?.DeviceRestartBehavior ?? 'suppress')
    if ($idRestart -notin @('suppress','allow','force','basedOnReturnCode')) { Write-Host "  '$idRestart' invalid — using 'suppress'." -ForegroundColor DarkYellow; $idRestart = 'suppress' }
    $idRuntime = Read-TI 'Max run time (minutes)'                          (${ExistingTemplate}?.IntuneDefaults?.MaxRuntimeMinutes ?? 60)
    if ($idRuntime -le 0) { $idRuntime = 60 }
    $idDesc    = Read-TV 'Description boilerplate appended to every app (blank=none)' (${ExistingTemplate}?.IntuneDefaults?.DescriptionBoilerplate ?? '') -Clear
    $idPrivacy = Read-TV 'Privacy information URL (blank=none)'            (${ExistingTemplate}?.IntuneDefaults?.PrivacyUrl ?? '') -Clear
    $docFooter = Read-TV 'Customer-doc footer line (blank=default)'        (${ExistingTemplate}?.DocFooter ?? '') -Clear

    $template = [PSCustomObject]@{
        TemplateSchemaVersion = $script:TemplateSchemaVersion
        TemplateName          = $templateName
        CompanyName           = $companyName
        AppScriptAuthor       = $scriptAuthor
        TenantId              = $tenantId
        DialogStyle           = $dialogStyle
        FluentAccentColor     = $accentColor
        LogPath               = $logPath
        LanguageOverride      = $languageOverride
        PsadtVersion          = $psadtVer
        ProgressMessage       = [PSCustomObject]@{ Install = $pMsgI; Repair = $pMsgR; Uninstall = $pMsgU }
        ProgressMessageDetail = [PSCustomObject]@{ Install = $pDtlI; Repair = $pDtlR; Uninstall = $pDtlU }
        BalloonComplete       = [PSCustomObject]@{ Install = $balI; Repair = $balR; Uninstall = $balU }
        WelcomeDialog         = [PSCustomObject]@{
            Enabled                 = $wEnabled
            AllowDefer              = $wDefer
            DeferTimes              = $wDeferTimes
            CheckDiskSpace          = $wDisk
            PersistPrompt           = $wPersist
            BlockExecution          = $wBlock
            CloseProcessesCountdown = $wCountdown
            CustomText              = $wCustomText
        }
        UninstallWelcomeDialog = [PSCustomObject]@{
            Enabled                 = $uwEnabled
            CloseProcessesCountdown = $uwCountdown
            PersistPrompt           = $uwPersist
            BlockExecution          = $uwBlock
        }
        ProgressDialog        = [PSCustomObject]@{
            Enabled             = $prEnabled
            StatusMessage       = $prStatus
            StatusMessageDetail = $prDetail
        }
        CompletionPrompt      = [PSCustomObject]@{
            Enabled         = $cpEnabled
            Message         = $cpMessage
            ButtonRightText = $cpButton
        }
        Hooks                 = [PSCustomObject]@{
            Enabled       = $hooksEnabled
            FailureAction = $hooksFailure
        }
        ExtensionModule       = $extModule
        CustomAssets          = $customAssets
        IntuneDefaults        = [PSCustomObject]@{
            MinimumWindowsRelease  = $idMinOS
            DeviceRestartBehavior  = $idRestart
            MaxRuntimeMinutes      = $idRuntime
            DescriptionBoilerplate = $idDesc
            PrivacyUrl             = $idPrivacy
        }
        DocFooter             = $docFooter
    }

    $savePath = Join-Path $templateFolder "$templateName.json"
    $template | ConvertTo-Json -Depth 10 | Set-Content -Path $savePath -Encoding UTF8
    Write-Host ''
    Write-Host "✓ Template '$templateName' saved: $savePath" -ForegroundColor Green
    return $template
}