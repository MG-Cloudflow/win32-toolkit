<#
    P1 — the self-relaunch after a PSAppDeployToolkit update targeted the WRONG script with the WRONG
    parameters.

    Create-PSADTProject (a PRIVATE helper) used to do this after updating PSADT:

        $scriptArgs = @('-NoExit','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
        foreach ($key in $PSBoundParameters.Keys) { ... }        # ProjectName / ProjectPath / Force
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $scriptArgs
        exit

    $PSCommandPath is Private\Create-PSADTProject.ps1 — a dot-sourced function definition, NOT a runnable
    entry point — and ProjectName/ProjectPath/Force are the HELPER's parameters, not the user's. So the
    "relaunch" started something meaningless and then killed the user's session, silently losing whatever
    the user actually asked for.

    The fix (option b): the helper cannot know the caller's command line, so it no longer pretends. When a
    PSADT version other than the one this run needs is already loaded, it returns $false with a clear
    "start a new session and re-run" message. No process is spawned, and the user's session is not exited.

    Since the PSADT version policy (impact analysis D1/L4, DOC-07) the update itself is different too:
    only a STABLE, IN-RANGE version is offered and it is installed side by side with
    Install-Module -RequiredVersion (never an in-place upgrade, which could leave the supported range),
    and a copy already loaded in the session suppresses the offer entirely. This test drives both
    paths in child sessions:
      [A] an older PSADT copy is already loaded -> no offer, no install, no import, no relaunch,
          $false + "new PowerShell session ... re-run".
      [B] a fresh session accepts the offer -> Install-Module -RequiredVersion, re-selection, import by
          path without -Force, scaffold, $true - and still no relaunch.
    The module lookups, the gallery, Start-Process and New-ADTTemplate are all shadowed — nothing is
    installed and nothing is launched.

    The call is made in a CHILD pwsh: if the function still called `exit`, it would terminate that child
    before it could record completion, which is exactly how we detect it (an `exit` inside this very test
    process would otherwise end the test with a misleading exit code 0).

    Run:  pwsh -File Tests\P1_SelfRelaunch.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$src  = Join-Path $repo 'Private\Create-PSADTProject.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('w32relaunch_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ══ Part 1 — the code itself ═════════════════════════════════════════════════════════════════════
Write-Host '[P1] Create-PSADTProject no longer spawns a bogus process, and never exits the session' -ForegroundColor Cyan

$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)

# AST, not a text match: the explanatory comment in the fix legitimately mentions these names.
$starts = $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.CommandAst] -and
    $n.GetCommandName() -in @('Start-Process', 'saps')
}, $true)
if ($starts.Count -eq 0) { Ok 'no Start-Process is INVOKED anywhere in the helper (AST-verified)' }
else { Bad "$($starts.Count) Start-Process call(s) remain" }

$exits = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
if ($exits.Count -eq 0) { Ok 'no `exit` statement remains — a private helper must not kill the host session' }
else { Bad "$($exits.Count) exit statement(s) remain" }

$psCmdPathRefs = $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $n.VariablePath.UserPath -eq 'PSCommandPath'
}, $true)
if ($psCmdPathRefs.Count -eq 0) { Ok '$PSCommandPath (the dot-sourced private file — not an entry point) is no longer used as a relaunch target' }
else { Bad '$PSCommandPath is still referenced' }

# The version policy: an update is an in-range side-by-side install, never Update-Module.
function CommandsNamed([string]$Name) {
    $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name
    }, $true)
}
function HasParam($cmd, [string]$Param) {
    @($cmd.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq $Param
    }).Count -gt 0
}
if (@(CommandsNamed 'Update-Module').Count -eq 0) { Ok 'no Update-Module call (an in-place upgrade can leave the supported range)' }
else { Bad 'Update-Module is still invoked' }
$installs = @(CommandsNamed 'Install-Module')
if ($installs.Count -ge 1 -and @($installs | Where-Object { -not (HasParam $_ 'RequiredVersion') }).Count -eq 0) {
    Ok "every Install-Module call pins -RequiredVersion ($($installs.Count) call(s), AST-verified)"
} else { Bad 'an Install-Module call without -RequiredVersion remains' }
$imports = @(CommandsNamed 'Import-Module')
if ($imports.Count -eq 1 -and -not (HasParam $imports[0] 'Force') -and $imports[0].Extent.Text -match '\$sel\.Module\.Path') {
    Ok 'PSADT is imported once, by the selected PATH, without -Force (re-import throws on PSADT 4.2)'
} else { Bad "Import-Module calls: $(($imports | ForEach-Object { $_.Extent.Text }) -join ' | ')" }

# ══ Part 2 — actually drive the policy, in child sessions ════════════════════════════════════════
$harness = Join-Path $work 'harness.ps1'
@'
param([string]$Repo, [string]$Out, [string]$Scenario)

$ErrorActionPreference = 'Stop'
$script:MsgFile = Join-Path $Out 'messages.txt'
$script:CallFile = Join-Path $Out 'calls.txt'
New-Item -ItemType File -Path $script:MsgFile -Force | Out-Null
New-Item -ItemType File -Path $script:CallFile -Force | Out-Null
function Rec([string]$Line) { Add-Content -LiteralPath $script:CallFile -Value $Line }

