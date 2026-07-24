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

    # Detect the installed PSADT version to embed in the template. On a fresh machine PSADT is not
    # installed yet (it is pulled in later, during packaging), so this MUST tolerate its absence:
    # calling .Version.ToString() on a $null module throws "You cannot call a method on a null-valued
    # expression" and blocks the wizard at first run (issue #49). Bind the module first, then guard.
    $psadtModule = Get-Module -Name PSAppDeployToolkit -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1
    $psadtVer = if ($psadtModule) { $psadtModule.Version.ToString() } else { 'unknown' }

    Write-Host ''
    Write-Host '=== Organisation Template Wizard ===' -ForegroundColor Cyan
    Write-Host 'Press Enter on any prompt to keep the default value.' -ForegroundColor DarkGray
    Write-Host ''

    function Read-TV { param([string]$P, [string]$D='') $s=if($D){"[$D] "}else{''}; $v=Read-Host "$P $s"; if([string]::IsNullOrWhiteSpace($v)){$D}else{$v.Trim()} }
    function Read-TB { param([string]$P, [bool]$D) $d=if($D){'y'}else{'n'}; $v=Read-Host "$P (y/n) [$d]"; if([string]::IsNullOrWhiteSpace($v)){$D}else{$v.Trim() -in @('y','Y','yes','Yes','1','true','True')} }
    function Read-TI { param([string]$P, [int]$D) $v=Read-Host "$P [$D]"; if([string]::IsNullOrWhiteSpace($v)){$D}else{$n=0;if([int]::TryParse($v.Trim(),[ref]$n)){$n}else{$D}} }

    Write-Host '--- A: Identity ---' -ForegroundColor Yellow
    $defaultTemplateName = if ($TemplateName) { $TemplateName } else { $ExistingTemplate?.TemplateName ?? 'Default' }
    $templateName = Read-TV 'Template name'                                    $defaultTemplateName
    $companyName  = Read-TV 'Company name (shown in dialog subtitles)'         ($ExistingTemplate?.CompanyName     ?? 'Your Organisation IT')
    $scriptAuthor = Read-TV 'App script author'                                ($ExistingTemplate?.AppScriptAuthor ?? 'IT Packaging Team')
    # Pinning the tenant is what lets publish REFUSE the wrong customer. Without it the toolkit cannot
    # know which tenant is correct and can only warn.
    Write-Host '  Pin this template to a customer tenant so publishing to the wrong one is refused.' -ForegroundColor DarkGray
    Write-Host '  Tenant GUID or domain (e.g. contoso.onmicrosoft.com). Blank = unpinned (not recommended).' -ForegroundColor DarkGray
    $tenantId     = Read-TV 'Intune tenant (blank = unpinned)'                 ($ExistingTemplate?.TenantId ?? '')

    Write-Host ''; Write-Host '--- B: Branding & dialog style ---' -ForegroundColor Yellow
    # DialogStyle (B2): Fluent = modern v4 look; Classic = v3-style dialogs (uses Banner.Classic.png).
    $dialogStyle = Read-TV 'Dialog style — Fluent or Classic'                    ($ExistingTemplate?.DialogStyle       ?? 'Fluent')
    if ($dialogStyle -notin @('Fluent','Classic')) {
        Write-Host "  '$dialogStyle' is not valid — using 'Fluent'." -ForegroundColor DarkYellow
        $dialogStyle = 'Fluent'
    }
    $accentColor = Read-TV 'Fluent accent hex e.g. 0xFF0078D7 (blank=default)' ($ExistingTemplate?.FluentAccentColor ?? '')
    if (-not [string]::IsNullOrWhiteSpace($accentColor)) {
        $accentNorm = ConvertTo-Win32ToolkitAccentLiteral -Value $accentColor
        if ($accentNorm) { $accentColor = $accentNorm }
        else { Write-Host "  '$accentColor' is not a valid hex colour — ignoring (PSADT default accent). Use 0xAARRGGBB, #RRGGBB, or RRGGBB." -ForegroundColor DarkYellow; $accentColor = '' }
    }
    $logPath     = Read-TV 'Log path'                                           ($ExistingTemplate?.LogPath           ?? '$envWinDir\Logs\Software')
    # LanguageOverride (C1): pin all PSADT dialogs to one UI language (e.g. nl, fr-FR, de).
    # Blank = auto-detect the signed-in user's language on-device (works under SYSTEM).
    $languageOverride = Read-TV 'Force dialog language e.g. nl / fr-FR (blank=auto-detect)' ($ExistingTemplate?.LanguageOverride ?? '')

    Write-Host ''; Write-Host '--- C: Progress Messages ---' -ForegroundColor Yellow
    $pMsgI = Read-TV 'Progress message - Install'   ($ExistingTemplate?.ProgressMessage?.Install   ?? 'Installation in progress. Please wait...')
    $pMsgR = Read-TV 'Progress message - Repair'    ($ExistingTemplate?.ProgressMessage?.Repair    ?? 'Repair in progress. Please wait...')
    $pMsgU = Read-TV 'Progress message - Uninstall' ($ExistingTemplate?.ProgressMessage?.Uninstall ?? 'Uninstallation in progress. Please wait...')
    $pDtlI = Read-TV 'Progress detail - Install'    ($ExistingTemplate?.ProgressMessageDetail?.Install   ?? 'This window will close automatically when the installation is complete.')
    $pDtlR = Read-TV 'Progress detail - Repair'     ($ExistingTemplate?.ProgressMessageDetail?.Repair    ?? 'This window will close automatically when the repair is complete.')
    $pDtlU = Read-TV 'Progress detail - Uninstall'  ($ExistingTemplate?.ProgressMessageDetail?.Uninstall ?? 'This window will close automatically when the uninstallation is complete.')

    Write-Host ''; Write-Host '--- C: Balloon Notifications ---' -ForegroundColor Yellow
    $balI = Read-TV 'Balloon complete - Install'   ($ExistingTemplate?.BalloonComplete?.Install   ?? 'Installation complete.')
    $balR = Read-TV 'Balloon complete - Repair'    ($ExistingTemplate?.BalloonComplete?.Repair    ?? 'Repair complete.')
    $balU = Read-TV 'Balloon complete - Uninstall' ($ExistingTemplate?.BalloonComplete?.Uninstall ?? 'Uninstallation complete.')

    Write-Host ''; Write-Host '--- D: Install Welcome Dialog ---' -ForegroundColor Yellow
    $wEnabled    = Read-TB 'Show Welcome dialog on install'              ($ExistingTemplate?.WelcomeDialog?.Enabled              ?? $true)
    $wDefer      = Read-TB 'Allow deferral'                              ($ExistingTemplate?.WelcomeDialog?.AllowDefer           ?? $true)
    $wDeferTimes = Read-TI 'Max deferrals'                               ($ExistingTemplate?.WelcomeDialog?.DeferTimes           ?? 3)
    $wDisk       = Read-TB 'Check disk space'                            ($ExistingTemplate?.WelcomeDialog?.CheckDiskSpace       ?? $false)
    $wPersist    = Read-TB 'Persist prompt (user cannot ignore)'         ($ExistingTemplate?.WelcomeDialog?.PersistPrompt        ?? $true)
    $wBlock      = Read-TB 'Block app re-launch during install'          ($ExistingTemplate?.WelcomeDialog?.BlockExecution       ?? $true)
    $wCountdown  = Read-TI 'Auto-close countdown seconds (0=off)'        ($ExistingTemplate?.WelcomeDialog?.CloseProcessesCountdown ?? 180)
    $wCustomText = Read-TB 'Show custom text from strings.psd1'          ($ExistingTemplate?.WelcomeDialog?.CustomText           ?? $false)

    Write-Host ''; Write-Host '--- D: Uninstall Welcome Dialog ---' -ForegroundColor Yellow
    Write-Host '  (shown only when processes need closing before uninstall)' -ForegroundColor DarkGray
    $uwEnabled   = Read-TB 'Show Welcome dialog on uninstall'            ($ExistingTemplate?.UninstallWelcomeDialog?.Enabled              ?? $true)
    $uwCountdown = Read-TI 'Auto-close countdown seconds (0=off)'        ($ExistingTemplate?.UninstallWelcomeDialog?.CloseProcessesCountdown ?? 60)
    $uwPersist   = Read-TB 'Persist prompt'                              ($ExistingTemplate?.UninstallWelcomeDialog?.PersistPrompt         ?? $false)
    $uwBlock     = Read-TB 'Block app re-launch during uninstall'        ($ExistingTemplate?.UninstallWelcomeDialog?.BlockExecution        ?? $false)

    Write-Host ''; Write-Host '--- D: Progress Dialog ---' -ForegroundColor Yellow
    $prEnabled = Read-TB  'Show Progress dialog'                                         ($ExistingTemplate?.ProgressDialog?.Enabled             ?? $true)
    $prStatus  = Read-TV  'Override status message (blank = use strings.psd1)'           ($ExistingTemplate?.ProgressDialog?.StatusMessage       ?? '')
    $prDetail  = Read-TV  'Override detail text, Fluent only (blank = use strings.psd1)' ($ExistingTemplate?.ProgressDialog?.StatusMessageDetail ?? '')

    Write-Host ''; Write-Host '--- D: Completion Prompt (Post-Install) ---' -ForegroundColor Yellow
    $cpEnabled = Read-TB 'Show completion prompt after install'  ($ExistingTemplate?.CompletionPrompt?.Enabled         ?? $false)
    $cpMessage = Read-TV 'Completion message'                   ($ExistingTemplate?.CompletionPrompt?.Message         ?? 'The installation has completed successfully.')
    $cpButton  = Read-TV 'Button label'                         ($ExistingTemplate?.CompletionPrompt?.ButtonRightText ?? 'OK')

    Write-Host ''; Write-Host '--- E: Org scripts & extension module (A1/A3) ---' -ForegroundColor Yellow
    $tplFolder = Join-Path $templateFolder $templateName
    Write-Host "  Hook scripts run in every packaged app's deploy phases. Drop .ps1 files in:" -ForegroundColor DarkGray
    Write-Host "    $tplFolder\Hooks\{PreInstall,PostInstall,PreUninstall,PostUninstall,PreRepair,PostRepair}.ps1" -ForegroundColor DarkGray
    Write-Host '  They run on-device under Windows PowerShell 5.1 — keep them 5.1-safe.' -ForegroundColor DarkGray
    $hooksEnabled = Read-TB 'Enable org hook scripts'                    ($ExistingTemplate?.Hooks?.Enabled ?? $false)
    $hooksFailure = if ($hooksEnabled) {
        $fa = Read-TV 'On hook error — Fail (stop the deploy) or Continue' ($ExistingTemplate?.Hooks?.FailureAction ?? 'Fail')
        if ($fa -notin @('Fail','Continue')) { Write-Host "  '$fa' invalid — using 'Fail'." -ForegroundColor DarkYellow; 'Fail' } else { $fa }
    } else { ($ExistingTemplate?.Hooks?.FailureAction ?? 'Fail') }
    Write-Host "  An org extension module (shared functions for your hooks) lives in:" -ForegroundColor DarkGray
    Write-Host "    $tplFolder\PSAppDeployToolkit.<YourOrg>\  (auto-imported by PSADT in every project)" -ForegroundColor DarkGray
    $extModule = Read-TB 'Ship an org PSADT extension module'            ($ExistingTemplate?.ExtensionModule ?? $false)
    Write-Host "  Org branding: drop AppIcon.png (dialogs + Intune tile fallback) and Banner.Classic.png in:" -ForegroundColor DarkGray
    Write-Host "    $tplFolder\Assets\" -ForegroundColor DarkGray
    $customAssets = Read-TB 'Ship org branding assets (logo / banner)'   ($ExistingTemplate?.CustomAssets ?? $false)
    if ($hooksEnabled -or $extModule -or $customAssets) {
        if (-not (Test-Path $tplFolder)) { New-Item -ItemType Directory -Path $tplFolder -Force | Out-Null }
        if ($hooksEnabled  -and -not (Test-Path (Join-Path $tplFolder 'Hooks')))  { New-Item -ItemType Directory -Path (Join-Path $tplFolder 'Hooks')  -Force | Out-Null }
        if ($customAssets  -and -not (Test-Path (Join-Path $tplFolder 'Assets'))) { New-Item -ItemType Directory -Path (Join-Path $tplFolder 'Assets') -Force | Out-Null }
        Write-Host "  ✓ Prepared $tplFolder — add your files there, then re-run the pipeline." -ForegroundColor DarkGreen
    }

    Write-Host ''; Write-Host '--- F: Intune publish defaults (D2/D3) ---' -ForegroundColor Yellow
    $idMinOS   = Read-TV 'Minimum Windows release (e.g. 1607, 22H2)'      ($ExistingTemplate?.IntuneDefaults?.MinimumWindowsRelease ?? '1607')
    $idRestart = Read-TV 'Device restart behavior (suppress/allow/force/basedOnReturnCode)' ($ExistingTemplate?.IntuneDefaults?.DeviceRestartBehavior ?? 'suppress')
    if ($idRestart -notin @('suppress','allow','force','basedOnReturnCode')) { Write-Host "  '$idRestart' invalid — using 'suppress'." -ForegroundColor DarkYellow; $idRestart = 'suppress' }
    $idRuntime = Read-TI 'Max run time (minutes)'                          ($ExistingTemplate?.IntuneDefaults?.MaxRuntimeMinutes ?? 60)
    if ($idRuntime -le 0) { $idRuntime = 60 }
    $idDesc    = Read-TV 'Description boilerplate appended to every app (blank=none)' ($ExistingTemplate?.IntuneDefaults?.DescriptionBoilerplate ?? '')
    $idPrivacy = Read-TV 'Privacy information URL (blank=none)'            ($ExistingTemplate?.IntuneDefaults?.PrivacyUrl ?? '')
    $docFooter = Read-TV 'Customer-doc footer line (blank=default)'        ($ExistingTemplate?.DocFooter ?? '')

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