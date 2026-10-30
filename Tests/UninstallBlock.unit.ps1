<#
    The data-driven Uninstall block, revision 2 (installer-identity PR 2 spec 2.3; D10, D11, D6 device half).

    THE BUG (live, S8-F6): an NSIS uninstaller returns at once while a copy of it in %TEMP% does the work
    (Firefox's helper.exe is a wrapper: it starts uninstall\uninstaller.exe, which copies itself to
    %TEMP%\~nsuA.tmp\Un_A.exe); the block's cleanup then raced the still-running copy ('Failed to delete
    folder(s)') and the uninstall reported success. An EXE uninstaller had no time limit, and the cleanup
    paths were deleted as SYSTEM with no check on the device.

    Revision 2: an EXE uninstaller runs with -WaitForChildProcesses and a 30-minute limit (exit code 69113
    when it is stopped (the uninstaller itself still running at the limit; when only a child outlives it,
    PSADT stops the child and its result counts - maintainer decision Dv2, 2026-10-22) - the child wait
    is what closes the race, for a wrapper too (live P1/P4: '_?=' does not reach Firefox's real
    uninstaller; PSADT 4.1.8 and 4.2.0-rc2 both wait for the copy, live Q2/Q4); an NSIS uninstaller (Kind 'nullsoft') always gets '/S' and '_?=<its own folder>' inside the
    one argument string (a plain NSIS uninstaller then runs in place), and its leftover file is deleted
    afterwards inside the install roots only (deleted / already gone: one severity-1 line); an uninstaller
    not run because an earlier one succeeded gets one severity-1 line; every cleanup
    path is re-checked on the device (plain path, inside Program Files / Program Files (x86) / ProgramData
    and not one of them itself, no shared or system tree, inside Uninstall.InstallRoots, no link above or
    below); a cleanup folder that is already gone gets one severity-1 line.

    Covered here:
      [1]  static checks on the catalog text: first line + revision marker, ASCII-only, no here-string,
           'New-TimeSpan -Minutes 30' once, 69113 once as the constant (and once in a comment), no
           Stopwatch / elapsed-time check (Dv2), the F12 Test-Path catch once, exactly two '-in $w32tUninstallOk', no
           KillChildProcessesWithParent / NoTerminateOnTimeout, no -LiteralPath on a PSADT cmdlet, every
           variable it assigns (assignment, foreach, scriptblock parameter) is $w32t* or one of the names the
           1.1.6 block already used; no catalog block (any -Name) names an app or vendor; the NSIS in-place
           rule ends in \z and refuses control / format characters, and its Test-Path / GetFullPath /
           GetDirectoryName run inside a try (X4).
      [2]  the block run under Windows PowerShell 5.1 (Set-StrictMode -Version 1, $ErrorActionPreference
           'Stop', stubbed Write-ADTLogEntry / Start-ADTProcess / Start-ADTMsiProcess / Remove-ADTFolder /
           $adtSession.SetExitCode): it parses; the NSIS argument string and wait/limit; the device '/S'
           rule; the leftover inside / outside the roots; '_?=' already present; no Kind; a missing NSIS
           exe; an NSIS Path with a TAB, with a final line feed, or whose Test-Path throws -> the block does
           not throw there: the severity-2 'not run in place' line, the captured Path and arguments passed on
           to the stub, no '_?=' (X4; real PSADT then rejects a TAB or line-feed path itself, so on a device
           that uninstall still fails, with the cause logged first); timeout -> 69113; PSADT's exit 0 after
           the limit (only a child was stopped) -> success, no 69113 (Dv2); a non-zero exit is re-thrown
           untouched; the
           no-success guard; first success wins, and every Uninstallers entry after the success (exe path,
           msi code, msix name) gets one 'uninstaller not run' line (live Q4-ff42-hv: Firefox's
           Maintenance Service entry was skipped silently; the ProductCodes loop stays the 1.1.6 loop); for
           an EXE entry with a plain absolute .exe path the line also says 'and its file is already gone'
           (severity 1), 'and its file is still there: that product may still be installed' (severity 2) or,
           for the uninstaller that already ran listed again, 'and it is the uninstaller that already ran'
           (severity 1); a relative path, a trailing line feed, msi and msix keep the plain line, and a path the
           rule lets through but Test-Path throws for (a TAB mid-path) keeps it without throwing (F12); the
           cleanup guard (outside the roots, a link below / above,
           a Microsoft segment, a trailing dot, a '~' short name, CMTrace delimiters, a missing folder,
           invalid-only roots, no InstallRoots, a clean sub-folder, a throwing Remove-ADTFolder) and the
           junction target canary.
    [2] runs twice (lean deploy script PR 1): once against the catalog block, once against Uninstall-W32TApp of the
    extension module DeployExtension\PSAppDeployToolkit.Win32Toolkit (imported as a module, PSADT stubs global, no
    $adtSession / $appConfig variable outside the call), so the two cannot behave differently.
    Test-time text substitution only: the shell-root list -> the 2nd segment of the long
    %USERPROFILE%\AppData\Local\Temp (so temp folders stand in for Program Files), and, for the case that
    returns after the limit, 'New-TimeSpan -Minutes 30' -> [TimeSpan]::FromMilliseconds(50) (5.1's
    New-TimeSpan has no -Milliseconds).

    Nothing is installed or executed (the PSADT commands are stubs); everything is written below
    %USERPROFILE%\AppData\Local\Temp and removed (junctions first: 5.1's Remove-Item cannot remove one).

    Run:  pwsh -File Tests\UninstallBlock.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitDeployScriptBlock.ps1')
# Lean deploy script PR 2: the uninstall code lives in Uninstall-W32TApp of the extension module (the catalog's Uninstall block is
# one call into it). $block = that function's body from its first code comment on, de-indented: the text the device runs.
$psm1 = Join-Path $repo 'DeployExtension\PSAppDeployToolkit.Win32Toolkit\PSAppDeployToolkit.Win32Toolkit.psm1'
$fnAst = [System.Management.Automation.Language.Parser]::ParseFile($psm1, [ref]$null, [ref]$null).Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Uninstall-W32TApp' }, $true)
$fnBody = ($fnAst.Body.Extent.Text -replace "`r`n", "`n")
$fnBody = $fnBody.Substring($fnBody.IndexOf('    ## Data-driven uninstall (values from SupportFiles\AppConfig.json).'))
$block = (($fnBody.Substring(0, $fnBody.LastIndexOf('}')).TrimEnd() -split "`n") | ForEach-Object { if ($_.StartsWith('    ')) { $_.Substring(4) } else { $_ } }) -join "`n"

# == [1] static checks =================================================================================
Write-Host '[1] the catalog text: revision marker, constants, 5.1/C-10 rules, variable names' -ForegroundColor Cyan
$lines = $block -split "`n"
if ($lines[0] -ceq '## Data-driven uninstall (values from SupportFiles\AppConfig.json).') { Ok 'first line unchanged' } else { Bad "first line: $($lines[0])" }
if ($lines[1] -clike '## Uninstall revision 2 (win32-toolkit). *') { Ok 'second line = the revision marker' } else { Bad "second line: $($lines[1])" }
function Get-Count([string]$Text, [string]$Needle) { ([regex]::Matches($Text, [regex]::Escape($Needle))).Count }
foreach ($c in @(
        @{ N = '## Uninstall revision 2 (win32-toolkit)'; W = 1 }
        @{ N = 'New-TimeSpan -Minutes 30'; W = 1 }
        # 69113: the catalog constant (used once, in the timeout catch) plus the comment above Start-ADTProcess.
        @{ N = '$w32tUninstallLimitCode = 69113'; W = 1 }
        @{ N = '69113'; W = 2 }
        # Dv2 (maintainer decision 2026-10-22): PSADT's exit code decides; no elapsed-time check after it returns.
        @{ N = 'Stopwatch'; W = 0 }
        @{ N = '.Elapsed'; W = 0 }
        @{ N = 'child processes ran longer'; W = 0 }
        @{ N = 'did not finish within 30 minutes'; W = 0 }
        # F12 (maintainer decision 2026-10-22, live Q2 r1 #2): the "not run" line of an EXE entry says whether its file
        # is there; the uninstaller that already ran is recognised without a third success check (C-10).
        @{ N = ', and its file is already gone'; W = 1 }
        @{ N = ', and its file is still there: that product may still be installed'; W = 1 }
        @{ N = ', and it is the uninstaller that already ran'; W = 1 }
        @{ N = '$w32tRanPath = [string]$u.Path'; W = 1 }
        # Two path rules end in \z: F12's and the NSIS in-place rule (X4); neither ends in '$'.
        @{ N = '.exe\z'; W = 2 }
        @{ N = '.exe$'''; W = 0 }
        # The F12 lookup is log-only and must never fail an uninstall (spec 2.2): Test-Path sits inside a try/catch.
        @{ N = 'catch { $w32tThere = $null }'; W = 1 }
        @{ N = '-in $w32tUninstallOk'; W = 2 }
        @{ N = 'WaitForChildProcesses = $true'; W = 1 }
        @{ N = 'KillChildProcessesWithParent'; W = 0 }
        @{ N = 'NoTerminateOnTimeout'; W = 0 }
        @{ N = "@'"; W = 0 }
        @{ N = '@"'; W = 0 }
    )) {
    $n = Get-Count $block $c.N
    if ($n -eq $c.W) { Ok "'$($c.N)' occurs $($c.W) time(s)" } else { Bad "'$($c.N)' occurs $n time(s), want $($c.W)" }
}
if (@([System.Text.Encoding]::UTF8.GetBytes($block) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'ASCII-only' } else { Bad 'non-ASCII characters in the block' }
# F12's path rule ends in \z, not $: in .NET '$' also matches before a final line feed (critique B3).
$f12Rule = '^[A-Za-z]:\\[^"*?<>|/:]+\.exe\z'
if ((Get-Count $block "-match '$f12Rule'") -eq 1 -and 'C:\Vendor\App\uninstall.exe' -match $f12Rule -and 'C:\VENDOR\APP\UNINS000.EXE' -match $f12Rule -and
    "C:\Vendor\App\uninstall.exe`n" -notmatch $f12Rule -and 'uninstall.exe' -notmatch $f12Rule -and 'C:\Vendor\App\un<ins>.exe' -notmatch $f12Rule) {
    Ok "F12 path rule: a plain absolute .exe path (any case) is looked up; a trailing line feed, a relative path or '<>' is not"
} else { Bad 'F12 path rule missing from the block or not anchored with \z' }
# X4: the NSIS in-place rule also ends in \z and refuses a control or format character (a TAB, a line feed, NEL, a
# zero-width space, a line separator): on Windows PowerShell 5.1 its Test-Path threw 'Illegal characters in path.' for
# such a path under 'Stop' before the severity-2 "not run in place" line was logged (PSADT's Start-ADTProcess still
# rejects such a path afterwards; the log now names the cause first).
$nsisRule = '^[A-Za-z]:\\[^"*?<>|/:\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+\.exe\z'
$nsisOdd = @("C:\Vendor\App\uninstall.exe`n", "C:\Vendor\App\un`tinstall.exe", "C:\Vendor\App\un$([char]0x85)install.exe",
    "C:\Vendor\App\un$([char]0x200B)install.exe", "C:\Vendor\App\un$([char]0x2028)install.exe", 'uninstall.exe', 'C:\Vendor\App\un<ins>.exe')
if ((Get-Count $block "-match '$nsisRule'") -eq 1 -and 'C:\Vendor\App\uninstall.exe' -match $nsisRule -and 'C:\VENDOR\APP\UNINS000.EXE' -match $nsisRule -and
    'C:\Program Files (x86)\Vendor App\uninstall.exe' -match $nsisRule -and @($nsisOdd | Where-Object { $_ -match $nsisRule }).Count -eq 0) {
    Ok 'NSIS in-place rule: a plain absolute .exe path (any case, spaces) passes; a final line feed, a TAB, NEL, a zero-width space, a line separator, a relative path or <> does not'
} else { Bad "NSIS in-place rule missing from the block or it lets a control / format character or a final line feed through: $(@($nsisOdd | Where-Object { $_ -match $nsisRule }).Count) odd path(s) pass" }
# Every catalog block ships verbatim in every app's deploy script: its comments must not name an app or vendor (live
# P1-ff-sb r2 / P4-ff-hv r2: a Notepad++ package's script said "Firefox's helper.exe" twice).
$appNames = '(?i)firefox|mozilla|helper\.exe|notepad|7-zip|chrome|google|adobe|zoom'
$named = [System.Collections.Generic.List[string]]::new()
foreach ($bn in @((Get-Command Get-Win32ToolkitDeployScriptBlock).Parameters['Name'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })) {
    $bt = if ($bn -eq 'Hook') { Get-Win32ToolkitDeployScriptBlock -Name Hook -Phase Pre-Install -HookFile PreInstall.ps1 } elseif ($bn -eq 'Install') { Get-Win32ToolkitDeployScriptBlock -Name Install -Technology Exe } else { Get-Win32ToolkitDeployScriptBlock -Name $bn }
    foreach ($hit in [regex]::Matches($bt, $appNames)) { $named.Add("${bn}: $($hit.Value)") }
}
if ($named.Count -eq 0) { Ok 'no catalog block names an app or vendor (the text ships in every package)' } else { Bad "app/vendor names in the catalog: $($named -join ', ')" }
$perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($block, [ref]$null, [ref]$perr)
if (-not $perr) { Ok 'parses (host)' } else { Bad "host parse: $($perr[0].Message)" }
$adtLiteral = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -like '*-ADT*' -and
            @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'LiteralPath' }).Count }, $true))
