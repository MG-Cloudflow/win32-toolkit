<#
    Installer-identity PR 3b, the 3b-2 extras (spec 2.15.5, 2.16; D61, L36): the command-line sibling capture follows the
    rules that came from earlier captures. The VM is shadowed (the capture shadow writes records in the frozen shape,
    Tests\Fixtures\sibling-proposal); the raise, the proposals and the rules are real.

      [1] X1: after a capture that recorded a newer version of a captured rule's identity, Test-Win32ToolkitProject
          -Scenario SiblingCapture raises the rule's VersionMax (VersionMin, the mode, the approval and every other
          AppConfig section unchanged); a capture that recorded nothing raises nothing.

    Run:  pwsh -File Tests\SiblingCaptureExtras.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test helpers')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Get-AuthenticodeSignature and Start-Sleep are shadowed: no real file is read, no wait')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')
. (Join-Path $repo 'Public\Set-Win32ToolkitPriorInstall.ps1')
. (Join-Path $repo 'Tests\Fixtures\sibling-proposal\SiblingFixture.ps1')
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32sx_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
$golden = [IO.File]::ReadAllText((Join-Path $repo 'Tests\Fixtures\psadt-4.1.8\Invoke-AppDeployToolkit.ps1'), [Text.Encoding]::UTF8)

# ---- shadows: the VM side of the capture ----
function Get-AuthenticodeSignature { [CmdletBinding()] param([string]$LiteralPath) $null = $LiteralPath; [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:TestSiblingSigner } } }
function Get-Win32ToolkitConfigValue { param($Name, $Default) $null = $Name; $Default }
function Test-Win32ToolkitSiblingCapturePreflight { param($ProjectPath, $Backend) $null = $ProjectPath, $Backend; [pscustomobject]@{ Ok = $true; Code = ''; Reasons = [string[]]@(); Backend = 'HyperV' } }
function Get-Win32ToolkitSiblingCapturePlan { param($ProjectPath, $SiblingInstallerType, $SiblingVersion, $VersionsBack, [switch]$IncludeReportOnly) $null = $ProjectPath, $SiblingInstallerType, $SiblingVersion, $VersionsBack, $IncludeReportOnly; [pscustomobject]@{ Backend = ''; Types = @() } }
$script:captureWrites = @(); $script:captureResult = $true
function Invoke-Win32ToolkitSiblingCapture {
    param($ProjectPath, $Plan, $Backend)
    $null = $Plan, $Backend
    foreach ($a in $script:captureWrites) { $null = Write-TestSiblingRecord -ProjectPath $ProjectPath -Record (New-TestSiblingRecord @a) }
    $script:captureResult
}
$realRaise = ${function:Update-Win32ToolkitPriorInstallWindow}
$script:raises = 0
function Update-Win32ToolkitPriorInstallWindow { param($ProjectPath) $script:raises++; & $realRaise -ProjectPath $ProjectPath }

$generated = $null
function New-XProject([string]$Name) {
    if (-not $script:generated) {
        $tmp = Join-Path $root 'gen.ps1'
        $null = New-Item -ItemType Directory -Path $root -Force
        [IO.File]::WriteAllText($tmp, $golden, [Text.UTF8Encoding]::new($true))
        $null = Set-PSADTDataDrivenScript -ScriptPath $tmp -WarningAction SilentlyContinue
        $t = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        $t = Remove-Win32ToolkitPhaseDefaultUi -Content $t -Phase 'Pre-Install'
        $script:generated = Set-Win32ToolkitPhaseBlock -Content $t -Phase 'Pre-Install' -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name OrgUiPreInstall)
    }
    $p = Join-Path $root "Projects\T\$Name"
    foreach ($d in 'SupportFiles', 'Documentation', 'Files') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), $script:generated, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllBytes((Join-Path $p 'Files\npp.msi'), [byte[]](1, 2, 3))
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = 'Notepad++'; DisplayName = 'Notepad++'; Version = '9.9.9'; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.msi'; SilentArgs = '' }; ProcessesToClose = @('zeta')
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Architecture = 'x64'; ProductCode = $PC }
        OrgUi = [ordered]@{ Welcome = [ordered]@{ Enabled = $true } }
        OwnIdentity = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $p
}
function Get-Cfg([string]$P) { Get-Content -LiteralPath (Join-Path $P 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json }

try {
    # == [1] X1: the raise after a command-line capture ===========================================================
    Write-Host '[1] X1: the command-line capture raises the captured rules' -ForegroundColor Cyan
    $p = New-XProject 'raise'
    foreach ($a in @(@{ Version = '8.7.9'; Role = 'Floor' }, @{ Version = '8.9.8' })) { $null = Write-TestSiblingRecord -ProjectPath $p -Record (New-TestSiblingRecord @a) }
    $null = Set-Win32ToolkitPriorInstall -ProjectPath $p -FromSiblingCapture -Mode Enforce -ProposalId 'nsis-x64' -Confirm:$false 6>$null
    $before = Get-Cfg $p
    $decFile = Join-Path $p 'Documentation\PriorInstallDecisions.json'
    $dec0 = (Get-FileHash -LiteralPath $decFile).Hash
    $script:captureWrites = @(@{ Version = '9.0.1' }); $script:captureResult = $true; $script:raises = 0
    $got = Test-Win32ToolkitProject -ProjectPath $p -Scenario SiblingCapture -Backend HyperV 6>$null
    $after = Get-Cfg $p
    $e0 = $before.PriorInstalls.Entries[0]; $e1 = $after.PriorInstalls.Entries[0]
    $sameElse = ($before | Select-Object -ExcludeProperty PriorInstalls | ConvertTo-Json -Depth 10) -ceq ($after | Select-Object -ExcludeProperty PriorInstalls | ConvertTo-Json -Depth 10)
    if ($got -eq $true -and $script:raises -eq 1 -and $e0.VersionMax -eq '8.9.8.0' -and $e1.VersionMax -eq '9.0.1.0' -and $e1.VersionMin -eq $e0.VersionMin -and $e1.Mode -eq 'Enforce' -and $e1.CaptureId -ceq $e0.CaptureId -and $sameElse -and (Get-FileHash -LiteralPath $decFile).Hash -ceq $dec0 -and @($after.PriorInstalls.Entries).Count -eq 1) {
        Ok 'a newer same-identity capture -> VersionMax 8.9.8.0 -> 9.0.1.0; VersionMin, mode, floor, the approval and every other section unchanged'
    } else { Bad "raise: got=$got raises=$($script:raises) $($e0.VersionMax) -> $($e1.VersionMax) sameElse=$sameElse" }
    $h = (Get-FileHash -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json')).Hash
    foreach ($r in @($null, $false)) {
        $script:captureWrites = @(); $script:captureResult = $r; $script:raises = 0
        $null = Test-Win32ToolkitProject -ProjectPath $p -Scenario SiblingCapture -Backend HyperV 6>$null 3>$null
        if ($script:raises -eq 0 -and (Get-FileHash -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json')).Hash -ceq $h) { Ok "a capture that recorded nothing ($(if ($null -eq $r) { '$null: nothing to capture' } else { '$false: every capture failed' })) -> no raise, nothing written" } else { Bad "no raise ($r): raises=$($script:raises)" }
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingCaptureExtras tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingCaptureExtras test(s) FAILED." -ForegroundColor Red; exit 1 }
