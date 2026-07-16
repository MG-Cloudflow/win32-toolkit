<#
    The three P0 (security / correctness) fixes.

      P0-1  Download-WingetApp reported SUCCESS when winget failed, and built its command line as a STRING
            run through Invoke-Expression — with an untrusted winget id spliced into it.
      P0-2  Update-PSADTUninstallLogic was said to throw on re-run. The data-driven rewrite already fixed
            it (it writes DATA, consumes no marker) — this locks that in so it cannot regress.
      P0-3  IntuneWinAppUtil.exe was downloaded from a MUTABLE ref with no integrity check, then EXECUTED.

    winget, Get-AuthenticodeSignature and the filesystem are shadowed; nothing hits the network.

    Run:  pwsh -File Tests\P0Fixes.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')  # installer-extension source of truth (bundle support)
. (Join-Path $repo 'Private\Download-WingetApp.ps1')
. (Join-Path $repo 'Private\Assert-Win32ToolkitTrustedBinary.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitProductCode.ps1')
. (Join-Path $repo 'Private\Update-PSADTUninstallLogic.ps1')

# ══ P0-1 ═════════════════════════════════════════════════════════════════════════════════════════
Write-Host '[P0-1] Download-WingetApp: a winget FAILURE must not be reported as success' -ForegroundColor Cyan

$script:wingetExit = 0
$script:wingetSeen = $null
function winget { $script:wingetSeen = $args; $global:LASTEXITCODE = $script:wingetExit }

function New-Dl { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32dl_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }

# happy path: exit 0 AND an installer actually landed
$d1 = New-Dl; Set-Content (Join-Path $d1 'git.exe') 'x'
$script:wingetExit = 0
if ((Download-WingetApp -AppId 'Git.Git' -AppName 'Git' -DownloadPath $d1 -Architecture 'x64' 6>$null) -eq $true) { Ok 'exit 0 + installer present -> $true' } else { Bad 'happy path returned false' }

# THE BUG: winget exits non-zero (package missing, no installer for the arch, network down).
# The old code returned $true and the pipeline scaffolded a project around an EMPTY Files\ folder.
$d2 = New-Dl
$script:wingetExit = 1
if ((Download-WingetApp -AppId 'Nope.Nope' -DownloadPath $d2 -ErrorAction SilentlyContinue 6>$null) -eq $false) { Ok 'non-zero winget exit -> $false (was: silently $true)' } else { Bad 'winget failure still reported as success' }

# winget can exit 0 having written only a manifest (zip/portable/store package) — nothing to install.
$d3 = New-Dl
$script:wingetExit = 0
if ((Download-WingetApp -AppId 'Some.Portable' -DownloadPath $d3 -ErrorAction SilentlyContinue 6>$null) -eq $false) { Ok 'exit 0 but no installer written -> $false' } else { Bad 'empty download reported as success' }

Write-Host '[P0-1] …and the untrusted winget id is an ARGUMENT, never shell-parsed' -ForegroundColor Cyan
$d4 = New-Dl; Set-Content (Join-Path $d4 'a.exe') 'x'
$script:wingetExit = 0
$evil = "Evil.App'; calc.exe; #"
$null = Download-WingetApp -AppId $evil -DownloadPath $d4 6>$null
if (@($script:wingetSeen) -contains $evil) { Ok 'a hostile id is passed as ONE argument (no shell parsing)' } else { Bad "args=$($script:wingetSeen -join '|')" }

# AST, not regex: the function's doc comment legitimately NAMES Invoke-Expression to explain the fix, and a
# text search cannot tell a comment from a call. Assert the command is never actually INVOKED.
$dlPath = Join-Path $repo 'Private\Download-WingetApp.ps1'
$ast    = [System.Management.Automation.Language.Parser]::ParseFile($dlPath, [ref]$null, [ref]$null)
$iex    = $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.CommandAst] -and
    $n.GetCommandName() -in @('Invoke-Expression', 'iex')
}, $true)
if ($iex.Count -eq 0) { Ok 'Invoke-Expression is never INVOKED (AST-verified, not a text match)' } else { Bad "$($iex.Count) Invoke-Expression call(s) remain" }
if ((Get-Content -LiteralPath $dlPath -Raw) -match '\$LASTEXITCODE') { Ok 'the exit code is actually checked' } else { Bad 'no $LASTEXITCODE check' }

