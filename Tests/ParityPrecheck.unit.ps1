<#
    Installer-identity PR 2 (spec 2.5, A1 hv r1.2): the Hyper-V Intune-parity pre-check.

      [1] Get-Win32ToolkitParityDialogRisk - the risk matrix on deploy scripts generated in %TEMP% from the PSADT
          fixtures with the real Set-PSADTDataDrivenScript, the org-ui catalog block and Remove-Win32ToolkitPhaseDefaultUi
          (as OrgUiBlocks.unit does): PSADT 4.1 + no process to close + a deferrable Pre-Install welcome (org-ui data,
          the splatted template default, a literal -AllowDefer) -> at risk; a listed process, AllowDefer/Enabled off,
          a literal call without -AllowDefer, -AllowDefer:$false, -ForceCountdown only, a deferring call outside
          Pre-Install, PSADT 4.2 Zero-Config -> not; the legacy 1.1.6 fixtures as their AST says; a missing or
          unreadable AppConfig or script -> not, no throw.
      [2] Get-Win32ToolkitGuestSignedInUser - Invoke-Command shadowed: console user / Active-or-Connected session ->
          signed in; a disconnected session only -> not; a throw, $null, a partial or a doubled answer -> Checked $false;
          -ErrorAction Stop and no -ArgumentList. C-11 on the captured scriptblock: 5.1 parse, ASCII, first statement
          $ErrorActionPreference = 'Stop', no quser, no here-string, every other assigned variable $w32t*; one live
          run of the text in a Windows PowerShell 5.1 child returns one object with the three properties.
      [3] Invoke-Win32ToolkitParityPrecheck - Get-VM, New-/Remove-Win32ToolkitHyperVSession, the credential and the
          config shadowed: not at risk -> the VM is not touched; signed in -> Blocked with the message, notes and NotRun;
          not signed in / not checked / no session / no VM / no credential -> not blocked (fail-open, one warning where
          the VM could not be reached); the configured HyperVCheckpoint is opened and reverted.
      [4] File hygiene of the three new files: ASCII, one function, every catch starts with the C-2 line.

    Nothing reaches a VM; no installer and no deploy script runs. Needs Windows PowerShell 5.1 (exit 3 = SKIP without it).

    Run:  pwsh -File Tests\ParityPrecheck.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows and fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-Command and Get-VM are shadowed on purpose')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51)) { Write-Host 'SKIP: Windows PowerShell 5.1 (powershell.exe) is not available.' -ForegroundColor Yellow; exit 3 }

# C-5 range + the version-policy shadow (as OrgUiBlocks.unit).
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
function Test-Win32ToolkitPsadtVersionSupported {
    param([Parameter(Position = 0)][object]$Version)
    if ($null -eq $Version) { return $false }
    $v = $null
    if ($Version -is [version]) { $v = $Version } elseif (-not [version]::TryParse((([string]$Version) -split '-', 2)[0], [ref]$v)) { return $false }
    return ($v -ge $script:PsadtSupportedRange.Min -and $v -lt $script:PsadtSupportedRange.MaxExclusive)
}
foreach ($f in 'Get-Win32ToolkitDeployScriptShape', 'Set-Win32ToolkitPhaseBlock', 'Remove-Win32ToolkitPhaseBlock', 'Remove-Win32ToolkitPhaseDefaultUi',
    'Get-Win32ToolkitDeployScriptBlock', 'Write-Win32ToolkitDeployScript', 'Test-Win32ToolkitPS51Syntax', 'Set-PSADTDataDrivenScript',
    'Set-Win32ToolkitTextBlock', 'Get-Win32ToolkitAppConfig', 'Set-Win32ToolkitAppConfig', 'ConvertTo-PSSingleQuoted', 'ConvertTo-Win32ToolkitSafeText',
    'Get-Win32ToolkitParityDialogRisk', 'Get-Win32ToolkitGuestSignedInUser', 'Invoke-Win32ToolkitParityPrecheck') {
    . (Join-Path $repo "Private\$f.ps1")
}

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32pp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $TMP -Force | Out-Null
$bom = [System.Text.UTF8Encoding]::new($true)

# A project generated from a fixture: AppConfig (ProcessesToClose, optional OrgUi.Welcome), the data-driven deploy
# script, optionally the Pre-Install org-ui block (the template default welcome removed, as Apply-OrgTemplate does),
# then an optional text edit of the script.
function New-RiskProject {
    param([string]$Label, [string]$Fixture = 'psadt-4.1.8', [string[]]$Processes = @(), $Welcome = $null, [switch]$OrgUi, [switch]$NoGenerate, [scriptblock]$Edit)
    $p = Join-Path $TMP $Label
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    $cfg = [ordered]@{
        SchemaVersion    = '1.0'
        App              = [ordered]@{ Vendor = 'Contoso'; Name = 'Tool'; DisplayName = 'Tool'; Version = '1.0'; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        ProcessesToClose = @($Processes)
    }
    if ($Welcome) { $cfg['OrgUi'] = [ordered]@{ SchemaVersion = '1.0'; Welcome = $Welcome } }
    $null = Set-Win32ToolkitAppConfig -ProjectPath $p -Config ([pscustomobject]$cfg)
    $script = Join-Path $p 'Invoke-AppDeployToolkit.ps1'
    Copy-Item -LiteralPath (Join-Path $repo "Tests\Fixtures\$Fixture\Invoke-AppDeployToolkit.ps1") -Destination $script
    if (-not $NoGenerate) { $null = Set-PSADTDataDrivenScript -ScriptPath $script -WarningAction SilentlyContinue }
    $text = [System.IO.File]::ReadAllText($script, [System.Text.Encoding]::UTF8)
    if ($OrgUi) {
        $text = Remove-Win32ToolkitPhaseDefaultUi -Content $text -Phase 'Pre-Install'
        $text = Set-Win32ToolkitPhaseBlock -Content $text -Phase 'Pre-Install' -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name 'OrgUiPreInstall')
    }
    if ($Edit) { $text = & $Edit $text }
    [System.IO.File]::WriteAllText($script, $text, $bom)
    $p
}
$welcomeOn = [ordered]@{ Enabled = $true; AllowDefer = $true; DeferTimes = 3; CheckDiskSpace = $false; PersistPrompt = $true; BlockExecution = $true; CloseProcessesCountdown = 180 }
function Get-Welcome([hashtable]$Override) { $w = [ordered]@{}; foreach ($k in $welcomeOn.Keys) { $w[$k] = $welcomeOn[$k] }; foreach ($k in $Override.Keys) { $w[$k] = $Override[$k] }; $w }
$templateWelcome = 'Show-ADTInstallationWelcome @saiwParams'
$literalWelcome  = 'Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60'
function Set-WelcomeCall([string]$Text, [string]$Call) {
    if (-not $Text.Contains($templateWelcome)) { throw 'fixture drift: the template default welcome call was not found' }
    $Text.Replace($templateWelcome, $Call)
}

