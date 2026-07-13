<#
    Unit tests for Get-Win32ToolkitGuestCredentialInteractive — the type-it-twice password confirmation.
    Read-Host is shadowed with an in-scope stub that dequeues scripted answers, so nothing actually
    prompts. No Hyper-V, no registry.

    Run:  pwsh -File Tests\GuestCredentialPrompt.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitGuestCredentialInteractive.ps1')

# Scripted Read-Host: dequeues one answer per call; password prompts (-AsSecureString) get a SecureString.
$script:answers = [System.Collections.Queue]::new()
function Read-Host {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Prompt, [switch]$AsSecureString, [switch]$MaskInput)
    $v = [string]$script:answers.Dequeue()
    if ($AsSecureString) {
        # ConvertTo-SecureString rejects '' — emit a genuinely empty SecureString for the blank case.
        if ([string]::IsNullOrEmpty($v)) { return [System.Security.SecureString]::new() }
        return (ConvertTo-SecureString $v -AsPlainText -Force)
    }
    return $v
}
function Plain([pscredential]$c) { $c.GetNetworkCredential().Password }

Write-Host '[1] matching, non-blank password -> returned as-is' -ForegroundColor Cyan
$script:answers = [System.Collections.Queue]::new((@('w32admin', 'P@ssw0rd!', 'P@ssw0rd!')))
$c = Get-Win32ToolkitGuestCredentialInteractive
if ($c.UserName -eq 'w32admin' -and (Plain $c) -eq 'P@ssw0rd!') { Ok 'user + confirmed password round-trip' } else { Bad "got '$($c.UserName)' / '$(Plain $c)'" }

Write-Host '[2] blank user name -> falls back to the default' -ForegroundColor Cyan
$script:answers = [System.Collections.Queue]::new((@('', 'Secret123', 'Secret123')))
$c = Get-Win32ToolkitGuestCredentialInteractive -UserName 'labadmin'
if ($c.UserName -eq 'labadmin') { Ok 'empty user -> default user' } else { Bad "user was '$($c.UserName)'" }

Write-Host '[3] mismatch first, then matching -> loops until confirmed' -ForegroundColor Cyan
$script:answers = [System.Collections.Queue]::new((@('u', 'aaa', 'bbb', 'u', 'ccc', 'ccc')))
$c = Get-Win32ToolkitGuestCredentialInteractive -WarningAction SilentlyContinue
if ((Plain $c) -eq 'ccc') { Ok 'mismatch re-prompts, second matching pair accepted' } else { Bad "got '$(Plain $c)'" }

Write-Host '[4] blank first, then non-blank -> loops until non-blank' -ForegroundColor Cyan
$script:answers = [System.Collections.Queue]::new((@('u', '', '', 'u', 'x1y2', 'x1y2')))
$c = Get-Win32ToolkitGuestCredentialInteractive -WarningAction SilentlyContinue
if ((Plain $c) -eq 'x1y2') { Ok 'blank re-prompts, first non-blank matching pair accepted' } else { Bad "got '$(Plain $c)'" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All GuestCredentialPrompt tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail GuestCredentialPrompt test(s) FAILED." -ForegroundColor Red; exit 1 }