# ══ P0-2 ═════════════════════════════════════════════════════════════════════════════════════════
Write-Host '[P0-2] Update-PSADTUninstallLogic is IDEMPOTENT (re-running must not throw)' -ForegroundColor Cyan
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('w32un_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
$capture = Join-Path $proj 'InstallationChanges_x.json'
@{
    NewRegistryKeys = @(
        @{ Path = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{11111111-2222-3333-4444-555555555555}'
           Values = @{ DisplayName = 'Test App'; UninstallString = 'C:\App\unins000.exe'; QuietUninstallString = 'C:\App\unins000.exe /S' } }
    )
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capture

$threw = $false
try {
    $null = Update-PSADTUninstallLogic -ProjectPath $proj -JsonFilePath $capture 6>$null 3>$null
    $null = Update-PSADTUninstallLogic -ProjectPath $proj -JsonFilePath $capture 6>$null 3>$null   # re-run
    $null = Update-PSADTUninstallLogic -ProjectPath $proj -JsonFilePath $capture 6>$null 3>$null   # and again
}
catch { $threw = $true }
if (-not $threw) { Ok 'runs 3x over the same project without throwing (data-driven: no marker to consume)' } else { Bad 're-run threw' }
$cfg = Get-Win32ToolkitAppConfig -ProjectPath $proj
if ($cfg.PSObject.Properties.Name -contains 'Uninstall') { Ok 'the Uninstall section is written as DATA (overwritten, not appended)' } else { Bad 'no Uninstall section' }
$uSrc = Get-Content -LiteralPath (Join-Path $repo 'Private\Update-PSADTUninstallLogic.ps1') -Raw
if ($uSrc -notmatch '<Perform Uninstallation tasks here>') { Ok 'no pristine-marker dependency remains (the old non-idempotency)' } else { Bad 'still consumes the pristine marker' }

# ══ P0-3 ═════════════════════════════════════════════════════════════════════════════════════════
Write-Host '[P0-3] IntuneWinAppUtil.exe: fail CLOSED unless Microsoft-signed' -ForegroundColor Cyan
$bin = Join-Path ([System.IO.Path]::GetTempPath()) ('w32bin_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.exe')
Set-Content -LiteralPath $bin 'MZ'

$script:sig = $null
function Get-AuthenticodeSignature { param($LiteralPath, $ErrorAction) return $script:sig }

$script:sig = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond' } }
$threw = $false
try { Assert-Win32ToolkitTrustedBinary -Path $bin -ExpectedSubject 'Microsoft Corporation' } catch { $threw = $true }
if (-not $threw) { Ok 'a genuine Microsoft-signed binary is accepted' } else { Bad 'rejected a valid signature' }

# tampered / unsigned -> must throw AND delete (so a bad binary can never be reused next run)
$script:sig = [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } }
$threw = $false
try { Assert-Win32ToolkitTrustedBinary -Path $bin -ExpectedSubject 'Microsoft Corporation' -RemoveOnFailure } catch { $threw = $true }
if ($threw -and -not (Test-Path -LiteralPath $bin)) { Ok 'tampered binary: throws AND is deleted (fails closed)' } else { Bad "threw=$threw stillThere=$(Test-Path $bin)" }

# signed, but by SOMEONE ELSE — the substitution attack the mutable master ref allowed
Set-Content -LiteralPath $bin 'MZ'
$script:sig = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Totally Legit Software Ltd' } }
$threw = $false
try { Assert-Win32ToolkitTrustedBinary -Path $bin -ExpectedSubject 'Microsoft Corporation' -RemoveOnFailure } catch { $threw = $true }
if ($threw) { Ok 'validly signed by the WRONG publisher is still rejected' } else { Bad 'accepted a non-Microsoft signature' }

$eSrc = Get-Content -LiteralPath (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1') -Raw
if (([regex]::Matches($eSrc, 'Assert-Win32ToolkitTrustedBinary')).Count -ge 2) {
    Ok 'verified on BOTH download and reuse of an existing Tools\ copy'
} else { Bad 'not verified on both paths' }

Remove-Item -LiteralPath $d1, $d2, $d3, $d4, $proj -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P0Fixes tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P0Fixes test(s) FAILED." -ForegroundColor Red; exit 1 }
