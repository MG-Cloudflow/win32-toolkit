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

    # Detect installed PSADT version for embedding in template
    $psadtVer = (Get-Module -Name PSAppDeployToolkit -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
    if (-not $psadtVer) { $psadtVer = 'unknown' }

    Write-Host ''
    Write-Host '=== Organisation Template Wizard ===' -ForegroundColor Cyan
    Write-Host 'Only Fluent dialog style is supported.' -ForegroundColor DarkGray
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

    Write-Host ''; Write-Host '--- B: Branding (Fluent only) ---' -ForegroundColor Yellow
    $accentColor = Read-TV 'Fluent accent hex e.g. 0xFF0078D7 (blank=default)' ($ExistingTemplate?.FluentAccentColor ?? '')
    $logPath     = Read-TV 'Log path'                                           ($ExistingTemplate?.LogPath           ?? '$envWinDir\Logs\Software')

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

    $template = [PSCustomObject]@{
        TemplateSchemaVersion = $script:TemplateSchemaVersion
        TemplateName          = $templateName
        CompanyName           = $companyName
        AppScriptAuthor       = $scriptAuthor
        DialogStyle           = 'Fluent'
        FluentAccentColor     = $accentColor
        LogPath               = $logPath
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
    }

    $savePath = Join-Path $templateFolder "$templateName.json"
    $template | ConvertTo-Json -Depth 10 | Set-Content -Path $savePath -Encoding UTF8
    Write-Host ''
    Write-Host "✓ Template '$templateName' saved: $savePath" -ForegroundColor Green
    return $template
}