if ($adtLiteral.Count -eq 0) { Ok 'no PSADT cmdlet is called with -LiteralPath (not on 4.1.0-4.1.7)' } else { Bad "PSADT -LiteralPath: $($adtLiteral.Extent.Text -join ' | ')" }
# X4: every lookup of the NSIS uninstaller's path (Test-Path, GetFullPath, GetDirectoryName) runs inside the body of a try.
function Test-InTryBody($Node) {
    $child = $Node; $parent = $Node.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($parent.Body, $child)) { return $true }
        $child = $parent; $parent = $parent.Parent
    }
    return $false
}
$exeLookups = @($ast.FindAll({ param($n) (($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-Path') -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and @('GetFullPath', 'GetDirectoryName') -contains $n.Member.Extent.Text)) -and
        $n.Extent.Text -match '\$w32tExe\b' }, $true))
$unguarded = @($exeLookups | Where-Object { -not (Test-InTryBody $_) })
if ($exeLookups.Count -eq 3 -and $unguarded.Count -eq 0) { Ok 'the NSIS path lookups (Test-Path, GetFullPath, GetDirectoryName) all run inside a try (a path 5.1 cannot read is logged instead of throwing there)' }
else { Bad "NSIS path lookups: $($exeLookups.Count) found, outside a try: $($unguarded.Extent.Text -join ' | ')" }
# The names the 1.1.6 / GeneratorVersion-2 revision-1 block already assigned; every other name must be $w32t*.
$legacy = @('uninstallSuccess', 'pc', 'r', 'u', 'spUninstall', 'prov', 'pkg', 'folder')
$assigned = [System.Collections.Generic.List[string]]::new()
foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $left = $n.Left
    while ($left -is [System.Management.Automation.Language.IndexExpressionAst] -or $left -is [System.Management.Automation.Language.MemberExpressionAst]) { $left = if ($left -is [System.Management.Automation.Language.IndexExpressionAst]) { $left.Target } else { $left.Expression } }
    if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
    if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) { $assigned.Add($left.VariablePath.UserPath) }
}
foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $assigned.Add($n.Variable.VariablePath.UserPath) }
foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)) { $assigned.Add($n.Name.VariablePath.UserPath) }
$badNames = @($assigned | Sort-Object -Unique | Where-Object { $_ -notlike 'w32t*' -and $legacy -cnotcontains $_ })
if ($assigned.Count -gt 10 -and $badNames.Count -eq 0) { Ok "every assigned / foreach / parameter variable ($(@($assigned | Sort-Object -Unique).Count) names) is `$w32t* or a revision-1 name" } else { Bad "variables neither `$w32t* nor revision-1: $($badNames -join ', ')" }