# ── shadows: nothing reaches PSGallery, the disk we do not own, or a new process ──────────────────
function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object,
          $ForegroundColor, $BackgroundColor, [switch]$NoNewline)
    Add-Content -LiteralPath $script:MsgFile -Value ('HOST: ' + (@($Object) -join ' '))
}
function Write-Warning {
    param([Parameter(Position = 0)][string]$Message)
    Add-Content -LiteralPath $script:MsgFile -Value ('WARN: ' + $Message)
}

function FakeModule([string]$Version) {
    [pscustomobject]@{
        Name        = 'PSAppDeployToolkit'
        Version     = [version]$Version
        Path        = "C:\fake\PSAppDeployToolkit\$Version\PSAppDeployToolkit.psd1"
        ModuleBase  = "C:\fake\PSAppDeployToolkit\$Version"
        PrivateData = @{ PSData = @{} }
    }
}
# [A] 4.2.1 + 4.1.8 installed, 4.1.8 LOADED.  [B] 4.1.8 installed, nothing loaded, gallery has 4.2.1.
$script:installed = if ($Scenario -eq 'A') { @((FakeModule '4.2.1'), (FakeModule '4.1.8')) } else { @(FakeModule '4.1.8') }
$script:loaded    = if ($Scenario -eq 'A') { @(FakeModule '4.1.8') } else { @() }

function Get-Module {
    param($Name, [switch]$ListAvailable, [switch]$All)
    if ($ListAvailable) { return $script:installed }
    return $script:loaded
}
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Find-Module {
    param($Name, $Repository, [switch]$AllVersions, [switch]$AllowPrerelease, $ErrorAction)
    Rec "FIND AllVersions=$($AllVersions.IsPresent) AllowPrerelease=$($AllowPrerelease.IsPresent)"
    [pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = '4.3.0' }
    [pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = '4.2.1' }
}
function Update-Module { param($Name, [switch]$Force) Rec "UPDATE $Name" }
function Install-Module {
    param($Name, $RequiredVersion, $Scope, [switch]$Force, [switch]$AllowClobber, $ErrorAction)
    Rec "INSTALL RequiredVersion=$RequiredVersion Scope=$Scope"
    $script:installed = @(FakeModule $RequiredVersion) + $script:installed
}
function Import-Module {
    param($Name, [switch]$Force, $ErrorAction)
    Rec "IMPORT Name=$Name Force=$($Force.IsPresent)"
}

# the user says "yes, install the update"
function Read-Host { param($Prompt) Rec "PROMPT $Prompt"; 'y' }

# THE BUG: these two are what the broken relaunch used. If either fires, we record it.
function Start-Process {
    param($FilePath, $ArgumentList)
    @{ FilePath = $FilePath; ArgumentList = @($ArgumentList) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Out 'start.json')
}
function Get-Process { param($Id) [pscustomobject]@{ Path = 'C:\fake\pwsh.exe' } }

# The scaffold: a minimal project bundling the version the run selected (4.2.1 in [B]).
function New-ADTTemplate {
    param($Destination, $Name, [switch]$PassThru, [switch]$ZeroConfig)
    Rec "NTT ZeroConfig=$($ZeroConfig.IsPresent) PassThru=$($PassThru.IsPresent)"
    $p = Join-Path $Destination $Name
    New-Item -ItemType Directory -Path (Join-Path $p 'PSAppDeployToolkit') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'Invoke-AppDeployToolkit.ps1') -Value '# fake'
    Set-Content -LiteralPath (Join-Path $p 'Invoke-AppDeployToolkit.exe') -Value 'MZ'
    Set-Content -LiteralPath (Join-Path $p 'PSAppDeployToolkit\PSAppDeployToolkit.psd1') -Value "@{ ModuleVersion = '4.2.1' }"
}

$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
. (Join-Path $Repo 'Private\Test-Win32ToolkitPsadtVersionSupported.ps1')
. (Join-Path $Repo 'Private\Select-Win32ToolkitPsadtModule.ps1')
. (Join-Path $Repo 'Private\Create-PSADTProject.ps1')
Remove-Item Env:W32T_PSADT_VERSION -ErrorAction SilentlyContinue

$result = Create-PSADTProject -ProjectName 'App_x64_1.0' -ProjectPath (Join-Path $Out 'Projects')

# Reached only if the function RETURNED. The old code called `exit` and never got here.
@{ returned = $true; result = [bool]$result } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Out 'done.json')
'@ | Set-Content -LiteralPath $harness -Encoding UTF8

