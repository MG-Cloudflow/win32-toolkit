<#
    Installer-identity PR 3b (spec 2.14.2; SV21, SV24, SV29, SV34, D60, L32, L36): Get-Win32ToolkitSiblingCapturePlan -
    which other installer technologies of an app are captured, at which versions. The real sibling probe runs against
    the public winget-pkgs manifests in Tests\Fixtures\winget-manifests, served by an Invoke-WebRequest shadow (plus
    synthetic manifests for the version history); winget is shadowed. No network, no VM.

      [1] classes: Notepad++ x64 packaged WiX -> nullsoft RemovableNow, the zip/portable NotCapturable; TeamViewer (packaged
          nullsoft) -> the zip-wrapped WiX NotCapturable with the SV21 reason; Paint.NET (packaged nullsoft) -> its
          zip-wrapped installers NotCapturable; an app shipping NSIS and Inno Setup (packaged MSI) -> both planned; MSI /
          Burn ReportOnly unless -IncludeReportOnly; -SiblingInstallerType filters.
      [2] versions: Newest = the newest offering version at or below the package version (strictly below for the
          package's own family); the floor by 12 months (release dates); by count (the 5th before Newest) when a date is
          missing; Repeat when only one version offers the type; -SiblingVersion (one -> plus a Repeat); -VersionsBack; a
          failed GET skips that version (listed); a type that already has captured rules -> Newest only (L36).
      [3] CaptureKey: '<type>-<version>[-x86][-r]', lower-case, outside [a-z0-9._+-] -> '_', at most 80.

    Run:  pwsh -File Tests\SiblingCapturePlan.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-WebRequest is shadowed: the suite never touches the network')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'ConvertTo-Win32ToolkitSafeText', 'Get-Win32ToolkitInstallerFamily', 'Get-Win32ToolkitSiblingInstaller', 'Get-Win32ToolkitSiblingCapturePlan', 'Get-Win32ToolkitSiblingCaptureClass', 'Get-Win32ToolkitAppConfig', 'Get-Win32ToolkitDeployScriptBlock', 'ConvertTo-Win32ToolkitPriorVersion') {
    . (Join-Path $repo "Private\$f.ps1")
}
$fx = Join-Path $repo 'Tests\Fixtures\winget-manifests'
$script:served = @{}       # 'id|version' -> manifest text
$script:failVersions = @()
$script:gets = [System.Collections.Generic.List[string]]::new()
function Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, [int]$TimeoutSec, [int]$MaximumRedirection, [switch]$SkipHttpErrorCheck)
    $null = $TimeoutSec, $MaximumRedirection, $SkipHttpErrorCheck
    $script:gets.Add($Uri)
    $parts = $Uri -split '/'
    $ver = [uri]::UnescapeDataString($parts[-2]); $id = [uri]::UnescapeDataString(($parts[-1] -replace '\.installer\.yaml$', ''))
    if ($script:failVersions -contains $ver) { return [pscustomobject]@{ StatusCode = 503; Content = '' } }
    $k = "$id|$ver"
    if ($script:served.ContainsKey($k)) { return [pscustomobject]@{ StatusCode = 200; Content = $script:served[$k] } }
    [pscustomobject]@{ StatusCode = 404; Content = '' }
}
$script:versions = @{}
function Get-WingetVersions { param($AppId, $CurrentVersion) $null = $CurrentVersion; @($script:versions[$AppId]) }
$script:src = $null
function Get-Win32ToolkitProjectSource { param($ProjectPath, [switch]$Rebuild) $null = $ProjectPath, $Rebuild; $script:src }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32scp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function New-PlanProject([string]$Version, [string]$Type = 'wix', [string]$Arch = 'x64', [object[]]$Entries) {
    $p = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force
    $cfg = [ordered]@{ App = [ordered]@{ Version = $Version; Arch = $Arch }; Installer = [ordered]@{ Type = $(if ($Type -eq 'wix') { 'msi' } else { 'exe' }) } }
    if ($Entries) { $cfg['PriorInstalls'] = [ordered]@{ SchemaVersion = '1.0'; Entries = @($Entries) } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $p
}
function Use-App([string]$Id, [string]$Version, [string]$Type, [string]$Arch = 'x64') { $script:src = [pscustomobject]@{ WingetId = $Id; InstallerType = $Type; Architecture = $Arch; Family = '' } }
function Synth([string]$Id, [string]$Ver, [string]$Date, [string[]]$Types, [string]$Arch = 'x64') {
    $lines = @("PackageIdentifier: $Id", "PackageVersion: $Ver")
    if ($Date) { $lines += "ReleaseDate: $Date" }
    $lines += 'Installers:'
    foreach ($t in $Types) { $lines += "- Architecture: $Arch"; $lines += "  InstallerType: $t"; $lines += '  Scope: machine' }
    $lines -join "`n"
}
function Reset-Probe { $script:W32TSiblingProbeMemo = @{}; $script:served = @{}; $script:failVersions = @(); $script:gets.Clear() }
function TypeOf($Plan, [string]$Type) { @($Plan.Types | Where-Object Type -eq $Type) | Select-Object -First 1 }
function Caps($T) { (@($T.Captures) | ForEach-Object { "$($_.Version)/$($_.Role)" }) -join ',' }
$today = (Get-Date).Date
function D([int]$DaysAgo) { $today.AddDays(-$DaysAgo).ToString('yyyy-MM-dd') }

try {
    # == [1] classes ========================================================================================
    Write-Host '[1] classes' -ForegroundColor Cyan
    Reset-Probe
    $script:served['Notepad++.Notepad++|8.9.8.1'] = [IO.File]::ReadAllText((Join-Path $fx 'Notepad++.Notepad++\8.9.8.1.installer.yaml'))
    $script:served['Notepad++.Notepad++|8.9.8'] = [IO.File]::ReadAllText((Join-Path $fx 'Notepad++.Notepad++\8.9.8.installer.yaml'))
    $script:versions['Notepad++.Notepad++'] = @('8.9.8.1', '8.9.8')
    Use-App 'Notepad++.Notepad++' '8.9.8.1' 'wix'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '8.9.8.1' 'wix')
    $ns = TypeOf $plan 'nullsoft'; $zip = @($plan.Types | Where-Object { $_.Class -eq 'NotCapturable' })
    if ($ns.Class -eq 'RemovableNow' -and $zip.Count -eq 1 -and $zip[0].EffectiveType -eq 'portable' -and $zip[0].Reason -match 'registers no uninstall entry' -and -not (TypeOf $plan 'wix')) { Ok 'Notepad++ x64 packaged WiX: nullsoft RemovableNow, the zip/portable NotCapturable, the packaged WiX itself not planned' } else { Bad "npp classes: $($plan.Types | ConvertTo-Json -Depth 3 -Compress)" }
    if ((Caps $ns) -eq '8.9.8.1/Newest,8.9.8/Floor' -and $plan.Package.Version -eq '8.9.8.1' -and $plan.EstimatedRuns -eq 2) { Ok 'nullsoft: Newest 8.9.8.1 (a sibling of another family may be the package version), Floor 8.9.8 (both in the last 12 months), 2 runs' } else { Bad "npp versions: $(Caps $ns) runs $($plan.EstimatedRuns)" }

    Reset-Probe
    $script:served['TeamViewer.TeamViewer|15.82.6'] = [IO.File]::ReadAllText((Join-Path $fx 'TeamViewer.TeamViewer\15.82.6.installer.yaml'))
    $script:versions['TeamViewer.TeamViewer'] = @('15.82.6')
    Use-App 'TeamViewer.TeamViewer' '15.82.6' 'nullsoft'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '15.82.6' 'nullsoft')
    $nc = @($plan.Types | Where-Object Class -eq 'NotCapturable')
    if ($nc.Count -eq 1 -and $nc[0].EffectiveType -eq 'wix' -and $nc[0].Reason -match 'zip-wrapped installer.*extraction is not supported yet' -and $plan.EstimatedRuns -eq 0) { Ok 'TeamViewer (packaged nullsoft): the zip-wrapped WiX is NotCapturable (SV21 reason), nothing to run' } else { Bad "teamviewer: $($plan.Types | ConvertTo-Json -Depth 3 -Compress)" }

    Reset-Probe
    $script:served['dotPDN.PaintDotNet|5.1.12'] = [IO.File]::ReadAllText((Join-Path $fx 'dotPDN.PaintDotNet\5.1.12.installer.yaml'))
    $script:versions['dotPDN.PaintDotNet'] = @('5.1.12')
    Use-App 'dotPDN.PaintDotNet' '5.1.12' 'nullsoft'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '5.1.12' 'nullsoft')
    if (@($plan.Types | Where-Object { $_.Class -ne 'NotCapturable' }).Count -eq 0 -and @($plan.Types | Where-Object { $_.Reason -match 'zip-wrapped' }).Count -ge 1) { Ok 'Paint.NET (packaged nullsoft): its zip-wrapped installers are NotCapturable' } else { Bad "paint.net: $($plan.Types | ConvertTo-Json -Depth 3 -Compress)" }

    Reset-Probe
    $script:served['Acme.Both|2.0'] = Synth 'Acme.Both' '2.0' (D 10) @('msi', 'nullsoft', 'inno', 'burn')
    $script:served['Acme.Both|1.9'] = Synth 'Acme.Both' '1.9' (D 100) @('msi', 'nullsoft', 'inno', 'burn')
    $script:versions['Acme.Both'] = @('2.0', '1.9')
    Use-App 'Acme.Both' '2.0' 'msi'
    $proj = New-PlanProject '2.0' 'wix'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $proj
    if ((TypeOf $plan 'nullsoft').Class -eq 'RemovableNow' -and (TypeOf $plan 'inno').Class -eq 'RemovableNow' -and (TypeOf $plan 'burn').Class -eq 'ReportOnly' -and @((TypeOf $plan 'burn').Captures).Count -eq 0 -and $plan.EstimatedRuns -eq 4) { Ok 'NSIS and Inno Setup of one family are both planned; Burn is ReportOnly and not captured' } else { Bad "both: $($plan.Types | Select-Object Type, Class, @{n='c';e={Caps $_}} | ConvertTo-Json -Compress)" }
    # Live rows OP-OWN, SB-REGRESSION: the ReportOnly reason is operator text and named the internal plan id '(PR 7)'.
    if ((TypeOf $plan 'burn').Reason -ceq 'removing a burn sibling comes in a later win32-toolkit version' -and
        (Get-Win32ToolkitSiblingCaptureClass -Sibling ([pscustomobject]@{ EffectiveType = 'wix'; InstallerType = 'wix'; Registers = $true; ZipWrapped = $false; Architecture = 'x64' })).Reason -ceq 'removing an MSI sibling comes in a later win32-toolkit version') {
        Ok 'the ReportOnly reasons name no internal plan id (burn, wix)'
    } else { Bad "reason: $((TypeOf $plan 'burn').Reason)" }
    $planR = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $proj -IncludeReportOnly
    if (@((TypeOf $planR 'burn').Captures).Count -eq 2) { Ok '-IncludeReportOnly captures the ReportOnly types too' } else { Bad "report only: $(Caps (TypeOf $planR 'burn'))" }
    $planF = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $proj -SiblingInstallerType inno
    if (@($planF.Types).Count -eq 1 -and $planF.Types[0].Type -eq 'inno') { Ok '-SiblingInstallerType inno keeps only that type' } else { Bad "filter: $(@($planF.Types | ForEach-Object Type) -join ',')" }

    # == [2] versions =======================================================================================
    Write-Host '[2] versions' -ForegroundColor Cyan
    Reset-Probe
    $vs = @('3.0', '2.9', '2.8', '2.7', '2.6', '2.5', '2.4', '2.3')
    $ages = @{ '3.0' = 5; '2.9' = 40; '2.8' = 100; '2.7' = 200; '2.6' = 300; '2.5' = 400; '2.4' = 500; '2.3' = 600 }
    foreach ($v in $vs) { $script:served["Acme.Dated|$v"] = Synth 'Acme.Dated' $v (D $ages[$v]) @('msi', 'nullsoft') }
    $script:versions['Acme.Dated'] = @('3.1') + $vs
    Use-App 'Acme.Dated' '3.0' 'msi'
    $p2 = New-PlanProject '3.0' 'wix'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $p2
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '3.0/Newest,2.6/Floor' -and -not ($script:gets | Where-Object { $_ -match '/3\.1/' }) -and -not ($script:gets | Where-Object { $_ -match '/2\.3/' })) { Ok 'the floor is the oldest version released in the last 12 months (2.6); a version above the package is never probed; probing stops once past the window' } else { Bad "dated: $(Caps (TypeOf $plan 'nullsoft')) gets $(($script:gets | ForEach-Object { ($_ -split '/')[-2] }) -join ',')" }
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $p2 -VersionsBack 2
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '3.0/Newest,2.8/Floor') { Ok '-VersionsBack 2 -> the floor is the 2nd offering version before Newest' } else { Bad "back: $(Caps (TypeOf $plan 'nullsoft'))" }
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $p2 -SiblingVersion '2.7', '2.9', '2.5'
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '2.9/Newest,2.7/Extra,2.5/Floor') { Ok '-SiblingVersion: exactly those versions, newest first (Newest, Extra, Floor)' } else { Bad "explicit: $(Caps (TypeOf $plan 'nullsoft'))" }
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $p2 -SiblingVersion '2.7'
    $c27 = @((TypeOf $plan 'nullsoft').Captures)
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '2.7/Newest,2.7/Repeat' -and $c27[0].CaptureKey -eq 'nullsoft-2.7' -and $c27[1].CaptureKey -eq 'nullsoft-2.7-r') { Ok 'one -SiblingVersion -> captured twice (Newest + Repeat, keys nullsoft-2.7 / nullsoft-2.7-r)' } else { Bad "one: $(Caps (TypeOf $plan 'nullsoft')) $($c27 | ForEach-Object CaptureKey)" }

    Reset-Probe
    foreach ($v in $vs) { $script:served["Acme.Undated|$v"] = Synth 'Acme.Undated' $v $(if ($v -eq '2.8') { '' } else { D 10 }) @('msi', 'nullsoft') }
    $script:versions['Acme.Undated'] = $vs
    Use-App 'Acme.Undated' '3.0' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '3.0/Newest,2.5/Floor') { Ok 'a version without a release date -> the floor by count (the 5th offering version before Newest)' } else { Bad "undated: $(Caps (TypeOf $plan 'nullsoft'))" }

    Reset-Probe
    $script:served['Acme.Once|1.0'] = Synth 'Acme.Once' '1.0' (D 10) @('msi', 'inno')
    $script:served['Acme.Once|0.9'] = Synth 'Acme.Once' '0.9' (D 20) @('msi')
    $script:versions['Acme.Once'] = @('1.0', '0.9')
    Use-App 'Acme.Once' '1.0' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '1.0' 'wix')
    if ((Caps (TypeOf $plan 'inno')) -eq '1.0/Newest,1.0/Repeat') { Ok 'only one version offers the type -> Repeat' } else { Bad "repeat: $(Caps (TypeOf $plan 'inno'))" }

    Reset-Probe
    foreach ($v in @('3.0', '2.9', '2.8')) { $script:served["Acme.Flaky|$v"] = Synth 'Acme.Flaky' $v (D 30) @('msi', 'nullsoft') }
    $script:failVersions = @('2.9')
    $script:versions['Acme.Flaky'] = @('3.0', '2.9', '2.8')
    Use-App 'Acme.Flaky' '3.0' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '3.0/Newest,2.8/Floor' -and @($plan.ProbeFailures | Where-Object { $_ -match '2\.9' }).Count -eq 1) { Ok 'a failed GET skips that version and is listed' } else { Bad "flaky: $(Caps (TypeOf $plan 'nullsoft')) / $($plan.ProbeFailures -join ' | ')" }

    Reset-Probe
    foreach ($v in @('3.0', '2.9')) { $script:served["Acme.Same|$v"] = Synth 'Acme.Same' $v (D 30) @('nullsoft', 'inno') }
    $script:versions['Acme.Same'] = @('3.0', '2.9')
    Use-App 'Acme.Same' '3.0' 'nullsoft'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')
    if ((Caps (TypeOf $plan 'inno')) -eq '2.9/Newest,2.9/Repeat') { Ok "a type of the package's own family: strictly below the package version (Newest 2.9)" } else { Bad "same family: $(Caps (TypeOf $plan 'inno'))" }

    Reset-Probe
    foreach ($v in $vs) { $script:served["Acme.Dated|$v"] = Synth 'Acme.Dated' $v (D $ages[$v]) @('msi', 'nullsoft') }
    $script:versions['Acme.Dated'] = $vs
    Use-App 'Acme.Dated' '3.0' 'msi'
    $carried = [ordered]@{ Id = 'nsis-x64'; Mode = 'Block'; Key = 'Acme'; View = 'Native'; UninstallerType = 'nullsoft'; Source = 'SiblingCapture'; CaptureId = '0123456789abcdef' }
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix' -Entries @($carried))
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '3.0/Newest') { Ok 'a type with a carried captured rule -> Newest only (its floor record still counts, L36)' } else { Bad "carried: $(Caps (TypeOf $plan 'nullsoft'))" }

    # == [3] CaptureKey =====================================================================================
    Write-Host '[3] CaptureKey' -ForegroundColor Cyan
    Reset-Probe
    $script:served['Acme.Odd|2.0-Beta+1!rc'] = Synth 'Acme.Odd' '2.0-Beta+1!rc' (D 1) @('msi', 'nullsoft') 'x86'
    $script:served['Acme.Odd|2.0'] = Synth 'Acme.Odd' '2.0' (D 1) @('msi', 'nullsoft') 'x86'
    $script:versions['Acme.Odd'] = @('2.0-Beta+1!rc')
    Use-App 'Acme.Odd' '2.0' 'msi' 'x86'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '2.0' 'wix' 'x86') -SiblingVersion '2.0-Beta+1!rc'
    $keys = @((TypeOf $plan 'nullsoft').Captures | ForEach-Object CaptureKey)
    if (($keys -join ',') -ceq 'nullsoft-2.0-beta+1_rc-x86,nullsoft-2.0-beta+1_rc-x86-r') { Ok "lower-case, '_' for other characters, '-x86' for an x86 capture, '-r' for the Repeat" } else { Bad "keys: $($keys -join ',')" }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingCapturePlan tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingCapturePlan test(s) FAILED." -ForegroundColor Red; exit 1 }