try {
    # ============================== [1] the risk matrix ==============================
    Write-Host '[1] Get-Win32ToolkitParityDialogRisk on generated PSADT 4.1 / 4.2 projects' -ForegroundColor Cyan
    $riskCase = {
        param([string]$Label, $Project, [bool]$Want, [string]$Shape = 'Psadt41', [string]$Welcome = $null)
        $r = $null; $threw = $null
        try { $r = Get-Win32ToolkitParityDialogRisk -ProjectPath $Project -ErrorAction Stop } catch { $threw = $_ }
        $ok = -not $threw -and $r -and $r.AtRisk -eq $Want -and $r.Shape -eq $Shape -and ($null -eq $Welcome -or $r.Welcome -eq $Welcome)
        $tag = if ($Want) { 'AT RISK' } else { 'not at risk' }
        if ($ok) { Ok "${Label}: $tag (Shape $($r.Shape), Welcome '$($r.Welcome)', defers $($r.WelcomeDefers), processes $($r.ProcessCount))" }
        else { Bad "${Label}: threw=$($threw.Exception.Message) result=$($r | ConvertTo-Json -Compress)" }
        $r
    }
    $pAtRisk = New-RiskProject 'orgui-defer' -OrgUi -Welcome (Get-Welcome @{})
    $r = & $riskCase '4.1 + org-ui + Welcome {Enabled, AllowDefer} + no process' $pAtRisk $true 'Psadt41' 'OrgUi'
    if ($r.WelcomeDefers -and $r.ProcessCount -eq 0 -and $r.Reason) { Ok 'WelcomeDefers $true, ProcessCount 0, a Reason' } else { Bad "fields: $($r | ConvertTo-Json -Compress)" }
    $pListed = New-RiskProject 'orgui-listed' -OrgUi -Welcome (Get-Welcome @{}) -Processes @('notepad++')
    $r = & $riskCase '... + ProcessesToClose [notepad++]' $pListed $false
    if ($r.ProcessCount -eq 1) { Ok 'ProcessCount 1' } else { Bad "ProcessCount $($r.ProcessCount)" }
    $null = & $riskCase '... + an empty-string ProcessesToClose entry (filtered like the deploy script)' (New-RiskProject 'orgui-emptyentry' -OrgUi -Welcome (Get-Welcome @{}) -Processes @('')) $true 'Psadt41' 'OrgUi'
    $null = & $riskCase '... AllowDefer $false' (New-RiskProject 'orgui-nodefer' -OrgUi -Welcome (Get-Welcome @{ AllowDefer = $false })) $false 'Psadt41' 'OrgUi'
    $null = & $riskCase '... Enabled $false' (New-RiskProject 'orgui-disabled' -OrgUi -Welcome (Get-Welcome @{ Enabled = $false })) $false 'Psadt41' 'OrgUi'
    $null = & $riskCase '... no OrgUi in AppConfig' (New-RiskProject 'orgui-nodata' -OrgUi) $false 'Psadt41' 'OrgUi'
    $null = & $riskCase '4.1 without org-ui (template default @saiwParams, splatted) + no process' (New-RiskProject 'tpl-default') $true 'Psadt41' 'Script'
    $null = & $riskCase '... + ProcessesToClose [app]' (New-RiskProject 'tpl-default-listed' -Processes @('app')) $false 'Psadt41'
    $null = & $riskCase 'literal -CloseProcesses ... -CloseProcessesCountdown 60 (no deferral)' (New-RiskProject 'lit-plain' -Edit { param($t) Set-WelcomeCall $t $literalWelcome }) $false 'Psadt41' 'Script'
    $null = & $riskCase 'literal + -AllowDefer' (New-RiskProject 'lit-defer' -Edit { param($t) Set-WelcomeCall $t "$literalWelcome -AllowDefer" }) $true 'Psadt41' 'Script'
    $null = & $riskCase 'literal + -AllowDefer:$true' (New-RiskProject 'lit-defer-true' -Edit { param($t) Set-WelcomeCall $t "$literalWelcome -AllowDefer:`$true" }) $true 'Psadt41' 'Script'
    $null = & $riskCase 'literal + -AllowDefer:$x (not a literal $false)' (New-RiskProject 'lit-defer-var' -Edit { param($t) Set-WelcomeCall $t "$literalWelcome -AllowDefer:`$x" }) $true 'Psadt41' 'Script'
    $null = & $riskCase 'literal + -AllowDefer:$false' (New-RiskProject 'lit-defer-false' -Edit { param($t) Set-WelcomeCall $t "$literalWelcome -AllowDefer:`$false" }) $false 'Psadt41' 'Script'
    $null = & $riskCase 'literal + -ForceCountdown 60 only (a countdown that continues by itself)' (New-RiskProject 'lit-force' -Edit { param($t) Set-WelcomeCall $t "$literalWelcome -ForceCountdown 60" }) $false 'Psadt41' 'Script'
    # A deferring call outside Pre-Install (here: Pre-Uninstall / Pre-Repair) is not the install's welcome.
    $null = & $riskCase 'no Pre-Install welcome, -AllowDefer only in Pre-Uninstall/Pre-Repair' (New-RiskProject 'defer-elsewhere' -Edit {
            param($t)
            if (-not $t.Contains($literalWelcome)) { throw 'fixture drift: the Pre-Uninstall welcome call was not found' }
            (Set-WelcomeCall $t '## (no welcome)').Replace($literalWelcome, "$literalWelcome -AllowDefer") }) $false 'Psadt41' ''
    $null = & $riskCase '4.2 Zero-Config + org-ui + Welcome {Enabled, AllowDefer} + no process' (New-RiskProject 'zc-orgui' -Fixture 'psadt-4.2.0-zeroconfig' -OrgUi -Welcome (Get-Welcome @{})) $false 'Psadt42ZeroConfig'
    $null = & $riskCase '4.2 Zero-Config generated, no org-ui, no process' (New-RiskProject 'zc-default' -Fixture 'psadt-4.2.0-zeroconfig') $false 'Psadt42ZeroConfig'
    foreach ($lf in 'legacy-1.1.6-auto', 'legacy-1.1.6-org') {
        $null = & $riskCase "$lf (1.1.6 script, splatted welcome) + no process" (New-RiskProject "$lf-empty" -Fixture $lf -NoGenerate) $true 'Psadt41' 'Script'
        $null = & $riskCase "$lf + ProcessesToClose [app]" (New-RiskProject "$lf-listed" -Fixture $lf -NoGenerate -Processes @('app')) $false 'Psadt41'
    }
    # Unreadable inputs: never at risk, never a throw.
    $pNoCfg = New-RiskProject 'no-appconfig'
    Remove-Item -LiteralPath (Join-Path $pNoCfg 'SupportFiles\AppConfig.json') -Force
    $null = & $riskCase 'no SupportFiles\AppConfig.json' $pNoCfg $false 'Psadt41'
    $pBadCfg = New-RiskProject 'bad-appconfig'
    [System.IO.File]::WriteAllText((Join-Path $pBadCfg 'SupportFiles\AppConfig.json'), '{ not json ][', [System.Text.UTF8Encoding]::new($false))
    $null = & $riskCase 'an unreadable AppConfig.json' $pBadCfg $false 'Psadt41'
    $pLocked = New-RiskProject 'locked-appconfig'
    $lock = [System.IO.File]::Open((Join-Path $pLocked 'SupportFiles\AppConfig.json'), 'Open', 'Read', 'None')
    try { $null = & $riskCase 'an AppConfig.json locked by another process' $pLocked $false 'Psadt41' } finally { $lock.Dispose() }
    $pNoScript = New-RiskProject 'no-script'
    Remove-Item -LiteralPath (Join-Path $pNoScript 'Invoke-AppDeployToolkit.ps1') -Force
    $null = & $riskCase 'no Invoke-AppDeployToolkit.ps1' $pNoScript $false ''
    $null = & $riskCase 'a deploy script that does not parse' (New-RiskProject 'parse-error' -Edit { param($t) $t + "`r`nfunction Broken {`r`n" }) $false 'Unknown'
    $null = & $riskCase 'a missing project folder' (Join-Path $TMP 'does-not-exist') $false ''

    # ============================== [2] the guest probe ==============================
    Write-Host '[2] Get-Win32ToolkitGuestSignedInUser (Invoke-Command shadowed)' -ForegroundColor Cyan
    $script:icBound = $null
    $script:icAnswer = { $null }
    function Invoke-Command {
        [CmdletBinding()]
        param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
        $script:icBound = @{}
        foreach ($k in $PSBoundParameters.Keys) { $script:icBound[$k] = $PSBoundParameters[$k] }
        & $script:icAnswer
    }
    $guestCase = {
        param([string]$Label, [scriptblock]$Answer, [bool]$Checked, [bool]$SignedIn, [int]$Count)
        $script:icAnswer = $Answer
        $g = $null; $threw = $null
        try { $g = Get-Win32ToolkitGuestSignedInUser -Session 'SESSION' -ErrorAction Stop } catch { $threw = $_ }
        if (-not $threw -and $g -and $g.Checked -eq $Checked -and $g.SignedIn -eq $SignedIn -and $g.SessionCount -eq $Count -and ($Checked -or $g.Reason)) {
            Ok "${Label}: Checked $Checked, SignedIn $SignedIn, SessionCount $Count$(if (-not $Checked) { " ($($g.Reason))" })"
        } else { Bad "${Label}: threw=$($threw.Exception.Message) result=$($g | ConvertTo-Json -Compress)" }
    }
    & $guestCase 'an Active/Connected user session (UiSessionIds [1])' { [pscustomobject]@{ ConsoleUser = $false; ExplorerSessionIds = [int[]]@(1); UiSessionIds = [int[]]@(1) } } $true $true 1
    & $guestCase 'a console user only (UiSessionIds [])' { [pscustomobject]@{ ConsoleUser = $true; ExplorerSessionIds = [int[]]@(); UiSessionIds = [int[]]@() } } $true $true 1
    & $guestCase 'two UI sessions and a console user' { [pscustomobject]@{ ConsoleUser = $true; ExplorerSessionIds = [int[]]@(1, 3); UiSessionIds = [int[]]@(1, 3) } } $true $true 2
    & $guestCase 'a disconnected session only (ExplorerSessionIds [2], UiSessionIds [], no console user)' { [pscustomobject]@{ ConsoleUser = $false; ExplorerSessionIds = [int[]]@(2); UiSessionIds = [int[]]@() } } $true $false 0
    & $guestCase 'nobody (UiSessionIds deserialised as $null)' { [pscustomobject]@{ ConsoleUser = $false; ExplorerSessionIds = $null; UiSessionIds = $null } } $true $false 0
    & $guestCase 'the remote call throws' { throw 'PowerShell Direct broke' } $false $false 0
    & $guestCase 'the remote call returns $null' { $null } $false $false 0
    & $guestCase 'an answer without UiSessionIds' { [pscustomobject]@{ ConsoleUser = $true; ExplorerSessionIds = [int[]]@(1) } } $false $false 0
    & $guestCase 'an answer without ConsoleUser' { [pscustomobject]@{ ExplorerSessionIds = [int[]]@(1); UiSessionIds = [int[]]@(1) } } $false $false 0
    & $guestCase 'two answers' { [pscustomobject]@{ ConsoleUser = $true; ExplorerSessionIds = @(); UiSessionIds = @() }; [pscustomobject]@{ ConsoleUser = $true; ExplorerSessionIds = @(); UiSessionIds = @() } } $false $false 0
    $script:icAnswer = { throw "bad`e[31m news" }
    $gEsc = Get-Win32ToolkitGuestSignedInUser -Session 'SESSION'
    if ($gEsc.Reason -notmatch "`e" -and $gEsc.Reason -like 'bad?*news') { Ok 'the Reason is sanitised (ESC -> ?)' } else { Bad "reason: $($gEsc.Reason)" }
    if ($script:icBound.ErrorAction -eq 'Stop' -and -not $script:icBound.ContainsKey('ArgumentList') -and $script:icBound.Session -eq 'SESSION' -and $script:icBound.ScriptBlock) {
        Ok 'Invoke-Command -Session <the session> -ErrorAction Stop -ScriptBlock { ... }, no -ArgumentList'
    } else { Bad "bound: $(@($script:icBound.Keys) -join ',') ErrorAction=$($script:icBound.ErrorAction)" }

    # C-11 on the scriptblock text the guest receives.
    $sbText = $script:icBound.ScriptBlock.ToString()
    $sbFile = Join-Path $TMP 'guest-scriptblock.ps1'
    [System.IO.File]::WriteAllText($sbFile, $sbText, [System.Text.UTF8Encoding]::new($false))
    $err51 = @(Test-Win32ToolkitPS51Syntax -Path $sbFile)
    if ($err51.Count -eq 0) { Ok 'the guest scriptblock parses under Windows PowerShell 5.1' } else { Bad "5.1 parse: $($err51 -join ' | ')" }
    if (@([System.Text.Encoding]::UTF8.GetBytes($sbText) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the guest scriptblock is ASCII' } else { Bad 'non-ASCII guest scriptblock' }
    $tokens = $null
    $sbAst = [System.Management.Automation.Language.Parser]::ParseInput($sbText, [ref]$tokens, [ref]$null)
    $first = @($sbAst.EndBlock.Statements)[0]
    if ($first -and $first.Extent.Text -ceq "`$ErrorActionPreference = 'Stop'") { Ok "its first statement is `$ErrorActionPreference = 'Stop'" } else { Bad "first statement: $($first.Extent.Text)" }
    if ($sbText -notmatch '(?i)\bquser\b' -and $sbText -notmatch '(?i)\bquery\s+(user|session)\b') { Ok 'no quser / query session text scraping' } else { Bad 'text scraping in the guest scriptblock' }
    if (@($tokens | Where-Object { $_.Kind -in 'HereStringExpandable', 'HereStringLiteral' }).Count -eq 0) { Ok 'no here-string' } else { Bad 'here-string in the guest scriptblock' }
    $assigned = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $sbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ([object]::ReferenceEquals($a, $first)) { continue }
        $left = $a.Left
        while ($true) {
            if ($left -is [System.Management.Automation.Language.IndexExpressionAst]) { $left = $left.Target }
            elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst]) { $left = $left.Expression }
            elseif ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
            else { break }
        }
        $assigned.Add($(if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) { $left.VariablePath.UserPath } else { $left.Extent.Text }))
    }
    foreach ($fe in $sbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $assigned.Add($fe.Variable.VariablePath.UserPath) }
    $notW32t = @($assigned | Where-Object { $_ -notlike 'w32t*' })
    if ($assigned.Count -ge 4 -and $notW32t.Count -eq 0) { Ok "every other assigned variable is `$w32t* ($(@($assigned | Select-Object -Unique) -join ', '))" } else { Bad "assigned: $($assigned -join ', ')" }
    # One live run of that text in a Windows PowerShell 5.1 child on this host (read-only: CIM + the session list).
    $liveFile = Join-Path $TMP 'guest-live.ps1'
    [System.IO.File]::WriteAllText($liveFile, ("`$w32tAnswer = @(& {`r`n" + $sbText + "`r`n})`r`nConvertTo-Json -InputObject @(`$w32tAnswer | Select-Object ConsoleUser, ExplorerSessionIds, UiSessionIds) -Compress`r`n"), [System.Text.UTF8Encoding]::new($false))
    $liveOut = & $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $liveFile 2>&1
    $liveRc = $LASTEXITCODE
    $live = $null
    try { $live = @((@($liveOut) | ForEach-Object { "$_" }) -join '' | ConvertFrom-Json) } catch { $live = $null }
    if ($liveRc -eq 0 -and $live -and @($live).Count -eq 1 -and @('ConsoleUser', 'ExplorerSessionIds', 'UiSessionIds' | Where-Object { $live[0].PSObject.Properties[$_] }).Count -eq 3) {
        Ok 'a live run under Windows PowerShell 5.1 on this host returns one object with ConsoleUser, ExplorerSessionIds and UiSessionIds'
    } else { Bad "live 5.1 run: rc=$liveRc out=$(@($liveOut) -join ' ')" }
    Remove-Item Function:\Invoke-Command

    # ============================== [3] the pre-check ==============================
    Write-Host '[3] Invoke-Win32ToolkitParityPrecheck (VM, sessions, credential and config shadowed)' -ForegroundColor Cyan
    $script:cfg = @{}
    function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
    $script:cred = [pscredential]::new('w32admin', (New-Object System.Security.SecureString))
    function Get-Win32ToolkitGuestCredential { $script:cred }
    $script:log = [System.Collections.Generic.List[string]]::new()
    $script:vmThrows = $false; $script:openThrows = $false
    function Get-VM { param($Name, $ErrorAction) $script:log.Add("get-vm:$Name"); if ($script:vmThrows) { throw "Hyper-V was unable to find a virtual machine with name '$Name'." }; [pscustomobject]@{ Name = $Name; State = 'Running' } }
    # Speed-up PR 1: the open fills -Info (a restore that landed warm by default; [3b] varies it).
    $script:openRevertSkipped = $false; $script:openWarm = $true
    function New-Win32ToolkitHyperVSession { param($VMName, [pscredential]$Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop, [hashtable]$Info)
        $script:log.Add("open:${VMName}:$CheckpointName"); if ($script:openThrows) { throw 'PowerShell Direct is not ready' }
        if ($null -ne $Info) { $Info['RevertSkipped'] = $script:openRevertSkipped; $Info['Warm'] = $script:openWarm; $Info['VMId'] = $script:laneVmId }
        'SESSION' }
    function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert) $script:log.Add("remove:${Session}:${VMName}:${CheckpointName}:revert=$($Revert.IsPresent)") }
    $script:guest = $null
    function Get-Win32ToolkitGuestSignedInUser { param($Session) $script:log.Add("query:$Session"); $script:guest }
    # Speed-up PR 1 (C-9): the cache, lane and console helpers of the pre-check. They default to a miss with a readable
    # lane and no console, and count their calls on their own (never in $script:log, so the sequences below stay exact).
    $script:laneVmId = '0e5f9e66-1111-2222-3333-444455556666'
    $script:laneCalls = 0; $script:laneNull = $false
    function Get-Win32ToolkitHyperVLane { param($VMName, $CheckpointName, $VM)
        $script:laneCalls++
        if ($script:laneNull) { return @{ VMName = $VMName; VMId = $script:laneVmId; CheckpointName = $CheckpointName; CheckpointId = ''; CheckpointCreationTicks = $null } }
        @{ VMName = $VMName; VMId = $script:laneVmId; CheckpointName = $CheckpointName; CheckpointId = '29613cba-d62f-4998-a421-df2e124a2b4f'; CheckpointCreationTicks = 638653893400000000; ConcurrentLanes = 1 }
    }
    $script:cacheGets = 0; $script:cacheAnswer = $null
    function Get-Win32ToolkitParityProbeCache { param($VMId, $CheckpointId, $CreationTimeUtcTicks, $ProbeVersion) $script:cacheGets++; $script:cacheAnswer }
    $script:cacheSets = [System.Collections.Generic.List[object]]::new()
    function Set-Win32ToolkitParityProbeCache { param($VMId, $CheckpointId, $CreationTimeUtcTicks, $SignedIn, $SessionCount, $ProbeVersion)
        $script:cacheSets.Add([pscustomobject]@{ VMId = $VMId; CheckpointId = $CheckpointId; Ticks = $CreationTimeUtcTicks; SignedIn = $SignedIn; SessionCount = $SessionCount }) }
    $script:vmcAnswers = [System.Collections.Generic.Queue[bool]]::new(); $script:vmcCalls = 0
    function Test-Win32ToolkitVMConnectOpen { param($VMName, $VMId) $script:vmcCalls++; if ($script:vmcAnswers.Count) { $script:vmcAnswers.Dequeue() } else { $false } }
    # The checkpoint attestation (P1-4): records how it was asked, returns $script:attAnswer ($null by default).
    $script:attCalls = [System.Collections.Generic.List[object]]::new(); $script:attAnswer = $null
    function Get-Win32ToolkitCheckpointAttestation { param($Session, $VMName, $CheckpointName, $VMId, $CheckpointId, $CreationTimeUtcTicks, [switch]$AllowLive, [switch]$AllowStore, $SignedInAnswer)
        $script:attCalls.Add([pscustomobject]@{ Session = $Session; AllowLive = [bool]$AllowLive; AllowStore = [bool]$AllowStore; SignedInAnswer = $SignedInAnswer; VMId = $VMId; CheckpointId = $CheckpointId; Ticks = $CreationTimeUtcTicks })
        $script:attAnswer }
    $signedIn = [pscustomobject]@{ Checked = $true; SignedIn = $true; SessionCount = 1; Reason = '' }
    $nobody   = [pscustomobject]@{ Checked = $true; SignedIn = $false; SessionCount = 0; Reason = '' }
    $unknown  = [pscustomobject]@{ Checked = $false; SignedIn = $false; SessionCount = 0; Reason = 'the guest returned no answer' }
    $preCase = {
        param([string]$Project, [string]$Scenario = 'InstallUninstall')
        $script:log.Clear()
        $w = $null; $r = $null; $threw = $null; $iv = $null
        try { $r = Invoke-Win32ToolkitParityPrecheck -ProjectPath $Project -Scenario $Scenario -WarningVariable w -InformationVariable iv -ErrorAction Stop 3>$null 6>$null } catch { $threw = $_ }
        [pscustomobject]@{ R = $r; Warnings = @($w | ForEach-Object { "$_" }); Threw = $threw; Log = @($script:log); Info = @($iv | ForEach-Object { "$_" }) }
    }
    $progressLine = { param($x, [string]$Cp) @($x.Info | Where-Object { $_ -ceq "Intune-parity pre-check: checking whether a user is signed in to the test VM 'vm-test' (restores checkpoint '$Cp' before and after; this can take a few minutes)..." }).Count }
    $script:cfg = @{ HyperVVMName = 'vm-test' }
    # not at risk: nothing touches the VM
    $script:guest = $signedIn
    $x = & $preCase $pListed
    if (-not $x.Threw -and $x.R.Blocked -eq $false -and $x.Log.Count -eq 0 -and $x.R.Risk -and $x.R.Risk.AtRisk -eq $false -and $x.R.Risk.Shape -eq 'Psadt41' -and -not $x.R.NotRun -and -not $x.R.Message) {
        Ok 'not at risk -> not blocked; no Get-VM, no session; Risk (with Shape) is still returned'
    } else { Bad "not at risk: $($x | ConvertTo-Json -Compress -Depth 4)" }
    if ($x.Info.Count -eq 0) { Ok 'not at risk -> no host line (the VM is not touched)' } else { Bad "not at risk printed: $($x.Info -join ' | ')" }
    # at risk + signed in: blocked
    $x = & $preCase $pAtRisk
    $leaf = Split-Path -Leaf $pAtRisk
    $m = [string]$x.R.Message
    if (-not $x.Threw -and $x.R.Blocked -and ($x.Log -join ' > ') -eq "get-vm:vm-test > open:vm-test:clean-base > query:SESSION > remove:SESSION:vm-test:clean-base:revert=True") {
        Ok 'at risk + signed in -> Blocked; its own session on the run''s checkpoint: Get-VM, open, query, revert (once)'
    } else { Bad "blocked: $($x | ConvertTo-Json -Compress -Depth 4)" }
    # Live P5: the two checkpoint restores took 3 minutes with no output before the warning.
    if ((& $progressLine $x 'clean-base') -eq 1 -and $x.Info.Count -eq 1) { Ok 'at risk -> one host line before the VM work: the check runs, the VM and checkpoint, it can take minutes' } else { Bad "progress line: $($x.Info -join ' | ')" }
    if ($m -match 'NOT started' -and $m -match '1460' -and $m -match 'watched' -and $m -match 'ProcessesToClose' -and $m -match 'always restores to a signed-in desktop' -and
        $m.Contains("'vm-test'") -and $m.Contains("'$leaf'") -and $m -notmatch '(?i)sign the user out' -and $m -match 'Install -> Uninstall' -and $m -match "org template's welcome dialog \(OrgUi\.Welcome: AllowDefer\)") {
        Ok 'the message: NOT started, 1460, watched, ProcessesToClose, the signed-in desktop, the VM and the project, no "sign the user out"'
    } else { Bad "message: $m" }
    # Live P5 r2: with HyperVTestMode=Unattended, dropping -Unattended alone ran unattended again (Get-Win32ToolkitTestMode).
    # TUI audit G3: -TestMode Interactive overrides HyperVTestMode for one run, so the advice names it (and the TUI's
    # Hyper-V run mode) instead of the three conditions and a registry edit.
    if ($m.Contains('(Test-Win32ToolkitProject -TestMode Interactive, or Interactive as the Hyper-V run mode under Run a test in the menu, from an interactive console: -TestMode overrides the HyperVTestMode value for that run), ') -and
        $m -notmatch 'all three' -and $m -notmatch 'without -Unattended, or') {
        Ok 'the watched-run advice names -TestMode Interactive and the menu''s Hyper-V run mode (no "all three", no registry edit)'
    } else { Bad "watched advice: $m" }
    if (@([System.Text.Encoding]::UTF8.GetBytes($m) | Where-Object { $_ -gt 127 }).Count -eq 0 -and $x.Warnings.Count -eq 0) { Ok 'the message is ASCII; the pre-check itself prints no warning (the caller prints the message)' } else { Bad "ascii/warnings: $($x.Warnings -join ' | ')" }
    $n = $x.R.NotRun
    if ($n -is [hashtable] -and $n.Code -eq 'PARITY-DIALOG-WAIT' -and $n.Shape -eq 'Psadt41' -and $n.ProcessesToClose -eq 0 -and $n.Welcome -eq 'OrgUi' -and $n.SignedInSessions -eq 1 -and
        $x.R.Notes -like 'Not run (Intune-parity pre-check): *' -and $x.R.Notes -match 'ProcessesToClose' -and $x.R.Guest.SignedIn) {
        Ok 'NotRun = Code PARITY-DIALOG-WAIT, Shape Psadt41, ProcessesToClose 0, Welcome OrgUi, SignedInSessions 1; Notes name ProcessesToClose'
    } else { Bad "NotRun/Notes: $($x.R | ConvertTo-Json -Compress -Depth 4)" }
    $x = & $preCase (Join-Path $TMP 'tpl-default') 'Update'
    if ($x.R.Blocked -and $x.R.Message -match 'unattended Hyper-V Update test' -and $x.R.Message -match 'a welcome dialog in the deploy script' -and $x.R.NotRun.Welcome -eq 'Script') { Ok 'Update + a deploy-script welcome: the message names the Update test and the deploy script''s welcome; NotRun.Welcome Script' } else { Bad "update/script: $($x.R.Message)" }
    # at risk + nobody signed in / not checked: not blocked
    $script:guest = $nobody
    $x = & $preCase $pAtRisk
    if ($x.R.Blocked -eq $false -and -not $x.R.NotRun -and $x.Warnings.Count -eq 0 -and @($x.Log | Where-Object { $_ -like 'remove:*revert=True' }).Count -eq 1) { Ok 'at risk + nobody signed in -> not blocked (no warning), the VM reverted once' } else { Bad "nobody: $($x | ConvertTo-Json -Compress -Depth 4)" }
    $script:guest = $unknown
    $x = & $preCase $pAtRisk
    if ($x.R.Blocked -eq $false -and $x.Warnings.Count -eq 1 -and $x.Warnings[0] -match 'could not tell whether a user is signed in' -and $x.Warnings[0] -match 'starts as usual') { Ok 'Checked $false -> not blocked (fail-open), one warning' } else { Bad "unknown: $($x | ConvertTo-Json -Compress -Depth 4)" }
    # the session cannot be opened: fail-open, still reverted
    $script:guest = $signedIn; $script:openThrows = $true
    $x = & $preCase $pAtRisk
    $script:openThrows = $false
    if (-not $x.Threw -and $x.R.Blocked -eq $false -and $x.Warnings.Count -eq 1 -and $x.Warnings[0] -match '^Intune-parity pre-check could not reach the VM \(PowerShell Direct is not ready\); the run starts as usual\.$' -and
        @($x.Log | Where-Object { $_ -like 'remove:*' }).Count -eq 1 -and @($x.Log | Where-Object { $_ -like 'remove:*' })[0] -like '*revert=True') {
        Ok 'the session open throws -> not blocked, one warning, Remove-Win32ToolkitHyperVSession -Revert called once'
    } else { Bad "open throws: $($x | ConvertTo-Json -Compress -Depth 4)" }
    # no such VM: one warning, no teardown
    $script:vmThrows = $true
    $x = & $preCase $pAtRisk
    $script:vmThrows = $false
    if (-not $x.Threw -and $x.R.Blocked -eq $false -and $x.Warnings.Count -eq 1 -and $x.Warnings[0] -like 'Intune-parity pre-check could not reach the VM (*' -and @($x.Log | Where-Object { $_ -like 'remove:*' -or $_ -like 'open:*' }).Count -eq 0) {
        Ok 'Get-VM throws (no such VM) -> not blocked, exactly one warning (the pre-check''s), Remove-Win32ToolkitHyperVSession never called'
    } else { Bad "no VM: $($x | ConvertTo-Json -Compress -Depth 4)" }
    # the run's configured checkpoint
    $script:cfg = @{ HyperVVMName = 'vm-test'; HyperVCheckpoint = 'warm-x' }
    $x = & $preCase $pAtRisk
    if ($x.R.Blocked -and @($x.Log | Where-Object { $_ -eq 'open:vm-test:warm-x' }).Count -eq 1 -and @($x.Log | Where-Object { $_ -eq 'remove:SESSION:vm-test:warm-x:revert=True' }).Count -eq 1) { Ok 'HyperVCheckpoint warm-x -> the session opens and reverts warm-x (the run''s base checkpoint)' } else { Bad "checkpoint: $($x.Log -join ' > ')" }
    if ((& $progressLine $x 'warm-x') -eq 1) { Ok 'the host line names the configured checkpoint' } else { Bad "progress line (warm-x): $($x.Info -join ' | ')" }
    # no credential: nothing touches the VM
    $script:cfg = @{ HyperVVMName = 'vm-test' }; $script:cred = $null
    $x = & $preCase $pAtRisk
    if ($x.R.Blocked -eq $false -and $x.Log.Count -eq 0 -and $x.R.Risk.AtRisk) { Ok 'no guest credential -> not blocked, no Get-VM, no session (the run raises its usual error)' } else { Bad "no credential: $($x | ConvertTo-Json -Compress -Depth 4)" }
    if ($x.Info.Count -eq 0) { Ok 'no guest credential -> no host line' } else { Bad "no credential printed: $($x.Info -join ' | ')" }
    $script:cred = [pscredential]::new('w32admin', (New-Object System.Security.SecureString))

    # ============================== [3b] the answer cache (speed-up PR 1) ==============================
    Write-Host '[3b] the pre-check answer cache: a miss asks the guest and stores, a hit restores nothing; what is never stored' -ForegroundColor Cyan
    $reset3b = { $script:cacheGets = 0; $script:cacheAnswer = $null; $script:cacheSets.Clear(); $script:vmcAnswers.Clear(); $script:vmcCalls = 0; $script:laneCalls = 0; $script:laneNull = $false
        $script:openRevertSkipped = $false; $script:openWarm = $true; $script:guest = $signedIn; $script:cfg = @{ HyperVVMName = 'vm-test' } }
    # miss: the live probe, one host line, stored once
    & $reset3b
    $live = & $preCase $pAtRisk
    $set = @($script:cacheSets)
    if ($live.R.Blocked -and $live.R.FromCache -eq $false -and ($live.Log -join ' > ') -eq 'get-vm:vm-test > open:vm-test:clean-base > query:SESSION > remove:SESSION:vm-test:clean-base:revert=True' -and
        (& $progressLine $live 'clean-base') -eq 1 -and $script:cacheGets -eq 1 -and $set.Count -eq 1 -and $set[0].VMId -eq $script:laneVmId -and $set[0].CheckpointId -eq '29613cba-d62f-4998-a421-df2e124a2b4f' -and
        $set[0].Ticks -eq 638653893400000000 -and $set[0].SignedIn -eq $true -and $set[0].SessionCount -eq 1 -and $script:vmcCalls -eq 3) {
        Ok 'miss: the live probe (open, query, revert), one host line, the answer stored once with the checkpoint identity; three console checks (open, probe, store)'
    } else { Bad "miss: $($live | ConvertTo-Json -Compress -Depth 4) gets=$($script:cacheGets) sets=$($set | ConvertTo-Json -Compress) vmc=$($script:vmcCalls)" }
    if ($live.R.Seconds -is [double] -and $live.R.Seconds -ge 0 -and $live.R.Lane -and $live.R.Lane.CheckpointId -eq '29613cba-d62f-4998-a421-df2e124a2b4f') { Ok 'the result carries Seconds and the Lane' } else { Bad "keys: seconds=$($live.R.Seconds) lane=$($live.R.Lane | ConvertTo-Json -Compress)" }
    # hit: nothing restored, no host line, the same result
    & $reset3b
    $script:cacheAnswer = [pscustomobject]@{ SignedIn = $true; SessionCount = 1 }
    $hit = & $preCase $pAtRisk
    if ($hit.R.Blocked -and $hit.R.FromCache -eq $true -and ($hit.Log -join ' > ') -eq 'get-vm:vm-test' -and $hit.Info.Count -eq 0 -and $script:cacheSets.Count -eq 0 -and $script:vmcCalls -eq 0) {
        Ok 'hit: no open, no query, no revert, no host line, nothing stored again; FromCache $true'
    } else { Bad "hit: $($hit | ConvertTo-Json -Compress -Depth 4) sets=$($script:cacheSets.Count) vmc=$($script:vmcCalls)" }
    if ($hit.R.Message -ceq $live.R.Message -and $hit.R.Notes -ceq $live.R.Notes -and ($hit.R.NotRun | ConvertTo-Json -Compress) -ceq ($live.R.NotRun | ConvertTo-Json -Compress) -and $hit.R.Guest.Checked) {
        Ok 'hit: the same Message, Notes and NotRun as the live answer (SignedInSessions from the cache)'
    } else { Bad "hit vs live: $($hit.R.NotRun | ConvertTo-Json -Compress) / $($live.R.NotRun | ConvertTo-Json -Compress)" }
    $script:cacheAnswer = [pscustomobject]@{ SignedIn = $true; SessionCount = 2 }
    $hit2 = & $preCase $pAtRisk
    if ($hit2.R.NotRun.SignedInSessions -eq 2) { Ok 'hit: SignedInSessions is the stored session count' } else { Bad "sessions: $($hit2.R.NotRun | ConvertTo-Json -Compress)" }
    $script:cacheAnswer = [pscustomobject]@{ SignedIn = $false; SessionCount = 0 }
    $hit3 = & $preCase $pAtRisk
    if ($hit3.R.Blocked -eq $false -and $hit3.R.FromCache -and $hit3.Warnings.Count -eq 0) { Ok 'hit with nobody signed in: not blocked, no warning' } else { Bad "hit nobody: $($hit3 | ConvertTo-Json -Compress -Depth 4)" }
    # never stored
    foreach ($case in @(
            @{ Tag = 'Checked $false'; Set = { $script:guest = $unknown } }
            @{ Tag = 'the open landed cold (Warm $false)'; Set = { $script:openWarm = $false } }
            @{ Tag = 'the open skipped its restore (RevertSkipped $true)'; Set = { $script:openRevertSkipped = $true } }
            @{ Tag = 'a VM console open throughout'; Set = { foreach ($b in $true, $true, $true) { $script:vmcAnswers.Enqueue($b) } } }
            @{ Tag = 'a console seen at the open, gone at the store (V-10)'; Set = { foreach ($b in $true, $false, $false) { $script:vmcAnswers.Enqueue($b) } } }
            @{ Tag = 'a console seen only right after the probe (V-10)'; Set = { foreach ($b in $false, $true, $false) { $script:vmcAnswers.Enqueue($b) } } }
            @{ Tag = 'a console seen only at the store'; Set = { foreach ($b in $false, $false, $true) { $script:vmcAnswers.Enqueue($b) } } }
            @{ Tag = 'the checkpoint identity could not be read'; Set = { $script:laneNull = $true } })) {
        & $reset3b
        & $case.Set
        $x = & $preCase $pAtRisk
        if (-not $x.Threw -and $x.R.FromCache -eq $false -and @($x.Log | Where-Object { $_ -like 'query:*' }).Count -eq 1 -and $script:cacheSets.Count -eq 0) { Ok "$($case.Tag): asked live, not stored" } else { Bad "$($case.Tag): sets=$($script:cacheSets.Count) $($x | ConvertTo-Json -Compress -Depth 4)" }
    }
    # HyperVPrecheckCache Off: live, never read, never stored
    & $reset3b
    $script:cfg = @{ HyperVVMName = 'vm-test'; HyperVPrecheckCache = 'off' }
    $script:cacheAnswer = [pscustomobject]@{ SignedIn = $true; SessionCount = 1 }
    $x = & $preCase $pAtRisk
    if ($x.R.Blocked -and $x.R.FromCache -eq $false -and $script:cacheGets -eq 0 -and $script:cacheSets.Count -eq 0 -and @($x.Log | Where-Object { $_ -like 'query:*' }).Count -eq 1) { Ok 'HyperVPrecheckCache off (any case): the guest is asked, the cache is neither read nor written' } else { Bad "cache off: gets=$($script:cacheGets) sets=$($script:cacheSets.Count) $($x | ConvertTo-Json -Compress -Depth 4)" }
    $script:cfg = @{ HyperVVMName = 'vm-test'; HyperVPrecheckCache = 'Sometimes' }
    $x = & $preCase $pAtRisk
    if ($x.R.FromCache -eq $true) { Ok 'HyperVPrecheckCache with any other value: On (the stored answer is used)' } else { Bad "cache other value: $($x | ConvertTo-Json -Compress -Depth 4)" }
    # not at risk: the cache is never asked
    & $reset3b
    $x = & $preCase $pListed
    if ($script:cacheGets -eq 0 -and $script:cacheSets.Count -eq 0 -and $script:laneCalls -eq 0 -and $x.R.FromCache -eq $false -and $null -eq $x.R.Lane -and $x.R.Seconds -ge 0) { Ok 'not at risk: no lane, no cache call; FromCache $false, Lane $null' } else { Bad "not at risk: gets=$($script:cacheGets) lane=$($script:laneCalls) $($x.R | ConvertTo-Json -Compress -Depth 3)" }
    & $reset3b

    # ============================== [3c] the checkpoint attestation (speed-up PR 1) ==============================
    Write-Host '[3c] the checkpoint attestation: a miss reuses the probe''s answer; a hit only reads the stored attestation' -ForegroundColor Cyan
    & $reset3b
    $script:attCalls.Clear()
    $script:attAnswer = [pscustomobject]@{ SignedIn = $true; DefenderRealTime = $true; DefenderExclusionCount = 0; SignatureAgeDays = 3; FromCache = $false }
    $x = & $preCase $pAtRisk
    $c = @($script:attCalls)
    if ($c.Count -eq 1 -and $c[0].Session -eq 'SESSION' -and [object]::ReferenceEquals($c[0].SignedInAnswer, $signedIn) -and $c[0].AllowLive -and $c[0].AllowStore -and $c[0].VMId -eq $script:laneVmId -and
        $c[0].CheckpointId -eq '29613cba-d62f-4998-a421-df2e124a2b4f' -and $c[0].Ticks -eq 638653893400000000 -and $x.R.Lane.Attestation -and $x.R.Lane.Attestation.SignatureAgeDays -eq 3 -and @($x.Log | Where-Object { $_ -like 'query:*' }).Count -eq 1) {
        Ok 'miss: the attestation gets the session and the probe''s answer (-SignedInAnswer, no second sign-in probe), -AllowLive/-AllowStore, the lane identity; it reaches Lane.Attestation'
    } else { Bad "miss: calls=$($c | ConvertTo-Json -Compress -Depth 2) lane=$($x.R.Lane | ConvertTo-Json -Compress -Depth 3)" }
    foreach ($case in @(
            @{ Tag = 'a console seen after the probe'; Set = { foreach ($b in $false, $true) { $script:vmcAnswers.Enqueue($b) } }; Live = $true; Store = $false }
            @{ Tag = 'the open landed cold'; Set = { $script:openWarm = $false }; Live = $false; Store = $false }
            @{ Tag = 'the open skipped its restore'; Set = { $script:openRevertSkipped = $true }; Live = $false; Store = $false })) {
        & $reset3b
        $script:attCalls.Clear()
        & $case.Set
        $null = & $preCase $pAtRisk
        $c = @($script:attCalls)
        if ($c.Count -eq 1 -and $c[0].AllowLive -eq $case.Live -and $c[0].AllowStore -eq $case.Store) { Ok "$($case.Tag): -AllowLive $($case.Live), -AllowStore $($case.Store)" } else { Bad "$($case.Tag): $($c | ConvertTo-Json -Compress -Depth 2)" }
    }
    & $reset3b
    $script:attCalls.Clear()
    $script:cacheAnswer = [pscustomobject]@{ SignedIn = $true; SessionCount = 1 }
    $script:attAnswer = [pscustomobject]@{ SignedIn = $true; DefenderRealTime = $true; DefenderExclusionCount = 0; SignatureAgeDays = 3; FromCache = $true }
    $x = & $preCase $pAtRisk
    $c = @($script:attCalls)
    if ($x.R.FromCache -and $c.Count -eq 1 -and $c[0].AllowLive -eq $false -and $c[0].AllowStore -eq $false -and $x.R.Lane.Attestation.FromCache -and @($x.Log | Where-Object { $_ -like 'query:*' -or $_ -like 'open:*' }).Count -eq 0) {
        Ok 'hit: the attestation is only read from its store (-AllowLive off: no guest call), and reaches Lane.Attestation'
    } else { Bad "hit: $($c | ConvertTo-Json -Compress -Depth 2)" }
    ${function:Get-Win32ToolkitCheckpointAttestation_Saved} = ${function:Get-Win32ToolkitCheckpointAttestation}
    function Get-Win32ToolkitCheckpointAttestation { param([Parameter(ValueFromRemainingArguments)]$Rest) throw 'attestation broke' }
    & $reset3b
    $x = & $preCase $pAtRisk
    ${function:Get-Win32ToolkitCheckpointAttestation} = ${function:Get-Win32ToolkitCheckpointAttestation_Saved}
    Remove-Item Function:\Get-Win32ToolkitCheckpointAttestation_Saved
    if (-not $x.Threw -and $x.R.Blocked -and $x.Warnings.Count -eq 0 -and $script:cacheSets.Count -eq 1) { Ok 'a throwing attestation: the pre-check answer is unchanged (blocked, no warning, the probe answer still stored)' } else { Bad "attestation throws: $($x | ConvertTo-Json -Compress -Depth 3)" }
    & $reset3b; $script:attAnswer = $null; $script:attCalls.Clear()

    # ============================== [4] file hygiene ==============================
    Write-Host '[4] the pre-check files: ASCII, one function, every catch starts with the C-2 line' -ForegroundColor Cyan
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    # Speed-up PR 1: the four helpers the pre-check now calls.
    foreach ($name in 'Get-Win32ToolkitParityDialogRisk', 'Get-Win32ToolkitGuestSignedInUser', 'Invoke-Win32ToolkitParityPrecheck',
        'Get-Win32ToolkitHyperVLane', 'Get-Win32ToolkitParityProbeCache', 'Set-Win32ToolkitParityProbeCache', 'Test-Win32ToolkitVMConnectOpen', 'Get-Win32ToolkitCheckpointAttestation') {
        $file = Join-Path $repo "Private\$name.ps1"
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
        $catches = @($ast.FindAll({ param($nd) $nd -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
        $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
        $top = @($ast.EndBlock.Statements)
        $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $name -and -not $ast.ParamBlock
        if (@($errs).Count -eq 0 -and $catches.Count -ge 1 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "$name : $($catches.Count) catch(es) with the C-2 line, ASCII, one function" }
        else { Bad "$name : parse errors $(@($errs).Count), catches $($catches.Count), bad catches $($badCatch.Count), ascii $ascii, oneFunction $oneFunction" }
    }
}
finally {
    Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All ParityPrecheck tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail ParityPrecheck test(s) FAILED." -ForegroundColor Red; exit 1 }