# Runs one scenario in a child pwsh and returns what it recorded.
function Invoke-Scenario([string]$Name) {
    $out = Join-Path $work "out$Name"
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    & (Get-Process -Id $PID).Path -NoProfile -File $harness -Repo $repo -Out $out -Scenario $Name *> (Join-Path $work "child$Name.log")
    $done = Join-Path $out 'done.json'
    [pscustomobject]@{
        Done    = if (Test-Path -LiteralPath $done) { Get-Content -LiteralPath $done -Raw | ConvertFrom-Json } else { $null }
        Started = if (Test-Path -LiteralPath (Join-Path $out 'start.json')) { Get-Content -LiteralPath (Join-Path $out 'start.json') -Raw | ConvertFrom-Json } else { $null }
        Calls   = @(Get-Content -LiteralPath (Join-Path $out 'calls.txt') -ErrorAction SilentlyContinue)
        Msgs    = if (Test-Path -LiteralPath (Join-Path $out 'messages.txt')) { Get-Content -LiteralPath (Join-Path $out 'messages.txt') -Raw } else { '' }
    }
}
function Assert-NoRelaunch($r) {
    if ($r.Done) { Ok 'the function RETURNED — it did not `exit` the host session' }
    else { Bad 'the function never returned — it still terminates the session with `exit`' }
    if ($r.Started) {
        $cmdline = @($r.Started.ArgumentList) -join ' '
        Bad "a process was still launched: $($r.Started.FilePath) $cmdline"
        # and characterise WHY it was wrong, so a future 'option (a)' cannot pass by accident
        if ($cmdline -match 'Create-PSADTProject\.ps1') { Bad 'it targets the private helper file, not a runnable entry point' }
        if ($cmdline -match '-ProjectName|-ProjectPath')  { Bad "it passes the HELPER's parameters, not the user's command" }
    }
    else { Ok 'no process is launched at all (the old code launched pwsh -File <private helper> -ProjectName ...)' }
}

Write-Host '[A] an older PSADT copy is already loaded in this session' -ForegroundColor Cyan
$a = Invoke-Scenario 'A'
Assert-NoRelaunch $a
if ($a.Done -and $a.Done.result -eq $false) { Ok 'it returns $false, so the caller aborts instead of scaffolding against the loaded copy' }
elseif ($a.Done) { Bad "expected `$false, got $($a.Done.result)" }
if (@($a.Calls | Where-Object { $_ -like 'FIND*' -or $_ -like 'INSTALL*' -or $_ -like 'UPDATE*' -or $_ -like 'PROMPT*' }).Count -eq 0) { Ok 'no gallery query, no install, no prompt while a copy is loaded' }
else { Bad "unexpected calls: $($a.Calls -join ' | ')" }
if (@($a.Calls | Where-Object { $_ -like 'IMPORT*' -or $_ -like 'NTT*' }).Count -eq 0) { Ok 'nothing is imported and nothing is scaffolded' }
else { Bad "unexpected calls: $($a.Calls -join ' | ')" }
if ($a.Msgs -match 'is loaded in this session - start a new PowerShell session to check for updates') { Ok 'the update check explains why it was skipped' } else { Bad 'no "loaded in this session" note' }
if ($a.Msgs -match '(?i)new\s+powershell\s+session')          { Ok 'the user is told a NEW session is required' }      else { Bad 'no "new session" instruction' }
if ($a.Msgs -match '(?im)^WARN:.*4\.1\.8 is already loaded.*needs 4\.2\.1') { Ok 'the warning names the loaded and the needed version' } else { Bad 'no warning naming both versions' }
if ($a.Msgs -match '(?i)re-?run')                              { Ok 'the user is told to re-run their command' }        else { Bad 'no "re-run" instruction' }
if ($a.Msgs -match '(?i)no project was created')               { Ok 'it says plainly that no project was created' }      else { Bad 'does not say the work was not done' }

Write-Host '[B] a fresh session accepts the in-range update offer' -ForegroundColor Cyan
$b = Invoke-Scenario 'B'
Assert-NoRelaunch $b
if ($b.Done -and $b.Done.result -eq $true) { Ok 'the project is created in the same session ($true)' }
elseif ($b.Done) { Bad "expected `$true, got $($b.Done.result) / $($b.Msgs)" }
$ins = @($b.Calls | Where-Object { $_ -like 'INSTALL*' })
if ($ins.Count -eq 1 -and $ins[0] -eq 'INSTALL RequiredVersion=4.2.1 Scope=CurrentUser') { Ok 'the offered 4.2.1 (newest in range; 4.3.0 ignored) is installed side by side with -RequiredVersion' }
else { Bad "installs: $($ins -join ' | ')" }
if (@($b.Calls | Where-Object { $_ -like 'UPDATE*' }).Count -eq 0) { Ok 'Update-Module is never called' } else { Bad 'Update-Module was called' }
$imp = @($b.Calls | Where-Object { $_ -like 'IMPORT*' })
if ($imp.Count -eq 1 -and $imp[0] -match '\\4\.2\.1\\PSAppDeployToolkit\.psd1 Force=False$') { Ok 'the newly installed copy is imported by path, without -Force' }
else { Bad "imports: $($imp -join ' | ')" }
if (@($b.Calls | Where-Object { $_ -eq 'NTT ZeroConfig=True PassThru=True' }).Count -eq 1) { Ok 'scaffolded once, with -ZeroConfig -PassThru (4.2)' } else { Bad "calls: $($b.Calls -join ' | ')" }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_SelfRelaunch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_SelfRelaunch test(s) FAILED." -ForegroundColor Red; exit 1 }
