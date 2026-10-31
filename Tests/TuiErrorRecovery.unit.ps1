<#
    TUI audit G7 (tui-gaps-spec 8, G7): the menu keeps running after a screen error.

    Before: Show-Win32Toolkit's main loop had no catch, so any error a screen did not handle (an unreadable
    SupportFiles\AppConfig.json in Work with an existing project, a failing helper) ended the whole TUI.

    Now:
      [1] (AST) the screen dispatch - the switch on $choice - is inside a try that is a statement of the main
          while loop, with one catch that calls Show-Win32ToolkitScreenError -ErrorRecord $_; every screen the
          switch launches is inside that try; Show-Win32ToolkitHealth, Show-Win32ToolkitUpdateNotice and
          Show-Win32ToolkitMainMenu are NOT inside any try within the loop (an error there fails every pass the
          same way, so it still ends the TUI through the outer finally instead of looping forever).
      [2] Show-Win32ToolkitScreenError renders one red 'Something went wrong' panel (message and error id
          escaped; no id line for a plain throw, whose id is the message) and pauses once; it returns nothing.

    Show-Win32Toolkit itself refuses to run without an interactive console, so [1] reads its source.
    Run:  pwsh -File Tests\TuiErrorRecovery.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Show-Win32ToolkitScreenError.ps1')

# == [1] the main loop guards the screen dispatch only ==================================================
Write-Host '[1] Show-Win32Toolkit: the screen dispatch is inside a try/catch of the main loop; the menu itself is not' -ForegroundColor Cyan
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Public\Show-Win32Toolkit.ps1'), [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count) { Bad "Show-Win32Toolkit.ps1 does not parse: $($parseErrors[0].Message)" }
$loop = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true)
$switch = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$choice' }, $true)
$isInside = { param($Node, $Container) $Node.Extent.StartOffset -ge $Container.Extent.StartOffset -and $Node.Extent.EndOffset -le $Container.Extent.EndOffset }
# The try statements that are statements of the while body (not nested deeper).
$loopTries = if ($loop) { @($loop.Body.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }) } else { @() }
$guard = @($loopTries | Where-Object { $switch -and (& $isInside $switch $_.Body) }) | Select-Object -First 1
if ($loop -and $switch -and $guard) { Ok 'the switch on $choice is inside a try that is a statement of the main while loop' } else { Bad "loop=$([bool]$loop) switch on `$choice=$([bool]$switch) guarding try=$([bool]$guard)" }

$catchOk = $false
if ($guard -and $guard.CatchClauses.Count -eq 1 -and -not $guard.Finally) {
    $calls = @($guard.CatchClauses[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $catchOk = $calls.Count -eq 1 -and $calls[0].GetCommandName() -eq 'Show-Win32ToolkitScreenError' -and $calls[0].Extent.Text -match '^Show-Win32ToolkitScreenError\s+-ErrorRecord\s+\$_$'
}
if ($catchOk) { Ok 'one catch (catch-all), whose body is Show-Win32ToolkitScreenError -ErrorRecord $_' } else { Bad "catch: $(if ($guard) { $guard.CatchClauses | ForEach-Object { $_.Extent.Text } })" }

$screens = 'Invoke-Win32ToolkitWingetWizard', 'Invoke-Win32ToolkitManualWizard', 'Show-Win32ToolkitProjectActions', 'Show-Win32ToolkitBrowse',
    'Show-Win32ToolkitTemplates', 'Show-Win32ToolkitIntuneConnection', 'Show-Win32ToolkitSettings'
foreach ($s in $screens) {
    $c = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $s }, $true))
    if ($c.Count -ge 1 -and $guard -and @($c | Where-Object { -not (& $isInside $_ $guard.Body) }).Count -eq 0) { Ok "$s is called inside the guarded dispatch" } else { Bad "$s calls: $($c.Count), inside the try: $(@($c | Where-Object { $guard -and (& $isInside $_ $guard.Body) }).Count)" }
}

$loopAllTries = if ($loop) { @($loop.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)) } else { @() }
foreach ($s in 'Show-Win32ToolkitHealth', 'Show-Win32ToolkitUpdateNotice', 'Show-Win32ToolkitMainMenu') {
    $c = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $s }, $true))
    $inLoop = @($c | Where-Object { $loop -and (& $isInside $_ $loop.Body) })
    $inTry = @($inLoop | Where-Object { $call = $_; @($loopAllTries | Where-Object { & $isInside $call $_ }).Count })
    $before = $guard -and $inLoop.Count -ge 1 -and @($inLoop | Where-Object { $_.Extent.EndOffset -gt $guard.Extent.StartOffset }).Count -eq 0
    if ($inLoop.Count -ge 1 -and $inTry.Count -eq 0 -and $before) { Ok "$s runs in the loop, before the guarded dispatch and outside any try (an error there still ends the TUI)" } else { Bad "${s}: in loop=$($inLoop.Count) in a try=$($inTry.Count) before the guard=$before" }
}
$menuAssign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$choice' -and $n.Right.Extent.Text -eq 'Show-Win32ToolkitMainMenu' }, $true)
if ($menuAssign) { Ok '$choice = Show-Win32ToolkitMainMenu (the selection value, as the switch condition took it before)' } else { Bad 'no "$choice = Show-Win32ToolkitMainMenu" assignment' }

