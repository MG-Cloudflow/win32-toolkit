<#
    D9 - org-template text that PSAppDeployToolkit expands at runtime is rejected, in the wizard AND in
    stored JSON (impact analysis SCF-04 / ORG-06 / OPP-17, SWP-05; spec 2.12, 3.4 tasks 4-5).

    PSADT 4.2 runs the whole strings table through ExpandString whenever a dialog command binds (even in
    Silent mode), and config.psd1 values (CompanyName, LogPath) are expanded at Open-ADTSession on 4.1 and
    4.2. A '$Name', '$(...)', '${...}' or a backtick in template text therefore fails every deployment.

      [1] Test-Win32ToolkitOrgTemplateText -Field/-Value: every rule (Dollar, Backtick, Whitespace,
          LogPath, Countdown, Language), the legal cases ('US$ 5', ${env:...}, fr-FR), $null = not set
      [2] Test-Win32ToolkitOrgTemplateText -Template: every field, missing fields OK, AppScriptAuthor free
      [3] Assert-Win32ToolkitOrgTemplateText: ONE W32T.OrgTemplateInvalid listing every violation + the fix
      [4] New-OrgTemplate wizard: typed answers re-prompted until valid; countdowns 0..86400; an invalid
          value pre-filled from an existing template is re-prompted, then the built-in default is offered;
          an existing template really pre-fills the wizard; editing, '-' clears an optional value
          (e.g. unpins the tenant); D11 extension-module warning
      [5] Get-OrgTemplate: a stored template with bad text throws on every load path; -SkipTextValidation
      [6] Connect-Win32ToolkitIntune reads TenantId from such a template without being blocked

    Nothing touches the registry, PSADT, Graph or the network: Read-Host, the base path and the Graph
    helpers are shadowed; templates live in a scratch folder under %TEMP%.

    Run:  pwsh -File Tests\OrgTemplateText.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in @(
    'Private\Test-Win32ToolkitOrgTemplateText.ps1',
    'Private\Assert-Win32ToolkitOrgTemplateText.ps1',
    'Private\Get-Win32ToolkitPaths.ps1',
    'Private\ConvertTo-Win32ToolkitAccentLiteral.ps1',
    'Private\Update-OrgTemplateIfNeeded.ps1',
    'Private\Get-Win32ToolkitOrgExtensionLayoutFinding.ps1',   # C-9 (TUI audit G4): the wizard's extension module check
    'Private\New-OrgTemplate.ps1',
    'Private\Get-OrgTemplate.ps1',
    'Public\Connect-Win32ToolkitIntune.ps1')) {
    . (Join-Path $repo $f)
}
$script:TemplateSchemaVersion = '4.0'
# The supported PSADT range (a copy of win32-toolkit.psm1): the template wizard's RequiredModules version rule reads it.
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

# ---- shadows -----------------------------------------------------------------------------------
# Shadows take no parameters they do not read: a simple function puts any extra named argument in $args.
# Read-Host: scripted answers per prompt prefix (a queue each); anything unscripted answers '' (Enter).
# Defined through the function: drive so this suite does not redefine a built-in cmdlet by declaration.
$script:answers   = @{}
$script:promptLog = [System.Collections.Generic.List[string]]::new()
Set-Item -Path 'function:script:Read-Host' -Value {
    param($Prompt)
    $p = [string]$Prompt
    $script:promptLog.Add($p)
    if ($script:promptLog.Count -gt 500) { throw 'Read-Host called more than 500 times - the wizard is looping' }
    foreach ($k in $script:answers.Keys) {
        if ($p.StartsWith($k) -and $script:answers[$k].Count -gt 0) { return $script:answers[$k].Dequeue() }
    }
    ''
}
function Use-ScriptedAnswer {
    param([hashtable]$Map = @{})
    $script:answers = @{}
    foreach ($k in $Map.Keys) {
        $q = [System.Collections.Generic.Queue[string]]::new()
        foreach ($a in @($Map[$k])) { $q.Enqueue([string]$a) }
        $script:answers[$k] = $q
    }
    $script:promptLog.Clear()
}
function Get-PromptCount { param([string]$Prefix) @($script:promptLog | Where-Object { $_.StartsWith($Prefix) }).Count }
# C-9 (test campaign 2026-10-21, S12-F1): Update-OrgTemplateIfNeeded asks whether anybody can answer a prompt.
# Shadowed - the real probes depend on the host this suite runs under (CI may run it -NonInteractive) - and
# interactive unless a case says otherwise.
$script:nonInteractiveHost = $false; $script:nonInteractiveSwitch = $false
function Test-Win32ToolkitHostNonInteractive { $script:nonInteractiveHost }
function Test-Win32ToolkitNonInteractiveSwitch { $script:nonInteractiveSwitch }
function Get-Prompt { param([string]$Prefix) @($script:promptLog | Where-Object { $_.StartsWith($Prefix) }) }

# WP-A's selector is not part of this suite: report "no PSADT".
function Select-Win32ToolkitPsadtModule { [pscustomobject]@{ Status = 'NoneInstalled'; VersionText = '' } }
# Never resolve the registry-backed base path.
function Get-Win32ToolkitBasePath { $script:connectBase }
# Graph helpers used by Connect-Win32ToolkitIntune: record, never connect.
$script:graphCall = $null
function Connect-Win32ToolkitGraph {
    param([string]$TenantId)
    $script:graphCall = [pscustomobject]@{ TenantId = $TenantId }
    [pscustomobject]@{ TenantId = $TenantId; Account = 'tester@contoso.com'; Scopes = @('DeviceManagementApps.ReadWrite.All') }
}
function Show-Win32ToolkitTenantBanner { }
function Get-Win32ToolkitTenantInfo { $null }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-ot-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Rules { param($v) (@($v) | ForEach-Object { $_.Rule }) -join ',' }
function FieldCheck { param([string]$Field, $Value) @(Test-Win32ToolkitOrgTemplateText -Field $Field -Value $Value) }

# A complete, valid template (New-OrgTemplate schema 4.0).
function Get-ValidTemplate {
    param([string]$Name = 'Contoso')
    [pscustomobject]@{
        TemplateSchemaVersion = '4.0'
        TemplateName          = $Name
        CompanyName           = 'Contoso IT'
        AppScriptAuthor       = 'Packaging Team'
        TenantId              = ''
        DialogStyle           = 'Fluent'
        FluentAccentColor     = ''
        LogPath               = '$envWinDir\Logs\Software'
        LanguageOverride      = ''
        PsadtVersion          = 'unknown'
        ProgressMessage       = [pscustomobject]@{ Install = 'Installing. Please wait...'; Repair = 'Repairing...'; Uninstall = 'Removing...' }
        ProgressMessageDetail = [pscustomobject]@{ Install = 'Closes when done.'; Repair = 'Closes when done.'; Uninstall = 'Closes when done.' }
        BalloonComplete       = [pscustomobject]@{ Install = 'Installation complete.'; Repair = 'Repair complete.'; Uninstall = 'Uninstallation complete.' }
        WelcomeDialog         = [pscustomobject]@{ Enabled = $true; AllowDefer = $true; DeferTimes = 3; CheckDiskSpace = $false; PersistPrompt = $true; BlockExecution = $true; CloseProcessesCountdown = 180; CustomText = $false }
        UninstallWelcomeDialog = [pscustomobject]@{ Enabled = $true; CloseProcessesCountdown = 60; PersistPrompt = $false; BlockExecution = $false }
        ProgressDialog        = [pscustomobject]@{ Enabled = $true; StatusMessage = ''; StatusMessageDetail = '' }
        CompletionPrompt      = [pscustomobject]@{ Enabled = $false; Message = 'The installation has completed successfully.'; ButtonRightText = 'OK' }
        Hooks                 = [pscustomobject]@{ Enabled = $false; FailureAction = 'Fail' }
        ExtensionModule       = $false
        CustomAssets          = $false
        IntuneDefaults        = [pscustomobject]@{ MinimumWindowsRelease = '1607'; DeviceRestartBehavior = 'suppress'; MaxRuntimeMinutes = 60; DescriptionBoilerplate = ''; PrivacyUrl = '' }
        DocFooter             = ''
    }
}

$bt = [string][char]0x60   # backtick, built so this file never has to contain an escape sequence

