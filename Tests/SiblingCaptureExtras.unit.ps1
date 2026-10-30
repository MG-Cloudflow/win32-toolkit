<#
    Installer-identity PR 3b, the 3b-2 extras (spec 2.14.2, 2.14.5, 2.14.8, 2.15.5, 2.16; SV14, SV28, D61, D62, L30, L36): the
    rules that came from earlier captures. The VM is shadowed (the capture shadow writes records in the frozen shape,
    Tests\Fixtures\sibling-proposal); the raise, the proposals and the rules are real.

      [1] X1: after a capture that recorded a newer version of a captured rule's identity, Test-Win32ToolkitProject
          -Scenario SiblingCapture raises the rule's VersionMax (VersionMin, the mode, the approval and every other
          AppConfig section unchanged); a capture that recorded nothing raises nothing; a proposal that is not a rule
          yet is named with the command that applies it.
      [2] X2: the backend - the Hyper-V test VM when it is ready (whatever TestBackend says), else Windows Sandbox with the
          Block-only note (SV28); -Backend Sandbox; assisted captures need a ready VM and a console that can prompt (D62).
          The command-line scenario without a ready VM refuses a project whose captures already allow an Enforce rule
          (W32T.SiblingCaptureUnsupported, no -Backend or -Backend HyperV; spec Dv14); -Backend Sandbox or a type that
          costs nothing is captured in Windows Sandbox.
      [3] X2: Windows Sandbox - the .wsb maps in\ read-only and quarantine\ read-write (never the project), the LogonCommand
          is the -Command "& { ... }" form, files outside the allow-list are deleted, every record and proposal is Block-only;
          a sandbox that cannot be confirmed closed -> W32T.GuestTamper (L18); one that never starts -> CaptureFailed
          after 5 minutes.
      [4] X2: an assisted capture - the file to start in the VM window is named, the install phase is an interactive
          pause, the records say Assisted, Block-only.
      [5] X2: bisection - a drift between two captures gets Extra captures at the middle offering version, at most
          -MaxExtra, until the change is located; only the drift of the architecture the run captures, and only that
          architecture's records count as captured versions.
      [6] X2: x86 siblings of an x64 package - the x86 installer, Sibling.Architecture x86, View Wow6432 (nsis-x86).

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
$realPreflight = ${function:Test-Win32ToolkitSiblingCapturePreflight}
$realCapture = ${function:Invoke-Win32ToolkitSiblingCapture}
function Get-AuthenticodeSignature { [CmdletBinding()] param([string]$LiteralPath) $null = $LiteralPath; [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:TestSiblingSigner } } }
function Get-Win32ToolkitConfigValue { param($Name, $Default) $null = $Name; $Default }
function Test-Win32ToolkitSiblingCapturePreflight { param($ProjectPath, $Backend) $null = $ProjectPath, $Backend; [pscustomobject]@{ Ok = $true; Code = ''; Reasons = [string[]]@(); Backend = 'HyperV' } }
function Get-Win32ToolkitSiblingCapturePlan { param($ProjectPath, $SiblingInstallerType, $SiblingVersion, $VersionsBack, [switch]$IncludeReportOnly) $null = $ProjectPath, $SiblingInstallerType, $SiblingVersion, $VersionsBack, $IncludeReportOnly; [pscustomobject]@{ Backend = ''; Types = @() } }
$script:captureWrites = @(); $script:captureResult = $true
$script:captureBackends = [System.Collections.Generic.List[string]]::new()
function Invoke-Win32ToolkitSiblingCapture {
    param($ProjectPath, $Plan, $Backend)
    $null = $Plan
    $script:captureBackends.Add([string]$Backend)
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
        $null = Set-PSADTDataDrivenScript -ScriptPath $tmp -InstallerType msi -WarningAction SilentlyContinue
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
    # What to approve next: a proposal that is not a rule yet is named with the command that applies it (as the pipeline
    # prints it); an applied one is not.
    $pu = New-XProject 'unapplied'
    $script:captureWrites = @(@{ Version = '8.7.9'; Role = 'Floor' }, @{ Version = '8.9.8' }); $script:captureResult = $true
    $out = @(Test-Win32ToolkitProject -ProjectPath $pu -Scenario SiblingCapture -Backend HyperV 3>$null 6>&1 | ForEach-Object { "$_" })
    $line = @($out | Where-Object { $_ -match "^Sibling capture: the sibling-capture proposal 'nsis-x64' .* is not a rule" -and $_ -match '-FromSiblingCapture -Mode Block -ProposalId nsis-x64$' })
    $outApplied = @(Test-Win32ToolkitProject -ProjectPath $p -Scenario SiblingCapture -Backend HyperV 3>$null 6>&1 | ForEach-Object { "$_" })
    if ($line.Count -eq 1 -and @($outApplied | Where-Object { $_ -match 'is not a rule' }).Count -eq 0 -and @($out | Where-Object { $_ -match "^Every proposal, with its window and flags: Set-Win32ToolkitPriorInstall -ProjectPath '" }).Count -eq 1) {
        Ok 'after the capture: the proposal that is not a rule yet is named with its exact command (-Mode Block -ProposalId nsis-x64); an applied one is not'
    } else { Bad "unapplied: $($out -join ' | ')" }

    # == [2] the pre-flight backend (SV28) and assisted captures (D62) =====================================
    Write-Host '[2] X2: the backend of a capture; assisted captures' -ForegroundColor Cyan
    ${function:Test-Win32ToolkitSiblingCapturePreflight} = $realPreflight
    $script:hvNotReady = @(); $script:nonInteractive = $false
    function Test-Win32ToolkitHyperVReady { @($script:hvNotReady) }
    function Test-Win32ToolkitHostNonInteractive { [bool]$script:nonInteractive }
    $script:noniSwitch = $false
    function Test-Win32ToolkitNonInteractiveSwitch { [bool]$script:noniSwitch }
    $pp = New-XProject 'preflight'
    $pre = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $pp
    if ($pre.Ok -and $pre.Backend -eq 'HyperV' -and @($pre.Notes).Count -eq 0) { Ok 'a ready Hyper-V test VM -> Hyper-V (whatever TestBackend says), no note' } else { Bad "ready: $($pre | ConvertTo-Json -Compress)" }
    $script:hvNotReady = @('no guest credential')
    $pre = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $pp -Backend HyperV
    if ($pre.Ok -and $pre.Backend -eq 'Sandbox' -and ($pre.Notes -join ' ') -match '^Hyper-V is not ready \(no guest credential\): this capture runs in Windows Sandbox as a user and can only give Block-only proposals\.$') { Ok 'Hyper-V not ready -> Windows Sandbox, with the SV28 note (Block-only)' } else { Bad "fallback: $($pre | ConvertTo-Json -Compress)" }
    $script:hvNotReady = @()
    $pre = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $pp -Backend Sandbox
    if ($pre.Ok -and $pre.Backend -eq 'Sandbox' -and ($pre.Notes -join ' ') -match 'Windows Sandbox as a user and can only give Block-only proposals') { Ok '-Backend Sandbox -> Windows Sandbox, with the Block-only note' } else { Bad "sandbox: $($pre | ConvertTo-Json -Compress)" }
    foreach ($c in @(
            @{ L = 'assisted, Hyper-V not ready'; S = { $script:hvNotReady = @('no VM') }; B = 'HyperV'; Rx = 'an assisted capture runs on the Hyper-V test VM, which is not ready \(no VM\)' }
            @{ L = 'assisted in Windows Sandbox'; S = { }; B = 'Sandbox'; Rx = 'an assisted capture runs on the Hyper-V test VM only' }
            @{ L = 'assisted on a console that cannot prompt'; S = { $script:nonInteractive = $true }; B = 'HyperV'; Rx = 'needs a console that can answer a prompt' }
            # Live row ASSISTED (2026-10-27): 'pwsh -NonInteractive -File' with a console (UserInteractive, input not
            # redirected) passed the pre-flight and spent two VM runs that failed at the prompt.
            @{ L = 'assisted on a console started with -NonInteractive'; S = { $script:noniSwitch = $true }; B = 'HyperV'; Rx = 'needs a console that can answer a prompt' }
        )) {
        $script:hvNotReady = @(); $script:nonInteractive = $false; $script:noniSwitch = $false
        & $c.S
        $pre = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $pp -Backend $c.B -Assisted
        if (-not $pre.Ok -and $pre.Code -eq 'W32T.SiblingCaptureUnsupported' -and ($pre.Reasons -join ' ') -match $c.Rx) { Ok "$($c.L) -> refused" } else { Bad "$($c.L): $($pre | ConvertTo-Json -Compress)" }
    }
    $script:hvNotReady = @(); $script:nonInteractive = $false; $script:noniSwitch = $false
    $pre = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $pp -Assisted
    if ($pre.Ok -and $pre.Backend -eq 'HyperV') { Ok 'assisted on a ready Hyper-V test VM from an interactive console -> Ok' } else { Bad "assisted ok: $($pre | ConvertTo-Json -Compress)" }
    # The command-line scenario (spec Dv14): a VM that is not ready never turns a capture into a Windows Sandbox one over
    # captures an Enforce rule can use (a Sandbox record would make that identity Block-only for good); -Backend Sandbox
    # captures there on purpose, and a type that would cost nothing is captured.
    $pc = New-XProject 'clisandbox'
    foreach ($a in @(@{ Version = '8.7.9'; Role = 'Floor' }, @{ Version = '8.9.8' })) { $null = Write-TestSiblingRecord -ProjectPath $pc -Record (New-TestSiblingRecord @a) }
    $recDir = Join-Path $pc 'Documentation\SiblingCapture'
    $nRec = @(Get-ChildItem -LiteralPath $recDir -Filter *.json).Count
    $script:hvNotReady = @('no guest credential'); $script:captureWrites = @(@{ Version = '8.6.0'; Role = 'Extra'; Backend = 'Sandbox' }); $script:captureResult = $true
    foreach ($c in @(@{ L = 'no -Backend'; A = @{} }, @{ L = '-Backend HyperV'; A = @{ Backend = 'HyperV' } })) {
        $script:captureBackends.Clear()
        $err = $null
        $cliArgs = $c.A
        try { $null = Test-Win32ToolkitProject -ProjectPath $pc -Scenario SiblingCapture @cliArgs 6>$null 3>$null } catch { $err = $_ }
        $still = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $pc).Proposals | Where-Object { $_.ProposalId -eq 'nsis-x64' -and $_.EnforceEligible })
        if ($err.FullyQualifiedErrorId -eq 'W32T.SiblingCaptureUnsupported' -and "$($err.Exception.Message)" -match 'the Hyper-V test VM is not ready, and a capture in Windows Sandbox would make nsis-x64 Block-only .*-Backend Sandbox\. Nothing was downloaded or run\.$' -and $script:captureBackends.Count -eq 0 -and @(Get-ChildItem -LiteralPath $recDir -Filter *.json).Count -eq $nRec -and $still.Count -eq 1) {
            Ok "Hyper-V not ready + an Enforce-eligible proposal, $($c.L) -> W32T.SiblingCaptureUnsupported naming nsis-x64 and -Backend Sandbox; nothing captured, the proposal stays eligible"
        } else { Bad "cli $($c.L): $($err.FullyQualifiedErrorId) $($err.Exception.Message) captures=$($script:captureBackends -join ',')" }
    }
    $script:captureBackends.Clear(); $script:captureWrites = @()
    # The single-instance wait before a Windows Sandbox capture (shadowed: the host's real sandboxes never decide a test).
    $script:sbFreeCli = $true
    function Wait-Win32ToolkitSandboxFree { param($TimeoutSeconds, [switch]$OwnRun) $null = $TimeoutSeconds, $OwnRun; [bool]$script:sbFreeCli }
    # Live row SB-CAPTURE: with another sandbox open, -Backend Sandbox warned "Block-only for good", planned, staged and then
    # failed each capture after 90 s with a plain error. Now: one W32T.SandboxBusy before any of it.
    $script:sbFreeCli = $false
    $busyErr = $null; $busyWarn = $null
    try { $null = Test-Win32ToolkitProject -ProjectPath $pc -Scenario SiblingCapture -Backend Sandbox -WarningVariable busyWarn 6>$null 3>$null } catch { $busyErr = $_ }
    $script:sbFreeCli = $true
    if ($busyErr.FullyQualifiedErrorId -eq 'W32T.SandboxBusy' -and "$($busyErr.Exception.Message)" -match 'another Windows Sandbox is still running after 90 s' -and $script:captureBackends.Count -eq 0 -and @($busyWarn).Count -eq 0) {
        Ok 'another Windows Sandbox open -> W32T.SandboxBusy once, before any warning, plan or capture'
    } else { Bad "busy: $($busyErr.FullyQualifiedErrorId) $($busyErr.Exception.Message) captures=$($script:captureBackends -join ',') warnings=$($busyWarn -join ' | ')" }
    $got = $null
    try { $got = Test-Win32ToolkitProject -ProjectPath $pc -Scenario SiblingCapture -SiblingInstallerType inno 6>$null 3>$null } catch { $got = "threw: $($_.Exception.Message)" }
    $mid = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $pc).Proposals | Where-Object { $_.ProposalId -eq 'nsis-x64' -and $_.EnforceEligible })
    if ($got -eq $true -and ($script:captureBackends -join ',') -eq 'Sandbox' -and $mid.Count -eq 1) { Ok 'Hyper-V not ready + -SiblingInstallerType inno (nothing of that type an Enforce rule can use) -> captured in Windows Sandbox' } else { Bad "cli inno: $got $($script:captureBackends -join ',')" }
    $script:captureBackends.Clear(); $script:captureWrites = @(@{ Version = '8.6.0'; Role = 'Extra'; Backend = 'Sandbox' })
    $got = $null
    $sbWarn = $null
    try { $got = Test-Win32ToolkitProject -ProjectPath $pc -Scenario SiblingCapture -Backend Sandbox -WarningVariable sbWarn 6>$null 3>$null } catch { $got = "threw: $($_.Exception.Message)" }
    $after = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $pc).Proposals | Where-Object { $_.ProposalId -eq 'nsis-x64' })[0]
    if ($got -eq $true -and ($script:captureBackends -join ',') -eq 'Sandbox' -and -not $after.EnforceEligible) { Ok '-Backend Sandbox -> captured in Windows Sandbox on purpose (nsis-x64 is then Block-only)' } else { Bad "cli sandbox: $got $($script:captureBackends -join ',') eligible=$($after.EnforceEligible)" }
    # Live row SB-CAPTURE: the capture on purpose names the identity it makes Block-only, before it runs.
    if (@($sbWarn | Where-Object { "$_" -match '^This capture in Windows Sandbox \(-Backend Sandbox\) makes nsis-x64 Block-only for good' }).Count -eq 1) { Ok '-Backend Sandbox over an Enforce-eligible identity -> one warning naming nsis-x64 (the capture still runs)' } else { Bad "sandbox warning: $($sbWarn -join ' | ')" }
    $script:hvNotReady = @(); $script:captureWrites = @()
    # Live row ASSISTED: an assisted capture made an Enforce-eligible identity Block-only with no word before it ran.
    $pas = New-XProject 'assisted-warn'
    foreach ($a in @(@{ Version = '8.7.9'; Role = 'Floor' }, @{ Version = '8.9.8' })) { $null = Write-TestSiblingRecord -ProjectPath $pas -Record (New-TestSiblingRecord @a) }
    $script:captureBackends.Clear(); $asWarn = $null
    try { $null = Test-Win32ToolkitProject -ProjectPath $pas -Scenario SiblingCapture -Assisted -WarningVariable asWarn 6>$null 3>$null } catch { Bad "assisted warn threw: $($_.Exception.Message)" }
    if (@($asWarn | Where-Object { "$_" -match '^This assisted capture \(-Assisted\) makes nsis-x64 Block-only for good' }).Count -eq 1 -and ($script:captureBackends -join ',') -eq 'HyperV') { Ok '-Assisted over an Enforce-eligible identity -> one warning naming nsis-x64 before the capture (as for Windows Sandbox)' } else { Bad "assisted warning: $($asWarn -join ' | ') captures=$($script:captureBackends -join ',')" }

    # ---- the real capture engine with its VM side shadowed ----
    ${function:Invoke-Win32ToolkitSiblingCapture} = $realCapture
    function New-NsisBytes { $b = [byte[]]::new(2048); $sig = [byte[]](0xEF, 0xBE, 0xAD, 0xDE) + [Text.Encoding]::ASCII.GetBytes('NullsoftInst'); [Array]::Copy($sig, 0, $b, 516, $sig.Length); $b }
    function Write-GuestOutput([string]$Folder, [string]$Key, [string]$Version, [string]$Publisher = 'Notepad++ Team', [string]$View = 'Native', [switch]$NoInstall, [switch]$NoPrimary) {
        $pf = if ($View -eq 'Wow6432') { 'C:\Program Files (x86)' } else { 'C:\Program Files' }
        $tok = if ($View -eq 'Wow6432') { '%ProgramFiles(x86)%' } else { '%ProgramFiles%' }
        $cand = [ordered]@{ Key = 'Notepad++'; View = $View; DisplayName = 'Notepad++'; DisplayVersion = $Version; Publisher = $Publisher; WindowsInstaller = $false; SystemComponent = $false
            InstallLocation = "$pf\Notepad++"; DisplayIconLeaf = 'notepad++.exe'; UninstallerPath = "$pf\Notepad++\uninstall.exe"; UninstallerCanonical = $true; UninstallerLeaf = 'uninstall.exe'
            InstallDir = "$tok\Notepad++"; MainExe = 'notepad++.exe'; Files = @('notepad++.exe', 'uninstall.exe'); InstallLocationFiles = @(); InnoAppPath = $false; UnsDat = $false; QuietUninstallArgs = ''
            Acl = @(New-TestSiblingAcl -Folder "$pf\Notepad++" -Exe "$pf\Notepad++\uninstall.exe"); UnsafeText = $false }
        $null = New-Item -ItemType Directory -Path (Join-Path $Folder 'Logs') -Force
        $files = [ordered]@{
            "SiblingPre_$Key.json"     = [ordered]@{ SchemaVersion = '1.0'; StartedUtc = '2026-10-25T10:00:00Z'; Account = 'X'; Is64 = $true; OsBuild = '26100'; NoiseVerified = $true }
            "SiblingCapture_$Key.json" = [ordered]@{ SchemaVersion = '1.0'; Candidates = @($cand); Services = @(); Shortcuts = @(); Tasks = @(); Appx = @(); HkcuArp = @(); NewRoots = @("$pf\Notepad++"); NoiseControl = 'Verified'; PfroCount = 0; ProvisionalPrimary = 'Notepad++'; ProvisionalView = $View }
            "SiblingProbe_$Key.json"   = [ordered]@{ Result = 'Clean'; ProbedKey = 'Notepad++'; ProbedView = $View; ExitCode = 0; Seconds = 9; LingeringProcess = @(); PfroUnderRoot = $false; RootConfigRemoved = $false; VendorConfigRemoved = @() }
            "SiblingDone_$Key.json"    = [ordered]@{ SchemaVersion = '1.0' }
        }
        if (-not $NoInstall) { $files["SiblingInstall_$Key.json"] = [ordered]@{ InstallFailed = $false; ExitCode = 0; TimedOut = $false; Completed = $true; RebootRequested = $false; Lingering = @(); Seconds = 30 } }
        if ($NoPrimary) { $files["SiblingCapture_$Key.json"]['Candidates'] = @(); $files["SiblingCapture_$Key.json"]['ProvisionalPrimary'] = ''; $files["SiblingCapture_$Key.json"]['ProvisionalView'] = ''; $files["SiblingCapture_$Key.json"]['NewRoots'] = @() }
        foreach ($n in $files.Keys) { [IO.File]::WriteAllText((Join-Path $Folder $n), ($files[$n] | ConvertTo-Json -Depth 10), $utf8) }
        [IO.File]::WriteAllBytes((Join-Path $Folder "SiblingCopy_${Key}_uninstaller.exe"), (New-NsisBytes))
        [IO.File]::WriteAllText((Join-Path $Folder 'Logs\SiblingCapture_All.log'), 'log', $utf8)
    }
    $script:downloads = [System.Collections.Generic.List[object]]::new()
    function Download-OldVersionInstaller {
        param($AppId, $Version, $ProjectPath, $DestinationDir, $Architecture, $InstallerType, [switch]$ExactType, $Scope)
        $script:downloads.Add([pscustomobject]@{ Version = $Version; Architecture = $Architecture; InstallerType = $InstallerType; ExactType = [bool]$ExactType })
        $null = New-Item -ItemType Directory -Path $DestinationDir -Force
        $file = Join-Path $DestinationDir "npp.$Version.exe"
        [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes("installer $Version $Architecture"))
        # The merged manifest winget writes next to the installer: the ProductCode attributes the primary entry (High).
        $man = Join-Path $DestinationDir 'Notepad++.Notepad++.yaml'
        [IO.File]::WriteAllText($man, "PackageIdentifier: Notepad++.Notepad++`nPackageVersion: $Version`nPackageName: Notepad++`nPublisher: Notepad++ Team`nInstallers:`n- Architecture: $Architecture`n  InstallerType: $InstallerType`n  ProductCode: Notepad++`n", $utf8)
        [pscustomobject]@{ InstallerPath = $file; InstallerName = "npp.$Version.exe"; SilentArgs = '/S'; SilentArgsSource = 'catalog'; ManifestPath = @($man); Scope = 'machine'; Locale = '' }
    }
    $script:identityOf = { param([string]$Version) 'Notepad++ Team' }
    $script:hvPhases = $null; $script:hvView = 'Native'; $script:hvNoInstall = $false; $script:hvNoPrimary = $false
    function Invoke-Win32ToolkitHyperVRun {
        param($ProjectPath, $Phase, $Output, $ResultDestination, $ResultAllowedEntry, $ResultMaxEntryBytes, $ResultMaxTotalBytes)
        $null = $Output, $ResultAllowedEntry, $ResultMaxEntryBytes, $ResultMaxTotalBytes
        $script:hvPhases = @($Phase)
        $d = Get-Content -LiteralPath (Join-Path $ProjectPath 'SiblingCapture.data.json') -Raw | ConvertFrom-Json
        $script:lastData = $d
        Write-GuestOutput -Folder (Join-Path $ResultDestination 'Out') -Key $d.CaptureKey -Version $d.Version -Publisher (& $script:identityOf $d.Version) -View $script:hvView -NoInstall:$script:hvNoInstall -NoPrimary:$script:hvNoPrimary
        $true
    }
    $script:wsbText = ''
    # The start-up wait (90 s) always finds Windows Sandbox free; this capture's own sandbox closes unless $sbClosed says no.
    $script:sbClosed = $true; $script:sbWaits = [System.Collections.Generic.List[string]]::new()
    function Wait-Win32ToolkitSandboxFree { param($TimeoutSeconds, [switch]$OwnRun) $script:sbWaits.Add("$TimeoutSeconds$(if ($OwnRun) { '/own' })"); if ($TimeoutSeconds -eq 90 -and -not $OwnRun) { return $true }; [bool]$script:sbClosed }
    function Test-Win32ToolkitSandboxRunning { $false }
    # No real wait; a wait loop that never ends is stopped here (1000 polls) instead of hanging the suite.
    $script:sleeps = 0
    $script:slowGuest = $null
    function Start-Sleep {
        param($Seconds, $Milliseconds)
        $null = $Seconds, $Milliseconds
        $script:sleeps++
        if ($script:sleeps -gt 1000) { throw 'test guard: the sandbox wait did not stop' }
        # A slow guest: its output (and the done file) appears at the 40th poll.
        if ($script:slowGuest -and $script:sleeps -eq 40) { $g = $script:slowGuest; Write-GuestOutput -Folder $g.Folder -Key $g.Key -Version $g.Version }
    }
    $script:sbGuest = $true
    function Start-Win32ToolkitSandbox {
        param($ConfigPath)
        $script:wsbText = [IO.File]::ReadAllText($ConfigPath)
        if ('slow' -eq $script:sbGuest) {
            # The guest started (its Logs folder is there) but no sandbox process is seen; it finishes after 40 polls.
            $run = Split-Path -Path $ConfigPath -Parent
            $d = Get-Content -LiteralPath (Join-Path $run 'in\SiblingCapture.data.json') -Raw | ConvertFrom-Json
            $null = New-Item -ItemType Directory -Path (Join-Path $run 'quarantine\Logs') -Force
            $script:slowGuest = @{ Folder = (Join-Path $run 'quarantine'); Key = $d.CaptureKey; Version = $d.Version }
            return $true
        }
        if (-not $script:sbGuest) { return $true }
        $run = Split-Path -Path $ConfigPath -Parent
        $d = Get-Content -LiteralPath (Join-Path $run 'in\SiblingCapture.data.json') -Raw | ConvertFrom-Json
        $script:lastData = $d
        $q = Join-Path $run 'quarantine'
        Write-GuestOutput -Folder $q -Key $d.CaptureKey -Version $d.Version
        [IO.File]::WriteAllText((Join-Path $q 'evil.ps1'), 'Write-Host evil', $utf8)
        $null = New-Item -ItemType Directory -Path (Join-Path $q 'Extra') -Force
        $true
    }
    $plan1 = { param([string]$Arch = 'x64', [object[]]$Caps, [object[]]$Offering = @())
        [pscustomobject]@{ Package = [pscustomobject]@{ WingetId = 'Notepad++.Notepad++'; Version = '9.9.9'; Architecture = 'x64'; InstallerType = 'wix'; Family = 'msi' }; Architecture = $Arch; Backend = ''; ProbeFailures = @(); EstimatedRuns = @($Caps).Count
            Types = @([pscustomobject]@{ Type = 'nullsoft'; EffectiveType = 'nullsoft'; Class = 'RemovableNow'; Reason = ''; SameFamily = $false; Captures = @($Caps); Offering = @($Offering) }) } }
    $cap = { param([string]$V, [string]$Role, [string]$Arch = 'x64') [pscustomobject]@{ Version = $V; Role = $Role; ReleaseDate = ''; Scope = 'machine'; CaptureKey = ("nullsoft-$V" + $(if ($Arch -eq 'x86') { '-x86' }) + $(if ($Role -eq 'Repeat') { '-r' })) } }
    $off = { param([string[]]$Vs) @($Vs | ForEach-Object { [pscustomobject]@{ Version = $_; ReleaseDate = ''; Scope = 'machine' } }) }

    # == [3] Windows Sandbox ==================================================================================
    Write-Host '[3] X2: a capture in Windows Sandbox' -ForegroundColor Cyan
    $ps = New-XProject 'sandbox'
    $w = $null
    $r = Invoke-Win32ToolkitSiblingCapture -ProjectPath $ps -Plan (& $plan1 'x64' @((& $cap '8.9.8' 'Newest'), (& $cap '8.9.8' 'Repeat'))) -Backend Sandbox -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $wsb = [xml]$script:wsbText
    $maps = @($wsb.Configuration.MappedFolders.MappedFolder)
    $inMap = @($maps | Where-Object { $_.SandboxFolder -eq 'C:\PSADT' })[0]; $outMap = @($maps | Where-Object { $_.SandboxFolder -eq 'C:\W32TOut' })[0]
    $cmd = [string]$wsb.Configuration.LogonCommand.Command
    if ($maps.Count -eq 2 -and $inMap.ReadOnly -eq 'true' -and $inMap.HostFolder -like '*\Sandbox\SiblingRuns\nullsoft-8.9.8-*\in' -and $outMap.ReadOnly -eq 'false' -and $outMap.HostFolder -like '*\Sandbox\SiblingRuns\nullsoft-8.9.8-*\quarantine' -and @($maps | Where-Object { $_.HostFolder.TrimEnd('\') -eq $ps.TrimEnd('\') }).Count -eq 0) {
        Ok 'the .wsb maps in\ read-only at C:\PSADT and quarantine\ read-write at C:\W32TOut; the project is never mapped'
    } else { Bad "wsb maps: $($script:wsbText)" }
    if ($cmd -match "^powershell\.exe -ExecutionPolicy Bypass -Command `"& \{ & 'C:\\PSADT\\SiblingCapture\.ps1' -Phase All \}`"$" -and $cmd -notmatch '-File') { Ok 'the LogonCommand runs -Phase All in the -Command "& { ... }" form (never -File)' } else { Bad "cmd: $cmd" }
    $recs = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ps)
    if ($r -eq $true -and $script:lastData.OutDir -eq 'C:\W32TOut' -and $script:lastData.Mode -eq 'Unattended' -and $recs.Count -eq 2 -and @($recs | Where-Object { $_.Run.Backend -ne 'Sandbox' }).Count -eq 0) { Ok 'the data file names C:\W32TOut; two records, Run.Backend Sandbox' } else { Bad "sandbox records: r=$r $($recs.Count) $($script:lastData | ConvertTo-Json -Compress)" }
    if (@($w | Where-Object { "$_" -match "'evil\.ps1' from the sandbox was refused \(not an expected file\)" }).Count -ge 1 -and @($w | Where-Object { "$_" -match "'Extra' from the sandbox was refused" }).Count -ge 1) { Ok 'a file or folder outside the allow-list is refused and deleted before the read' } else { Bad "warnings: $($w -join ' | ')" }
    $px = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ps).Proposals)[0]
    if ($px.Flags -contains 'Sandbox' -and -not $px.EnforceEligible) { Ok 'every Sandbox proposal is Block-only (flag Sandbox)' } else { Bad "sandbox proposal: $($px.Flags -join ',')" }
    # L18: the quarantine is mapped read-write inside the project, so its output is trusted only once this capture's own
    # sandbox is closed: its own (10 minutes), then any (1 minute); still open -> W32T.GuestTamper, nothing recorded.
    $pso = New-XProject 'sandbox-open'
    $script:sbClosed = $false; $script:sbWaits.Clear()
    $err = try { $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $pso -Plan (& $plan1 'x64' @((& $cap '8.9.8' 'Newest'), (& $cap '8.9.8' 'Repeat'))) -Backend Sandbox -WarningAction SilentlyContinue 6>$null; '' } catch { $_.FullyQualifiedErrorId + '|' + $_.Exception.Message }
    $script:sbClosed = $true
    $marker = Join-Path $pso 'Documentation\GuestTamper.json'
    if ($err -like "W32T.GuestTamper|*this capture's Windows Sandbox could not be confirmed closed*" -and (Test-Path -LiteralPath $marker) -and @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pso).Count -eq 0 -and ($script:sbWaits -join ',') -eq '90,600/own,60') {
        Ok "the capture's sandbox cannot be confirmed closed (its own for 10 minutes, then any for 1 minute) -> W32T.GuestTamper with that reason, the marker, no record"
    } else { Bad "sandbox open: '$err' waits=$($script:sbWaits -join ',') marker=$(Test-Path -LiteralPath $marker)" }
    # A sandbox that never shows up: the capture gives up after 5 minutes (30 polls), never the 50-minute wait.
    $psn = New-XProject 'sandbox-none'
    $script:sbGuest = $false; $script:sleeps = 0
    $w = $null
    $r = Invoke-Win32ToolkitSiblingCapture -ProjectPath $psn -Plan (& $plan1 'x64' @((& $cap '8.9.8' 'Newest'))) -Backend Sandbox -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $script:sbGuest = $true
    $idx = Get-Content -LiteralPath (Join-Path $psn 'Documentation\SiblingCapture.json') -Raw | ConvertFrom-Json
    if ($r -eq $false -and $script:sleeps -eq 30 -and @($idx.Failed | Where-Object { $_.Reason -eq 'Windows Sandbox did not start within 5 minutes' }).Count -eq 1) {
        Ok 'a sandbox that never showed up -> CaptureFailed after 30 polls (5 minutes): "Windows Sandbox did not start within 5 minutes"'
    } else { Bad "sandbox none: r=$r sleeps=$($script:sleeps) failed=$($idx.Failed | ConvertTo-Json -Compress)" }
    # A guest that already wrote into the quarantine started, even when no sandbox process is seen: its capture is waited for.
    $pss = New-XProject 'sandbox-slow'
    $script:sbGuest = 'slow'; $script:sleeps = 0
    $r = Invoke-Win32ToolkitSiblingCapture -ProjectPath $pss -Plan (& $plan1 'x64' @((& $cap '8.9.8' 'Newest'))) -Backend Sandbox -WarningAction SilentlyContinue 6>$null
    $script:sbGuest = $true; $script:slowGuest = $null
    if ($r -eq $true -and $script:sleeps -eq 40 -and @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pss).Count -eq 1) {
        Ok 'a guest that wrote into the quarantine (no sandbox process seen) is waited for past 5 minutes: recorded at the 40th poll'
    } else { Bad "sandbox slow: r=$r sleeps=$($script:sleeps) records=$(@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pss).Count)" }

    # == [4] assisted ===========================================================================================
    Write-Host '[4] X2: an assisted capture on Hyper-V (D62)' -ForegroundColor Cyan
    $pa = New-XProject 'assisted'
    $script:hvNoInstall = $true
    $aOut = @(Invoke-Win32ToolkitSiblingCapture -ProjectPath $pa -Plan (& $plan1 'x64' @((& $cap '8.9.8' 'Newest'), (& $cap '8.9.8' 'Repeat'))) -Backend HyperV -Assisted -WarningAction SilentlyContinue 6>&1)
    $r = @($aOut | Where-Object { $_ -is [bool] })[-1]
    $aText = @($aOut | Where-Object { $_ -isnot [bool] } | ForEach-Object { "$_" })
    $script:hvNoInstall = $false
    if (@($aText | Where-Object { $_ -ceq 'Assisted: when the run pauses, start C:\PSADT\installer\npp.8.9.8.exe (the nullsoft installer of version 8.9.8) in the VM window, finish its setup, then press Enter here.' }).Count -eq 2) {
        Ok 'each assisted capture names the file to start in the VM window (C:\PSADT\installer\<leaf>) before its run'
    } else { Bad "assisted path line: $($aText -join ' | ')" }
    $ph = @($script:hvPhases)
    $recs = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pa)
    if ($ph[1].Pause -and $ph[1].Interactive -and $ph[1].StopRunOnFailure -and $ph[1].Label -match 'Assisted' -and -not $ph[1].Command -and $script:lastData.Mode -eq 'Assisted' -and $recs.Count -eq 2 -and @($recs | Where-Object { $_.Run.Mode -ne 'Assisted' -or -not $_.Install.Completed }).Count -eq 0) {
        Ok 'the install phase is an interactive pause; the data says Assisted; the records are Run.Mode Assisted (the install counts as done)'
    } else { Bad "assisted: $($ph | ConvertTo-Json -Compress -Depth 3)" }
    $px = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $pa).Proposals)[0]
    if ($px.Flags -contains 'Assisted' -and -not $px.EnforceEligible) { Ok 'an assisted proposal is Block-only (flag Assisted)' } else { Bad "assisted proposal: $($px.Flags -join ',')" }
    # Live row ASSISTED: an assisted run where the operator installed nothing was recorded ("no primary entry"), and its
    # records made the good identity of that version Unstable for good. No new uninstall entry -> CaptureFailed, no record.
    $pan = New-XProject 'assisted-nothing'
    $script:hvNoInstall = $true; $script:hvNoPrimary = $true
    $w = $null
    $r = Invoke-Win32ToolkitSiblingCapture -ProjectPath $pan -Plan (& $plan1 'x64' @((& $cap '8.9.8' 'Newest'))) -Backend HyperV -Assisted -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $script:hvNoInstall = $false; $script:hvNoPrimary = $false
    $idxN = Get-Content -LiteralPath (Join-Path $pan 'Documentation\SiblingCapture.json') -Raw | ConvertFrom-Json
    if ($r -eq $false -and @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pan).Count -eq 0 -and @($idxN.Failed | Where-Object { $_.Reason -match '^the assisted install left no uninstall entry of this app' }).Count -eq 1) {
        Ok 'an assisted capture that left no uninstall entry of the app -> CaptureFailed (no record), the reason says nothing was installed'
    } else { Bad "assisted nothing: r=$r records=$(@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pan).Count) failed=$($idxN.Failed | ConvertTo-Json -Compress)" }

    # == [5] bisection ==========================================================================================
    Write-Host '[5] X2: the bisection of a drift' -ForegroundColor Cyan
    $pb = New-XProject 'bisect'
    $script:identityOf = { param([string]$Version) if ((ConvertTo-Win32ToolkitPriorVersion -Text $Version) -ge [version]'8.8.0.0') { 'Notepad++ Team' } else { 'Don Ho' } }
    $offer = & $off @('9.0', '8.9', '8.8', '8.7', '8.6')
    $r = Invoke-Win32ToolkitSiblingCapture -ProjectPath $pb -Plan (& $plan1 'x64' @((& $cap '9.0' 'Newest'), (& $cap '8.6' 'Floor')) $offer) -Backend HyperV -MaxExtra 4 -WarningAction SilentlyContinue 6>$null
    $recs = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pb)
    $vers = (@($recs | Sort-Object { ConvertTo-Win32ToolkitPriorVersion -Text $_.Sibling.Version } | ForEach-Object { "$($_.Sibling.Version)/$($_.Sibling.Role)" }) -join ',')
    $sib = ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $pb
    $idx = Get-Content -LiteralPath (Join-Path $pb 'Documentation\SiblingCapture.json') -Raw | ConvertFrom-Json
    if ($vers -eq '8.6/Floor,8.7/Extra,8.8/Extra,9.0/Newest' -and @($sib.Proposals).Count -eq 2 -and @($sib.Gaps).Count -eq 1 -and $sib.Gaps[0].From -eq '8.7' -and $sib.Gaps[0].To -eq '8.8' -and @($idx.Gaps).Count -eq 1) {
        Ok 'Newest 9.0 and Floor 8.6 register two identities -> Extra captures at the middle (8.8, then 8.7) until the change is located (8.7 -> 8.8); two proposals; the index keeps the gap'
    } else { Bad "bisection: $vers gaps $($sib.Gaps | ConvertTo-Json -Compress)" }
    $pb0 = New-XProject 'bisect0'
    $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $pb0 -Plan (& $plan1 'x64' @((& $cap '9.0' 'Newest'), (& $cap '8.6' 'Floor')) $offer) -Backend HyperV -MaxExtra 0 -WarningAction SilentlyContinue 6>$null
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pb0).Count -eq 2) { Ok '-MaxExtra 0 -> no extra capture' } else { Bad 'maxextra 0' }
    $pb1 = New-XProject 'bisect1'
    $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $pb1 -Plan (& $plan1 'x64' @((& $cap '9.0' 'Newest'), (& $cap '8.6' 'Floor')) $offer) -Backend HyperV -MaxExtra 1 -WarningAction SilentlyContinue 6>$null
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pb1).Count -eq 3) { Ok '-MaxExtra 1 -> at most one extra capture' } else { Bad 'maxextra 1' }
    # Per architecture: an x86 run narrows only the x86 drift. The project's x64 records show a drift too (9.0 and 8.6
    # register two identities); x86 captures can never narrow it, so none is spent on it, and the line names the gap the
    # extra capture narrows. An x64 record inside the x86 gap (x64 8.8) is no x86 capture: the x86 bisection still
    # captures x86 8.8 (counting the x64 version as done would skip it and bisect 8.7, then 8.9).
    $pba = New-XProject 'bisect-arch'
    $null = Write-TestSiblingRecord -ProjectPath $pba -Record (New-TestSiblingRecord -Version '9.0' -Role 'Newest')
    $null = Write-TestSiblingRecord -ProjectPath $pba -Record (New-TestSiblingRecord -Version '8.8' -Role 'Extra')
    $null = Write-TestSiblingRecord -ProjectPath $pba -Record (New-TestSiblingRecord -Version '8.6' -Role 'Floor' -Publisher 'Don Ho')
    $script:hvView = 'Wow6432'
    $bOut = @(Invoke-Win32ToolkitSiblingCapture -ProjectPath $pba -Plan (& $plan1 'x86' @((& $cap '9.0' 'Newest' 'x86'), (& $cap '8.6' 'Floor' 'x86')) $offer) -Backend HyperV -MaxExtra 4 -WarningAction SilentlyContinue 6>&1 |
            Where-Object { $_ -isnot [bool] } | ForEach-Object { "$_" })
    $script:hvView = 'Native'
    $r86 = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $pba | Where-Object { $_.Sibling.Architecture -eq 'x86' } | Sort-Object { ConvertTo-Win32ToolkitPriorVersion -Text $_.Sibling.Version } | ForEach-Object { $_.Sibling.Version })
    $lines = @($bOut | Where-Object { $_ -match '^The \S+ sibling changed its identity between' })
    if (($r86 -join ',') -eq '8.6,8.7,8.8,9.0' -and $lines.Count -eq 2 -and $lines[0] -ceq 'The nullsoft sibling changed its identity between 8.6 and 9.0: one more capture (8.8) to narrow it down.' -and $lines[1] -ceq 'The nullsoft sibling changed its identity between 8.6 and 8.8: one more capture (8.7) to narrow it down.') {
        Ok 'an x86 run with an x64 drift on record (x64 8.6, 8.8, 9.0): Extra captures only for the x86 drift (8.8, 8.7; the x64 8.8 never counts as captured for x86), each line naming the gap it narrows'
    } else { Bad "bisect arch: x86 versions $($r86 -join ',') lines $($lines -join ' | ')" }
    $script:identityOf = { param([string]$Version) $null = $Version; 'Notepad++ Team' }

    # == [6] x86 siblings ========================================================================================
    Write-Host '[6] X2: x86 siblings of an x64 package' -ForegroundColor Cyan
    $p86 = New-XProject 'x86'
    $script:downloads.Clear(); $script:hvView = 'Wow6432'
    $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $p86 -Plan (& $plan1 'x86' @((& $cap '8.9.8' 'Newest' 'x86'), (& $cap '8.7.9' 'Floor' 'x86'))) -Backend HyperV -WarningAction SilentlyContinue 6>$null
    $script:hvView = 'Native'
    $recs = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $p86)
    $px = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $p86).Proposals)[0]
    if (@($script:downloads | Where-Object { $_.Architecture -ne 'x86' }).Count -eq 0 -and $script:lastData.Architecture -eq 'x86' -and @($recs | Where-Object { $_.Sibling.Architecture -ne 'x86' -or $_.Package.Architecture -ne 'x64' }).Count -eq 0 -and $px.View -eq 'Wow6432' -and $px.ProposalId -eq 'nsis-x86' -and $px.InstallDir -eq '%ProgramFiles(x86)%\Notepad++') {
        Ok 'the x86 installer is downloaded and captured (Sibling.Architecture x86, the package x64); the proposal nsis-x86 is View Wow6432'
    } else { Bad "x86: $($script:downloads | ConvertTo-Json -Compress) / $($px | ConvertTo-Json -Compress)" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingCaptureExtras tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingCaptureExtras test(s) FAILED." -ForegroundColor Red; exit 1 }