# == [2] Windows PowerShell 5.1 runs ===================================================================
Write-Host '[2] the block under Windows PowerShell 5.1 with stubbed PSADT commands' -ForegroundColor Cyan
$ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $ps51) {
    Write-Host '  SKIP: Windows PowerShell 5.1 not present for the runtime check' -ForegroundColor DarkYellow
    if ($fail -eq 0) { exit 3 }
    exit 1
}

$harness = @'
param([string]$BlockPath, [string]$ModulePath)
# -ModulePath: the same cases against Uninstall-W32TApp of the extension module (lean deploy script PR 1). Run with -File,
# Windows PowerShell 5.1 runs this harness in the global scope, so the stubs below are global and the module function
# resolves them while it keeps its own variables; no $adtSession / $appConfig variable exists outside Invoke-Block.
Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
$fail = 0
function Ok($m) { Write-Output "PASS: $m" }
function Bad($m) { Write-Output "FAIL: $m"; $script:fail++ }

$tempLong = Join-Path $env:USERPROFILE 'AppData\Local\Temp'
$root = Join-Path $tempLong ('w32tub-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$seg = $tempLong.Split('\')   # C:, Users, <user>, AppData, Local, Temp
$subject = if ($ModulePath) { 'Uninstall-W32TApp (the extension module)' } else { 'the catalog block' }
$shipped = if ($ModulePath) { [IO.File]::ReadAllText($ModulePath) } else { [IO.File]::ReadAllText($BlockPath) }
$e = $null; [void][Management.Automation.Language.Parser]::ParseInput($shipped, [ref]$null, [ref]$e)
if (@($e).Count -eq 0) { Ok "$subject parses under Windows PowerShell 5.1" } else { Bad "5.1 parse: $($e[0].Message)" }
$rootsLine = "`$w32tShellRoots = @('Program Files', 'Program Files (x86)', 'ProgramData')"
$text = $shipped.Replace($rootsLine, "`$w32tShellRoots = @('$($seg[1])')")
$fastText = $text.Replace('New-TimeSpan -Minutes 30', '[TimeSpan]::FromMilliseconds(50)')
if ($text -ne $shipped -and $fastText -ne $text) { Ok "test-time substitutions applied to $subject (shell roots, limit)" } else { Bad "a substitution target is missing from $subject" }
if ($ModulePath) {
    # Two copies of the module (normal limit, fast limit); each case calls the function inside its own module.
    $blockMod = New-Module -Name W32TUninstallNormal -ScriptBlock ([scriptblock]::Create($text))
    $fastMod = New-Module -Name W32TUninstallFast -ScriptBlock ([scriptblock]::Create($fastText))
    if (-not (Get-Variable -Name adtSession, appConfig -Scope Global -ErrorAction SilentlyContinue)) { Ok 'no global $adtSession / $appConfig: the function must use Get-ADTSession and -AppConfig' } else { Bad 'a global $adtSession / $appConfig exists' }
}
else {
    $blockSb = [scriptblock]::Create($text)
    $fastSb = [scriptblock]::Create($fastText)
}

function New-Tree {
    $app = Join-Path $root 'Vendor\App'
    New-Item -ItemType Directory -Path (Join-Path $app 'sub\deeper') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $app 'uninstall.exe') -Value 'x'
    Set-Content -LiteralPath (Join-Path $app 'sub\f.txt') -Value 'x'
    $app
}
$script:log = @(); $script:started = @(); $script:removed = @(); $script:exitCode = $null; $script:mode = 'ok'; $script:msi = @()
function Write-ADTLogEntry { param([string]$Message, [int]$Severity = 1) $script:log += "[$Severity] $Message" }
function Start-ADTMsiProcess { param($Action, $ProductCode, [switch]$PassThru) $script:msi += $ProductCode; [pscustomobject]@{ ExitCode = $(if ($script:mode -eq 'msiok') { 0 } else { 1603 }) } }
function Start-ADTProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [switch]$PassThru, [switch]$WaitForChildProcesses, [timespan]$Timeout)
    $script:started += [pscustomobject]@{ FilePath = $FilePath; Args = $ArgumentList; HasArgs = $PSBoundParameters.ContainsKey('ArgumentList'); Count = @($ArgumentList).Count
        Wait = [bool]$WaitForChildProcesses; Timeout = $Timeout; Bound = (@($PSBoundParameters.Keys | Sort-Object) -join ',') }
    switch ($script:mode) {
        'timeout' { throw (New-Object System.OperationCanceledException 'Process terminated because execution took too long to complete.') }
        'timeoutT' { throw (New-Object System.TimeoutException 'The operation has timed out.') }
        'exitcode' { throw (New-Object System.Runtime.InteropServices.ExternalException 'Execution failed with exit code [5].', 5) }
        'slow' { Start-Sleep -Milliseconds 120; return [pscustomobject]@{ ExitCode = 0 } }
        'fail1' { $script:mode = 'ok'; return [pscustomobject]@{ ExitCode = 1 } }
        # A wrapper / vendor uninstall that removes the uninstaller file itself (Firefox's helper.exe, live P1/P3).
        'selfdelete' { Remove-Item -LiteralPath $FilePath -Force; return [pscustomobject]@{ ExitCode = 0 } }
        default { return [pscustomobject]@{ ExitCode = 0 } }
    }
}
function Remove-ADTFolder { param([string]$Path) if ($script:mode -eq 'rmthrow') { throw 'access denied' }; $script:removed += $Path }
$w32tFakeSession = New-Object psobject
$w32tFakeSession | Add-Member -MemberType ScriptMethod -Name SetExitCode -Value { param($c) $script:exitCode = $c }
function Get-ADTSession { $w32tFakeSession }

