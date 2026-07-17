<#
    The Intune connection TUI screen: EXECUTED, not just parsed.

    THE BUG THIS EXISTS FOR: the screen shipped with

        $connected = [bool](try { Get-MgContext } catch { $null })

    try/catch is a STATEMENT. Assigning from one ($x = try {...} catch {...}) is fine and the codebase
    does it, but wrapping it in ( ) makes PowerShell parse 'try' as a COMMAND NAME. That is still valid
    syntax, so Parser::ParseFile passes clean, and it only dies at RUNTIME with
    "The term 'try' is not recognized". A parse check cannot catch it. Only running it can.

    So this drives the screen with Spectre + Graph shadowed and asserts it reaches the menu and returns.

    Run:  pwsh -File Tests\IntuneConnectionScreen.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitTenantBanner.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitIntuneConnection.ps1')

# ── Spectre + Graph shadows ──────────────────────────────────────────────────────────────────────
$script:menuShown = 0
$script:choicesSeen = $null
function Clear-Host { }
function Write-SpectreRule { param([Parameter(ValueFromRemainingArguments)]$a) }
function Write-SpectreHost { param([Parameter(ValueFromRemainingArguments)]$a) }
function Format-SpectrePanel { param([Parameter(ValueFromRemainingArguments)]$a) }
function Get-SpectreEscapedText { param($Text) $Text }
function Read-SpectrePause { param([Parameter(ValueFromRemainingArguments)]$a) }
function Read-SpectreText { param([Parameter(ValueFromRemainingArguments)]$a) '' }
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, $PageSize)
    $script:menuShown++
    $script:choicesSeen = @($Choices)
    # always pick 'back' so the loop terminates
    return (@($Choices) | Where-Object { $_.Key -eq 'back' } | Select-Object -First 1)
}
function Get-Win32ToolkitTenantInfo { $null }

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('tuiconn_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $base 'Templates') -Force | Out-Null

try {
    Write-Host "`n[1] DISCONNECTED: the screen runs and returns (the try/catch-in-parens regression)" -ForegroundColor Cyan
    function Get-MgContext { $null }
    $script:menuShown = 0
    $err = $null
    try { Show-Win32ToolkitIntuneConnection -BasePath $base } catch { $err = $_.Exception.Message }
    if (-not $err) { Ok 'screen executed with no session and returned cleanly' }
    else { Bad "threw: $err" }
    if ($script:menuShown -ge 1) { Ok 'the menu was actually rendered' } else { Bad 'never reached the menu' }
    # the regression's exact signature
    if ($err -notmatch "The term 'try' is not recognized") { Ok "no 'try is not recognized' runtime error" }
    else { Bad 'THE try/catch-in-parens BUG IS BACK' }
    $keys = @($script:choicesSeen | ForEach-Object { $_.Key })
    if ($keys -notcontains 'disconnect') { Ok 'no Sign out offered when not connected' } else { Bad 'offered sign-out with no session' }

    Write-Host "`n[2] CONNECTED: the screen offers Sign out" -ForegroundColor Cyan
    function Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'mg@cloudflow.be'; Scopes = @('DeviceManagementApps.ReadWrite.All'); ContextScope = 'Process'; AuthType = 'Delegated' } }
    $script:menuShown = 0
    $err2 = $null
    try { Show-Win32ToolkitIntuneConnection -BasePath $base } catch { $err2 = $_.Exception.Message }
    if (-not $err2) { Ok 'screen executed with a live session' } else { Bad "threw: $err2" }
    $keys2 = @($script:choicesSeen | ForEach-Object { $_.Key })
    if ($keys2 -contains 'disconnect') { Ok 'Sign out offered when connected' } else { Bad 'no sign-out offered' }
    foreach ($k in 'connect','tenant','back') {
        if ($keys2 -contains $k) { Ok "menu offers '$k'" } else { Bad "menu missing '$k'" }
    }

    Write-Host "`n[3] The banner runs in both states" -ForegroundColor Cyan
    $e3 = $null
    try { Show-Win32ToolkitTenantBanner } catch { $e3 = $_.Exception.Message }
    if (-not $e3) { Ok 'banner renders with a session' } else { Bad "banner threw: $e3" }
    function Get-MgContext { $null }
    $e4 = $null
    try { Show-Win32ToolkitTenantBanner } catch { $e4 = $_.Exception.Message }
    if (-not $e4) { Ok 'banner renders with no session' } else { Bad "banner threw: $e4" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All IntuneConnectionScreen tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail IntuneConnectionScreen test(s) FAILED." -ForegroundColor Red; exit 1 }
