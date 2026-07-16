<#
    The six defects an adversarial review found in the P1 round-2 fixes themselves — bugs introduced (or
    left behind) by the very changes meant to harden the module. Each check below failed before the follow-up.

      [1] COMMENT INJECTION (the serious one). New-IntuneRequirementScript spliced the RAW, unescaped app name
          into the generated script comment header. A DisplayName containing a comment terminator closes the
          block, and everything after it becomes top-level code in a script Intune runs as SYSTEM.
          ConvertTo-PSSingleQuoted guards a single-quoted LITERAL; it does nothing in a comment context.
      [2] DEAD YAML FALLBACK. The same function hand-picked the alphabetically-first manifest — the installer
          manifest, which carries no PackageName — so when the capture produced no program entries the
          fallback yielded null and NO requirement script was written at all.
      [3] FALSE ABORT. Create-PSADTProject's post-update guard tested whether PSADT was INSTALLED, not whether
          it was LOADED. PSADT is imported later in that same function, so in a fresh session nothing is loaded
          and accepting the update killed a perfectly good run.
      [4] HARMFUL ADVICE. The download-failure warning told the user to drop an installer into Files\ and
          re-run — but a re-run recreates the project folder, deleting exactly what they put there.
      [5] SILENT INSTALLER GUESS. Get-InstallerFileInfo takes the first file BY NAME with no content
          inspection and said nothing — the file it picks is what the device actually executes.
      [6] EMPTY PUBLISH METADATA. Publish read description/informationUrl from the installer manifest, where
          they do not live, so they published as empty strings.

    Run:  pwsh -File Tests\P1_ReviewFixes.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }
function NewTmp { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32rv_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }

. (Join-Path $repo 'Private\ConvertTo-PSSingleQuoted.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitProductCode.ps1')
. (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
. (Join-Path $repo 'Private\Get-YAMLInstallerInfo.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')  # installer-extension source of truth (bundle support)
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')
. (Join-Path $repo 'Private\New-IntuneRequirementScript.ps1')

$closeComment = '#' + '>'   # kept out of THIS file's own header on purpose
$openComment  = '<' + '#'

# ══ [1] a hostile DisplayName cannot break out of the comment header into executable code ══════════
Write-Host '[1] New-IntuneRequirementScript: a hostile DisplayName cannot inject code via the comment header' -ForegroundColor Cyan
$proj = NewTmp
New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $proj 'Files') -Force | Out-Null

# Payload: close the comment, run code, reopen a comment so the tail still parses.
$evil = "Evil App $closeComment ; Write-Output 'PWNED' ; $openComment"
$capture = Join-Path $proj 'InstallationChanges_evil.json'
@{
    NewRegistryKeys = @(
        @{ Path   = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{11111111-2222-3333-4444-555555555555}'
           Values = @{ DisplayName = $evil; DisplayVersion = '1.0'; Publisher = 'ACME'; UninstallString = 'C:\x\u.exe' } }
    )
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capture

$null = New-IntuneRequirementScript -ProjectPath $proj -JsonFilePath $capture 6>$null 3>$null
$reqScript = Join-Path $proj 'SupportFiles\RequirementScript.ps1'
if (Test-Path $reqScript) {
    $genText = Get-Content -LiteralPath $reqScript -Raw
    # The real proof is AST-based, not textual: the payload string legitimately appears INSIDE the safe,
    # single-quoted `-eq '<name>'` literal (escaped by ConvertTo-PSSingleQuoted), so a substring grep would
    # false-positive. Parse the generated script and assert 'PWNED' never appears as an executable COMMAND —
    # if the comment breakout had worked, there would be a `Write-Output 'PWNED'` CommandAst at top level.
    $perr = $null
    $genAst = [System.Management.Automation.Language.Parser]::ParseInput($genText, [ref]$null, [ref]$perr)
    if (-not $perr -or $perr.Count -eq 0) { Ok 'the generated requirement script still parses with a hostile name' }
    else { Bad "hostile name broke the generated script parse: $($perr[0].Message)" }

    # The injected payload's command is `Write-Output`; the genuine requirement script never calls it. Match on
    # the resolved command NAME, not on the extent span (a legitimate Where-Object's span encloses the safe
    # single-quoted literal that contains the payload text).
    $pwnedCmd = $genAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Write-Output'
    }, $true)
    if ($pwnedCmd.Count -eq 0) { Ok 'the payload never becomes an executable command (comment breakout neutralised)' }
    else { Bad "injected payload executes: $($pwnedCmd[0].Extent.Text)" }
} else { Bad 'no requirement script was produced for the hostile-name capture' }

# ══ [2] the YAML fallback actually works (no program entries in the capture) ═══════════════════════
Write-Host '[2] New-IntuneRequirementScript: the winget-manifest fallback still produces a script' -ForegroundColor Cyan
$proj2 = NewTmp
New-Item -ItemType Directory -Path (Join-Path $proj2 'SupportFiles') -Force | Out-Null
$files2 = Join-Path $proj2 'Files'; New-Item -ItemType Directory -Path $files2 -Force | Out-Null
# A realistic multi-manifest set. The ALPHABETICALLY-FIRST file is the installer manifest (no PackageName);
# the display fields live only in the locale manifest.
Set-Content -LiteralPath (Join-Path $files2 'Acme.App.installer.yaml') -Value @"
PackageIdentifier: Acme.App
PackageVersion: 2.5.0
InstallerType: exe
Installers:
  - Architecture: x64