# == [2] the error panel ================================================================================
Write-Host '[2] Show-Win32ToolkitScreenError: one red panel (escaped message and id), one pause, no output' -ForegroundColor Cyan
$script:panels = [System.Collections.Generic.List[object]]::new()
$script:pauses = [System.Collections.Generic.List[string]]::new()
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) $script:panels.Add([pscustomobject]@{ Data = [string]$Data; Header = [string]$Header; Color = [string]$Color }) }
function Read-SpectrePause { param($Message, [switch]$AnyKey) $script:pauses.Add([string]$Message); 'pause-output' }
function Get-SpectreEscapedText { param($Text) ([string]$Text).Replace('[', '[[').Replace(']', ']]') }

$w32t = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("'App [x]' is marked not configured"), 'W32T.ProjectNotConfigured', 'InvalidOperation', $null)
$out = @(Show-Win32ToolkitScreenError -ErrorRecord $w32t)
$want = "[red]'App [[x]]' is marked not configured[/]`n[grey]Error id: W32T.ProjectNotConfigured[/]`n`nYou are back in the menu: fix the cause and try again."
if ($script:panels.Count -eq 1 -and $script:panels[0].Header -eq 'Something went wrong' -and $script:panels[0].Color -eq 'Red' -and $script:panels[0].Data -ceq $want) { Ok 'a W32T.* error -> the escaped message, the grey error id and "You are back in the menu"' } else { Bad "panel: $($script:panels | ConvertTo-Json -Compress)" }
if ($script:pauses.Count -eq 1 -and $script:pauses[0] -eq 'Press any key to return to the menu') { Ok 'one pause: "Press any key to return to the menu"' } else { Bad "pauses: $($script:pauses -join ' | ')" }
if ($out.Count -eq 0) { Ok 'nothing leaves the function except the panel render (the pause output is discarded)' } else { Bad "output: $($out -join ' | ')" }

$script:panels.Clear(); $script:pauses.Clear()
try { throw 'Conversion from JSON failed [y]' } catch { $plain = $_ }
Show-Win32ToolkitScreenError -ErrorRecord $plain
if ($script:panels.Count -eq 1 -and $script:panels[0].Data -ceq "[red]Conversion from JSON failed [[y]][/]`n`nYou are back in the menu: fix the cause and try again.") { Ok 'a plain throw (its id is the message) -> no error id line' } else { Bad "panel: $($script:panels | ConvertTo-Json -Compress)" }

$script:panels.Clear(); $script:pauses.Clear()
try { Get-Item -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-no-such-' + [guid]::NewGuid().ToString('N'))) -ErrorAction Stop } catch { $cmdErr = $_ }
Show-Win32ToolkitScreenError -ErrorRecord $cmdErr
if ($script:panels.Count -eq 1 -and $script:panels[0].Data -match '\[grey\]Error id: PathNotFound,Microsoft\.PowerShell\.Commands\.GetItemCommand\[/\]') { Ok "a cmdlet error -> its id ('PathNotFound,...GetItemCommand')" } else { Bad "panel: $($script:panels | ConvertTo-Json -Compress)" }

$script:panels.Clear(); $script:pauses.Clear()
$oddId = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('x'), 'W32T.Odd[id]', 'NotSpecified', $null)
Show-Win32ToolkitScreenError -ErrorRecord $oddId
if ($script:panels.Count -eq 1 -and $script:panels[0].Data -ceq "[red]x[/]`n[grey]Error id: W32T.Odd[[id]][/]`n`nYou are back in the menu: fix the cause and try again.") { Ok "an error id with markup ('W32T.Odd[id]') -> escaped: 'Error id: W32T.Odd[[id]]'" } else { Bad "panel: $($script:panels | ConvertTo-Json -Compress)" }

# == [3] an error without a message ======================================================================
# PwshSpectreConsole's Get-SpectreEscapedText refuses an empty string; the panel must not throw from the catch.
Write-Host '[3] an error without a message -> a fixed text, no throw (faithful Get-SpectreEscapedText)' -ForegroundColor Cyan
$script:panels.Clear(); $script:pauses.Clear()
$threw = $null
& {
    function Get-SpectreEscapedText { param([Parameter(Mandatory)][string]$Text) $Text.Replace('[', '[[').Replace(']', ']]') }
    $empty = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new(''), 'W32T.Empty', 'NotSpecified', $null)
    try { Show-Win32ToolkitScreenError -ErrorRecord $empty } catch { $script:threwEmpty = $_ }
}
$threw = $script:threwEmpty
if (-not $threw -and $script:panels.Count -eq 1 -and $script:panels[0].Data -ceq "[red]The screen stopped on an error that carries no message.[/]`n[grey]Error id: W32T.Empty[/]`n`nYou are back in the menu: fix the cause and try again." -and $script:pauses.Count -eq 1) {
    Ok 'an empty message -> "The screen stopped on an error that carries no message.", the id, one pause'
} else { Bad "threw=$threw panels: $($script:panels | ConvertTo-Json -Compress)" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TuiErrorRecovery tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail TuiErrorRecovery test(s) FAILED." -ForegroundColor Red
exit 1
