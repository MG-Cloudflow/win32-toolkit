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
          missing or not a real date (2025-02-30: from the manifest and from a stubbed probe, no throw); Repeat when only
          one version offers the type; -SiblingVersion (one -> plus a Repeat); -VersionsBack; a
          failed GET skips that version (listed); a type that already has captured rules -> Newest only (L36).
      [3] CaptureKey: '<type>-<version>[-x86][-r]', lower-case, outside [a-z0-9._+-] -> '_', at most 80.
      [4] X2: -Coverage (the newest version of each of the last n major.minor lines); -Architecture x86 (the x86 siblings
          of an x64 package); carried rules count per type and architecture of their floor record (without a readable
          record: by UninstallerType and View, Wow6432 = x86).
      [5] live rows RAISE, INNO: the package manifest answered HTTP 429 -> PackageProbe RateLimited with RetryAfterUtc, no
          type; the package probe asks a memoised failure again; a type whose every version failed to read, or whose
          versions could not be listed, is ProbeFailed (never "no version offers it"); a 429 stops all further probing.

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

foreach ($f in 'ConvertTo-Win32ToolkitSafeText', 'Get-Win32ToolkitInstallerFamily', 'Get-Win32ToolkitSiblingInstaller', 'Get-Win32ToolkitSiblingCapturePlan', 'Get-Win32ToolkitSiblingCaptureClass', 'Get-Win32ToolkitAppConfig', 'Get-Win32ToolkitDeployScriptBlock', 'Get-Win32ToolkitDeployExtension', 'ConvertTo-Win32ToolkitPriorVersion',
    'Get-Win32ToolkitSiblingCaptureRecord', 'ConvertTo-Win32ToolkitSiblingCaptureRecord') {
    . (Join-Path $repo "Private\$f.ps1")
}
. (Join-Path $repo 'Tests\Fixtures\sibling-proposal\SiblingFixture.ps1')
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
    if ($script:timeoutVersions -contains $ver) { throw [System.Threading.Tasks.TaskCanceledException]::new('The request was canceled due to the configured HttpClient.Timeout of 10 seconds elapsing.') }
    if ($script:limitVersions -contains $ver) { return [pscustomobject]@{ StatusCode = 429; Content = ''; Headers = @{ 'Retry-After' = @('120') } } }
    $k = "$id|$ver"
    if ($script:served.ContainsKey($k)) { return [pscustomobject]@{ StatusCode = 200; Content = $script:served[$k] } }
    [pscustomobject]@{ StatusCode = 404; Content = '' }
}
$script:limitVersions = @()   # versions answered HTTP 429 (Retry-After 120)
$script:timeoutVersions = @() # versions whose GET times out
$script:versions = @{}
$script:versionsThrow = $false
function Get-WingetVersions { param($AppId, $CurrentVersion) $null = $CurrentVersion; if ($script:versionsThrow) { throw 'winget show --versions failed' }; @($script:versions[$AppId]) }
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
function Reset-Probe { $script:W32TSiblingProbeMemo = @{}; $script:W32TSiblingProbeRateLimitUntil = $null; $script:served = @{}; $script:failVersions = @(); $script:limitVersions = @(); $script:timeoutVersions = @(); $script:versionsThrow = $false; $script:gets.Clear() }
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

    # An impossible date that still matches yyyy-MM-dd (untrusted manifest data: 2025-02-30, 2025-13-01) is no date: the
    # plan does not throw (a raw FormatException skipped the whole capture), and the count rule applies for that type.
    Reset-Probe
    foreach ($v in $vs) { $script:served["Acme.BadDate|$v"] = Synth 'Acme.BadDate' $v $(if ($v -eq '2.8') { '2025-02-30' } else { D 10 }) @('msi', 'nullsoft') }
    $script:versions['Acme.BadDate'] = $vs
    Use-App 'Acme.BadDate' '3.0' 'msi'
    $planBad = $null; $planErr = ''
    try { $planBad = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix') } catch { $planErr = "$($_.FullyQualifiedErrorId): $($_.Exception.Message)" }
    $bad28 = if ($planBad) { @((TypeOf $planBad 'nullsoft').Offering | Where-Object Version -eq '2.8') } else { @() }
    if (-not $planErr -and (Caps (TypeOf $planBad 'nullsoft')) -eq '3.0/Newest,2.5/Floor' -and $bad28.Count -eq 1 -and $bad28[0].ReleaseDate -ceq '') {
        Ok "a manifest ReleaseDate 2025-02-30 (matches yyyy-MM-dd, no such day) -> no throw, read as no date: the count rule (floor 2.5), Offering 2.8 ReleaseDate ''"
    } else { Bad "impossible date: error '$planErr' caps $(if ($planBad) { Caps (TypeOf $planBad 'nullsoft') }) 2.8 $($bad28 | ConvertTo-Json -Compress)" }

    # The plan's own guard (not only the probe's): a stubbed probe hands it impossible dates for version 2.8 -
    # tuple '2025-13-01' and root '2025-02-30' -> no date (the count rule); tuple '2025-13-01' and a real root date ->
    # the root's date (every version dated and in the window -> the floor is the oldest, 2.3).
    $realProbe = ${function:Get-Win32ToolkitSiblingInstaller}
    $script:stubDates = @{}
    ${function:Get-Win32ToolkitSiblingInstaller} = {
        [CmdletBinding()]
        param([string]$WingetId, [string]$Version, [string]$Architecture, [string]$PackagedType, [switch]$RetryFailed)
        $null = $WingetId, $Architecture, $PackagedType, $RetryFailed
        $r = & $realProbe @PSBoundParameters
        if ($script:stubDates.ContainsKey($Version)) {
            $d = $script:stubDates[$Version]
            $r.ReleaseDate = $d.Root
            $r.Tuples = @(@($r.Tuples) | ForEach-Object { $c = $_.PSObject.Copy(); $c.ReleaseDate = $d.Tuple; $c })
        }
        $r
    }
    try {
        foreach ($case in @(
                @{ Label = "tuple '2025-13-01', root '2025-02-30'"; Root = '2025-02-30'; Exp = '3.0/Newest,2.5/Floor'; Exp28 = '' },
                @{ Label = "tuple '2025-13-01', root $(D 10)"; Root = (D 10); Exp = '3.0/Newest,2.3/Floor'; Exp28 = (D 10) })) {
            Reset-Probe
            foreach ($v in $vs) { $script:served["Acme.StubDate|$v"] = Synth 'Acme.StubDate' $v (D 10) @('msi', 'nullsoft') }
            $script:versions['Acme.StubDate'] = $vs
            $script:stubDates = @{ '2.8' = @{ Root = $case.Root; Tuple = '2025-13-01' } }
            Use-App 'Acme.StubDate' '3.0' 'msi'
            $planStub = $null; $stubErr = ''
            try { $planStub = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix') } catch { $stubErr = "$($_.FullyQualifiedErrorId): $($_.Exception.Message)" }
            $s28 = if ($planStub) { @((TypeOf $planStub 'nullsoft').Offering | Where-Object Version -eq '2.8') } else { @() }
            if (-not $stubErr -and (Caps (TypeOf $planStub 'nullsoft')) -eq $case.Exp -and $s28.Count -eq 1 -and $s28[0].ReleaseDate -ceq $case.Exp28) {
                Ok "stubbed probe, 2.8 $($case.Label) -> no throw, $($case.Exp), Offering 2.8 ReleaseDate '$($case.Exp28)'"
            } else { Bad "stubbed probe, 2.8 $($case.Label): error '$stubErr' caps $(if ($planStub) { Caps (TypeOf $planStub 'nullsoft') }) 2.8 $($s28 | ConvertTo-Json -Compress)" }
        }
    }
    finally { ${function:Get-Win32ToolkitSiblingInstaller} = $realProbe; $script:stubDates = @{} }

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

    # == [4] coverage and x86 (installer-identity PR 3b, X2) ================================================
    Write-Host '[4] -Coverage and -Architecture x86 (X2)' -ForegroundColor Cyan
    Reset-Probe
    $cv = @('3.1.2', '3.1.1', '3.0.5', '3.0.4', '2.9.9', '2.8')
    foreach ($v in $cv) { $script:served["Acme.Lines|$v"] = Synth 'Acme.Lines' $v (D 20) @('msi', 'nullsoft') }
    $script:versions['Acme.Lines'] = $cv
    Use-App 'Acme.Lines' '3.1.2' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.1.2' 'wix') -Coverage 3
    $ty = TypeOf $plan 'nullsoft'
    if ((Caps $ty) -eq '3.1.2/Newest,3.0.5/Coverage,2.9.9/Coverage' -and (@($ty.Offering | ForEach-Object Version) -join ',') -eq '3.1.2,3.1.1,3.0.5,3.0.4,2.9.9,2.8') {
        Ok '-Coverage 3: Newest and the newest version of each of the last 3 major.minor lines (3.0.5, 2.9.9); the probing stops once a 4th line shows (2.8, not captured); Offering lists what was probed'
    } else { Bad "coverage: $(Caps $ty) offering $(@($ty.Offering | ForEach-Object Version) -join ',')" }
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.1.2' 'wix') -Coverage 1
    if ((Caps (TypeOf $plan 'nullsoft')) -eq '3.1.2/Newest,3.1.2/Repeat') { Ok '-Coverage 1: the newest line only -> Newest + Repeat (two captures of one identity)' } else { Bad "coverage 1: $(Caps (TypeOf $plan 'nullsoft'))" }
    Reset-Probe
    $mixed = { param([string]$V) "PackageIdentifier: Acme.Arch`nPackageVersion: $V`nReleaseDate: $(D 10)`nInstallers:`n- Architecture: x64`n  InstallerType: msi`n  Scope: machine`n- Architecture: x86`n  InstallerType: msi`n  Scope: machine`n- Architecture: x86`n  InstallerType: nullsoft`n  Scope: machine`n" }
    foreach ($v in '5.0', '4.9') { $script:served["Acme.Arch|$v"] = & $mixed $v }
    $script:versions['Acme.Arch'] = @('5.0', '4.9')
    Use-App 'Acme.Arch' '5.0' 'msi' 'x64'
    $plan64 = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '5.0' 'wix')
    $plan86 = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '5.0' 'wix') -Architecture x86
    $keys = @((TypeOf $plan86 'nullsoft').Captures | ForEach-Object CaptureKey)
    if (-not (TypeOf $plan64 'nullsoft') -and $plan86.Package.Architecture -eq 'x64' -and $plan86.Architecture -eq 'x86' -and ($keys -join ',') -ceq 'nullsoft-5.0-x86,nullsoft-4.9-x86') {
        Ok '-Architecture x86: the x86 NSIS sibling of an x64 MSI package is planned (keys -x86); the package stays x64; without it, nothing for x64'
    } else { Bad "x86: 64=$((TypeOf $plan64 'nullsoft') | ConvertTo-Json -Compress) 86=$($plan86.Architecture) keys $($keys -join ',')" }

    # Carried rules count per type AND architecture, from their floor record (L36): the project's rules came from x64
    # captures (an NSIS one, and an 'exe' one whose uninstaller turned out to be NSIS, so its rule says nullsoft). The x64
    # plan captures both types at Newest only; an x86 plan still gets its floor (the x64 floors are not x86 captures).
    Reset-Probe
    $carry = { param([string]$V) "PackageIdentifier: Acme.Carry`nPackageVersion: $V`nReleaseDate: $(D 10)`nInstallers:`n- Architecture: x64`n  InstallerType: msi`n  Scope: machine`n- Architecture: x64`n  InstallerType: nullsoft`n  Scope: machine`n- Architecture: x86`n  InstallerType: nullsoft`n  Scope: machine`n- Architecture: x64`n  InstallerType: exe`n  Scope: machine`n" }
    foreach ($v in '5.0', '4.9') { $script:served["Acme.Carry|$v"] = & $carry $v }
    $script:versions['Acme.Carry'] = @('5.0', '4.9')
    Use-App 'Acme.Carry' '5.0' 'msi' 'x64'
    $pcar = New-PlanProject '5.0' 'wix'
    $fNsis = Write-TestSiblingRecord -ProjectPath $pcar -Record (New-TestSiblingRecord -Type 'nullsoft' -Version '4.9' -Role 'Floor')
    $fExe = Write-TestSiblingRecord -ProjectPath $pcar -Record (New-TestSiblingRecord -Type 'exe' -Version '4.9' -Role 'Floor' -Key 'AcmeExe')
    $cfgCar = Get-Content -LiteralPath (Join-Path $pcar 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json
    $cfgCar | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([ordered]@{ SchemaVersion = '1.0'; Entries = @(
                [ordered]@{ Id = 'nsis-x64'; Mode = 'Block'; Key = 'Notepad++'; View = 'Native'; UninstallerType = 'nullsoft'; Source = 'SiblingCapture'; CaptureId = $fNsis }
                [ordered]@{ Id = 'exe-x64'; Mode = 'Block'; Key = 'AcmeExe'; View = 'Native'; UninstallerType = 'nullsoft'; Source = 'SiblingCapture'; CaptureId = $fExe }) })
    [IO.File]::WriteAllText((Join-Path $pcar 'SupportFiles\AppConfig.json'), ($cfgCar | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $c64 = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $pcar
    $c86 = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $pcar -Architecture x86
    if ((Caps (TypeOf $c64 'nullsoft')) -eq '5.0/Newest' -and (Caps (TypeOf $c64 'exe')) -eq '5.0/Newest' -and (Caps (TypeOf $c86 'nullsoft')) -eq '5.0/Newest,4.9/Floor') {
        Ok 'carried rules count by their floor record: x64 nullsoft and exe (its rule says nullsoft) -> Newest only; an x86 plan of the same project -> Newest and Floor'
    } else { Bad "carried per arch: x64 nullsoft $(Caps (TypeOf $c64 'nullsoft')) exe $(Caps (TypeOf $c64 'exe')); x86 nullsoft $(Caps (TypeOf $c86 'nullsoft'))" }
    # A carried rule whose floor record cannot be read counts by its UninstallerType and View: Wow6432 is the registry view
    # an x86 installer writes on the 64-bit VM, so it counts for x86 (Newest only there) and the x64 plan keeps its floor.
    $pw = New-PlanProject '5.0' 'wix' -Entries @([ordered]@{ Id = 'nsis-x86'; Mode = 'Block'; Key = 'Acme'; View = 'Wow6432'; UninstallerType = 'nullsoft'; Source = 'SiblingCapture'; CaptureId = 'fedcba9876543210' })
    $w64 = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $pw
    $w86 = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $pw -Architecture x86
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pw).Count -eq 0 -and (Caps (TypeOf $w86 'nullsoft')) -eq '5.0/Newest' -and (Caps (TypeOf $w64 'nullsoft')) -eq '5.0/Newest,4.9/Floor') {
        Ok 'a carried Wow6432 rule without a readable floor record counts for x86: the x86 plan -> Newest only; the x64 plan -> Newest and Floor'
    } else { Bad "carried Wow6432 fallback: x86 nullsoft $(Caps (TypeOf $w86 'nullsoft')); x64 nullsoft $(Caps (TypeOf $w64 'nullsoft'))" }

    # == [5] manifests that could not be read (live rows RAISE, INNO) =====================================
    Write-Host '[5] manifests that could not be read: PackageProbe, ProbeFailed, HTTP 429' -ForegroundColor Cyan
    # The package version's manifest answered 429: PackageProbe says so, with when to ask again; no type is planned.
    Reset-Probe
    $script:served['Acme.Limited|3.0'] = Synth 'Acme.Limited' '3.0' (D 10) @('msi', 'nullsoft')
    $script:limitVersions = @('3.0'); $script:versions['Acme.Limited'] = @('3.0', '2.9')
    Use-App 'Acme.Limited' '3.0' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')
    $wait = if ($plan.RetryAfterUtc) { ([datetimeoffset]::Parse($plan.RetryAfterUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime - [datetime]::UtcNow).TotalSeconds } else { -1 }
    if ($plan.PackageProbe.Status -eq 'Unavailable' -and $plan.PackageProbe.Reason -eq 'RateLimited' -and $plan.PackageProbe.Cause -ceq 'Transient' -and $plan.PackageProbe.RetryAfterUtc -ceq $plan.RetryAfterUtc -and $wait -gt 100 -and $wait -le 121 -and
        @($plan.Types).Count -eq 0 -and $plan.EstimatedRuns -eq 0 -and ($plan.ProbeFailures -join '|') -match "the package version's winget manifest could not be read \(RateLimited\)" -and $script:gets.Count -eq 1) {
        Ok 'the package manifest answered 429 -> PackageProbe Unavailable/RateLimited, Cause Transient, with RetryAfterUtc (also the plan''s), no type planned, one request'
    } else { Bad "package 429: $($plan.PackageProbe | ConvertTo-Json -Compress) retry '$($plan.RetryAfterUtc)' ($wait s) types $(@($plan.Types).Count) gets $($script:gets.Count)" }
    # The package version is no longer in winget-pkgs (404): Cause Permanent (capturing again cannot help); the plan records
    # what was asked (Request), also on this early return.
    Reset-Probe
    $script:versions['Acme.Removed'] = @('3.0')
    Use-App 'Acme.Removed' '3.0' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix') -SiblingInstallerType nullsoft -SiblingVersion '2.7', '2.9' -IncludeReportOnly -Coverage 2
    $rq = $plan.Request
    if ($plan.PackageProbe.Reason -eq 'NotFound' -and $plan.PackageProbe.Cause -ceq 'Permanent' -and $plan.RetryAfterUtc -ceq '' -and @($plan.Types).Count -eq 0 -and
        ($rq.SiblingInstallerType -join ',') -ceq 'nullsoft' -and ($rq.SiblingVersion -join ',') -ceq '2.7,2.9' -and $rq.IncludeReportOnly -eq $true -and $rq.Coverage -eq 2 -and $rq.VersionsBack -eq 0) {
        Ok 'the package manifest is gone (404) -> PackageProbe Cause Permanent; Request records -SiblingInstallerType, -SiblingVersion, -IncludeReportOnly, -Coverage'
    } else { Bad "package 404: $($plan.PackageProbe | ConvertTo-Json -Compress) request $($rq | ConvertTo-Json -Compress)" }
    $rq0 = (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')).Request
    $rqB = (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix') -VersionsBack 3).Request
    if ($rq0.SiblingInstallerType.Count -eq 0 -and $rq0.SiblingVersion.Count -eq 0 -and $rq0.IncludeReportOnly -eq $false -and $rq0.VersionsBack -eq 0 -and $rqB.VersionsBack -eq 3) { Ok 'nothing asked -> Request with empty lists (not one $null entry); -VersionsBack 3 -> Request.VersionsBack 3' } else { Bad "empty request: $($rq0 | ConvertTo-Json -Compress) / back $($rqB.VersionsBack)" }
    # An explicit plan asks a failure of earlier in the process again (-RetryFailed): a Network failure 1 minute ago is
    # not reused.
    Reset-Probe
    $script:served['Acme.Again|3.0'] = Synth 'Acme.Again' '3.0' (D 10) @('msi', 'nullsoft')
    $script:versions['Acme.Again'] = @('3.0')
    $script:failVersions = @('3.0')
    $first = Get-Win32ToolkitSiblingInstaller -WingetId 'Acme.Again' -Version '3.0' -Architecture x64 -PackagedType msi
    $script:failVersions = @()
    Use-App 'Acme.Again' '3.0' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')
    if ($first.Reason -eq 'Network' -and $plan.PackageProbe.Status -eq 'Ok' -and $plan.RetryAfterUtc -ceq '' -and @((TypeOf $plan 'nullsoft').Captures).Count -gt 0 -and @($script:gets | Where-Object { $_ -match '/3\.0/' }).Count -eq 2) {
        Ok "the plan's package probe asks a memoised Network failure again (-RetryFailed): planned"
    } else { Bad "retry failed: first $($first.Reason) package $($plan.PackageProbe.Status) gets $($script:gets.Count)" }
    # Every version of a type failed to read: ProbeFailed with the count and reason, never "no version offers it".
    Reset-Probe
    $script:served['Acme.Down|3.0'] = Synth 'Acme.Down' '3.0' (D 10) @('nullsoft', 'inno')
    $script:versions['Acme.Down'] = @('3.0', '2.9', '2.8')
    $script:failVersions = @('2.9', '2.8')
    Use-App 'Acme.Down' '3.0' 'nullsoft'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')
    $inno = TypeOf $plan 'inno'
    if ($inno.ProbeFailed -eq $true -and $inno.ProbeCause -ceq 'Transient' -and $inno.Reason -ceq 'its versions could not be checked: 2 winget manifest(s) could not be read (Network)' -and @($inno.Captures).Count -eq 0 -and $plan.EstimatedRuns -eq 0 -and $plan.PackageProbe.Status -eq 'Ok' -and $plan.PackageProbe.Cause -ceq '') {
        Ok 'every version probe of a type failed -> ProbeFailed (Transient), "its versions could not be checked: 2 winget manifest(s) could not be read (Network)"'
    } else { Bad "probe failed: $($inno | ConvertTo-Json -Depth 3 -Compress)" }
    # An explicit plan asks a memoised version failure again, once per plan (not once per type): the next plan, after
    # GitHub answers again, reads the version that failed a minute ago.
    $before29 = @($script:gets | Where-Object { $_ -match '/2\.9/' }).Count
    $script:failVersions = @()
    $script:served['Acme.Down|2.9'] = Synth 'Acme.Down' '2.9' (D 20) @('nullsoft', 'inno')
    $plan2 = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')
    $after29 = @($script:gets | Where-Object { $_ -match '/2\.9/' }).Count
    if ($before29 -eq 1 -and $after29 -eq 2 -and -not (TypeOf $plan2 'inno').ProbeFailed -and (Caps (TypeOf $plan2 'inno')) -match '^2\.9/Newest') {
        Ok 'a version that failed is asked again by the next plan (one GET per plan, not per type): inno planned at 2.9'
    } else { Bad "re-ask: 2.9 GETs $before29 then $after29; inno $(Caps (TypeOf $plan2 'inno')) failed=$((TypeOf $plan2 'inno').ProbeFailed)" }
    # One plan, two types, a version that keeps failing: one GET of it in that plan.
    Reset-Probe
    $script:served['Acme.Twice|3.0'] = Synth 'Acme.Twice' '3.0' (D 10) @('msi', 'nullsoft', 'inno')
    $script:versions['Acme.Twice'] = @('3.0', '2.9')
    $script:failVersions = @('2.9')
    Use-App 'Acme.Twice' '3.0' 'msi'
    $null = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')
    if (@($script:gets | Where-Object { $_ -match '/2\.9/' }).Count -eq 1) { Ok 'two types, 2.9 failing: one GET of 2.9 in one plan (the second type reuses the memo)' } else { Bad "twice: 2.9 GETs $(@($script:gets | Where-Object { $_ -match '/2\.9/' }).Count)" }
    # A version of the default walk winget-pkgs has no manifest for (404) does not offer the type (winget could not install
    # it either): not ProbeFailed. Named with -SiblingVersion it is a failed check that will not pass later (Permanent);
    # so is a manifest that cannot be used (Parse).
    Reset-Probe
    $script:served['Acme.Gone|3.0'] = Synth 'Acme.Gone' '3.0' (D 10) @('nullsoft', 'inno')
    $script:served['Acme.Gone|2.7'] = "PackageIdentifier: Acme.Gone`nPackageVersion: 2.7`n"
    $script:versions['Acme.Gone'] = @('3.0', '2.9')
    Use-App 'Acme.Gone' '3.0' 'nullsoft'
    $gWalk = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')) 'inno'
    $gNamed = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft') -SiblingVersion '2.10') 'inno'
    $gParse = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft') -SiblingVersion '2.7') 'inno'
    if (-not $gWalk.ProbeFailed -and $gWalk.Reason -match 'no version at or below' -and
        $gNamed.ProbeFailed -and $gNamed.ProbeCause -ceq 'Permanent' -and $gNamed.Reason -match '1 winget manifest\(s\) could not be read \(NotFound\)' -and
        $gParse.ProbeFailed -and $gParse.ProbeCause -ceq 'Permanent' -and $gParse.Reason -match '\(Parse\)') {
        Ok 'a 404 in the default walk -> not offered (not ProbeFailed); -SiblingVersion 2.10 (404) and a manifest without installers (Parse) -> ProbeFailed, Permanent'
    } else { Bad "gone: walk $($gWalk.ProbeFailed) '$($gWalk.Reason)'; named $($gNamed.ProbeFailed)/$($gNamed.ProbeCause) '$($gNamed.Reason)'; parse $($gParse.ProbeFailed)/$($gParse.ProbeCause) '$($gParse.Reason)'" }
    # Mixed failures in one walk (second review): 2.9 cannot be used (Parse), 2.8 answers 429 and stops the walk before
    # 2.7 (which offers inno) is asked. Capturing again can help, so the cause is Transient (both reasons kept); after
    # GitHub lets this computer ask again, the next plan reads 2.7.
    Reset-Probe
    $script:served['Acme.Mixed|3.0'] = Synth 'Acme.Mixed' '3.0' (D 10) @('nullsoft', 'inno')
    $script:served['Acme.Mixed|2.9'] = "PackageIdentifier: Acme.Mixed`nPackageVersion: 2.9`n"
    $script:served['Acme.Mixed|2.7'] = Synth 'Acme.Mixed' '2.7' (D 40) @('nullsoft', 'inno')
    $script:versions['Acme.Mixed'] = @('3.0', '2.9', '2.8', '2.7')
    $script:limitVersions = @('2.8')
    Use-App 'Acme.Mixed' '3.0' 'nullsoft'
    $mx = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')) 'inno'
    $script:limitVersions = @(); $script:W32TSiblingProbeRateLimitUntil = $null
    $mx2 = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')) 'inno'
    if ($mx.ProbeFailed -and $mx.ProbeCause -ceq 'Transient' -and $mx.Reason -match '2 winget manifest\(s\) could not be read \(Parse, RateLimited\)' -and -not $mx2.ProbeFailed -and (Caps $mx2) -eq '2.7/Newest,2.7/Repeat') {
        Ok 'Parse + 429 in one walk -> ProbeFailed Transient (capturing again helps; both reasons named); the next plan reads 2.7 and plans it'
    } else { Bad "mixed: $($mx.ProbeFailed)/$($mx.ProbeCause) '$($mx.Reason)'; next $(Caps $mx2)" }
    # A timed-out manifest is transient too.
    Reset-Probe
    $script:served['Acme.Slow|3.0'] = Synth 'Acme.Slow' '3.0' (D 10) @('nullsoft', 'inno')
    $script:versions['Acme.Slow'] = @('3.0', '2.9')
    $script:timeoutVersions = @('2.9')
    Use-App 'Acme.Slow' '3.0' 'nullsoft'
    $sl = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')) 'inno'
    if ($sl.ProbeFailed -and $sl.ProbeCause -ceq 'Transient' -and $sl.Reason -match '\(Timeout\)') { Ok 'a timed-out version manifest -> ProbeFailed Transient (Timeout)' } else { Bad "timeout: $($sl.ProbeFailed)/$($sl.ProbeCause) '$($sl.Reason)'" }
    # A type that no version offers (every probe read) stays "no version offers it", not ProbeFailed.
    Reset-Probe
    $script:served['Acme.None|3.0'] = Synth 'Acme.None' '3.0' (D 10) @('nullsoft', 'inno')
    $script:served['Acme.None|2.9'] = Synth 'Acme.None' '2.9' (D 20) @('nullsoft')
    $script:versions['Acme.None'] = @('3.0', '2.9')
    Use-App 'Acme.None' '3.0' 'nullsoft'
    $none = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'nullsoft')) 'inno'
    if ($none.ProbeFailed -eq $false -and $none.Reason -match 'no version at or below the package version offers it') { Ok 'every probe read and none offers the type -> not ProbeFailed ("no version ... offers it")' } else { Bad "none: $($none | ConvertTo-Json -Depth 3 -Compress)" }
    # A 429 on a version: no further version is asked, for this type or the next (the gate would answer them all);
    # a type left with no offering version is ProbeFailed; the plan says when to ask again.
    Reset-Probe
    foreach ($v in '3.0', '2.9', '2.8') { $script:served["Acme.Rate|$v"] = Synth 'Acme.Rate' $v (D 10) @('msi', 'nullsoft', 'inno') }
    $script:versions['Acme.Rate'] = @('3.0', '2.9', '2.8')
    $script:limitVersions = @('2.9')
    Use-App 'Acme.Rate' '3.0' 'msi'
    $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')
    # The first type planned reads 3.0 (memo) and hits the 429 on 2.9; the second is not asked at all.
    $firstT = @($plan.Types | Where-Object { $_.Class -eq 'RemovableNow' })[0]; $secondT = @($plan.Types | Where-Object { $_.Class -eq 'RemovableNow' })[1]
    $asked = @($script:gets | ForEach-Object { ($_ -split '/')[-2] }) -join ','
    if ($asked -eq '3.0,2.9' -and -not $firstT.ProbeFailed -and (Caps $firstT) -eq '3.0/Newest,3.0/Repeat' -and $secondT.ProbeFailed -and $secondT.ProbeCause -ceq 'Transient' -and $secondT.Reason -ceq 'its versions were not checked: GitHub limits requests from this computer (RateLimited)' -and
        $plan.RetryAfterUtc -and ($plan.ProbeFailures -join '|') -ceq "$($firstT.Type) 2.9: the manifest could not be read (RateLimited); no further version was checked|$($secondT.Type): its versions were not checked (RateLimited)") {
        Ok "a 429 on 2.9 -> no further request (2.8, the other type); $($firstT.Type) keeps what it read; $($secondT.Type) ProbeFailed 'were not checked (RateLimited)'; RetryAfterUtc set"
    } else { Bad "rate: asked $asked first $($firstT.Type) $(Caps $firstT)/$($firstT.ProbeFailed) second $($secondT.Type) $($secondT.ProbeFailed) '$($secondT.Reason)' retry '$($plan.RetryAfterUtc)' failures $($plan.ProbeFailures -join ' | ')" }
    # The winget version list could not be read: the types are ProbeFailed (no version was there to check) - but an
    # explicit -SiblingVersion that was read and does not offer the type stays "no version offers it".
    Reset-Probe
    $script:served['Acme.NoList|3.0'] = Synth 'Acme.NoList' '3.0' (D 10) @('msi', 'nullsoft')
    $script:served['Acme.NoList|2.9'] = Synth 'Acme.NoList' '2.9' (D 20) @('msi')
    $script:versionsThrow = $true
    Use-App 'Acme.NoList' '3.0' 'msi'
    $nl = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix')) 'nullsoft'
    $nlv = TypeOf (Get-Win32ToolkitSiblingCapturePlan -ProjectPath (New-PlanProject '3.0' 'wix') -SiblingVersion '2.9') 'nullsoft'
    if ($nl.ProbeFailed -and $nl.ProbeCause -ceq 'WingetList' -and $nl.Reason -ceq 'its versions could not be checked: the winget versions could not be listed' -and -not $nlv.ProbeFailed -and $nlv.Reason -match 'no version at or below') {
        Ok 'the winget version list failed -> ProbeFailed (WingetList, "the winget versions could not be listed"); with -SiblingVersion read and not offering -> not ProbeFailed'
    } else { Bad "no list: $($nl | ConvertTo-Json -Depth 3 -Compress) / $($nlv | ConvertTo-Json -Depth 3 -Compress)" }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingCapturePlan tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingCapturePlan test(s) FAILED." -ForegroundColor Red; exit 1 }