"@
Set-Content -LiteralPath (Join-Path $files2 'Acme.App.locale.en-US.yaml') -Value @"
PackageIdentifier: Acme.App
PackageName: Acme Application
Publisher: Acme Corp
ShortDescription: Does acme things.
"@
# capture JSON with NO program entries -> forces the fallback
$capture2 = Join-Path $proj2 'InstallationChanges_empty.json'
@{ NewRegistryKeys = @() } | ConvertTo-Json | Set-Content -LiteralPath $capture2
$null = New-IntuneRequirementScript -ProjectPath $proj2 -JsonFilePath $capture2 6>$null 3>$null
$req2 = Join-Path $proj2 'SupportFiles\RequirementScript.ps1'
if (Test-Path $req2) {
    $t2 = Get-Content -LiteralPath $req2 -Raw
    if ($t2 -match 'Acme Application') { Ok 'fallback read PackageName from the LOCALE manifest and wrote a script' }
    else { Bad 'fallback produced a script but without the manifest DisplayName' }
} else { Bad 'no requirement script written from the manifest fallback (dead fallback regression)' }

# ══ [5] Get-InstallerFileInfo warns when it is guessing between same-extension files ════════════════
Write-Host '[5] Get-InstallerFileInfo: an ambiguous installer folder produces a warning, not a silent guess' -ForegroundColor Cyan
$fx = NewTmp
Set-Content -LiteralPath (Join-Path $fx 'aaa-setup.exe') 'x'
Set-Content -LiteralPath (Join-Path $fx 'zzz-helper.exe') 'y'
$warns = @()
$info = Get-InstallerFileInfo -FilesPath $fx -WarningVariable +warns 3>&1 | Out-Null
$info = Get-InstallerFileInfo -FilesPath $fx -WarningAction SilentlyContinue
$capWarn = Get-InstallerFileInfo -FilesPath $fx -WarningVariable wv -WarningAction SilentlyContinue; $null = $capWarn
if ($wv -and ($wv -join ' ') -match 'aaa-setup\.exe' -and ($wv -join ' ') -match 'zzz-helper\.exe') {
    Ok 'both candidate .exe names are surfaced in a warning'
} else { Bad "no ambiguity warning naming both candidates (got: $($wv -join ' | '))" }
if ($info.FileName) { Ok 'it still returns a deterministic installer (first by name) so the pipeline proceeds' }
else { Bad 'ambiguous folder returned no installer at all' }
# single-file folder must stay silent (no false noise)
$fx2 = NewTmp; Set-Content -LiteralPath (Join-Path $fx2 'only.exe') 'x'
$null = Get-InstallerFileInfo -FilesPath $fx2 -WarningVariable wv2 -WarningAction SilentlyContinue
if (-not $wv2) { Ok 'a single-installer folder produces no warning' } else { Bad "false ambiguity warning on a single file: $($wv2 -join '|')" }

# ══ [6] Get-YAMLInstallerInfo surfaces Description / InformationUrl / PackageIdentifier ═════════════
Write-Host '[6] Get-YAMLInstallerInfo: description, information URL and PackageIdentifier come from the right manifest' -ForegroundColor Cyan
$fx3 = NewTmp
Set-Content -LiteralPath (Join-Path $fx3 'Acme.App.installer.yaml') -Value @"
PackageIdentifier: Acme.App
PackageVersion: 2.5.0
InstallerType: exe
"@
Set-Content -LiteralPath (Join-Path $fx3 'Acme.App.locale.en-US.yaml') -Value @"
PackageIdentifier: Acme.App
PackageName: Acme Application
Publisher: Acme Corp
ShortDescription: Does acme things.
PublisherUrl: https://acme.example
"@
$yi = Get-YAMLInstallerInfo -FilesPath $fx3
if ($yi.Description -eq 'Does acme things.') { Ok 'Description read from the locale manifest' } else { Bad "Description = '$($yi.Description)'" }
if ($yi.InformationUrl -eq 'https://acme.example') { Ok 'InformationUrl read from the locale manifest' } else { Bad "InformationUrl = '$($yi.InformationUrl)'" }
if ($yi.PackageIdentifier -eq 'Acme.App') { Ok 'PackageIdentifier is exposed (Publish reads it for the winget id)' } else { Bad "PackageIdentifier = '$($yi.PackageIdentifier)'" }

# ══ [3]+[4] source-level guards (behaviour proven in P1_SelfRelaunch / P1_DroppedFlags) ════════════
Write-Host '[3] Create-PSADTProject: the post-update guard keys off a LOADED module, not an installed one' -ForegroundColor Cyan
$cpText = Get-Content -LiteralPath (Join-Path $repo 'Private\Create-PSADTProject.ps1') -Raw
# the abort must be gated on a bare Get-Module (loaded), and must re-read the module after the update
if ($cpText -match '\$loaded\s*=\s*Get-Module\s+-Name\s+PSAppDeployToolkit(?!\s+-ListAvailable)') {
    Ok 'the abort is gated on a bare Get-Module (loaded), not -ListAvailable (installed)'
} else { Bad 'the loaded-vs-installed guard is missing' }

Write-Host '[4] Invoke-Win32Toolkit: the download-failure advice no longer says "drop into Files\ and re-run"' -ForegroundColor Cyan
$ivText = Get-Content -LiteralPath (Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1') -Raw
if ($ivText -match 'New-Win32ToolkitManualApp' -and $ivText -match 'recreated from scratch') {
    Ok 'it points at the manual flow and warns the folder is recreated on re-run'
} else { Bad 'the harmful "drop into Files\ and re-run" advice was not replaced' }

Remove-Item -LiteralPath $proj, $proj2, $fx, $fx2, $fx3 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1 review-fix regression tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1 review-fix test(s) FAILED." -ForegroundColor Red; exit 1 }
