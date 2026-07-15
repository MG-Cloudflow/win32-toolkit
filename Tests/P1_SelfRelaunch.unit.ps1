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

    The fix (option b): the helper cannot know the caller's command line, so it no longer pretends. It
    performs the update, then returns $false with a clear "start a new session and re-run" message. No
    process is spawned, and the user's session is not exited.

    This test drives the code path that fires AFTER a PSADT update. The update itself, the module lookups
    and Start-Process are all shadowed — nothing is installed and nothing is launched.

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

# ...and the PSADT update itself must be preserved — we only changed what happens AFTER it.
$updates = $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.CommandAst] -and
    $n.GetCommandName() -eq 'Update-Module'
}, $true)
if ($updates.Count -ge 1) { Ok 'the PSAppDeployToolkit update itself is still performed' }
else { Bad 'Update-Module is gone — the update was supposed to be preserved' }

# ══ Part 2 — actually drive the post-update path, in a child session ══════════════════════════════
Write-Host '[P1] driving the post-update path for real (module cmdlets + Start-Process shadowed)' -ForegroundColor Cyan

$harness = Join-Path $work 'harness.ps1'
@'
param([string]$Repo, [string]$Out)

$ErrorActionPreference = 'Stop'
$script:MsgFile = Join-Path $Out 'messages.txt'
New-Item -ItemType File -Path $script:MsgFile -Force | Out-Null

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

# installed 4.0.0, gallery has 4.1.0  -> the "update available" branch
function Get-Module {
    param($Name, [switch]$ListAvailable)
    [pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = [version]'4.0.0' }
}
function Find-Module {
    param($Name, $Repository, $ErrorAction)
    [pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = '4.1.0' }
}
function Update-Module {
    param($Name, [switch]$Force)
    Set-Content -LiteralPath (Join-Path $Out 'update.json') -Value ('{"updated":"' + $Name + '"}')
}
function Install-Module { param($Name, $Scope, [switch]$Force, [switch]$AllowClobber) }
function Import-Module  { param($Name, [switch]$Force) }

# the user says "yes, update"
function Read-Host { param($Prompt) 'y' }

# THE BUG: these two are what the broken relaunch used. If either fires, we record it.
function Start-Process {
    param($FilePath, $ArgumentList)
    @{ FilePath = $FilePath; ArgumentList = @($ArgumentList) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Out 'start.json')
}
function Get-Process { param($Id) [pscustomobject]@{ Path = 'C:\fake\pwsh.exe' } }

# scaffolding must NOT happen on this path (the loaded assembly is the OLD one)
function New-ADTTemplate {
    param($Destination, $Name)
    Set-Content -LiteralPath (Join-Path $Out 'template.json') -Value '{"scaffolded":true}'
}

. (Join-Path $Repo 'Private\Create-PSADTProject.ps1')

$result = Create-PSADTProject -ProjectName 'App_x64_1.0' -ProjectPath (Join-Path $Out 'Projects')

# Reached only if the function RETURNED. The old code called `exit` and never got here.
@{ returned = $true; result = [bool]$result } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Out 'done.json')
'@ | Set-Content -LiteralPath $harness -Encoding UTF8

$out = Join-Path $work 'out'
New-Item -ItemType Directory -Path $out -Force | Out-Null

& (Get-Process -Id $PID).Path -NoProfile -File $harness -Repo $repo -Out $out *> (Join-Path $work 'child.log')

$doneFile  = Join-Path $out 'done.json'
$startFile = Join-Path $out 'start.json'
$updFile   = Join-Path $out 'update.json'
$tmplFile  = Join-Path $out 'template.json'
$msgFile   = Join-Path $out 'messages.txt'

# 1. the function must hand control back — it must NOT exit the user's session
if (Test-Path -LiteralPath $doneFile) {
    Ok 'the function RETURNED — it did not `exit` the host session'
    $done = Get-Content -LiteralPath $doneFile -Raw | ConvertFrom-Json
    if ($done.result -eq $false) { Ok 'it returns $false, so the caller aborts instead of scaffolding against a stale assembly' }
    else { Bad "expected `$false, got $($done.result)" }
}
else {
    Bad 'the function never returned — it still terminates the session with `exit`'
}

# 2. no bogus process — this is the actual bug
if (Test-Path -LiteralPath $startFile) {
    $started = Get-Content -LiteralPath $startFile -Raw | ConvertFrom-Json
    $cmdline = @($started.ArgumentList) -join ' '
    Bad "a process was still launched: $($started.FilePath) $cmdline"
    # and characterise WHY it was wrong, so a future 'option (a)' cannot pass by accident
    if ($cmdline -match 'Create-PSADTProject\.ps1') { Bad 'it targets the private helper file, not a runnable entry point' }
    if ($cmdline -match '-ProjectName|-ProjectPath')  { Bad "it passes the HELPER's parameters, not the user's command" }
}
else {
    Ok 'no process is launched at all (the old code launched pwsh -File <private helper> -ProjectName ...)'
}

# 3. the update itself still happened
if (Test-Path -LiteralPath $updFile) { Ok 'PSAppDeployToolkit was still actually updated' }
else { Bad 'the update did not run — only the post-update behaviour was supposed to change' }

# 4. no scaffolding with the stale in-process assembly
if (-not (Test-Path -LiteralPath $tmplFile)) { Ok 'no project is scaffolded after the update (the old assembly is still loaded)' }
else { Bad 'New-ADTTemplate ran anyway, against the stale assembly' }

# 5. the user is told, in plain words, what to do
$msgs = if (Test-Path -LiteralPath $msgFile) { Get-Content -LiteralPath $msgFile -Raw } else { '' }
if ($msgs -match '(?i)re-?run')                                 { Ok 'the user is told to re-run their command' }        else { Bad 'no "re-run" instruction' }
if ($msgs -match '(?i)new\s+powershell\s+session|new\s+session'){ Ok 'the user is told a NEW session is required' }      else { Bad 'no "new session" instruction' }
if ($msgs -match '(?im)^WARN:.*updated to 4\.1\.0')             { Ok 'the update is surfaced as a warning, not buried' }  else { Bad 'no warning naming the new version' }
if ($msgs -match '(?i)no project was created')                  { Ok 'it says plainly that no project was created' }      else { Bad 'does not say the work was not done' }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_SelfRelaunch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_SelfRelaunch test(s) FAILED." -ForegroundColor Red; exit 1 }
