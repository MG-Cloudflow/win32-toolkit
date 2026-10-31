<#
    PowerShell 7.4 host floor (impact analysis D8; SCF-05, SWP-04, DOC-08; critique C1-m5).

    PSAppDeployToolkit 4.2 loads lib\net8.0 under pwsh and therefore needs .NET 8, i.e. PowerShell 7.4
    or later on the packaging host. The floor is declared at several sites; this suite pins every one of
    them so a later edit cannot quietly lower one site (e.g. the manifest says 7.4 while the TUI guard
    still lets 7.2 in and the health check shows green):

      - win32-toolkit.psd1          PowerShellVersion = '7.4'
      - win32-toolkit.psm1          first line  #Requires -Version 7.4
      - build\Publish-ToPSGallery.ps1  first line  #Requires -Version 7.4
      - PSScriptAnalyzerSettings.psd1  PSUseCompatibleSyntax TargetVersions = @('7.4')
      - Public\Show-Win32Toolkit.ps1   guard compares with [version]'7.4', message and help say 7.4
      - Private\Test-Win32ToolkitPrerequisites.ps1  row 'PowerShell 7.4+' with -ge [version]'7.4'
      - Launch-Win32Toolkit.cmd     the 'pwsh not found' message names PowerShell 7.4 or later (TUI audit
                                    G12; an older pwsh still fails closed through the manifest floor)
      - no stale 7.2 floor anywhere in *.ps1 / *.psm1 / *.psd1 outside Tests\

    The generated DEVICE scripts are unaffected: they still target Windows PowerShell 5.1.
    Pure text/data checks: no PSADT, no module import.

    Run:  pwsh -File Tests\PwshFloor.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }
function TextOf([string]$Rel) { Get-Content -LiteralPath (Join-Path $repo $Rel) -Raw }
function FirstLineOf([string]$Rel) { (Get-Content -LiteralPath (Join-Path $repo $Rel) -TotalCount 1) -replace ('^' + [char]0xFEFF), '' }

Write-Host "`n[1] module manifest, loader and publish script" -ForegroundColor Cyan
$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'win32-toolkit.psd1')
if ($manifest.PowerShellVersion -eq '7.4') { Ok "win32-toolkit.psd1 PowerShellVersion = '7.4'" } else { Bad "win32-toolkit.psd1 PowerShellVersion = '$($manifest.PowerShellVersion)'" }
foreach ($rel in 'win32-toolkit.psm1', 'build\Publish-ToPSGallery.ps1') {
    $first = FirstLineOf $rel
    if ($first -match '^#Requires -Version 7\.4\s*$') { Ok "$rel starts with '#Requires -Version 7.4'" } else { Bad "$rel first line: '$first'" }
}

Write-Host "`n[2] PSScriptAnalyzer compatibility target" -ForegroundColor Cyan
$pssa = Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'PSScriptAnalyzerSettings.psd1')
$targets = @($pssa.Rules.PSUseCompatibleSyntax.TargetVersions)
if ($pssa.Rules.PSUseCompatibleSyntax.Enable -and $targets.Count -eq 1 -and $targets[0] -eq '7.4') { Ok "PSUseCompatibleSyntax TargetVersions = @('7.4')" } else { Bad "TargetVersions = @($($targets -join ', ')) (Enable = $($pssa.Rules.PSUseCompatibleSyntax.Enable))" }

Write-Host "`n[3] Show-Win32Toolkit guard and help" -ForegroundColor Cyan
$tui = TextOf 'Public\Show-Win32Toolkit.ps1'
if ($tui -match "\`$PSVersionTable\.PSVersion\s+-lt\s+\[version\]'7\.4'") { Ok "the guard compares with [version]'7.4'" } else { Bad 'the guard does not compare with [version]''7.4''' }
if ($tui -match "Write-Warning\s+'Show-Win32Toolkit requires PowerShell 7\.4 or later\.'") { Ok 'the guard message says PowerShell 7.4' } else { Bad 'the guard message does not say PowerShell 7.4' }
if ($tui -match 'PowerShell 7\.4 or later in an interactive console') { Ok 'the help says PowerShell 7.4 or later' } else { Bad 'the help does not say PowerShell 7.4 or later' }

Write-Host "`n[4] health check row" -ForegroundColor Cyan
$pre = TextOf 'Private\Test-Win32ToolkitPrerequisites.ps1'
if ($pre -match "\`$psOk\s*=\s*\`$PSVersionTable\.PSVersion\s+-ge\s+\[version\]'7\.4'") { Ok "the check uses -ge [version]'7.4'" } else { Bad 'the check does not use -ge [version]''7.4''' }
if ($pre -match "Add-Check\s+'PowerShell 7\.4\+'") { Ok "the row is named 'PowerShell 7.4+'" } else { Bad 'the row is not named ''PowerShell 7.4+''' }

Write-Host "`n[5] no stale 7.2 floor outside Tests\" -ForegroundColor Cyan
# Everything the module ships or builds with. Tests\ (fixtures, shadows) and the local, git-ignored
# working folders (.claude, knowledge-base) are not product code.
$skip = @('Tests', '.git', '.claude', 'knowledge-base', 'node_modules', 'site')
$files = @(Get-ChildItem -LiteralPath $repo -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
foreach ($dir in Get-ChildItem -LiteralPath $repo -Directory -Force | Where-Object { $_.Name -notin $skip }) {
    $files += @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
}
$stale = foreach ($f in $files) {
    Select-String -LiteralPath $f.FullName -Pattern "(PowerShell|PS|-Version)\s*7\.2|'7\.2'" |
        ForEach-Object { '{0}:{1}: {2}' -f $f.FullName.Substring($repo.Length + 1), $_.LineNumber, $_.Line.Trim() }
}
if ($files.Count -gt 10 -and @($stale).Count -eq 0) { Ok "no 7.2 floor reference in $($files.Count) script/manifest files" }
elseif ($files.Count -le 10) { Bad "scanned only $($files.Count) files - the scan root looks wrong" }
else { foreach ($s in $stale) { Bad "stale 7.2 floor: $s" } }

Write-Host "`n[6] the double-click launcher names the 7.4 floor" -ForegroundColor Cyan
$launcher = TextOf 'Launch-Win32Toolkit.cmd'
if ($launcher.Contains('echo   PowerShell 7.4 or later ^(pwsh^) is required, but pwsh was not found.')) { Ok "Launch-Win32Toolkit.cmd: 'PowerShell 7.4 or later ^(pwsh^) is required, but pwsh was not found.'" } else { Bad 'the launcher does not name PowerShell 7.4 or later' }
if (-not $launcher.Contains('PowerShell 7 ^(pwsh^)')) { Ok "no 'PowerShell 7 ^(pwsh^)' (the floor without its minor version)" } else { Bad "the launcher still says 'PowerShell 7 ^(pwsh^)'" }
# An older pwsh is refused by the manifest floor at Import-Module; the launcher shows that error and waits.
if ($launcher -match "Import-Module '%~dp0win32-toolkit\.psd1'" -and $launcher -match 'catch \{ Write-Host \$_\.Exception\.Message -ForegroundColor Red; Read-Host') { Ok 'the launcher imports the manifest (7.4 floor) in a try and shows its error' } else { Bad 'the launcher no longer imports the manifest in a try/catch' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PwshFloor tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PwshFloor test(s) FAILED." -ForegroundColor Red; exit 1 }
