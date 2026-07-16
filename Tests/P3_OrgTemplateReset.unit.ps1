<#
    P3 / ITEM #7 — $script:OrgTemplate must not leak across public commands in one session.

    Both Invoke-Win32Toolkit and New-Win32ToolkitManualApp set the module-scoped $script:OrgTemplate
    during a run. With no finally, a stale template survived the command and could be read by the NEXT
    command before it set its own. The fix adds a finally that resets $script:OrgTemplate to $null on
    BOTH success and failure paths.

    This test has two parts:
      (a) SOURCE — both public files contain a finally block that sets $script:OrgTemplate to $null.
      (b) BEHAVIOUR — dot-source New-Win32ToolkitManualApp with the heavy helpers shadowed (mirroring
          Tests\ManualApp.integration.ps1), seed $script:OrgTemplate with a sentinel, run the command,
          and assert $script:OrgTemplate is $null afterward (and stays $null after a failing run too).

    Against the OLD behaviour (no finally) part (a) finds no reset and part (b) sees the sentinel
    replaced by the run's template (not $null) — both FAIL. Against the fix both PASS.

    Run:  pwsh -File Tests\P3_OrgTemplateReset.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# ── (a) SOURCE assertion ──────────────────────────────────────────────────────────────────────────
# A finally block that clears $script:OrgTemplate to $null. Tolerant of spacing/casing.
$resetPattern = '(?is)finally\s*\{[^}]*\$script:OrgTemplate\s*=\s*\$null[^}]*\}'

Write-Host '[1] SOURCE: both public commands clear $script:OrgTemplate in a finally' -ForegroundColor Cyan
foreach ($rel in 'Public\Invoke-Win32Toolkit.ps1', 'Public\New-Win32ToolkitManualApp.ps1') {
    $path = Join-Path $repo $rel
    $text = Get-Content -LiteralPath $path -Raw
    if ($text -match $resetPattern) {
        Ok "$rel resets `$script:OrgTemplate to `$null in a finally block"
    } else {
        Bad "$rel has NO finally that clears `$script:OrgTemplate (stale template leaks to next command)"
    }
    # Parse check — the finally must not break the file.
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
    if (-not $errors -or $errors.Count -eq 0) { Ok "$rel parses cleanly" } else { Bad "$rel has parse errors: $($errors -join '; ')" }
}

# ── (b) BEHAVIOUR — New-Win32ToolkitManualApp is the more testable of the two ────────────────────────
. (Join-Path $repo 'Private\Sanitize-ProjectName.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')  # installer-extension source of truth (bundle support)
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Add-Win32ToolkitInstallerFiles.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitDependencies.ps1')
. (Join-Path $repo 'Public\Set-Win32ToolkitAppDependency.ps1')
. (Join-Path $repo 'Public\New-Win32ToolkitManualApp.ps1')

# shadow only what is NOT under test (mirrors Tests\ManualApp.integration.ps1)
$BASE = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ot_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$Reconfigure) $BASE }
function Get-OrgTemplate { param($BasePath, $TemplateName) [pscustomobject]@{ TemplateName = 'Contoso'; AppScriptAuthor = 'IT' } }
function Apply-OrgTemplate { param($ProjectPath, $Template) $true }
function Create-PSADTProject {
    param($ProjectName, $ProjectPath, $Force)
    $full = Join-Path $ProjectPath $ProjectName
    New-Item -ItemType Directory -Path $full -Force | Out-Null
    foreach ($d in 'Files', 'SupportFiles') { New-Item -ItemType Directory -Path (Join-Path $full $d) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $full 'Invoke-AppDeployToolkit.ps1') -Value '## <Perform Installation tasks here>'
    return $true
}
function Set-PSADTDataDrivenScript { param($ScriptPath, [switch]$ManualInstall) $true }
function Invoke-Win32ToolkitFinalize { param($ProjectPath, $ProjectName, $AppInfo, $RunTest, [switch]$PackageIntune, [switch]$PublishIntune, [switch]$PublishUpdate) }

function New-Src { param([string]$Name) $d = Join-Path $BASE ('src_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $d -Force | Out-Null; $f = Join-Path $d $Name; Set-Content -LiteralPath $f 'binary'; $f }

$SENTINEL = [pscustomobject]@{ TemplateName = 'STALE_FROM_PREVIOUS_COMMAND'; AppScriptAuthor = 'ghost' }

Write-Host '[2] BEHAVIOUR: a successful run leaves $script:OrgTemplate cleared to $null' -ForegroundColor Cyan
$script:OrgTemplate = $SENTINEL
$msi = New-Src 'reset.msi'
$null = New-Win32ToolkitManualApp -Name 'Reset App' -Version '1.0' -Architecture x64 -SourcePath $msi -TemplateName 'Contoso' -Force 6>$null 3>$null
if ($null -eq $script:OrgTemplate) { Ok 'after a successful command $script:OrgTemplate is $null (no leak to the next command)' }
else { Bad "stale template survived: $($script:OrgTemplate | Out-String)" }

Write-Host '[3] BEHAVIOUR: a FAILING run also clears $script:OrgTemplate (finally on both paths)' -ForegroundColor Cyan
$script:OrgTemplate = $SENTINEL
# A non-existent SourcePath makes the command throw inside the try (before it finishes) — the finally
# must still run. The function's catch calls Write-Error; under this test's $ErrorActionPreference='Stop'
# that re-throws, so swallow it here — we only care that the finally cleared the module variable.
try { $null = New-Win32ToolkitManualApp -Name 'Boom' -Version '1.0' -Architecture x64 -SourcePath (Join-Path $BASE 'does-not-exist.msi') -TemplateName 'Contoso' -Force 6>$null 3>$null 2>$null } catch { }
if ($null -eq $script:OrgTemplate) { Ok 'after a failed command $script:OrgTemplate is $null too' }
else { Bad "stale template survived a failed run: $($script:OrgTemplate | Out-String)" }

Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'OrgTemplate-reset test PASSED.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail OrgTemplate-reset check(s) FAILED." -ForegroundColor Red; exit 1 }
