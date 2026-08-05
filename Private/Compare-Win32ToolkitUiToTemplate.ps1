function Compare-Win32ToolkitUiToTemplate {
    <#
    .SYNOPSIS
        Validates a guest UI-driver state-log against the org template's branding config. HOST-ONLY.
    .DESCRIPTION
        Parses the STATE lines produced by DrivePsadtUi.ps1 (see New-Win32ToolkitUiDriverScript) and
        checks each machine-assertable branding expectation from the org template — company name in the
        subtitle, deferrals offered and the initial count, close-processes countdown, the progress and
        completion dialogs, and which dialogs were reached. Things UI Automation cannot see from a window
        (accent color, logo image, the balloon/toast, exact rendered language) are emitted as GAP checks
        for a human — or Claude reading the captured PNGs — to judge visually.

        Runs on the HOST after the state-log is copied out, so PowerShell 7 syntax is fine here.
    .PARAMETER StateLogPath
        Path to the copied-out uidriver-state.log.
    .PARAMETER Template
        The org template object (as returned by Get-OrgTemplate / parsed template JSON).
    .PARAMETER DeploymentType
        'Install' (default) or 'Uninstall' — selects which template dialog section applies.
    .OUTPUTS
        [PSCustomObject] with .Checks (array of check objects) and .Summary (counts by status).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$StateLogPath,
        [Parameter(Mandatory)] $Template,
        [ValidateSet('Install', 'Uninstall')] [string]$DeploymentType = 'Install'
    )

    if (-not (Test-Path -LiteralPath $StateLogPath)) {
        throw "State log not found: $StateLogPath. Did the guest driver run and get copied out?"
    }

    # --- parse the state log into records -------------------------------------------------------
    $lines = Get-Content -LiteralPath $StateLogPath -ErrorAction Stop
    $states = @()
    $sessionStarted = $false
    $result = $null
    foreach ($line in $lines) {
        if ($line -match ' SESSION_START ') { $sessionStarted = $true; continue }
        if ($line -match ' RESULT (\w+)') { $result = $Matches[1]; continue }
        if ($line -notmatch ' STATE (\w+) ') { continue }
        $stateName = $Matches[1]
        # Each field is KEY='value'; a value may itself contain apostrophes, so capture lazily up to the
        # next " KEY=" boundary (or end of line for the final field).
        function Get-Field([string]$text, [string]$key) {
            $m = [regex]::Match($text, "$key='(.*?)'(?=\s+[A-Za-z]+=|\s*$)")
            if ($m.Success) { return $m.Groups[1].Value }
            $m2 = [regex]::Match($text, "$key=(\d+)")   # bare numeric flags (hasIcon=1)
            if ($m2.Success) { return $m2.Groups[1].Value }
            return ''
        }
        $states += [PSCustomObject]@{
            State       = $stateName
            App         = Get-Field $line 'app'
            Subtitle    = Get-Field $line 'subtitle'
            Message     = Get-Field $line 'msg'
            Custom      = Get-Field $line 'custom'
            Buttons     = Get-Field $line 'buttons'
            Defers      = Get-Field $line 'defers'
            Countdown   = Get-Field $line 'countdown'
            HasIcon     = (Get-Field $line 'hasIcon') -eq '1'
            HasProgress = (Get-Field $line 'hasProgress') -eq '1'
            HasAppsList = (Get-Field $line 'hasAppsList') -eq '1'
            Shot        = Get-Field $line 'shot'
        }
    }

    $checks = [System.Collections.Generic.List[object]]::new()
    function Add-Check {
        param([string]$Name, [string]$Category, [string]$Status, [string]$Expected, [string]$Observed)
        $checks.Add([PSCustomObject]@{
                Name = $Name; Category = $Category; Status = $Status; Expected = $Expected; Observed = $Observed
            })
    }

    $welcome = $states | Where-Object { $_.State -in @('Welcome', 'UninstallWelcome') } | Select-Object -First 1
    $progress = $states | Where-Object { $_.State -eq 'Progress' } | Select-Object -First 1
    $completion = $states | Where-Object { $_.State -eq 'CompletionPrompt' } | Select-Object -First 1
    $unknown = @($states | Where-Object { $_.State -eq 'Unknown' })

    # --- run-level sanity -----------------------------------------------------------------------
    Add-Check 'Driver session started' 'Run' ($(if ($sessionStarted) { 'PASS' } else { 'FAIL' })) 'SESSION_START recorded' ($(if ($sessionStarted) { 'yes' } else { 'no' }))
    Add-Check 'Driver reached a terminal result' 'Run' ($(if ($result -eq 'COMPLETE') { 'PASS' } elseif ($result) { 'WARN' } else { 'FAIL' })) 'RESULT COMPLETE' ($result ?? 'none')
    Add-Check 'Dialogs were observed' 'Run' ($(if ($states.Count -gt 0) { 'PASS' } else { 'FAIL' })) 'at least one PSADT dialog' "$($states.Count) state(s)"
    if ($unknown.Count -gt 0) {
        Add-Check 'Unclassified dialogs' 'Run' 'WARN' 'every dialog classified' "$($unknown.Count) Unknown dialog(s) — review their screenshots"
    }

    # --- dialog style ---------------------------------------------------------------------------
    $style = "$($Template.DialogStyle)"
    if ($style -eq 'Classic') {
        Add-Check 'Dialog style' 'Structural' 'GAP' 'Classic' 'Classic dialogs are not driven by the Fluent AutomationId anchor — validate visually from the screenshots'
    }
    else {
        Add-Check 'Dialog style (Fluent anchor matched)' 'Structural' ($(if ($states.Count -gt 0) { 'PASS' } else { 'WARN' })) 'Fluent' ($(if ($states.Count -gt 0) { 'Fluent dialogs matched by AutomationId' } else { 'no Fluent dialog matched' }))
    }

    # --- company name in the subtitle -----------------------------------------------------------
    $company = "$($Template.CompanyName)"
    if ($company) {
        $subj = $welcome ?? ($states | Select-Object -First 1)
        $seen = ($states | Where-Object { $_.Subtitle -and ($_.Subtitle -like "*$company*") } | Select-Object -First 1)
        Add-Check 'Company name in subtitle' 'Structural' ($(if ($seen) { 'PASS' } else { 'WARN' })) $company ($subj.Subtitle ?? '(no subtitle observed)')
    }

    # --- welcome dialog + deferrals (install) ---------------------------------------------------
    $wcfg = if ($DeploymentType -eq 'Uninstall') { $Template.UninstallWelcomeDialog } else { $Template.WelcomeDialog }
    if ($wcfg -and $wcfg.Enabled) {
        Add-Check 'Welcome dialog reached' 'Structural' ($(if ($welcome) { 'PASS' } else { 'WARN' })) 'enabled -> shown' ($(if ($welcome) { $welcome.State } else { 'not observed (may be skipped when nothing to close)' }))
        if ($welcome -and $DeploymentType -eq 'Install' -and $Template.WelcomeDialog.AllowDefer) {
            $hasDefer = $welcome.Buttons -match 'ButtonRight'
            Add-Check 'Deferral offered' 'Structural' ($(if ($hasDefer) { 'PASS' } else { 'FAIL' })) 'Defer button present' ($welcome.Buttons)
            $want = "$($Template.WelcomeDialog.DeferTimes)"
            if ($want -and $welcome.Defers) {
                Add-Check 'Initial deferrals remaining' 'Structural' ($(if ($welcome.Defers.Trim() -eq $want) { 'PASS' } else { 'WARN' })) $want $welcome.Defers
            }
        }
        $cd = if ($DeploymentType -eq 'Uninstall') { $Template.UninstallWelcomeDialog.CloseProcessesCountdown } else { $Template.WelcomeDialog.CloseProcessesCountdown }
        if ($welcome -and [int]($cd ?? 0) -gt 0) {
            Add-Check 'Close-processes countdown shown' 'Structural' ($(if ($welcome.Countdown) { 'PASS' } else { 'WARN' })) "$cd s configured" ($welcome.Countdown ? "value '$($welcome.Countdown)'" : 'no countdown observed (no apps to close?)')
        }
    }

    # --- progress dialog ------------------------------------------------------------------------
    if ($Template.ProgressDialog -and $Template.ProgressDialog.Enabled) {
        Add-Check 'Progress dialog reached' 'Structural' ($(if ($progress) { 'PASS' } else { 'WARN' })) 'enabled -> shown' ($(if ($progress) { 'observed' } else { 'not observed' }))
        $wantMsg = if ($Template.ProgressDialog.StatusMessage) { $Template.ProgressDialog.StatusMessage } elseif ($DeploymentType -eq 'Uninstall') { $Template.ProgressMessage.Uninstall } else { $Template.ProgressMessage.Install }
        if ($progress -and $wantMsg) {
            $obs = "$($progress.Subtitle) $($progress.Message)"
            Add-Check 'Progress message' 'Content' ($(if ($obs -like "*$wantMsg*") { 'PASS' } else { 'WARN' })) $wantMsg ($obs.Trim() ? $obs.Trim() : '(none observed)')
        }
    }

    # --- completion prompt (install) ------------------------------------------------------------
    if ($DeploymentType -eq 'Install' -and $Template.CompletionPrompt -and $Template.CompletionPrompt.Enabled) {
        Add-Check 'Completion prompt reached' 'Structural' ($(if ($completion) { 'PASS' } else { 'FAIL' })) 'enabled -> shown' ($(if ($completion) { 'observed' } else { 'not observed' }))
        $wantMsg = "$($Template.CompletionPrompt.Message)"
        if ($completion -and $wantMsg) {
            Add-Check 'Completion message' 'Content' ($(if ($completion.Message -like "*$wantMsg*") { 'PASS' } else { 'WARN' })) $wantMsg ($completion.Message ? $completion.Message : '(none)')
        }
        $wantBtn = "$($Template.CompletionPrompt.ButtonRightText)"
        if ($completion -and $wantBtn) {
            Add-Check 'Completion button label' 'Content' ($(if ($completion.Buttons -like "*$wantBtn*") { 'PASS' } else { 'WARN' })) $wantBtn ($completion.Buttons)
        }
    }

    # --- visual / non-assertable (GAP: judged from the PNGs) ------------------------------------
    if ($Template.FluentAccentColor) {
        Add-Check 'Fluent accent color' 'Visual' 'GAP' "$($Template.FluentAccentColor)" 'accent color is not exposed to UI Automation — confirm from the screenshots'
    }
    if ($Template.CustomAssets) {
        Add-Check 'Org logo / banner' 'Visual' 'GAP' 'org AppIcon.png shown' ($(if ($welcome -and $welcome.HasIcon) { 'an icon element is present; confirm it is the org logo from the screenshot' } else { 'confirm the logo from the screenshot' }))
    }
    if ($Template.LanguageOverride) {
        Add-Check 'Dialog language' 'Visual' 'GAP' "$($Template.LanguageOverride)" 'rendered language is best judged visually — confirm button/label language from the screenshots'
    }
    Add-Check 'Balloon / toast notification' 'Visual' 'GAP' "$($Template.BalloonComplete.($DeploymentType))" 'Windows toast is not a PSADT window and is not captured by the driver — confirm manually if required'

    # --- summary --------------------------------------------------------------------------------
    $summary = [PSCustomObject]@{
        Pass = @($checks | Where-Object Status -eq 'PASS').Count
        Fail = @($checks | Where-Object Status -eq 'FAIL').Count
        Warn = @($checks | Where-Object Status -eq 'WARN').Count
        Gap  = @($checks | Where-Object Status -eq 'GAP').Count
    }

    [PSCustomObject]@{
        DeploymentType = $DeploymentType
        Result         = $result
        States         = $states
        Checks         = $checks.ToArray()
        Summary        = $summary
    }
}