function Invoke-Block([object]$Uninstall, [switch]$Fast) {
    $script:log = @(); $script:started = @(); $script:removed = @(); $script:exitCode = $null; $script:msi = @()
    $appConfig = [pscustomobject]@{ Uninstall = $Uninstall }
    if ($ModulePath) {
        $mod = if ($Fast) { $fastMod } else { $blockMod }
        try { $null = & $mod { param($c) Uninstall-W32TApp -AppConfig $c } $appConfig; return 'ok' } catch { return "threw: $($_.Exception.Message)" }
    }
    $adtSession = $w32tFakeSession
    $sb = if ($Fast) { $fastSb } else { $blockSb }
    try { . $sb; return 'ok' } catch { return "threw: $($_.Exception.Message)" }
}
function Show { param($s) "args=[$(@($s.Args) -join '|')] count=$($s.Count) wait=$($s.Wait) timeout=$($s.Timeout) bound=$($s.Bound)" }

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # ---- NSIS in place, leftover deleted, cleanup inside the root ----
    $app = New-Tree
    $exe = Join-Path $app 'uninstall.exe'
    $u = [pscustomobject]@{ AppName = 'App'; ProductCodes = @(); InstallRoots = @($app)
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; ProductCode = $null; Path = $exe; Args = '/S'; Kind = 'nullsoft' })
        CleanupPaths = @($app) }
    $res = Invoke-Block $u
    $s = $script:started[0]
    if ($res -eq 'ok' -and $s.Count -eq 1 -and $s.Args[0] -ceq "/S _?=$app" -and $s.Wait -and $s.Timeout.TotalMinutes -eq 30 -and $s.Bound -ceq 'ArgumentList,FilePath,PassThru,Timeout,WaitForChildProcesses') { Ok "NSIS: ONE argument string '/S _?=<its folder>' (unquoted, last), -WaitForChildProcesses, -Timeout 30 min, -PassThru" } else { Bad "NSIS start: $res $(Show $s)" }
    if (-not (Test-Path -LiteralPath $exe)) { Ok 'the leftover NSIS uninstaller is deleted (its folder is inside an install root)' } else { Bad 'leftover uninstaller still there' }
    if (@($script:log | Where-Object { $_ -ceq "[1] win32-toolkit: deleted the NSIS uninstaller it left behind: $exe" }).Count -eq 1) { Ok 'the deletion is logged (severity 1, the path)' } else { Bad "no deletion line: $($script:log -join ' | ')" }
    if ($script:removed -contains $app -and $null -eq $script:exitCode) { Ok 'the cleanup path inside the root -> Remove-ADTFolder; no exit code set' } else { Bad "removed: $($script:removed -join ';') log: $($script:log -join ' | ')" }

    # ---- the uninstaller removed its own file (a wrapper such as Firefox's helper.exe) and the cleanup folder ----
    $app = New-Tree; $exe = Join-Path $app 'uninstall.exe'
    $gone = Join-Path $app 'removed-by-vendor'
    $u = [pscustomobject]@{ ProductCodes = @(); InstallRoots = @($app); CleanupPaths = @($gone)
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/S'; Kind = 'nullsoft' }) }
    $script:mode = 'selfdelete'; $res = Invoke-Block $u; $script:mode = 'ok'
    $want = @("[1] win32-toolkit: the NSIS uninstaller is already gone: $exe", "[1] win32-toolkit: cleanup path already absent (no folder there): $gone")
    if ($res -eq 'ok' -and ($script:log -join '|') -ceq ($want -join '|') -and $script:removed.Count -eq 0) { Ok 'an uninstaller file and a cleanup folder that are already gone -> one severity-1 line each (nothing else logged, nothing deleted)' } else { Bad "already gone: $res $($script:log -join ' | ')" }

    # ---- leftover OUTSIDE the roots is kept ----
    $app = New-Tree; $exe = Join-Path $app 'uninstall.exe'
    $elsewhere = Join-Path $root 'Elsewhere'; New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
    $u = [pscustomobject]@{ ProductCodes = @(); InstallRoots = @($elsewhere); CleanupPaths = @()
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/S'; Kind = 'nullsoft' }) }
    $res = Invoke-Block $u
    if ($res -eq 'ok' -and $script:started[0].Args[0] -ceq "/S _?=$app" -and (Test-Path -LiteralPath $exe) -and ($script:log -join '|') -match "NSIS uninstaller is left in place \(outside the app's install folders") { Ok 'run in place, but its folder is outside the install roots -> the leftover is kept and logged' } else { Bad "outside: $res $($script:log -join ' | ')" }

    # ---- '_?=' already present; no Kind; the device /S rule ----
    $u = [pscustomobject]@{ ProductCodes = @(); InstallRoots = @($app); CleanupPaths = @()
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = "/S _?=$app"; Kind = 'nullsoft' }) }
    $res = Invoke-Block $u
    if ($script:started[0].Args[0] -ceq "/S _?=$app" -and $script:started[0].Count -eq 1 -and (Test-Path -LiteralPath $exe) -and ($script:log -join '|') -match "already contain '_\?='") { Ok "arguments that already contain '_?=' are used as they are (logged); no leftover deletion" } else { Bad "_?= present: $(Show $script:started[0]) $($script:log -join ' | ')" }
    $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/S' })
    $res = Invoke-Block $u
    $s = $script:started[0]
    if ($s.Args[0] -ceq '/S' -and $s.Count -eq 1 -and $s.Wait -and $s.Timeout.TotalMinutes -eq 30 -and (Test-Path -LiteralPath $exe)) { Ok 'no Kind (older data, Inno Setup, another EXE): no _?=, still waited for with its child processes, 30-minute limit' } else { Bad "no Kind: $(Show $s)" }
    $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = ''; Kind = '' })
    $res = Invoke-Block $u
    if (-not $script:started[0].HasArgs -and $script:started[0].Wait) { Ok "Kind '' + empty Args -> no -ArgumentList at all (unchanged)" } else { Bad "empty args: $(Show $script:started[0])" }
    foreach ($c in @(
            @{ A = ''; W = "/S _?=$app"; L = "empty Args" }
            @{ A = '/allusers'; W = "/S /allusers _?=$app"; L = "'/allusers'" }
            @{ A = '/s'; W = "/S /s _?=$app"; L = "lower-case '/s' (not '/S')" }
            @{ A = '/S /allusers'; W = "/S /allusers _?=$app"; L = "'/S /allusers'" }
        )) {
        Set-Content -LiteralPath $exe -Value 'x'
        $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = $c.A; Kind = 'nullsoft' })
        $res = Invoke-Block $u
        if ($res -eq 'ok' -and $script:started[0].Args[0] -ceq $c.W -and $script:started[0].Count -eq 1) { Ok "nullsoft + $($c.L) -> '$($c.W.Replace($app, '<folder>'))' (the device adds a missing '/S', L5)" } else { Bad "nullsoft $($c.L): $(Show $script:started[0])" }
    }
    $missing = Join-Path $app 'missing.exe'
    $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $missing; Args = ''; Kind = 'nullsoft' })
    $res = Invoke-Block $u
    if ($script:started[0].Args[0] -ceq '/S' -and ($script:log -join '|') -match 'not run in place') { Ok "a missing NSIS exe + empty Args -> '/S' still added, not in place (logged)" } else { Bad "missing + empty: $(Show $script:started[0]) $($script:log -join ' | ')" }
    $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $missing; Args = '/S'; Kind = 'nullsoft' })
    $res = Invoke-Block $u
    if ($script:started[0].Args[0] -ceq '/S' -and @($script:log | Where-Object { $_ -match 'not run in place' }).Count -eq 1) { Ok 'a missing NSIS exe -> not in place, one log line; PSADT reports the missing file' } else { Bad "missing: $($script:log -join ' | ')" }
    foreach ($p in @("$app\..\App\uninstall.exe", 'uninstall.exe', "$app\uninstall.exe`" /x")) {
        Set-Content -LiteralPath $exe -Value 'x'
        $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $p; Args = '/S'; Kind = 'nullsoft' })
        $res = Invoke-Block $u
        if ($script:started[0].Args[0] -ceq '/S' -and ($script:log -join '|') -match 'not run in place' -and (Test-Path -LiteralPath $exe)) { Ok "not a plain absolute path to an .exe ('$($p.Replace($app, '<folder>'))') -> not in place, nothing deleted" } else { Bad "path '$p': $(Show $script:started[0]) $($script:log -join ' | ')" }
    }
    # X4: a captured or hand-edited Path with a TAB, or one that ends in a line feed ('$' matched before it), passed the
    # old '$'-anchored rule and made 5.1's Test-Path throw 'Illegal characters in path.' under 'Stop' before anything was
    # logged. Now the block logs the severity-2 line only and the captured Path and arguments are passed on, no '_?='.
    # Here they reach the stub; real PSADT then rejects the path (Start-ADTProcess in 4.1.8 and 4.2.0-rc2 calls
    # [IO.Path]::HasExtension on it, which throws the same error on 5.1), so on a device the uninstall still fails and the
    # uninstaller never starts - no Windows file name can hold a control character - but the log names the cause first.
    $nsisLine = '[2] win32-toolkit: the NSIS uninstaller is not a plain path to an existing .exe, so it is not run in place.'
    foreach ($c in @(
            @{ P = (Join-Path $app 'x') + [char]9 + 'y\uninstall.exe'; L = 'a TAB mid-path' }
            @{ P = "$exe`n"; L = 'a final line feed (the file exists)' }
        )) {
        Set-Content -LiteralPath $exe -Value 'x'
        $pre = try { $null = Test-Path -LiteralPath $c.P -PathType Leaf; 'no throw' } catch { 'throws' }
        if ($c.P -match '^[A-Za-z]:\\[^"*?<>|/:]+\.exe$' -and $pre -eq 'throws') { Ok "precondition ($($c.L)): the old '$'-anchored rule accepts it and 5.1's Test-Path throws for it" } else { Bad "precondition ($($c.L)): old rule=$($c.P -match '^[A-Za-z]:\\[^"*?<>|/:]+\.exe$') Test-Path=$pre" }
        $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $c.P; Args = '/S'; Kind = 'nullsoft' })
        $res = Invoke-Block $u
        $s = $script:started[0]
        if ($res -eq 'ok' -and $null -eq $script:exitCode -and $script:started.Count -eq 1 -and $s.FilePath -ceq $c.P -and $s.Count -eq 1 -and $s.Args[0] -ceq '/S' -and
            -not (@($s.Args) -join ' ').Contains('_?=') -and ($script:log -join '|') -ceq $nsisLine -and (Test-Path -LiteralPath $exe)) {
            Ok "NSIS Path with $($c.L) -> the block does not throw: the severity-2 'not run in place' line only, the captured Path and '/S' passed on (real PSADT then rejects that path), no '_?=', nothing deleted"
        } else { Bad "NSIS $($c.L): $res $(Show $s) log=$($script:log -join ' | ')" }
    }
    # The try itself: a path the rule accepts but Test-Path throws for (Test-Path shadowed for this one case; no such
    # path is known on 5.1 today - probed: a 300-character path, a device name and a lone surrogate return $false).
    Set-Content -LiteralPath $exe -Value 'x'
    $script:tpThrow = $exe
    function Test-Path { [CmdletBinding()] param([string]$LiteralPath, [string]$PathType) if ($LiteralPath -ceq $script:tpThrow) { throw (New-Object System.ArgumentException 'Illegal characters in path.') }; Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
    $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/S'; Kind = 'nullsoft' })
    $res = Invoke-Block $u
    Remove-Item -LiteralPath Function:\Test-Path
    $s = $script:started[0]
    if ($res -eq 'ok' -and $null -eq $script:exitCode -and $script:started.Count -eq 1 -and $s.Args[0] -ceq '/S' -and $s.Count -eq 1 -and ($script:log -join '|') -ceq $nsisLine -and (Test-Path -LiteralPath $exe)) {
        Ok "a plain NSIS path whose Test-Path throws -> caught: the severity-2 'not run in place' line, the captured Path and '/S' passed on, no '_?=', nothing deleted"
    } else { Bad "NSIS Test-Path throws: $res $(Show $s) log=$($script:log -join ' | ')" }

    # ---- timeout, PSADT's exit 0 after the limit (Dv2), non-zero exit ----
    $u.Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/S'; Kind = 'nullsoft' })
    foreach ($m in 'timeout', 'timeoutT') {
        $script:mode = $m; $res = Invoke-Block $u
        if ($res -like 'threw*' -and $script:exitCode -eq 69113 -and ($script:log -join '|') -match '\[3\] win32-toolkit: the uninstaller ran longer than 30 minutes and was stopped \(exit code 69113\)' -and (Test-Path -LiteralPath $exe)) { Ok "$m -> SetExitCode(69113), severity-3 line, re-thrown; the leftover is not touched" } else { Bad "${m}: $res code=$($script:exitCode) log=$($script:log -join ' | ')" }
    }
    # Maintainer decision Dv2 (2026-10-22): when only a child process outlives the limit, PSADT stops it and returns the
    # uninstaller's own exit code; the block trusts that result (no elapsed-time check after Start-ADTProcess returns).
    $script:mode = 'slow'; $res = Invoke-Block $u -Fast
    if ($res -eq 'ok' -and $null -eq $script:exitCode -and @($script:log | Where-Object { $_ -match 'ran longer than 30 minutes' }).Count -eq 0 -and -not (Test-Path -LiteralPath $exe)) { Ok "PSADT returned exit 0 after the limit (only a child was stopped) -> PSADT's result counts: success, no 69113 (Dv2)" } else { Bad "after the limit: $res code=$($script:exitCode) log=$($script:log -join ' | ')" }
    $script:mode = 'ok'
    Set-Content -LiteralPath $exe -Value 'x'
    $script:mode = 'exitcode'; $res = Invoke-Block $u
    if ($res -like 'threw: Execution failed with exit code `[5`]*' -and $null -eq $script:exitCode -and (Test-Path -LiteralPath $exe)) { Ok 'a non-zero exit (PSADT throws) -> re-thrown untouched, no SetExitCode, the leftover kept' } else { Bad "exitcode: $res code=$($script:exitCode)" }
    $script:mode = 'ok'

    # ---- no-success guard, first success wins, MSI loop unchanged ----
    $exe2 = Join-Path $app 'second\uninstall2.exe'
    $u = [pscustomobject]@{ ProductCodes = @('{11111111-2222-3333-4444-555555555555}'); InstallRoots = @(); CleanupPaths = @()
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/x'; Kind = '' }, [pscustomobject]@{ Type = 'exe'; Path = $exe2; Args = '/y'; Kind = '' }) }
    $res = Invoke-Block $u
    if ($res -eq 'ok' -and $script:msi.Count -eq 1 -and $script:started.Count -eq 1 -and $script:started[0].Args[0] -ceq '/x') { Ok 'an MSI exit 1603 is not success; the first EXE uninstaller succeeds and the second never runs' } else { Bad "first success: $res msi=$($script:msi.Count) started=$($script:started.Count)" }
    # Live Q4-ff42-hv: Firefox's second entry (the Maintenance Service uninstaller) was skipped with no log line, so
    # "not run because an earlier one succeeded" looked the same as "not captured". One line per entry; for an EXE
    # entry it also says whether its file is still there (F12, live Q2 r1 #2): here it was never created.
    $want = @("[1] win32-toolkit: uninstaller not run (an earlier one already succeeded): $exe2, and its file is already gone")
    if (($script:log -join '|') -ceq ($want -join '|')) { Ok "the uninstaller skipped after a success -> one severity-1 line with its path, 'and its file is already gone' (first success still wins)" } else { Bad "skip line: $($script:log -join ' | ')" }
    $script:mode = 'fail1'; $res = Invoke-Block $u
    if ($res -eq 'ok' -and $script:started.Count -eq 2 -and $script:started[1].Args[0] -ceq '/y') { Ok 'an exit code outside the success list moves on to the next uninstaller' } else { Bad "fallback: $res started=$($script:started.Count)" }
    if (@($script:log | Where-Object { $_ -match 'not run' }).Count -eq 0) { Ok 'no "not run" line when the last uninstaller is the one that succeeds' } else { Bad "fallback log: $($script:log -join ' | ')" }
    $script:mode = 'ok'

    # ---- F12: the file state of a skipped EXE entry (its own AppConfig Path only) ----
    $first = [pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/x'; Kind = '' }
    $exe3 = Join-Path $app 'third\uninstall3.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $exe3) -Force | Out-Null
    Set-Content -LiteralPath $exe3 -Value 'x'
    $u = [pscustomobject]@{ ProductCodes = @(); InstallRoots = @(); CleanupPaths = @()
        Uninstallers = @($first, [pscustomobject]@{ Type = 'exe'; Path = $exe3; Args = '/y'; Kind = '' }) }
    $res = Invoke-Block $u
    $want = @("[2] win32-toolkit: uninstaller not run (an earlier one already succeeded): $exe3, and its file is still there: that product may still be installed")
    if ($res -eq 'ok' -and $script:started.Count -eq 1 -and ($script:log -join '|') -ceq ($want -join '|')) { Ok "a skipped EXE entry whose file exists -> severity 2, 'and its file is still there: that product may still be installed'" } else { Bad "still there: $res $($script:log -join ' | ')" }
    $u.Uninstallers = @($first, [pscustomobject]@{ Type = 'exe'; Path = 'uninstall.exe'; Args = '/y'; Kind = '' })
    $res = Invoke-Block $u
    $want = @('[1] win32-toolkit: uninstaller not run (an earlier one already succeeded): uninstall.exe')
    if ($res -eq 'ok' -and ($script:log -join '|') -ceq ($want -join '|')) { Ok 'a relative path is not looked up -> the plain severity-1 line' } else { Bad "relative: $res $($script:log -join ' | ')" }
    # Critique B3: '$' would also match before a final line feed; the rule ends in \z, so such a path is not looked up.
    New-Item -ItemType Directory -Path (Split-Path -Parent $exe2) -Force | Out-Null
    Set-Content -LiteralPath $exe2 -Value 'x'
    $u.Uninstallers = @($first, [pscustomobject]@{ Type = 'exe'; Path = "$exe2`n"; Args = '/y'; Kind = '' })
    $res = Invoke-Block $u
    $want = @("[1] win32-toolkit: uninstaller not run (an earlier one already succeeded): ${exe2}?")
    if ($res -eq 'ok' -and ($script:log -join '|') -ceq ($want -join '|')) { Ok 'a path that ends in a line feed is not looked up -> the plain severity-1 line (the line feed shown as ?)' } else { Bad "trailing LF: $res $($script:log -join ' | ')" }
    Remove-Item -LiteralPath $exe2 -Force
    # F12 never throws (spec 2.2): the rule lets a control character in the middle of a path through, and 5.1's Test-Path
    # throws for it under 'Stop' ('Illegal characters in path.'). The catch around Test-Path keeps the plain line; without
    # it an uninstall that succeeded would throw (the tattoo stays, the leftover and the cleanup paths are skipped).
    $ctl = (Join-Path $app 'x') + [char]9 + 'y\uninstall.exe'
    $pre = try { $null = Test-Path -LiteralPath $ctl -PathType Leaf; 'no throw' } catch { 'throws' }
    if ($ctl -match '^[A-Za-z]:\\[^"*?<>|/:]+\.exe\z' -and $pre -eq 'throws') { Ok "precondition: a TAB mid-path passes the F12 rule and 5.1's Test-Path throws for it (the next case reaches the catch)" } else { Bad "control-character precondition: rule=$($ctl -match '^[A-Za-z]:\\[^"*?<>|/:]+\.exe\z') Test-Path=$pre" }
    $u.Uninstallers = @($first, [pscustomobject]@{ Type = 'exe'; Path = $ctl; Args = '/y'; Kind = '' })
    $res = Invoke-Block $u
    $want = @("[1] win32-toolkit: uninstaller not run (an earlier one already succeeded): $($ctl.Replace([string][char]9, '?'))")
    if ($res -eq 'ok' -and $null -eq $script:exitCode -and $script:started.Count -eq 1 -and ($script:log -join '|') -ceq ($want -join '|')) { Ok 'a path Test-Path cannot look up (a TAB mid-path) -> no throw, the plain severity-1 line (the TAB shown as ?), no file-state suffix' } else { Bad "control character: $res $($script:log -join ' | ')" }
    # Critique B7: the same uninstaller recorded twice (an NSIS uninstaller run in place, then the same file in another
    # case, for example under the other registry view): its file is deleted only after the loop, so it is not looked
    # up - no false severity-2 "still there" line.
    Set-Content -LiteralPath $exe -Value 'x'
    $u = [pscustomobject]@{ ProductCodes = @(); InstallRoots = @($app); CleanupPaths = @()
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/S'; Kind = 'nullsoft' }, [pscustomobject]@{ Type = 'exe'; Path = $exe.ToUpperInvariant(); Args = '/S'; Kind = 'nullsoft' }) }
    $res = Invoke-Block $u
    $want = @("[1] win32-toolkit: uninstaller not run (an earlier one already succeeded): $($exe.ToUpperInvariant()), and it is the uninstaller that already ran", "[1] win32-toolkit: deleted the NSIS uninstaller it left behind: $exe")
    if ($res -eq 'ok' -and $script:started.Count -eq 1 -and $script:started[0].Args[0] -ceq "/S _?=$app" -and ($script:log -join '|') -ceq ($want -join '|') -and -not (Test-Path -LiteralPath $exe)) {
        Ok "the uninstaller that already ran, listed again (other case) -> 'and it is the uninstaller that already ran' (severity 1, no 'still there'); its leftover is still deleted after the loop"
    } else { Bad "same uninstaller: $res $($script:log -join ' | ')" }
    Set-Content -LiteralPath $exe -Value 'x'
    $script:mode = 'msiok'
    $odd = Join-Path $app 'x[1]\un<ins>.exe'
    $u = [pscustomobject]@{ ProductCodes = @('{AAAAAAAA-2222-3333-4444-555555555555}', '', '{BBBBBBBB-2222-3333-4444-555555555555}'); InstallRoots = @(); CleanupPaths = @()
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; ProductCode = $null; Path = $odd; Args = '/S'; Kind = 'nullsoft' }, $null,
            [pscustomobject]@{ Type = 'msi'; ProductCode = '{CCCCCCCC-2222-3333-4444-555555555555}'; Path = $null; Args = $null; Kind = '' },
            [pscustomobject]@{ Type = 'msix'; PackageName = 'Vendor.App'; Publisher = 'CN=Vendor'; ProductCode = $null; Path = $null; Args = $null }) }
    $res = Invoke-Block $u
    # The ProductCodes loop is the 1.1.6 loop line for line (GeneratorFailClosed.unit pins it), so a second product
    # code after a success stays silent; every Uninstallers entry after it is logged.
    $want = @(($odd -replace '[\[\]<>]', '?'), '{CCCCCCCC-2222-3333-4444-555555555555}', 'Vendor.App') | ForEach-Object { "[1] win32-toolkit: uninstaller not run (an earlier one already succeeded): $_" }
    if ($res -eq 'ok' -and $script:msi.Count -eq 1 -and $script:started.Count -eq 0 -and ($script:log -join '|') -ceq ($want -join '|')) { Ok 'a product code succeeds -> every uninstaller after it (exe path, msi code, msix name) gets one line; blank entries stay silent; CMTrace delimiters masked' } else { Bad "msi first: $res msi=$($script:msi.Count) started=$($script:started.Count) log=$($script:log -join ' | ')" }
    $script:mode = 'ok'
    $u = [pscustomobject]@{ ProductCodes = @('{11111111-2222-3333-4444-555555555555}'); Uninstallers = @(); CleanupPaths = @() }
    $res = Invoke-Block $u
    if ($res -like 'threw: Uninstall failed: no uninstaller reported success*') { Ok 'nothing reported success -> the unchanged no-success throw' } else { Bad "no success: $res" }

    # ---- cleanup guard ----
    $app = New-Tree
    $other = Join-Path $root 'Other'; New-Item -ItemType Directory -Path $other -Force | Out-Null
    $target = Join-Path $root 'Target'; New-Item -ItemType Directory -Path $target -Force | Out-Null; Set-Content (Join-Path $target 'canary.txt') 'keep'
    $null = New-Item -ItemType Junction -Path (Join-Path $app 'sub\link') -Value $target
    $linkedRootParent = Join-Path $root 'LinkedVendor'
    $null = New-Item -ItemType Junction -Path $linkedRootParent -Value (Join-Path $root 'Vendor')
    New-Item -ItemType Directory -Path (Join-Path $app 'Microsoft') -Force | Out-Null
    $short = $root.Replace($seg[2], 'ABCDEF~1')
    $u = [pscustomobject]@{ ProductCodes = @(); Uninstallers = @(); InstallRoots = @($app, ($seg[0] + '\' + $seg[1]))
        CleanupPaths = @($app, $other, (Join-Path $app 'sub'), (Join-Path $app 'Microsoft'), ($app + '.'), $short, "$app\x]LOG]!>", (Join-Path $app 'deeper-missing'), '', $null) }
    $res = Invoke-Block $u
    $logText = $script:log -join "`n"
    if ($res -eq 'ok' -and $script:removed.Count -eq 0) { Ok 'nothing deleted: every path refused or absent' } else { Bad "removed: $($script:removed -join ' ; ')" }
    foreach ($want in @("outside the app's install folders", 'a folder below it is a link', 'inside a shared or system folder', 'not a plain folder path')) {
        if ($logText.Contains($want)) { Ok "refused and logged: $want" } else { Bad "missing log reason '$want':`n$logText" }
    }
    if (@($script:log | Where-Object { $_ -like '`[2`] win32-toolkit: cleanup path left in place*' }).Count -eq 7) { Ok '7 refused paths -> 7 severity-2 lines' } else { Bad "refusal lines:`n$logText" }
    if (@($script:log | Where-Object { $_ -like '`[1`]*' }).Count -eq 1 -and $logText.Contains("[1] win32-toolkit: cleanup path already absent (no folder there): $(Join-Path $app 'deeper-missing')") -and $script:log.Count -eq 8) {
        Ok 'the missing folder -> one severity-1 "already absent" line; the blank entries are skipped silently'
    } else { Bad "absent / blank lines:`n$logText" }
    if (@($script:log | Where-Object { $_ -match 'cleanup path left in place \(not a plain folder path\)' -and $_ -match '~1' }).Count -eq 1 -and @($script:log | Where-Object { $_ -match 'not a plain folder path' -and $_.EndsWith('App.') }).Count -eq 1) { Ok "a '~' short name and a trailing dot are not plain paths" } else { Bad "short name / trailing dot:`n$logText" }
    if ($logText -notmatch 'LOG\]!>' -and $logText.Contains('x?LOG?!?')) { Ok 'a refused path is logged without CMTrace delimiters' } else { Bad "log not sanitised: $logText" }
    if (Test-Path -LiteralPath (Join-Path $target 'canary.txt')) { Ok 'the junction target is untouched (canary)' } else { Bad 'canary gone' }
    $u2 = [pscustomobject]@{ ProductCodes = @(); Uninstallers = @(); InstallRoots = @(($seg[0] + '\' + $seg[1]), "$root\Vendor\.."); CleanupPaths = @($other) }
    $res = Invoke-Block $u2
    if ($res -eq 'ok' -and @($script:log | Where-Object { $_ -match 'no valid install folder is recorded' }).Count -eq 1 -and $script:removed.Count -eq 0) { Ok 'only invalid roots (a shell root, a ..) -> one summary line, nothing deleted' } else { Bad "invalid roots: $($script:log -join '|')" }
    $u3 = [pscustomobject]@{ ProductCodes = @(); Uninstallers = @(); CleanupPaths = @($other) }
    $res = Invoke-Block $u3
    if ($res -eq 'ok' -and @($script:log | Where-Object { $_ -match 'no valid install folder is recorded' }).Count -eq 1 -and $script:removed.Count -eq 0) { Ok 'no InstallRoots property (older data) -> nothing deleted' } else { Bad "no roots: $($script:log -join '|')" }
    [IO.Directory]::Delete((Join-Path $app 'sub\link'))
    $u4 = [pscustomobject]@{ ProductCodes = @(); Uninstallers = @(); InstallRoots = @("$app\"); CleanupPaths = @((Join-Path $app 'sub')) }
    $res = Invoke-Block $u4
    if ($res -eq 'ok' -and $script:removed -contains (Join-Path $app 'sub') -and $script:log.Count -eq 0) { Ok "a clean sub-folder inside the root (root with a trailing '\') -> Remove-ADTFolder, no log line" } else { Bad "u4: $($script:removed -join ';') $($script:log -join '|')" }
    $u5 = [pscustomobject]@{ ProductCodes = @(); Uninstallers = @(); InstallRoots = @((Join-Path $linkedRootParent 'App')); CleanupPaths = @((Join-Path $linkedRootParent 'App')) }
    $res = Invoke-Block $u5
    if ($res -eq 'ok' -and ($script:log -join '|') -match 'a folder above it is a link' -and $script:removed.Count -eq 0) { Ok 'a junction above the path (a root reached through a link) -> refused' } else { Bad "u5: $($script:log -join '|')" }
    $exe = Join-Path $linkedRootParent 'App\uninstall.exe'
    Set-Content -LiteralPath (Join-Path $root 'Vendor\App\uninstall.exe') -Value 'x'
    $u6 = [pscustomobject]@{ ProductCodes = @(); InstallRoots = @((Join-Path $linkedRootParent 'App')); CleanupPaths = @()
        Uninstallers = @([pscustomobject]@{ Type = 'exe'; Path = $exe; Args = '/S'; Kind = 'nullsoft' }) }
    $res = Invoke-Block $u6
    if ($res -eq 'ok' -and (Test-Path -LiteralPath $exe) -and ($script:log -join '|') -match 'NSIS uninstaller is left in place \(it or a folder above it is a link') { Ok 'the leftover below a linked folder is kept (logged)' } else { Bad "u6: $($script:log -join '|')" }
    $script:mode = 'rmthrow'
    $u7 = [pscustomobject]@{ ProductCodes = @(); Uninstallers = @(); InstallRoots = @($app); CleanupPaths = @($app) }
    $res = Invoke-Block $u7
    if ($res -eq 'ok' -and ($script:log -join '|') -match '\[2\] Cleanup failed for .*access denied') { Ok 'a throwing Remove-ADTFolder is logged (severity 2) and never escapes' } else { Bad "rmthrow: $res $($script:log -join '|')" }
    $script:mode = 'ok'
    # The shell root itself names the same reason as the host gate (Test-Win32ToolkitCleanupPath ShellFolder); a path
    # whose second segment is not a shell root keeps 'not inside ...' (live P3: 'C:\Program Files (x86)' was called
    # "not inside Program Files (x86)").
    $shellRoot = $seg[0] + '\' + $seg[1]
    $u8 = [pscustomobject]@{ ProductCodes = @(); Uninstallers = @(); InstallRoots = @($app); CleanupPaths = @($shellRoot, 'D:\Vendor\App') }
    $res = Invoke-Block $u8
    $want = @("[2] win32-toolkit: cleanup path left in place (it is a Windows system folder itself): $shellRoot",
        '[2] win32-toolkit: cleanup path left in place (not inside Program Files, Program Files (x86) or ProgramData): D:\Vendor\App')
    if ($res -eq 'ok' -and ($script:log -join '|') -ceq ($want -join '|') -and $script:removed.Count -eq 0) { Ok "the shell root itself -> 'it is a Windows system folder itself'; another top folder -> 'not inside ...'" } else { Bad "u8: $($script:log -join ' | ')" }
    if (-not ([IO.FileAttributes]0 -band [IO.FileAttributes]::ReparsePoint)) { Ok 'a zero FileAttributes value is false in an if (the reparse test relies on it)' } else { Bad 'enum zero is truthy' }
}
catch {
    Bad "the harness stopped: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage -replace '\s*[\r\n]+\s*', ' ')"
}
finally {
    Get-ChildItem -LiteralPath $root -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "RESULT: $fail"
exit $fail
'@

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ub_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $blockFile = Join-Path $work 'Uninstall.block.ps1'
    $harnessFile = Join-Path $work 'harness.ps1'
    [System.IO.File]::WriteAllText($blockFile, $block, (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText($harnessFile, $harness, (New-Object System.Text.UTF8Encoding($true)))
    # Lean deploy script PR 2: projects run Uninstall-W32TApp (the catalog block is one call into it), so only the function runs here;
    # the harness keeps its -BlockPath mode for the text of a GeneratorVersion 2 project.
    foreach ($run in @(@{ Label = 'Uninstall-W32TApp'; Arg = '-ModulePath'; Path = $psm1 })) {
        $out = @(& $ps51.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harnessFile $run.Arg $run.Path 2>&1 | ForEach-Object { "$_" })
        $childExit = $LASTEXITCODE
        $passes = 0
        foreach ($line in $out) {
            if ($line -like 'PASS: *') { Ok "5.1 [$($run.Label)]: $($line.Substring(6))"; $passes++ }
            elseif ($line -like 'FAIL: *') { Bad "5.1 [$($run.Label)]: $($line.Substring(6))" }
        }
        $result = @($out | Where-Object { $_ -like 'RESULT: *' })
        if ($result.Count -eq 1 -and $childExit -eq [int]$result[0].Substring(8) -and $passes -ge 40) { Ok "the 5.1 child [$($run.Label)] ran to its end ($passes checks, exit $childExit)" }
        else { Bad "the 5.1 child [$($run.Label)] did not finish: exit $childExit, $passes passes, output:`n$($out -join "`n")" }
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All UninstallBlock tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail UninstallBlock test(s) FAILED." -ForegroundColor Red; exit 1 }