try {
    # =============================================================================================
    Write-Host "`n[1] -Field / -Value: every rule" -ForegroundColor Cyan
    $textFields = @(
        'CompanyName',
        'ProgressMessage.Install', 'ProgressMessage.Repair', 'ProgressMessage.Uninstall',
        'ProgressMessageDetail.Install', 'ProgressMessageDetail.Repair', 'ProgressMessageDetail.Uninstall',
        'BalloonComplete.Install', 'BalloonComplete.Repair', 'BalloonComplete.Uninstall',
        'ProgressDialog.StatusMessage', 'ProgressDialog.StatusMessageDetail',
        'CompletionPrompt.Message', 'CompletionPrompt.ButtonRightText')

    # Dollar: '$' + name char / { / ( / : / ?  -> rejected; 'US$ 5' and a trailing '$' are fine.
    # '$$' / '$^' (S10-F3): automatic variables PSADT expands silently to empty text.
    $dollarBad  = @('Contact $Helpdesk', '$5', 'Cost: US$5', '$(Get-Date)', '${C:\x}', '${x}', 'a $_ b', '$:x', '$?', 'Ca$h IT', '$envWinDir',
                    'Contoso $$ IT', 'Contoso $^ IT', 'US$$ 5', 'ends $$')
    $dollarGood = @('US$ 5', 'Price $ 10', 'ends with $', 'Plain text, no dollar', '', 'Smile :-) (ok)')
    foreach ($field in $textFields) {
        $okAll = $true
        foreach ($v in $dollarBad)  { if ((Rules (FieldCheck $field $v)) -notmatch '\bDollar\b') { $okAll = $false; Bad "$field '$v' not rejected (Dollar)" } }
        foreach ($v in $dollarGood) { if (@(FieldCheck $field $v).Count -ne 0) { $okAll = $false; Bad "$field '$v' wrongly rejected: $(Rules (FieldCheck $field $v))" } }
        if ($okAll) { Ok "$field - Dollar rule ($($dollarBad.Count) rejected, $($dollarGood.Count) legal incl. 'US$ 5')" }
    }
    $m5 = FieldCheck 'CompanyName' 'Cost $5'
    if ($m5.Count -eq 1 -and $m5[0].Rule -eq 'Dollar' -and $m5[0].Field -eq 'CompanyName' -and $m5[0].Message -match [regex]::Escape("'`$5'")) { Ok "'`$5' rejected; violation names the field and the token" } else { Bad "`$5 -> $($m5 | Out-String)" }

    # Backtick: anywhere, in every text field and in LogPath.
    foreach ($field in @($textFields + 'LogPath')) {
        $vb = FieldCheck $field ("Line one${bt}nLine two")
        $vt = FieldCheck $field ("trailing$bt")
        if ((Rules $vb) -match 'Backtick' -and (Rules $vt) -match 'Backtick') { } else { Bad "$field backtick not rejected ($(Rules $vb) / $(Rules $vt))" }
    }
    Ok 'a backtick (escape sequence or trailing) is rejected in every text field and in LogPath'

    # Whitespace-only text: rejected; empty stays legal (= "not set").
    foreach ($ws in @('  ', "`t", " `t ")) {
        $vw = FieldCheck 'CompletionPrompt.ButtonRightText' $ws
        if ((Rules $vw) -eq 'Whitespace') { } else { Bad "whitespace-only '$ws' -> $(Rules $vw)" }
    }
    if ((Rules (FieldCheck 'ProgressMessage.Install' '  ')) -eq 'Whitespace') { Ok "'  ' (whitespace only) rejected (Whitespace)" } else { Bad "'  ' not rejected" }
    if ((FieldCheck 'ProgressDialog.StatusMessage' '').Count -eq 0) { Ok "'' (empty) is legal" } else { Bad "'' rejected" }

    # LogPath allow-list: only environment variables.
    foreach ($lp in @('$envWinDir\Logs\Software', '$env:ProgramData\Logs', '${env:ProgramData}\Logs', '${env:SystemDrive}\Logs\Apps',
                      '$envProgramFilesX86\Vendor\Logs', 'D:\Logs\Software', "C:\Logs\O'Neil", '$ENVWINDIR\Logs')) {
        $vl = FieldCheck 'LogPath' $lp
        if ($vl.Count -eq 0) { } else { Bad "LogPath '$lp' wrongly rejected: $(Rules $vl)" }
    }
    Ok 'LogPath: $envName, $env:Name, ${env:Name} and literal paths are legal'
    foreach ($lp in @('$(Get-Date)', 'C:\Logs\$(whoami)', '${C:\x}', '${function:prompt}\x', 'C:\Logs\$user', '$global:x\Logs', 'US$ 5', 'C:\$')) {
        $vl = FieldCheck 'LogPath' $lp
        if ((Rules $vl) -match '\bLogPath\b') { } else { Bad "LogPath '$lp' not rejected: $(Rules $vl)" }
    }
    Ok 'LogPath: $(...), ${C:\x}, ${provider:...}, other variables and a bare $ are rejected (LogPath)'
    if ((Rules (FieldCheck 'LogPath' '${env:ProgramData}\Logs')) -eq '') { Ok "'`${env:ProgramData}\Logs' OK" } else { Bad '${env:ProgramData}\Logs rejected' }
    if ((Rules (FieldCheck 'LogPath' '$(Get-Date)')) -match 'LogPath') { Ok "'`$(Get-Date)' rejected" } else { Bad '$(Get-Date) accepted' }
    if ((Rules (FieldCheck 'LogPath' '${C:\x}')) -match 'LogPath') { Ok "'`${C:\x}' rejected" } else { Bad '${C:\x} accepted' }

    # Countdown: whole number 0..86400.
    foreach ($cf in @('WelcomeDialog.CloseProcessesCountdown', 'UninstallWelcomeDialog.CloseProcessesCountdown')) {
        foreach ($good in @(0, 1, 180, 86400, [long]60, [int16]5, [double]120, '300', ' 42 ')) {
            if ((FieldCheck $cf $good).Count -ne 0) { Bad "$cf '$good' ($($good.GetType().Name)) wrongly rejected" }
        }
        foreach ($badV in @(86401, -1, [long]100000, 1.5, 'abc', '', '0x10', $true, [double]::NaN)) {
            if ((Rules (FieldCheck $cf $badV)) -ne 'Countdown') { Bad "$cf '$badV' not rejected" }
        }
    }
    Ok 'countdowns: 0, 180, 86400 (int/long/double/string) legal; 86401, -1, 1.5, text, bool rejected'
    if ((Rules (FieldCheck 'WelcomeDialog.CloseProcessesCountdown' 86401)) -eq 'Countdown') { Ok '86401 rejected (Countdown)' } else { Bad '86401 accepted' }

    # Language: LanguageOverride is a config.psd1 string PSADT expands and then casts to [CultureInfo];
    # only a culture name is accepted ('nl$(1+1)' would run code on 4.1 and fail every 4.2 deployment).
    $langGood = @('nl', 'NL', 'fr-FR', 'zh-Hans', 'ZH-Hant', 'sr-Latn-RS', 'CZ', 'pt-BR', 'gsw-CH', '', '   ')
    $langBad  = @('nl$(1+1)', '$env:LANG', 'Dutch', 'nl_NL', 'fr-', '-fr', "nl$bt", 'n', 'nl fr', ' nl', "nl`n", 'nl-ABCDEFGHI', 'nl;x', '${x}')
    $langOk = $true
    foreach ($v in $langGood) { if (@(FieldCheck 'LanguageOverride' $v).Count -ne 0) { $langOk = $false; Bad "LanguageOverride '$v' wrongly rejected" } }
    foreach ($v in $langBad)  { if ((Rules (FieldCheck 'LanguageOverride' $v)) -ne 'Language') { $langOk = $false; Bad "LanguageOverride '$v' not rejected (Language): $(Rules (FieldCheck 'LanguageOverride' $v))" } }
    if ($langOk) { Ok "LanguageOverride: culture names and blank legal; $($langBad.Count) others (incl. 'nl`$(1+1)', a trailing newline) rejected with one Language violation" }
    $lv = FieldCheck 'LanguageOverride' 'nl$(1+1)'
    if ($lv.Count -eq 1 -and $lv[0].Field -eq 'LanguageOverride' -and $lv[0].Message -match [regex]::Escape("'nl`$(1+1)'")) { Ok 'the Language violation names the field and the value' } else { Bad "Language violation: $($lv | Out-String)" }

    # $null = not set.
    $nulls = @(foreach ($f in @($textFields + 'LogPath' + 'WelcomeDialog.CloseProcessesCountdown' + 'LanguageOverride')) { FieldCheck $f $null })
    if ($nulls.Count -eq 0) { Ok '$null (not set) is never a violation' } else { Bad "$($nulls.Count) violation(s) for `$null" }

    # Unknown field name = programming error.
    $threw = $false
    try { $null = Test-Win32ToolkitOrgTemplateText -Field 'AppScriptAuthor' -Value 'x' } catch { $threw = $true }
    if ($threw) { Ok 'an unknown -Field (e.g. AppScriptAuthor) is a parameter error' } else { Bad 'unknown -Field accepted' }

    # Several rules on one value are all reported.
    $multi = FieldCheck 'CompanyName' ("Ca`$h${bt} IT")
    if ((Rules $multi) -match 'Dollar' -and (Rules $multi) -match 'Backtick') { Ok 'a value breaking two rules yields two violations' } else { Bad "multi -> $(Rules $multi)" }

    # =============================================================================================
    Write-Host "`n[2] -Template: every field, older schemas, AppScriptAuthor" -ForegroundColor Cyan
    $valid = Get-ValidTemplate
    $vv = @(Test-Win32ToolkitOrgTemplateText -Template $valid)
    if ($vv.Count -eq 0) { Ok 'a valid full template has no violation' } else { Bad "valid template -> $(Rules $vv) / $($vv.Field -join ',')" }

    $badT = Get-ValidTemplate
    $badT.CompanyName = 'Ca$h IT'
    $badT.LogPath = 'C:\Logs\$(whoami)'
    $badT.ProgressMessage.Install = 'Contact $Helpdesk'
    $badT.ProgressMessageDetail.Repair = "Line${bt}n2"
    $badT.BalloonComplete.Uninstall = '   '
    $badT.ProgressDialog.StatusMessage = '$5 off'
    $badT.ProgressDialog.StatusMessageDetail = '${x}'
    $badT.CompletionPrompt.Message = 'Done $(Get-Date)'
    $badT.CompletionPrompt.ButtonRightText = ' '
    $badT.WelcomeDialog.CloseProcessesCountdown = 86401
    $badT.UninstallWelcomeDialog.CloseProcessesCountdown = -5
    $badT.LanguageOverride = 'nl$(1+1)'
    $badT.AppScriptAuthor = 'Team $Packaging'   # NOT validated: data in AppConfig.json, never expanded
    $bv = @(Test-Win32ToolkitOrgTemplateText -Template $badT)
    $expect = [ordered]@{
        'CompanyName'                                    = 'Dollar'
        'LogPath'                                        = 'LogPath'
        'ProgressMessage.Install'                        = 'Dollar'
        'ProgressMessageDetail.Repair'                   = 'Backtick'
        'BalloonComplete.Uninstall'                      = 'Whitespace'
        'ProgressDialog.StatusMessage'                   = 'Dollar'
        'ProgressDialog.StatusMessageDetail'             = 'Dollar'
        'CompletionPrompt.Message'                       = 'Dollar'
        'CompletionPrompt.ButtonRightText'               = 'Whitespace'
        'WelcomeDialog.CloseProcessesCountdown'          = 'Countdown'
        'UninstallWelcomeDialog.CloseProcessesCountdown' = 'Countdown'
        'LanguageOverride'                               = 'Language'
    }
    $got = @{}; foreach ($x in $bv) { $got[$x.Field] = $x.Rule }
    $allMatch = $bv.Count -eq $expect.Count
    foreach ($k in $expect.Keys) { if ($got[$k] -ne $expect[$k]) { $allMatch = $false; Bad "$k -> '$($got[$k])' (expected $($expect[$k]))" } }
    if ($allMatch) { Ok "every field is checked: $($bv.Count) violations, one per broken field, right rule each" } else { Bad "got: $(($bv | ForEach-Object { "$($_.Field)=$($_.Rule)" }) -join '; ')" }
    if (-not $got.ContainsKey('AppScriptAuthor')) { Ok 'AppScriptAuthor is not validated (data, never expanded)' } else { Bad 'AppScriptAuthor validated' }
    $shape = $bv[0]
    if ($shape.PSObject.Properties['Field'] -and $shape.PSObject.Properties['Rule'] -and $shape.PSObject.Properties['Message'] -and $shape.Message) { Ok 'violation objects carry Field / Rule / Message' } else { Bad 'violation shape' }

    $old = [pscustomobject]@{ TemplateName = 'Old'; CompanyName = 'Old Co'; LogPath = 'C:\Logs' }   # schema 1.0: no dialog sections at all
    if (@(Test-Win32ToolkitOrgTemplateText -Template $old).Count -eq 0) { Ok 'missing fields (older schema) produce no violation' } else { Bad 'older schema flagged' }
    $partial = [pscustomobject]@{ TemplateName = 'P'; ProgressMessage = [pscustomobject]@{ Install = 'ok' }; WelcomeDialog = [pscustomobject]@{ Enabled = $true } }
    if (@(Test-Win32ToolkitOrgTemplateText -Template $partial).Count -eq 0) { Ok 'missing sub-fields (no Repair/Uninstall, no countdown) produce no violation' } else { Bad 'partial template flagged' }
    $fromJson = ($badT | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    if (@(Test-Win32ToolkitOrgTemplateText -Template $fromJson).Count -eq $expect.Count) { Ok 'a template read back from JSON (Int64 countdowns) gives the same violations' } else { Bad 'JSON round-trip differs' }
    $ht = @{ TemplateName = 'H'; CompanyName = 'Ca$h'; WelcomeDialog = @{ CloseProcessesCountdown = 90000 } }
    if ((Rules (Test-Win32ToolkitOrgTemplateText -Template $ht)) -eq 'Dollar,Countdown') { Ok 'a hashtable-shaped template is read too' } else { Bad "hashtable -> $(Rules (Test-Win32ToolkitOrgTemplateText -Template $ht))" }

    # =============================================================================================
    Write-Host "`n[3] Assert: one W32T.OrgTemplateInvalid listing every violation" -ForegroundColor Cyan
    $noThrow = $true
    try { Assert-Win32ToolkitOrgTemplateText -Template $valid } catch { $noThrow = $false }
    if ($noThrow) { Ok 'a valid template passes silently' } else { Bad 'valid template threw' }
    $out = Assert-Win32ToolkitOrgTemplateText -Template $valid
    if ($null -eq $out) { Ok 'returns nothing on success' } else { Bad 'Assert returned output' }

    $err = $null
    try { Assert-Win32ToolkitOrgTemplateText -Template $badT -Context 'apply' } catch { $err = $_ }
    if ($err -and $err.FullyQualifiedErrorId -eq 'W32T.OrgTemplateInvalid') { Ok 'throws FQID W32T.OrgTemplateInvalid' } else { Bad "FQID = [$($err.FullyQualifiedErrorId)]" }
    if ($err -and $err.CategoryInfo.Category -eq 'InvalidData' -and $err.Exception -is [System.InvalidOperationException]) { Ok 'InvalidOperationException, category InvalidData (spec C-1)' } else { Bad 'error shape' }
    if ($err -and [object]::ReferenceEquals($err.TargetObject, $badT)) { Ok 'TargetObject is the template' } else { Bad 'TargetObject' }
    $msg = if ($err) { $err.Exception.Message } else { '' }
    $listed = @($expect.Keys | Where-Object { $msg -match ('(?m)^  - ' + [regex]::Escape($_) + ':') })
    if ($listed.Count -eq $expect.Count) { Ok "the ONE message lists all $($expect.Count) violations" } else { Bad "message lists $($listed.Count)/$($expect.Count): $msg" }
    if ($msg -match '\(apply\)') { Ok 'the -Context is named' } else { Bad 'context missing' }
    if ($msg -match [regex]::Escape("Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'") -and $msg -match [regex]::Escape('Templates\Contoso.json')) { Ok 'the fix names the wizard command and Templates\<name>.json' } else { Bad "fix text: $msg" }
    # -NewTemplate does not pre-fill (it starts from the built-in defaults and overwrites the file), so the
    # hint must offer the TUI edit path as the edit and describe -NewTemplate as a re-create.
    $fixLine = @($msg -split '\r?\n' | Where-Object { $_ -like 'Fix:*' }) | Select-Object -Last 1
    if ($fixLine -match [regex]::Escape('Org templates > Edit a template (pre-filled') -and
        $fixLine -match [regex]::Escape("-TemplateName 'Contoso' re-creates the template from the built-in defaults") -and
        $fixLine -notmatch 'edit the template in the wizard') { Ok 'the fix line calls only the pre-filled TUI path an edit; -NewTemplate is a re-create' } else { Bad "fix line: $fixLine" }
    $err2 = $null
    try { Assert-Win32ToolkitOrgTemplateText -Template $badT } catch { $err2 = $_ }
    if ($err2 -and $err2.Exception.Message -match [regex]::Escape("(template 'Contoso')")) { Ok "default context = template '<name>'" } else { Bad "default context: $($err2.Exception.Message)" }
    # Re-throw contract (spec C-2): the FQID survives a catch + bare throw.
    $err3 = $null
    try { try { Assert-Win32ToolkitOrgTemplateText -Template $badT } catch { if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw } } } catch { $err3 = $_ }
    if ($err3 -and $err3.FullyQualifiedErrorId -eq 'W32T.OrgTemplateInvalid') { Ok 'FQID survives a C-2 re-throw' } else { Bad 'FQID lost on re-throw' }

    # =============================================================================================
    Write-Host "`n[4] Wizard (New-OrgTemplate): validated answers, re-prompts, pre-fill, D11" -ForegroundColor Cyan
    $wizBase = Join-Path $root 'wiz'
    New-Item -ItemType Directory -Path $wizBase -Force | Out-Null
    function Invoke-Wizard {
        param([string]$Name, $Existing = $null)
        $res = [pscustomobject]@{ Template = $null; Error = $null; Info = @(); Warnings = @() }
        $wv = $null
        try {
            $all = @(New-OrgTemplate -BasePath $wizBase -TemplateName $Name -ExistingTemplate $Existing -WarningVariable wv -WarningAction SilentlyContinue 6>&1)
            $res.Info     = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            $res.Template = $all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
        }
        catch { $res.Error = $_.Exception.Message }
        $res.Warnings = @($wv | ForEach-Object { [string]$_ })
        $res
    }

    # 4a: typed invalid answers are rejected and asked again.
    Use-ScriptedAnswer @{
        'Company name'                    = @('Ca$h IT', 'Cash IT')
        'Progress message - Install'      = @('Contact $Helpdesk now', 'Contact the Helpdesk now')
        'Balloon complete - Install'      = @("Done${bt}n", 'Done.')
        'Log path'                        = @('C:\Logs\$(whoami)', '${env:ProgramData}\Logs\Contoso')
        'Auto-close countdown'            = @('86401', 'abc', '-5', '120')
        'Override status message'         = @('   ')
        'Button label'                    = @('$x', 'Close')
        'Force dialog language'           = @('nl$(1+1)', 'Dutch', 'fr-FR')
    }
    $w = Invoke-Wizard 'Typed'
    if (-not $w.Error) { Ok 'wizard completed' } else { Bad "wizard threw: $($w.Error)" }
    $t = $w.Template
    if ($t.CompanyName -eq 'Cash IT' -and (Get-PromptCount 'Company name') -eq 2) { Ok "CompanyName 'Ca`$h IT' rejected, asked again, 'Cash IT' kept" } else { Bad "CompanyName=[$($t.CompanyName)] prompts=$(Get-PromptCount 'Company name')" }
    if ($t.ProgressMessage.Install -eq 'Contact the Helpdesk now' -and (Get-PromptCount 'Progress message - Install') -eq 2) { Ok 'progress message with $Helpdesk re-prompted' } else { Bad "ProgressMessage.Install=[$($t.ProgressMessage.Install)]" }
    if ($t.BalloonComplete.Install -eq 'Done.' -and (Get-PromptCount 'Balloon complete - Install') -eq 2) { Ok 'balloon text with a backtick re-prompted' } else { Bad "BalloonComplete.Install=[$($t.BalloonComplete.Install)]" }
    if ($t.LogPath -eq '${env:ProgramData}\Logs\Contoso' -and (Get-PromptCount 'Log path') -eq 2) { Ok 'LogPath with $(...) re-prompted; ${env:...} accepted' } else { Bad "LogPath=[$($t.LogPath)]" }
    if ($t.ProgressDialog.StatusMessage -eq '' -and (Get-PromptCount 'Override status message') -eq 1) { Ok "typed whitespace counts as Enter: the (empty) default is kept, never '   '" } else { Bad "StatusMessage=[$($t.ProgressDialog.StatusMessage)] prompts=$(Get-PromptCount 'Override status message')" }
    if ($t.CompletionPrompt.ButtonRightText -eq 'Close') { Ok 'button label $x re-prompted' } else { Bad "ButtonRightText=[$($t.CompletionPrompt.ButtonRightText)]" }
    if ($t.LanguageOverride -eq 'fr-FR' -and (Get-PromptCount 'Force dialog language') -eq 3) { Ok "dialog language 'nl`$(1+1)' and 'Dutch' rejected, asked again, 'fr-FR' kept" } else { Bad "LanguageOverride=[$($t.LanguageOverride)] prompts=$(Get-PromptCount 'Force dialog language')" }
    if ($t.WelcomeDialog.CloseProcessesCountdown -eq 120 -and $t.WelcomeDialog.CloseProcessesCountdown -is [int]) { Ok 'install countdown: 86401, abc, -5 rejected, 120 kept (as [int])' } else { Bad "install countdown=[$($t.WelcomeDialog.CloseProcessesCountdown)]" }
    if ($t.UninstallWelcomeDialog.CloseProcessesCountdown -eq 60) { Ok 'uninstall countdown default 60 accepted' } else { Bad "uninstall countdown=[$($t.UninstallWelcomeDialog.CloseProcessesCountdown)]" }
    if ((Get-PromptCount 'Auto-close countdown') -eq 5) { Ok 'countdown asked 4x (install) + 1x (uninstall)' } else { Bad "countdown prompts=$(Get-PromptCount 'Auto-close countdown')" }
    if (@($w.Info | Where-Object { $_ -match '^  CompanyName: ' -and $_ -match 'Ca\$h IT' }).Count -ge 1) { Ok 'the violation is printed to the operator' } else { Bad "no violation message printed: $($w.Info -join ' | ')" }
    if (@(Test-Win32ToolkitOrgTemplateText -Template $t).Count -eq 0) { Ok 'the saved template passes the stored-JSON check' } else { Bad 'wizard saved an invalid template' }
    $savedJson = Get-Content -LiteralPath (Join-Path $wizBase 'Templates\Typed.json') -Raw | ConvertFrom-Json
    if (@(Test-Win32ToolkitOrgTemplateText -Template $savedJson).Count -eq 0 -and $savedJson.CompanyName -eq 'Cash IT') { Ok 'Templates\Typed.json written with the valid answers' } else { Bad 'saved JSON wrong' }

    # 4b: editing an existing template really pre-fills it. Two regressions: '$ExistingTemplate?.X' parsed
    # as the variable 'ExistingTemplate?' (so every edit silently reset every answer to the built-in
    # default), and Read-TB's '$d' hint variable overwrote its [bool]$D default (Enter = always "yes").
    $ex = Get-ValidTemplate 'Prefill'
    $ex.WelcomeDialog.PersistPrompt = $false
    $ex.ProgressDialog.Enabled = $false
    $ex.CompanyName = 'Fabrikam IT'
    $ex.TenantId = 'fabrikam.onmicrosoft.com'
    $ex.LogPath = '${env:ProgramData}\Logs\Fabrikam'
    $ex.ProgressMessage.Repair = 'Fixing things...'
    $ex.WelcomeDialog.DeferTimes = 5
    $ex.WelcomeDialog.AllowDefer = $false
    $ex.WelcomeDialog.CloseProcessesCountdown = 900
    $ex.UninstallWelcomeDialog.CloseProcessesCountdown = 0
    $ex.CompletionPrompt.Enabled = $true
    $ex.CompletionPrompt.ButtonRightText = 'Close'
    $ex.Hooks.Enabled = $true
    $ex.Hooks.FailureAction = 'Continue'
    $ex.IntuneDefaults.MaxRuntimeMinutes = 90
    $exJson = $ex | ConvertTo-Json -Depth 10 | ConvertFrom-Json   # as Get-OrgTemplate / the TUI hand it over
    Use-ScriptedAnswer @{}
    $w2 = Invoke-Wizard -Name '' -Existing $exJson
    $t2 = $w2.Template
    $pre = [ordered]@{
        'TemplateName'                          = @($t2.TemplateName, 'Prefill')
        'CompanyName'                           = @($t2.CompanyName, 'Fabrikam IT')
        'TenantId'                              = @($t2.TenantId, 'fabrikam.onmicrosoft.com')
        'LogPath'                               = @($t2.LogPath, '${env:ProgramData}\Logs\Fabrikam')
        'ProgressMessage.Repair'                = @($t2.ProgressMessage.Repair, 'Fixing things...')
        'WelcomeDialog.DeferTimes'              = @($t2.WelcomeDialog.DeferTimes, 5)
        'WelcomeDialog.AllowDefer'              = @($t2.WelcomeDialog.AllowDefer, $false)
        'WelcomeDialog.PersistPrompt'           = @($t2.WelcomeDialog.PersistPrompt, $false)
        'ProgressDialog.Enabled'                = @($t2.ProgressDialog.Enabled, $false)
        'WelcomeDialog.CloseProcessesCountdown' = @($t2.WelcomeDialog.CloseProcessesCountdown, 900)
        'UninstallWelcome...Countdown (0=off)'  = @($t2.UninstallWelcomeDialog.CloseProcessesCountdown, 0)
        'CompletionPrompt.Enabled'              = @($t2.CompletionPrompt.Enabled, $true)
        'CompletionPrompt.ButtonRightText'      = @($t2.CompletionPrompt.ButtonRightText, 'Close')
        'Hooks.FailureAction'                   = @($t2.Hooks.FailureAction, 'Continue')
        'IntuneDefaults.MaxRuntimeMinutes'      = @($t2.IntuneDefaults.MaxRuntimeMinutes, 90)
    }
    $preOk = -not $w2.Error
    foreach ($k in $pre.Keys) { if ($pre[$k][0] -ne $pre[$k][1]) { $preOk = $false; Bad "pre-fill lost: $k = [$($pre[$k][0])] (expected [$($pre[$k][1])])" } }
    if ($preOk) { Ok "Enter on every prompt keeps all $($pre.Count) existing values (edit really pre-fills)" } elseif ($w2.Error) { Bad "edit wizard threw: $($w2.Error)" }
    if (@(Get-Prompt 'Company name') -match [regex]::Escape('[Fabrikam IT]')) { Ok 'the prompt shows the existing value as its default' } else { Bad "prompt: $(Get-Prompt 'Company name')" }

    # 4c: an INVALID value pre-filled from an existing (older) template is re-prompted too; after it is
    # rejected the built-in default is offered, so pressing Enter always gets out.
    $exBad = Get-ValidTemplate 'Legacy'
    $exBad.CompanyName = 'Ca$h IT'
    $exBad.LogPath = 'C:\Logs\$(whoami)'
    $exBad.ProgressMessage.Install = 'Contact $Helpdesk'
    $exBad.ProgressDialog.StatusMessage = '   '
    $exBad.CompletionPrompt.ButtonRightText = "OK$bt"
    $exBad.WelcomeDialog.CloseProcessesCountdown = 100000
    $exBad.UninstallWelcomeDialog.CloseProcessesCountdown = 86401
    $exBad.LanguageOverride = 'nl$(1+1)'
    $exBadJson = $exBad | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    Use-ScriptedAnswer @{}
    $w3 = Invoke-Wizard -Name '' -Existing $exBadJson
    $t3 = $w3.Template
    if (-not $w3.Error) { Ok 'wizard completes with only Enter presses (no endless loop)' } else { Bad "threw: $($w3.Error)" }
    $cn = @(Get-Prompt 'Company name')
    if ($cn.Count -eq 2 -and $cn[0] -match [regex]::Escape('[Ca$h IT]') -and $cn[1] -match [regex]::Escape('[Your Organisation IT]') -and $t3.CompanyName -eq 'Your Organisation IT') {
        Ok "invalid pre-filled CompanyName shown, rejected, then the built-in default offered and kept"
    } else { Bad "CompanyName prompts: $($cn -join ' || ') -> [$($t3.CompanyName)]" }
    if ($t3.LogPath -eq '$envWinDir\Logs\Software') { Ok 'invalid pre-filled LogPath replaced by the built-in default' } else { Bad "LogPath=[$($t3.LogPath)]" }
    if ($t3.ProgressMessage.Install -eq 'Installation in progress. Please wait...') { Ok 'invalid pre-filled progress message replaced' } else { Bad "ProgressMessage.Install=[$($t3.ProgressMessage.Install)]" }
    if ($t3.ProgressDialog.StatusMessage -eq '') { Ok "whitespace-only pre-filled status message -> '' (not set)" } else { Bad "StatusMessage=[$($t3.ProgressDialog.StatusMessage)]" }
    if ($t3.CompletionPrompt.ButtonRightText -eq 'OK') { Ok 'pre-filled button label with a backtick replaced by OK' } else { Bad "ButtonRightText=[$($t3.CompletionPrompt.ButtonRightText)]" }
    $lg = @(Get-Prompt 'Force dialog language')
    if ($t3.LanguageOverride -eq '' -and $lg.Count -eq 2 -and $lg[0] -match [regex]::Escape('[nl$(1+1)]') -and $lg[1] -notmatch '\[') { Ok "invalid pre-filled language 'nl`$(1+1)' re-prompted, then auto-detect ('') kept" } else { Bad "LanguageOverride=[$($t3.LanguageOverride)] prompts: $($lg -join ' || ')" }
    $cd = @(Get-Prompt 'Auto-close countdown')
    if ($t3.WelcomeDialog.CloseProcessesCountdown -eq 180 -and $t3.UninstallWelcomeDialog.CloseProcessesCountdown -eq 60 -and $cd.Count -eq 4 -and $cd[0] -match '\[100000\]') {
        Ok 'countdowns 100000 / 86401 pre-filled -> re-prompted -> defaults 180 / 60'
    } else { Bad "countdowns=[$($t3.WelcomeDialog.CloseProcessesCountdown)/$($t3.UninstallWelcomeDialog.CloseProcessesCountdown)] prompts: $($cd -join ' || ')" }
    if (@(Test-Win32ToolkitOrgTemplateText -Template $t3).Count -eq 0) { Ok 'the re-saved template is valid' } else { Bad 're-saved template still invalid' }

    # 4d: optional values can be cleared when editing. Editing pre-fills, so Enter keeps the current value;
    # a typed '-' empties an optional value (tenant pin, accent, language, overrides, Intune texts) and the
    # label says so. Creating a template, the labels stay "(blank = ...)".
    $optPrompts = [ordered]@{
        'Intune tenant'                  = 'unpinned'
        'Fluent accent hex'              = 'default'
        'Force dialog language'          = 'auto-detect'
        'Override status message'        = 'use strings.psd1'
        'Override detail text'           = 'use strings.psd1'
        'Description boilerplate'        = 'none'
        'Privacy information URL'        = 'none'
        'Customer-doc footer line'       = 'default'
    }
    $pin = Get-ValidTemplate 'Pinned'
    $pin.TenantId = 'fabrikam.onmicrosoft.com'
    $pin.FluentAccentColor = '0xFF112233'
    $pin.LanguageOverride = 'nl'
    $pin.ProgressDialog.StatusMessage = 'Updating your apps'
    $pin.ProgressDialog.StatusMessageDetail = 'Hang on'
    $pin.IntuneDefaults.DescriptionBoilerplate = 'Packaged by IT.'
    $pin.IntuneDefaults.PrivacyUrl = 'https://contoso.example/privacy'
    $pin.DocFooter = 'Contoso IT'
    $pinJson = $pin | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    function Get-OptValue { param($T) @($T.TenantId, $T.FluentAccentColor, $T.LanguageOverride, $T.ProgressDialog.StatusMessage,
        $T.ProgressDialog.StatusMessageDetail, $T.IntuneDefaults.DescriptionBoilerplate, $T.IntuneDefaults.PrivacyUrl, $T.DocFooter) }

    Use-ScriptedAnswer @{}
    $wk = Invoke-Wizard -Name '' -Existing $pinJson
    $kept = Get-OptValue $wk.Template
    if (-not $wk.Error -and ($kept -join '|') -eq ((Get-OptValue $pin) -join '|')) { Ok 'editing: Enter keeps every optional value (tenant pin, accent, language, overrides, Intune texts)' } else { Bad "Enter lost a value: $($kept -join ' | ') $($wk.Error)" }
    $labelsOk = $true
    foreach ($k in $optPrompts.Keys) {
        $pl = @(Get-Prompt $k)
        if ($pl.Count -ne 1 -or $pl[0] -notmatch [regex]::Escape("(Enter = keep, '-' = $($optPrompts[$k]))")) { $labelsOk = $false; Bad "edit label for '$k': $($pl -join ' || ')" }
    }
    if ($labelsOk) { Ok "editing: every optional prompt is labelled (Enter = keep, '-' = ...)" }
    if (@($wk.Info | Where-Object { $_ -match "Type '-' to clear an optional value" }).Count -eq 1 -and
        @($wk.Info | Where-Object { $_ -match "'-' = unpinned \(not recommended\)" }).Count -eq 1) { Ok "editing: the intro and the tenant hint explain '-'" } else { Bad "edit hints: $($wk.Info -join ' | ')" }

    $clearMap = @{}; foreach ($k in $optPrompts.Keys) { $clearMap[$k] = '-' }
    Use-ScriptedAnswer $clearMap
    $wc = Invoke-Wizard -Name '' -Existing $pinJson
    $cleared = Get-OptValue $wc.Template
    if (-not $wc.Error -and @($cleared | Where-Object { $_ -ne '' }).Count -eq 0 -and $wc.Template.TenantId -eq '') { Ok "editing a pinned template: '-' unpins the tenant and clears every other optional value" } else { Bad "'-' did not clear: $($cleared -join ' | ') $($wc.Error)" }
    $savedPin = Get-Content -LiteralPath (Join-Path $wizBase 'Templates\Pinned.json') -Raw | ConvertFrom-Json
    if ($savedPin.TenantId -eq '' -and $savedPin.LanguageOverride -eq '' -and $savedPin.ProgressDialog.StatusMessage -eq '') { Ok 'Templates\Pinned.json saved unpinned, overrides removed' } else { Bad "saved: tenant=[$($savedPin.TenantId)] lang=[$($savedPin.LanguageOverride)]" }
    if ($wc.Template.CompanyName -eq 'Contoso IT' -and $wc.Template.CompletionPrompt.ButtonRightText -eq 'OK') { Ok 'non-optional values are untouched by the clears' } else { Bad "company=[$($wc.Template.CompanyName)]" }

    Use-ScriptedAnswer @{ 'Intune tenant' = '-' }
    $wn2 = Invoke-Wizard 'Fresh'
    $tp = @(Get-Prompt 'Intune tenant')
    if (-not $wn2.Error -and $tp.Count -eq 1 -and $tp[0].StartsWith('Intune tenant (blank = unpinned)') -and $wn2.Template.TenantId -eq '' -and
        @($wn2.Info | Where-Object { $_ -match "Type '-' to clear" }).Count -eq 0) { Ok "creating: labels stay '(blank = ...)', no edit hint, '-' still gives ''" } else { Bad "create label: $($tp -join ' || ') tenant=[$($wn2.Template.TenantId)]" }

    # 4e: D11 - extension module rule explained, an existing module folder checked now.
    function Add-ExtensionCase {
        param([string]$Tpl, [scriptblock]$Build)
        $dir = Join-Path $wizBase "Templates\$Tpl\PSAppDeployToolkit.Contoso"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        & $Build $dir
    }
    Add-ExtensionCase 'ExtPsm1Only' { param($d) Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psm1') 'function Get-ContosoThing { 1 }' }
    Add-ExtensionCase 'ExtSaveModule' { param($d)
        New-Item -ItemType Directory -Path (Join-Path $d '1.0.0') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d '1.0.0\PSAppDeployToolkit.Contoso.psm1') 'function Get-ContosoThing { 1 }'
        Set-Content -LiteralPath (Join-Path $d '1.0.0\PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; ModuleVersion = '1.0.0' }" }
    Add-ExtensionCase 'ExtNoRoot' { param($d)
        Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psm1') 'function Get-ContosoThing { 1 }'
        Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ ModuleVersion = '1.0.0' }" }
    Add-ExtensionCase 'ExtMissingRoot' { param($d)
        Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; ModuleVersion = '1.0.0' }" }
    Add-ExtensionCase 'ExtValid' { param($d)
        Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psm1') 'function Get-ContosoThing { 1 }'
        Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; ModuleVersion = '1.0.0'; RequiredModules = @('PSAppDeployToolkit') }" }
    $extCases = [ordered]@{
        # The Assert's texts (TUI audit G4: the wizard runs Get-Win32ToolkitOrgExtensionLayoutFinding, the Assert's rules).
        'ExtPsm1Only'    = "it has no 'PSAppDeployToolkit\.Contoso\\PSAppDeployToolkit\.Contoso\.psd1' manifest"
        'ExtSaveModule'  = "it has no 'PSAppDeployToolkit\.Contoso\\PSAppDeployToolkit\.Contoso\.psd1' manifest.*A Save-Module '1\.0\.0\\' version-folder layout is not supported"
        'ExtNoRoot'      = 'has no RootModule'
        'ExtMissingRoot' = "the RootModule 'PSAppDeployToolkit\.Contoso\.psm1' of 'PSAppDeployToolkit\.Contoso\.psd1' does not exist in the folder"
        'ExtValid'       = $null
    }
    foreach ($name in $extCases.Keys) {
        Use-ScriptedAnswer @{ 'Ship an org PSADT extension module' = 'y' }
        $we = Invoke-Wizard $name
        $pattern = $extCases[$name]
        if ($we.Error) { Bad "$name : wizard threw: $($we.Error)"; continue }
        if ($null -eq $pattern) {
            if ($we.Warnings.Count -eq 0) { Ok "$name : valid <Dir>\<Dir>.psd1 + RootModule -> no warning" } else { Bad "$name : unexpected warning(s): $($we.Warnings -join ' | ')" }
        }
        elseif ($we.Warnings.Count -eq 1 -and $we.Warnings[0] -match $pattern) { Ok "$name : warned ($pattern)" }
        else { Bad "$name : warnings = $($we.Warnings -join ' | ')" }
        if (@($we.Info | Where-Object { $_ -match [regex]::Escape('PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psd1') }).Count -ge 1) { } else { Bad "$name : the psd1 + RootModule rule was not explained" }
    }
    Ok 'the <Dir>\<Dir>.psd1 + RootModule rule is explained whenever the extension module is enabled'
    Use-ScriptedAnswer @{ 'Ship an org PSADT extension module' = 'n' }
    $wn = Invoke-Wizard 'ExtPsm1Only'
    if (-not $wn.Error -and $wn.Warnings.Count -eq 0 -and @($wn.Info | Where-Object { $_ -match 'RootModule' }).Count -eq 0) { Ok 'extension module disabled -> no rule text, no check' } else { Bad "disabled: warnings=$($wn.Warnings -join ' | ')" }

    # 4f (TUI audit G4): the same rules as Assert-Win32ToolkitOrgExtensionModule, and the RequiredModules version range.
    Use-ScriptedAnswer @{ 'Ship an org PSADT extension module' = 'y' }
    $we = Invoke-Wizard 'ExtPsm1Only'
    $why = @(Get-Win32ToolkitOrgExtensionLayoutFinding -ModuleFolder (Get-Item -LiteralPath (Join-Path $wizBase 'Templates\ExtPsm1Only\PSAppDeployToolkit.Contoso')))
    if ($why.Count -eq 1 -and $we.Warnings.Count -eq 1 -and $we.Warnings[0] -ceq "Org extension module 'PSAppDeployToolkit.Contoso' cannot be used: $($why[0].Why) Applying this template will fail until you fix it.") {
        Ok 'a psm1-only folder -> the warning carries the shared rule''s Why text (the one the Assert throws), then ''Applying this template will fail until you fix it.'''
    } else { Bad "psm1-only: $($we.Warnings -join ' | ')" }
    if (@($we.Info | Where-Object { $_ -ceq '  A RequiredModules entry for PSAppDeployToolkit must be valid for Windows PowerShell 5.1 and must not pin a version.' }).Count -eq 1) { Ok 'the RequiredModules rule is explained' } else { Bad "info: $($we.Info -join ' | ')" }
    $reqCases = [ordered]@{
        'ExtPin'    = @("@{ ModuleName = 'PSAppDeployToolkit'; RequiredVersion = '4.2.0' }", "Org extension module 'PSAppDeployToolkit.Contoso' pins PSAppDeployToolkit (RequiredVersion = '4.2.0'): win32-toolkit builds 4.1.x and 4.2.x projects side by side, so projects that bundle a version outside it fail every deployment. Declare ModuleVersion = '4.1.0' (a minimum) or no version.")
        'ExtCap'    = @("@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0'; MaximumVersion = '4.1.*' }", "Org extension module 'PSAppDeployToolkit.Contoso' pins PSAppDeployToolkit (MaximumVersion = '4.1.*'; ModuleVersion = '4.1.0'): win32-toolkit builds 4.1.x and 4.2.x projects side by side, so projects that bundle a version outside it fail every deployment. Declare ModuleVersion = '4.1.0' (a minimum) or no version.")
        'ExtMin42'  = @("@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.2.0' }", "Org extension module 'PSAppDeployToolkit.Contoso' requires PSAppDeployToolkit 4.2.0 or later (ModuleVersion = '4.2.0'): win32-toolkit builds 4.1.x and 4.2.x projects side by side, so projects that bundle a PSAppDeployToolkit older than 4.2.0 fail every deployment. Declare ModuleVersion = '4.1.0' (a minimum) or no version.")
        'ExtMin41'  = @("@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0' }", $null)
        'ExtBare'   = @("'PSAppDeployToolkit'", $null)
    }
    foreach ($name in $reqCases.Keys) {
        $psd1Text = "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; ModuleVersion = '1.0.0'; RequiredModules = @($($reqCases[$name][0])) }"
        Add-ExtensionCase $name { param($d)
            Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psm1') 'function Get-ContosoThing { 1 }'
            Set-Content -LiteralPath (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') $psd1Text }
        Use-ScriptedAnswer @{ 'Ship an org PSADT extension module' = 'y' }
        $we = Invoke-Wizard $name
        $want = $reqCases[$name][1]
        if ($we.Error) { Bad "$name : wizard threw: $($we.Error)"; continue }
        if ($null -eq $want) {
            if ($we.Warnings.Count -eq 0) { Ok "$name ($($reqCases[$name][0])) -> no warning" } else { Bad "$name : $($we.Warnings -join ' | ')" }
        }
        elseif ($we.Warnings.Count -eq 1 -and $we.Warnings[0] -ceq $want) { Ok "$name -> exactly: $want" }
        else { Bad "$name : warnings = $($we.Warnings -join ' | ')" }
    }
    # The shared helper itself: every finding of a folder, in rule order; GUID; an unreadable manifest.
    $hDir = Join-Path $root 'helper\PSAppDeployToolkit.Contoso'
    New-Item -ItemType Directory -Path $hDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $hDir 'PSAppDeployToolkit.Contoso.psd1') "@{ ModuleVersion = '1.0.0'; RequiredModules = @(@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.2.0-rc2' }, @{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0'; Guid = '11111111-2222-3333-4444-555555555555' }) }"
    $hf = @(Get-Win32ToolkitOrgExtensionLayoutFinding -ModuleFolder (Get-Item -LiteralPath $hDir))
    if ($hf.Count -eq 3 -and $hf[0].Why -like "its manifest 'PSAppDeployToolkit.Contoso.psd1' has no RootModule.*" -and
        $hf[1].Why -like "its RequiredModules entry for PSAppDeployToolkit (ModuleVersion = '4.2.0-rc2') is not valid for Windows PowerShell 5.1: *" -and
        $hf[2].Why -like "its RequiredModules entry for PSAppDeployToolkit has GUID 11111111-2222-3333-4444-555555555555, which is not PSAppDeployToolkit's (8c3c366b-8606-4576-9f2d-4051144f7ca2)*" -and
        @($hf | Where-Object { $_.Folder -ne 'PSAppDeployToolkit.Contoso' }).Count -eq 0) {
        Ok 'Get-Win32ToolkitOrgExtensionLayoutFinding: no RootModule, an entry 5.1 rejects, a foreign GUID -> three findings in rule order'
    } else { Bad "helper findings: $($hf | ConvertTo-Json -Compress)" }
    Set-Content -LiteralPath (Join-Path $hDir 'PSAppDeployToolkit.Contoso.psd1') '@{ this is not a data file'
    $hf = @(Get-Win32ToolkitOrgExtensionLayoutFinding -ModuleFolder (Get-Item -LiteralPath $hDir))
    if ($hf.Count -eq 1 -and $hf[0].Why -like "its manifest 'PSAppDeployToolkit.Contoso.psd1' could not be read: *") { Ok 'an unreadable manifest -> one finding, nothing else checked, no throw' } else { Bad "unreadable: $($hf | ConvertTo-Json -Compress)" }

    # A suite that forgot the range: the version rule is skipped (never 'builds  projects').
    $savedRange = $script:PsadtSupportedRange; $script:PsadtSupportedRange = $null
    Use-ScriptedAnswer @{ 'Ship an org PSADT extension module' = 'y' }
    $we = Invoke-Wizard 'ExtPin'
    $script:PsadtSupportedRange = $savedRange
    if (-not $we.Error -and $we.Warnings.Count -eq 0) { Ok 'no supported range -> the version rule is skipped (no warning)' } else { Bad "no range: $($we.Error) $($we.Warnings -join ' | ')" }

    # =============================================================================================
    Write-Host "`n[5] Get-OrgTemplate re-validates stored JSON on every load path" -ForegroundColor Cyan
    function Save-TemplateJson { param([string]$Base, $Tpl) $d = Join-Path $Base 'Templates'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $Tpl | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $d "$($Tpl.TemplateName).json") -Encoding UTF8 }
    $storedBad = Get-ValidTemplate 'Bad'
    $storedBad.ProgressMessage.Install = 'Call $Helpdesk'
    $storedBad.WelcomeDialog.CloseProcessesCountdown = 100000
    $storedBad.TenantId = 'contoso.onmicrosoft.com'
    $storedBad.LanguageOverride = 'nl$(1+1)'
    $storedGood = Get-ValidTemplate 'Good'
    $storedGood.LanguageOverride = 'nl-BE'

    $multiBase = Join-Path $root 'multi'
    Save-TemplateJson $multiBase $storedBad
    Save-TemplateJson $multiBase $storedGood
    $singleBase = Join-Path $root 'single'
    Save-TemplateJson $singleBase $storedBad

    function Invoke-Get { param([scriptblock]$Call) $r = [pscustomobject]@{ Value = $null; Error = $null }
        try { $r.Value = & $Call 6>$null } catch { $r.Error = $_ }; $r }

    # by name (Get-OrgTemplate.ps1 -TemplateName path)
    Use-ScriptedAnswer @{}
    $g1 = Invoke-Get { Get-OrgTemplate -TemplateName 'Bad' -BasePath $multiBase }
    if ($g1.Error -and $g1.Error.FullyQualifiedErrorId -eq 'W32T.OrgTemplateInvalid') { Ok '-TemplateName path: bad stored text -> W32T.OrgTemplateInvalid' } else { Bad "-TemplateName path: $($g1.Error) / $($g1.Value.TemplateName)" }
    $g1m = if ($g1.Error) { $g1.Error.Exception.Message } else { '' }
    if ($g1m -match 'ProgressMessage\.Install' -and $g1m -match 'WelcomeDialog\.CloseProcessesCountdown' -and $g1m -match '(?m)^  - LanguageOverride:' -and $g1m -match [regex]::Escape("(template 'Bad')") -and $g1m -match [regex]::Escape('Templates\Bad.json')) { Ok 'message names all three fields (incl. LanguageOverride), the template and Templates\Bad.json' } else { Bad "message: $g1m" }
    $g2 = Invoke-Get { Get-OrgTemplate -TemplateName 'Bad' -BasePath $multiBase -SkipTextValidation }
    if (-not $g2.Error -and $g2.Value.TemplateName -eq 'Bad') { Ok '-SkipTextValidation loads it anyway' } else { Bad "-SkipTextValidation: $($g2.Error)" }
    $g3 = Invoke-Get { Get-OrgTemplate -TemplateName 'Good' -BasePath $multiBase }
    if (-not $g3.Error -and $g3.Value.TemplateName -eq 'Good') { Ok 'a valid stored template loads' } else { Bad "valid: $($g3.Error)" }

    # the only template (single-template path)
    $g4 = Invoke-Get { Get-OrgTemplate -BasePath $singleBase }
    if ($g4.Error -and $g4.Error.FullyQualifiedErrorId -eq 'W32T.OrgTemplateInvalid') { Ok 'single-template path validates too' } else { Bad "single path: $($g4.Error) / $($g4.Value.TemplateName)" }
    $g4s = Invoke-Get { Get-OrgTemplate -BasePath $singleBase -SkipTextValidation }
    if (-not $g4s.Error -and $g4s.Value.TemplateName -eq 'Bad') { Ok 'single-template path honours -SkipTextValidation' } else { Bad "single skip: $($g4s.Error)" }

    # the picker (several templates; Bad.json sorts first)
    Use-ScriptedAnswer @{ 'Select template (' = '1' }
    $g5 = Invoke-Get { Get-OrgTemplate -BasePath $multiBase }
    if ($g5.Error -and $g5.Error.FullyQualifiedErrorId -eq 'W32T.OrgTemplateInvalid') { Ok 'picker path validates the chosen template' } else { Bad "picker: $($g5.Error) / $($g5.Value.TemplateName)" }
    Use-ScriptedAnswer @{ 'Select template (' = '2' }
    $g6 = Invoke-Get { Get-OrgTemplate -BasePath $multiBase }
    if (-not $g6.Error -and $g6.Value.TemplateName -eq 'Good') { Ok 'picker path loads a valid template' } else { Bad "picker valid: $($g6.Error)" }

    # older schema with no dialog sections loads fine (missing fields are not violations)
    $oldBase = Join-Path $root 'old'
    $oldTpl = [pscustomobject]@{ TemplateSchemaVersion = '4.0'; TemplateName = 'Old'; CompanyName = 'Old Co'; AppScriptAuthor = 'x' }
    Save-TemplateJson $oldBase $oldTpl
    $g7 = Invoke-Get { Get-OrgTemplate -TemplateName 'Old' -BasePath $oldBase }
    if (-not $g7.Error -and $g7.Value.TemplateName -eq 'Old') { Ok 'a sparse older-schema template loads' } else { Bad "old schema: $($g7.Error)" }

    # =============================================================================================
    Write-Host "`n[6] Connect-Win32ToolkitIntune -Template is not blocked by bad dialog text" -ForegroundColor Cyan
    $script:connectBase = $multiBase
    $script:graphCall = $null
    $ce = $null
    $res = Connect-Win32ToolkitIntune -Template 'Bad' -ErrorVariable ce -ErrorAction SilentlyContinue 6>$null
    if (-not $ce -and $script:graphCall -and $script:graphCall.TenantId -eq 'contoso.onmicrosoft.com') { Ok "the pinned TenantId is read (Get-OrgTemplate -SkipTextValidation) and used" } else { Bad "connect: error=[$ce] graph=[$($script:graphCall.TenantId)]" }
    if ($res -and $res.TenantId -eq 'contoso.onmicrosoft.com') { Ok 'connection result returned' } else { Bad 'no connection result' }
    $connSrc = Get-Content -LiteralPath (Join-Path $repo 'Public\Connect-Win32ToolkitIntune.ps1') -Raw
    if ($connSrc -match 'Get-OrgTemplate[^\r\n]*-SkipTextValidation') { Ok 'Connect-Win32ToolkitIntune passes -SkipTextValidation (source)' } else { Bad 'switch not passed in source' }

    # =============================================================================================
    Write-Host "`n[7] an older-schema template when nobody can answer the upgrade prompt (S12-F1)" -ForegroundColor Cyan
    $v2 = { [pscustomobject]@{ TemplateSchemaVersion = '2.0'; TemplateName = 'Arxus'; CompanyName = 'Arxus' } }
    $script:wizardCalls = 0
    $wizardSaved = ${function:New-OrgTemplate}
    $script:wizardBase = 'unset'
    ${function:New-OrgTemplate} = { param($ExistingTemplate, $TemplateName, $BasePath) $script:wizardCalls++; $script:wizardBase = $BasePath; $ExistingTemplate }
    foreach ($case in @(@{ Host = $true; Switch = $false; Tag = 'non-interactive host' }, @{ Host = $false; Switch = $true; Tag = 'pwsh -NonInteractive console' })) {
        $script:nonInteractiveHost = $case.Host; $script:nonInteractiveSwitch = $case.Switch
        Use-ScriptedAnswer @{}
        $w7 = $null
        $t7 = Update-OrgTemplateIfNeeded -Template (& $v2) -FilePath 'X:\never-written.json' -WarningVariable w7 -WarningAction SilentlyContinue 6>$null
        if ((Get-PromptCount '  Update template?') -eq 0 -and @($w7 | Where-Object { "$_" -match "Template 'Arxus' uses schema v2\.0, current is v4\.0; this run cannot prompt" -and "$_" -match 'file is unchanged' }).Count -eq 1) { Ok "$($case.Tag): no prompt, one warning" } else { Bad "$($case.Tag): prompts=$(Get-PromptCount '  Update template?') warn=$($w7 -join ' | ')" }
        if ($t7.DialogStyle -eq 'Fluent' -and $t7.Hooks -and $t7.TemplateSchemaVersion -eq '2.0' -and $script:wizardCalls -eq 0) { Ok "$($case.Tag): the missing options get their defaults for this run; schema stays 2.0; no wizard" } else { Bad "$($case.Tag): $($t7 | ConvertTo-Json -Compress -Depth 3)" }
    }
    # A host the checks do not recognise still refuses Read-Host: the same fallback, not an abort.
    $script:nonInteractiveHost = $false; $script:nonInteractiveSwitch = $false
    $rhSaved = (Get-Item function:Read-Host).ScriptBlock
    Set-Item -Path 'function:script:Read-Host' -Value {
        param($Prompt)
        throw [System.Management.Automation.ErrorRecord]::new([System.Management.Automation.PSInvalidOperationException]::new('PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.'),
            'InvalidOperation,Microsoft.PowerShell.Commands.ReadHostCommand', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    }
    $w7 = $null; $e7 = $null; $t7 = $null
    try { $t7 = Update-OrgTemplateIfNeeded -Template (& $v2) -FilePath 'X:\never-written.json' -WarningVariable w7 -WarningAction SilentlyContinue 6>$null } catch { $e7 = $_ }
    Set-Item -Path 'function:script:Read-Host' -Value $rhSaved
    if (-not $e7 -and $t7.DialogStyle -eq 'Fluent' -and @($w7 | Where-Object { "$_" -match 'this run cannot prompt' }).Count -eq 1) { Ok 'Read-Host refused (ReadHostCommand error) -> the same default fallback, no abort' } else { Bad "refused prompt: err=$($e7.FullyQualifiedErrorId) warn=$($w7 -join ' | ')" }
    # Interactive answers still work.
    Use-ScriptedAnswer @{ '  Update template?' = 'n' }
    $w7 = $null
    $t7 = Update-OrgTemplateIfNeeded -Template (& $v2) -WarningVariable w7 -WarningAction SilentlyContinue 6>$null
    if ((Get-PromptCount '  Update template?') -eq 1 -and @($w7).Count -eq 0 -and $t7.DialogStyle -eq 'Fluent' -and $script:wizardCalls -eq 0) { Ok "interactive 'n': asked once, defaults patched, no warning" } else { Bad "interactive n: prompts=$(Get-PromptCount '  Update template?') warn=$($w7 -join ' | ')" }
    Use-ScriptedAnswer @{ '  Update template?' = 'y' }
    $null = Update-OrgTemplateIfNeeded -Template (& $v2) 6>$null
    if ($script:wizardCalls -eq 1) { Ok "interactive 'y': opens the template wizard" } else { Bad "wizard calls: $($script:wizardCalls)" }
    # TUI audit G4: the run's base folder reaches the wizard opened for the upgrade (it saved under the registry base).
    $upBase = Join-Path $root 'upgrade-base'
    Use-ScriptedAnswer @{ '  Update template?' = 'y' }
    $null = Update-OrgTemplateIfNeeded -Template (& $v2) -BasePath $upBase 6>$null
    if ($script:wizardCalls -eq 2 -and $script:wizardBase -eq $upBase) { Ok "interactive 'y' with -BasePath: New-OrgTemplate gets that base folder" } else { Bad "wizard base: [$($script:wizardBase)]" }
    # Get-OrgTemplate passes its -BasePath on every load path (source: the three calls).
    $getSrc = Get-Content -LiteralPath (Join-Path $repo 'Private\Get-OrgTemplate.ps1') -Raw
    if (([regex]::Matches($getSrc, 'Update-OrgTemplateIfNeeded [^\r\n]*-BasePath \$BasePath')).Count -eq 3 -and ([regex]::Matches($getSrc, 'Update-OrgTemplateIfNeeded ')).Count -eq 3) { Ok 'Get-OrgTemplate passes -BasePath to Update-OrgTemplateIfNeeded on all three load paths' } else { Bad 'a Get-OrgTemplate load path does not pass -BasePath' }
    # And for real: a v2.0 template loaded from another base folder opens the wizard with that base.
    $v2Base = Join-Path $root 'v2'
    Save-TemplateJson $v2Base (& $v2)
    Use-ScriptedAnswer @{ '  Update template?' = 'y' }
    $script:wizardBase = 'unset'
    $null = Invoke-Get { Get-OrgTemplate -TemplateName 'Arxus' -BasePath $v2Base -SkipTextValidation }
    if ($script:wizardBase -eq $v2Base) { Ok 'Get-OrgTemplate -TemplateName -BasePath <base> on a v2.0 template -> the upgrade wizard gets <base>' } else { Bad "get-orgtemplate wizard base: [$($script:wizardBase)]" }
    ${function:New-OrgTemplate} = $wizardSaved
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All OrgTemplateText tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail OrgTemplateText test(s) FAILED." -ForegroundColor Red; exit 1 }
