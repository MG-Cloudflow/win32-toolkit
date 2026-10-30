<#
    Installer-identity PR 3b, commit P1 (spec 2.17; SV2, SV25, SV28, D58, D59a, L36, L37): the pipeline switches
    Invoke-Win32Toolkit -CaptureSiblingTechnologies / -ApplySiblingCapture and the Finalize step that runs them.
    Finalize runs for real on a generated project; the documentation capture, the sibling capture, the VM and the tests
    are shadowed (the proof runs write Update records against the current binding, as the real run does).

      [1] the switches: -ApplySiblingCapture is None|Block only (no Enforce, D58) in Invoke-Win32Toolkit and Finalize; the
          Finalize arguments are passed only when the switch is set; the promise line before the download (Hyper-V ready /
          not ready) and -ApplySiblingCapture without the switch (one warning, ignored).
      [2] the order: after the install capture is processed, under the per-project lease (TestProjectLease On), before
          the tests: pre-flight, plan, capture, the raise; with None nothing is written and the commands are printed.
      [3] no capture: the install capture failed, or the pre-flight refuses (no OwnIdentity, an arm64 package, Hyper-V not
          ready) -> one Problems sentence, the pipeline goes on, nothing thrown; W32T.GuestTamper still aborts. Without a
          ready VM (Windows Sandbox) a project whose captures already allow an Enforce rule is not captured (one sentence
          naming them); one without such captures is captured in Windows Sandbox, and so is one whose only rule is a
          Block or Report rule of an ineligible proposal; a ready VM captures over an Enforce-eligible proposal.
      [4] -ApplySiblingCapture Block: only the High flag-free proposal becomes a Block rule, after the raise; an existing
          rule of the same identity (an approved Enforce rule) is never rewritten (B27); a ready VM captures over that
          Enforce rule and raises its VersionMax (D61).
      [5] proof and demotion: unproven Enforce rules + -RunTest Update -> the proof loop replaces the generic Update run
          (one proof run per group, the Update verdict in Result.Tests); a failing captured rule is demoted (removed, its
          approval Demoted, named in Problems); an operator rule never is (the -Waive PROOF sentence); -RunTest without
          Update -> demoted with the -RunTest Update hint and no proof run; Hyper-V not ready -> no proof, the generic
          Update run as before.

    Run:  pwsh -File Tests\SiblingCapturePipeline.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Get-AuthenticodeSignature is shadowed: the signer checks never read a real file')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Set-Win32ToolkitPriorInstall.ps1')
. (Join-Path $repo 'Tests\Fixtures\sibling-proposal\SiblingFixture.ps1')
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32sp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
$golden = [IO.File]::ReadAllText((Join-Path $repo 'Tests\Fixtures\psadt-4.1.8\Invoke-AppDeployToolkit.ps1'), [Text.Encoding]::UTF8)

# ---- shadows: the documentation capture, the VM, the tests ----
$script:log = [System.Collections.Generic.List[string]]::new()
$script:jsonOk = $true; $script:docOk = $true
$script:preOk = $true; $script:preReasons = @(); $script:preBackend = 'HyperV'
$script:captureThrows = $false; $script:captureWrites = @()
$script:hvNotReady = @(); $script:leaseCfg = 'Off'
$script:failIds = @()
function Assert-Win32ToolkitPackageReady { param($ProjectPath, $Stage, [switch]$AllowLegacyScript) $null = $ProjectPath, $AllowLegacyScript; $script:log.Add("assert:$Stage"); [pscustomobject]@{ Ready = $true; Warnings = @() } }
function Get-Win32ToolkitTestBackend { 'Sandbox' }
function New-TargetedDocumentation { param($ProjectPath, $ProjectName, $AppInfo, $Backend, $BasePath) $null = $ProjectName, $AppInfo, $Backend, $BasePath; $script:log.Add('document'); if ($script:docOk) { Join-Path $ProjectPath 'Documentation\InstallationChanges_x.json' } else { $false } }
function Wait-ForDocumentationAndProcess { param($ProjectPath, $InstallerType, $ExpectedJsonPath) $null = $ProjectPath, $InstallerType, $ExpectedJsonPath; $script:log.Add('process'); $script:jsonOk }
function Wait-Win32ToolkitHyperVTeardown { param($VMName, $ReleaseOwner, [switch]$Prewarm) $null = $VMName, $ReleaseOwner, $Prewarm }
function Initialize-Win32ToolkitTestRunLog { param($ProjectPath, $Scenario, $Family) $null = $ProjectPath, $Scenario, $Family; $null }
function Import-Win32ToolkitCapturedIcon { param($ProjectPath) $null = $ProjectPath }
function Get-InstallerFileInfo { param($FilesPath) $null = $FilesPath; [pscustomobject]@{ Type = 'msi' } }
function Export-Win32ToolkitIntuneWin { param($ProjectPath) $null = $ProjectPath }
function Get-AuthenticodeSignature { [CmdletBinding()] param([string]$LiteralPath) $null = $LiteralPath; [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:TestSiblingSigner } } }
function Test-Win32ToolkitHyperVReady { @($script:hvNotReady) }
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($Name -eq 'TestProjectLease') { $script:leaseCfg } else { $Default } }
function Test-Win32ToolkitElevated { $true }
function Enter-Win32ToolkitHyperVLease { param($VMName, $VMId, $ProjectPath, $Purpose) $null = $VMName, $VMId, $ProjectPath; $script:log.Add("lease:enter:$Purpose"); [pscustomobject]@{ Kind = 'Project' } }
function Exit-Win32ToolkitHyperVLease { param($Lease) $null = $Lease; $script:log.Add('lease:exit') }
function Test-Win32ToolkitSiblingCapturePreflight { param($ProjectPath, $Backend) $null = $ProjectPath; $script:log.Add("preflight:$Backend"); [pscustomobject]@{ Ok = $script:preOk; Code = $(if ($script:preOk) { '' } else { 'W32T.SiblingCaptureUnsupported' }); Reasons = [string[]]$script:preReasons; Backend = $script:preBackend } }
$script:planRuns = 1; $script:captureResult = $true; $script:planProbe = $null; $script:planTypes = @()
function Get-Win32ToolkitSiblingCapturePlan { param($ProjectPath) $null = $ProjectPath; $script:log.Add('plan'); [pscustomobject]@{ Backend = ''; PackageProbe = $script:planProbe; Types = @($script:planTypes); EstimatedRuns = $script:planRuns } }
function Invoke-Win32ToolkitSiblingCapture {
    param($ProjectPath, $Plan, $Backend)
    $null = $Plan
    $script:log.Add("capture:$Backend")
    if ($script:captureThrows) { throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('a guest changed project files'), 'W32T.GuestTamper', [System.Management.Automation.ErrorCategory]::SecurityError, $ProjectPath) }
    foreach ($a in $script:captureWrites) { $null = Write-TestSiblingRecord -ProjectPath $ProjectPath -Record (New-TestSiblingRecord @a) }
    $script:captureResult
}
$realRaise = ${function:Update-Win32ToolkitPriorInstallWindow}
function Update-Win32ToolkitPriorInstallWindow { param($ProjectPath) $script:log.Add('raise'); & $realRaise -ProjectPath $ProjectPath }
function Test-Win32ToolkitProject {
    [CmdletBinding()]
    param([string]$ProjectPath, [string]$Scenario, [string]$Backend, [string]$TestMode, [string[]]$ProofEntryId, $BasePath, $SpecificVersion, $VersionsBack, $BaselineInstallerType)
    $null = $BasePath, $SpecificVersion, $VersionsBack, $BaselineInstallerType
    if (-not $ProofEntryId) { $script:log.Add("test:$Scenario"); return $true }
    $script:log.Add("proof:$($ProofEntryId -join ',')")
    $b = Get-Win32ToolkitPriorProofBinding -ProjectPath $ProjectPath
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $names = @('Requirement-PreUpdate', 'NewAppIntact-PostUpdate', 'Tattoo-PostUpdate'); $sha = ''
    foreach ($id in $ProofEntryId) {
        $names += @("PriorPresent-PreUpdate.$id", "PriorAbsent-PostUpdate.$id", "SiblingIdentityStable-PreUpdate.$id", "PriorResidue-PostUpdate.$id")
        $e = @($cfg.PriorInstalls.Entries | Where-Object Id -ceq $id)[0]
        if ($e.CaptureId) { $rec = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath -CaptureId $e.CaptureId)[0]; if ($rec) { $sha = [string]$rec.Sibling.InstallerSha256 } }
    }
    $failNames = @($ProofEntryId | Where-Object { $script:failIds -ccontains $_ } | ForEach-Object { "PriorAbsent-PostUpdate.$_" })
    $obs = [ordered]@{}; foreach ($id in $ProofEntryId) { $obs[$id] = '8.7.9' }
    $rec = [ordered]@{ Scenario = 'Update'; Backend = $Backend; Mode = $TestMode; TimestampUtc = (Get-Date).ToUniversalTime().AddSeconds($script:log.Count).ToString('o'); Verdict = $(if ($failNames.Count) { 'Failed' } else { 'Passed' }); Notes = ''
        Assertions = @($names | ForEach-Object { [ordered]@{ Name = $_; Result = $(if ($failNames -contains $_) { 'FAIL' } else { 'PASS' }) } })
        Proof = [ordered]@{ SchemaVersion = '1.0'; PriorInstallsHash = $b.PriorInstallsHash; ScriptSha256 = $b.ScriptSha256; FilesSha256 = $b.FilesSha256; SupportFilesSha256 = $b.SupportFilesSha256
            BaselineInstallerSha256 = $sha; CatalogVersion = $b.CatalogVersion; EntryIds = @($ProofEntryId); CaptureIds = @(); RequirementChecked = $true; ObservedVersions = $obs; DataLoss = @() } }
    $file = Join-Path $ProjectPath 'Documentation\TestResults.json'
    $all = @(if (Test-Path -LiteralPath $file) { @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }) + @([pscustomobject]$rec)
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject @($all) -Depth 8), $utf8)
    $failNames.Count -eq 0
}

$generated = $null
function New-PProject([string]$Name) {
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
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = 'Notepad++'; DisplayName = 'Notepad++'; Version = '8.9.9'; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.msi'; SilentArgs = '' }; ProcessesToClose = @('zeta')
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Architecture = 'x64'; ProductCode = $PC }
        OrgUi = [ordered]@{ Welcome = [ordered]@{ Enabled = $true } }
        OwnIdentity = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $p
}
$nsisRecs = @(@{ Version = '8.7.9'; Role = 'Floor' }, @{ Version = '8.9.8' })
$flaggedRecs = @(@{ Type = 'exe'; NoNsis = $true; Key = 'NppPortable'; ProductCodes = @('NppPortable'); DisplayName = 'Npp Portable'; Dir = 'NppPortable'; Main = 'npp.exe'; DefaultInstallLocation = ''; Version = '8.7.9'; Role = 'Floor' },
    @{ Type = 'exe'; NoNsis = $true; Key = 'NppPortable'; ProductCodes = @('NppPortable'); DisplayName = 'Npp Portable'; Dir = 'NppPortable'; Main = 'npp.exe'; DefaultInstallLocation = ''; Version = '8.9.8' })
function Reset-Case { $script:log.Clear(); $script:jsonOk = $true; $script:docOk = $true; $script:preOk = $true; $script:preReasons = @(); $script:preBackend = 'HyperV'; $script:captureThrows = $false; $script:captureWrites = @(); $script:hvNotReady = @(); $script:leaseCfg = 'Off'; $script:failIds = @(); $script:planRuns = 1; $script:captureResult = $true; $script:planProbe = $null; $script:planTypes = @() }
function Invoke-Final([string]$P, [hashtable]$A = @{}) {
    $script:lastResult = Initialize-Win32ToolkitRunResult -Command 'Invoke-Win32Toolkit' -Mode 'Winget'
    $script:lastOut = @(Invoke-Win32ToolkitFinalize -ProjectPath $P -ProjectName (Split-Path $P -Leaf) -Result $script:lastResult @A -WarningVariable w -WarningAction SilentlyContinue 6>&1 | ForEach-Object { "$_" })
    $script:lastWarn = @($w | ForEach-Object { "$_" })
}
function Get-Cfg([string]$P) { Get-Content -LiteralPath (Join-Path $P 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json }
function Add-Applied([string]$P) {
    foreach ($a in $nsisRecs) { $null = Write-TestSiblingRecord -ProjectPath $P -Record (New-TestSiblingRecord @a) }
    $null = Set-Win32ToolkitPriorInstall -ProjectPath $P -FromSiblingCapture -Mode Enforce -ProposalId 'nsis-x64' -Confirm:$false 6>$null
}

try {
    # == [1] the switches ======================================================================================
    Write-Host '[1] the switches' -ForegroundColor Cyan
    $fin = Get-Command Invoke-Win32ToolkitFinalize
    $invText = [IO.File]::ReadAllText((Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1'))
    $vs = { param($Param) @($Param.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues }) -join ',' }
    $invAst = [Management.Automation.Language.Parser]::ParseInput($invText, [ref]$null, [ref]$null)
    $invFn = $invAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Win32Toolkit' }, $true)
    $applyParam = @($invFn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ApplySiblingCapture' })[0]
    $applySet = (@($applyParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0].PositionalArguments | ForEach-Object { $_.Value }) -join ','
    if ($applySet -eq 'None,Block' -and $applyParam.DefaultValue.Value -eq 'None' -and (& $vs $fin.Parameters['ApplySiblingCapture']) -eq 'None,Block' -and $fin.Parameters['CaptureSiblingTechnologies'].SwitchParameter) { Ok '-ApplySiblingCapture is None|Block (default None, no Enforce: D58) in Invoke-Win32Toolkit and Finalize' } else { Bad "sets: $applySet / $(& $vs $fin.Parameters['ApplySiblingCapture'])" }
    $splat = "if (`$CaptureSiblingTechnologies) { `$finalize['CaptureSiblingTechnologies'] = `$true; `$finalize['ApplySiblingCapture'] = `$ApplySiblingCapture }"
    $call = @($invText -split "`n" | Where-Object { $_ -match 'Invoke-Win32ToolkitFinalize @finalize' })
    if ($invText.Contains($splat) -and $call.Count -eq 1 -and $call[0] -notmatch 'Sibling') { Ok 'the Finalize arguments are passed only when the switch is set (a conditional splat; the fixed-parameter shadows keep binding)' } else { Bad 'splat' }
    $iTpl = $invText.IndexOf('$script:OrgTemplate = Get-OrgTemplate'); $iPromise = $invText.IndexOf('Sibling capture: after the install capture'); $iDl = $invText.IndexOf('Download-WingetApp -AppId')
    $promiseAst = $invFn.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$CaptureSiblingTechnologies' -and $n.Extent.Text -match 'Sibling capture:' }, $true)
    if ($iTpl -gt 0 -and $iPromise -gt $iTpl -and $iDl -gt $iPromise -and $promiseAst) { Ok 'the promise line comes right after the template loads, before the download' } else { Bad "order: $iTpl $iPromise $iDl" }
    $runPromise = {
        param([bool]$Switch, [string]$Apply)
        $CaptureSiblingTechnologies = $Switch; $ApplySiblingCapture = $Apply
        $null = $CaptureSiblingTechnologies, $ApplySiblingCapture
        @(& ([scriptblock]::Create($promiseAst.Extent.Text)) 3>&1 6>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { "WARN:$($_.Message)" } else { "$_" } })
    }
    $ready = & $runPromise $true 'None'
    $script:hvNotReady = @('the test VM win32tk-golden does not exist')
    $notReady = & $runPromise $true 'None'
    $script:hvNotReady = @()
    $orphan = & $runPromise $false 'Block'
    if (@($ready | Where-Object { $_ -match '^Sibling capture: after the install capture, each other installer technology .* Hyper-V test VM' }).Count -eq 1 -and @($notReady | Where-Object { $_ -match '^WARN:Sibling capture: Hyper-V is not ready \(the test VM win32tk-golden does not exist\): the other installer technologies are captured in Windows Sandbox as a user and can only give Block-only proposals; a project whose earlier captures allow an Enforce rule is not captured there \(that would make them Block-only\)\.$' }).Count -eq 1 -and @($orphan | Where-Object { $_ -match '^WARN:-ApplySiblingCapture Block has no effect without -CaptureSiblingTechnologies: ignored' }).Count -eq 1) {
        Ok 'the promise: Hyper-V ready -> what will happen; not ready -> Windows Sandbox, Block-only, said before the download (SV28); -ApplySiblingCapture alone -> one warning, ignored'
    } else { Bad "promise: $($ready -join ' | ') // $($notReady -join ' | ') // $($orphan -join ' | ')" }

    # == [2] the order ==========================================================================================
    Write-Host '[2] the order, the lease, None' -ForegroundColor Cyan
    Reset-Case
    $p = New-PProject 'order'
    $script:leaseCfg = 'On'
    $script:captureWrites = $nsisRecs
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
    $seq = $script:log -join '>'
    if ($seq -ceq 'assert:Finalize>document>process>lease:enter:test>preflight:HyperV>plan>capture:HyperV>raise>lease:exit>test:InstallUninstall') { Ok 'after the processed install capture, under the per-project lease, before the tests: pre-flight (Hyper-V), plan, capture, raise' } else { Bad "order: $seq" }
    $cfg = Get-Cfg $p
    $unapplied = @($script:lastOut | Where-Object { $_ -match "^Sibling capture: the sibling-capture proposal 'nsis-x64' .*-FromSiblingCapture -Mode Block -ProposalId nsis-x64" })
    if (-not $cfg.PSObject.Properties['PriorInstalls'] -and $unapplied.Count -eq 1 -and $script:lastResult.Problems.Count -eq 0) { Ok '-ApplySiblingCapture None: nothing written; the proposal printed with its exact command' } else { Bad "none: $($cfg.PriorInstalls | ConvertTo-Json -Compress) / $($unapplied.Count) / $($script:lastResult.Problems -join ' | ')" }
    Reset-Case
    $p = New-PProject 'nolease'
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true }
    if (@($script:log | Where-Object { $_ -like 'lease:*' }).Count -eq 0 -and $script:log -contains 'capture:HyperV') { Ok 'TestProjectLease Off -> no lease taken' } else { Bad "nolease: $($script:log -join '>')" }
    Reset-Case
    $p = New-PProject 'noswitch'
    Invoke-Final $p @{ RunTest = @('InstallUninstall') }
    if (($script:log -join '>') -ceq 'assert:Finalize>document>process>test:InstallUninstall') { Ok 'no switch and no unproven rule -> nothing of the prior-install step runs' } else { Bad "noswitch: $($script:log -join '>')" }

    # == [3] no capture ===========================================================================================
    Write-Host '[3] the capture is skipped, the pipeline goes on' -ForegroundColor Cyan
    Reset-Case
    $p = New-PProject 'stateerr'
    $realState = ${function:Get-Win32ToolkitPriorProofState}
    function Get-Win32ToolkitPriorProofState { param($ProjectPath) $null = $ProjectPath; throw 'AppConfig.json is locked' }
    $threw = $null
    try { Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') } } catch { $threw = $_ }
    ${function:Get-Win32ToolkitPriorProofState} = $realState
    if (-not $threw -and @($script:log | Where-Object { $_ -like 'preflight*' -or $_ -like 'capture*' }).Count -eq 0 -and $script:log -contains 'test:InstallUninstall' -and @($script:lastResult.Problems | Where-Object { $_ -match '^The prior-install rules could not be read \(AppConfig\.json is locked\)' }).Count -eq 1) {
        Ok 'an unreadable rule state -> one Problems sentence, no capture, the tests still run (never a throw)'
    } else { Bad "state error: threw=$threw $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }
    # Readable before the capture, unreadable when Finalize reads it again after the capture (its second own call).
    Reset-Case
    $p = New-PProject 'stateerr2'
    $script:captureWrites = $nsisRecs
    $script:finStateReads = 0
    function Get-Win32ToolkitPriorProofState {
        param($ProjectPath)
        if ((Get-PSCallStack)[1].Command -eq 'Invoke-Win32ToolkitFinalize') {
            $script:finStateReads++
            if ($script:finStateReads -ge 2) { throw 'AppConfig.json is locked' }
        }
        & $realState -ProjectPath $ProjectPath
    }
    $threw = $null
    try { Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') } } catch { $threw = $_ }
    ${function:Get-Win32ToolkitPriorProofState} = $realState
    $after = @($script:lastResult.Problems | Where-Object { $_ -ceq 'The prior-install rules could not be read after the capture (AppConfig.json is locked): no proof or demotion ran.' })
    if (-not $threw -and $script:finStateReads -eq 2 -and $script:log -contains 'capture:HyperV' -and $script:log -contains 'raise' -and $script:log -contains 'test:InstallUninstall' -and $after.Count -eq 1 -and @($script:lastResult.Problems).Count -eq 1) {
        Ok 'unreadable only after the capture -> the capture ran; one sentence says no proof or demotion ran; the tests still run'
    } else { Bad "state error after capture: threw=$threw reads=$($script:finStateReads) $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }
    Reset-Case
    $p = New-PProject 'nojson'
    $script:jsonOk = $false
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
    if (@($script:log | Where-Object { $_ -like 'preflight*' -or $_ -like 'capture*' }).Count -eq 0 -and $script:log -contains 'test:InstallUninstall' -and @($script:lastResult.Problems | Where-Object { $_ -match 'not captured: the install capture did not complete' }).Count -eq 1) { Ok 'the install capture was not processed -> no pre-flight, one Problems sentence, the tests still run' } else { Bad "nojson: $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }
    foreach ($c in @(
            @{ L = 'no OwnIdentity'; R = "the package's own identity is not recorded: run the install capture first (Finalize)" }
            @{ L = 'an arm64 package'; R = "the package architecture is 'arm64': an ARM64 sibling cannot be installed on the x64 test VM" }
            @{ L = 'Hyper-V not ready'; R = 'Hyper-V is not ready (the test VM win32tk-golden does not exist): this win32-toolkit version captures the other installer technologies on the Hyper-V test VM only' }
        )) {
        Reset-Case
        $p = New-PProject ('pre' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:preOk = $false; $script:preReasons = @($c.R)
        $threw = $null
        try { Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') } } catch { $threw = $_ }
        $prob = @($script:lastResult.Problems | Where-Object { $_ -eq "The other installer technologies were not captured: $($c.R)." })
        if (-not $threw -and $prob.Count -eq 1 -and @($script:log | Where-Object { $_ -like 'capture*' -or $_ -eq 'plan' -or $_ -eq 'raise' }).Count -eq 0 -and $script:log -contains 'test:InstallUninstall') { Ok "the pre-flight refuses ($($c.L)) -> one Problems sentence, no capture, no throw, the tests run" } else { Bad "$($c.L): threw=$threw $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }
    }
    Reset-Case
    $p = New-PProject 'tamper'
    $script:leaseCfg = 'On'; $script:captureThrows = $true
    $fq = ''
    try { Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') } } catch { $fq = $_.FullyQualifiedErrorId }
    if ($fq -eq 'W32T.GuestTamper' -and $script:log -notcontains 'test:InstallUninstall' -and $script:log[-1] -eq 'lease:exit') { Ok 'W32T.GuestTamper still aborts the run (no test runs; the lease is released)' } else { Bad "tamper: '$fq' $($script:log -join '>')" }
    # Live rows RAISE, INNO: nothing planned because the winget manifests could not be read ($false, no capture run, no
    # index written) is its own sentence; "every capture failed (... SiblingCapture.json lists why)" is for runs that failed.
    # The sentence follows the plan's causes: Transient (later), Permanent (capturing again does not help), WingetList.
    foreach ($c in @(
            @{ Runs = 0; L = 'nothing planned, Transient'; Probe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'RateLimited'; Cause = 'Transient' }; Types = @(); Rx = "^The other installer technologies were not captured: their winget manifests could not be read \(the warning above says why and when\)\. Capture them again later: Test-Win32ToolkitProject -ProjectPath '.+' -Scenario SiblingCapture\.$" }
            @{ Runs = 0; L = 'nothing planned, the package manifest gone (Permanent)'; Probe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'NotFound'; Cause = 'Permanent' }; Types = @(); Rx = "^The other installer technologies were not captured: their winget manifests could not be used \(the warning above says why\); capturing again will not change that: check the project's winget id and version\.$" }
            @{ Runs = 0; L = 'nothing planned, the winget version list failed (WingetList)'; Probe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; Cause = '' }; Types = @([pscustomobject]@{ Type = 'nullsoft'; ProbeFailed = $true; ProbeCause = 'WingetList' }); Rx = "^The other installer technologies were not captured: the app's winget versions could not be listed \(the warning above says why\)\. Check winget on this computer, then capture them again: Test-Win32ToolkitProject -ProjectPath '.+' -Scenario SiblingCapture\.$" }
            @{ Runs = 0; L = 'nothing planned, Permanent + WingetList types (capturing again can help)'; Probe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; Cause = '' }; Types = @([pscustomobject]@{ Type = 'exe'; ProbeFailed = $true; ProbeCause = 'Permanent' }, [pscustomobject]@{ Type = 'nullsoft'; ProbeFailed = $true; ProbeCause = 'WingetList' }); Rx = "^The other installer technologies were not captured: the app's winget versions could not be listed .+ Check winget on this computer, then capture them again: .+\.$" }
            @{ Runs = 0; L = 'nothing planned, Permanent + Transient types (capturing again can help)'; Probe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; Cause = '' }; Types = @([pscustomobject]@{ Type = 'exe'; ProbeFailed = $true; ProbeCause = 'Permanent' }, [pscustomobject]@{ Type = 'inno'; ProbeFailed = $true; ProbeCause = 'Transient' }); Rx = "^The other installer technologies were not captured: their winget manifests could not be read \(the warning above says why and when\)\. Capture them again later: .+\.$" }
            @{ Runs = 0; L = 'nothing planned, only a Permanent type (no package-id hint)'; Probe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; Cause = '' }; Types = @([pscustomobject]@{ Type = 'exe'; ProbeFailed = $true; ProbeCause = 'Permanent' }); Rx = "^The other installer technologies were not captured: their winget manifests could not be used \(the warning above says why\); capturing again will not change that\.$" }
            @{ Runs = 0; L = 'nothing planned, a Permanent type next to a ReportOnly type that was not probed'; Probe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; Cause = '' }; Types = @([pscustomobject]@{ Type = 'msi'; Class = 'ReportOnly'; ProbeFailed = $false; ProbeCause = '' }, [pscustomobject]@{ Type = 'inno'; Class = 'RemovableNow'; ProbeFailed = $true; ProbeCause = 'Permanent' }); Rx = "^The other installer technologies were not captured: their winget manifests could not be used \(the warning above says why\); capturing again will not change that\.$" }
            @{ Runs = 2; L = 'every planned capture failed'; Probe = $null; Types = @(); Rx = '^Every capture of the other installer technologies failed \(Documentation\\SiblingCapture\.json lists why\): no new proposal\.$' })) {
        Reset-Case
        $p = New-PProject ('unread' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:captureResult = $false; $script:planRuns = $c.Runs; $script:planProbe = $c.Probe; $script:planTypes = $c.Types
        Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
        if (@($script:lastResult.Problems | Where-Object { $_ -match $c.Rx }).Count -eq 1 -and @($script:lastResult.Problems).Count -eq 1 -and $script:log -contains 'test:InstallUninstall') {
            Ok "the capture returned `$false, $($c.L) (EstimatedRuns $($c.Runs)) -> its own Problems sentence; the tests still run"
        } else { Bad "$($c.L): $($script:lastResult.Problems -join ' | ') / $($script:log -join '>')" }
    }
    # The Finalize retry command parses back to the exact project path: ' and U+2019 (a PowerShell quote that
    # Sanitize-ProjectName keeps) in a name over 64 characters, in both sentences that carry it; a bidi override (U+202E)
    # reads '?'.
    foreach ($kc in @(
            @{ L = 'Transient'; Lead = 'Capture them again later: '; Probe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'RateLimited'; Cause = 'Transient' }; Types = @() },
            @{ L = 'WingetList'; Lead = 'capture them again: '; Probe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; Cause = '' }; Types = @([pscustomobject]@{ Type = 'nullsoft'; ProbeFailed = $true; ProbeCause = 'WingetList' }) })) {
        Reset-Case
        $p = New-PProject ("unread$([char]0x2019)q'x" + ('z' * 80) + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:captureResult = $false; $script:planRuns = 0; $script:planProbe = $kc.Probe; $script:planTypes = $kc.Types
        Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
        $s = [string](@($script:lastResult.Problems) | Where-Object { $_.Contains($kc.Lead) } | Select-Object -First 1)
        $cmd = if ($s) { $s.Substring($s.IndexOf($kc.Lead) + $kc.Lead.Length) -replace '\.$', '' } else { '' }
        $e = $null; $ast = [System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$e)
        $ca = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $val = $null
        if ($ca.Count -eq 1) { $els = @($ca[0].CommandElements); for ($j = 0; $j -lt $els.Count - 1; $j++) { if ($els[$j] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$j].ParameterName -eq 'ProjectPath') { $val = $els[$j + 1].SafeGetValue() } } }
        if ($s -and @($e).Count -eq 0 -and @($ast.EndBlock.Statements).Count -eq 1 -and $ca.Count -eq 1 -and $val -ceq $p -and $p.Length -gt 128) { Ok "nothing planned ($($kc.L)): the retry command parses back to the exact $($p.Length)-character project path (' and U+2019 in it)" } else { Bad "retry command ($($kc.L)): errors $(@($e).Count) statements $(@($ast.EndBlock.Statements).Count) value [$val] path [$p]" }
    }
    Reset-Case
    $p = New-PProject ("unread$([char]0x202E)rtl" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $script:captureResult = $false; $script:planRuns = 0; $script:planProbe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'RateLimited'; Cause = 'Transient' }; $script:planTypes = @()
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
    $s = [string](@($script:lastResult.Problems) | Where-Object { $_ -match 'Capture them again later: ' } | Select-Object -First 1)
    if ($s -and -not $s.Contains([string][char]0x202E) -and $s.Contains('unread?rtl')) { Ok 'nothing planned: a U+202E in the project path reads ? in the retry command' } else { Bad "bidi in path: [$s]" }
    # Without a ready VM the pre-flight resolves Windows Sandbox. A Sandbox record joins the records of the identity it
    # sees and makes it Block-only, so a project whose captures already allow an Enforce rule is not captured there.
    $sandboxRec = @(@{ Version = '8.6.0'; Role = 'Extra'; Backend = 'Sandbox' })
    $skipRx = '^The other installer technologies were not captured: the Hyper-V test VM is not ready, and a capture in Windows Sandbox would make '
    Reset-Case
    $p = New-PProject 'sbeligible'
    foreach ($a in $nsisRecs) { $null = Write-TestSiblingRecord -ProjectPath $p -Record (New-TestSiblingRecord @a) }
    $script:preBackend = 'Sandbox'; $script:captureWrites = $sandboxRec
    $threw = $null
    try { Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') } } catch { $threw = $_ }
    $sb = @($script:lastResult.Problems | Where-Object { $_ -match ($skipRx + 'nsis-x64 Block-only .*-Scenario SiblingCapture -Backend Sandbox\.$') })
    $still = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $p).Proposals | Where-Object { $_.ProposalId -eq 'nsis-x64' -and $_.EnforceEligible })
    if (-not $threw -and $sb.Count -eq 1 -and @($script:log | Where-Object { $_ -like 'capture*' -or $_ -eq 'plan' -or $_ -eq 'raise' }).Count -eq 0 -and $still.Count -eq 1 -and $script:log -contains 'test:InstallUninstall') {
        Ok 'Sandbox only + an Enforce-eligible proposal -> no capture (it would make nsis-x64 Block-only), one Problems sentence, the proposal stays eligible, the tests run'
    } else { Bad "sandbox eligible: threw=$threw $($script:log -join '>') / $($script:lastResult.Problems -join ' | ') / eligible=$($still.Count)" }
    Reset-Case
    $p = New-PProject 'sbrule'
    Add-Applied $p
    $script:preBackend = 'Sandbox'; $script:captureWrites = $sandboxRec
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
    if (@($script:lastResult.Problems | Where-Object { $_ -match ($skipRx + [regex]::Escape('nsis-x64 (Enforce rule nsis-x64) Block-only')) }).Count -eq 1 -and @($script:log | Where-Object { $_ -like 'capture*' }).Count -eq 0) {
        Ok 'Sandbox only + a captured Enforce rule -> no capture; the sentence names the rule'
    } else { Bad "sandbox rule: $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }
    Reset-Case
    $p = New-PProject 'sbfirst'
    $script:preBackend = 'Sandbox'; $script:captureWrites = $nsisRecs
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
    if ($script:log -contains 'capture:Sandbox' -and $script:log -contains 'raise' -and @($script:lastResult.Problems | Where-Object { $_ -match $skipRx }).Count -eq 0) {
        Ok 'Sandbox only + nothing an Enforce rule can use yet -> the capture runs in Windows Sandbox as before'
    } else { Bad "sandbox first: $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }
    # The skip is for Windows Sandbox only: a ready VM captures over an Enforce-eligible proposal.
    Reset-Case
    $p = New-PProject 'hveligible'
    foreach ($a in $nsisRecs) { $null = Write-TestSiblingRecord -ProjectPath $p -Record (New-TestSiblingRecord @a) }
    $script:captureWrites = @(@{ Version = '8.9.9'; Role = 'Newest' })
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
    $hvProp = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $p).Proposals | Where-Object { $_.ProposalId -eq 'nsis-x64' })[0]
    if (($script:log -join '>') -match 'preflight:HyperV>plan>capture:HyperV>raise>' -and @($script:lastResult.Problems).Count -eq 0 -and $hvProp.EnforceEligible -and $hvProp.VersionMax -ceq '8.9.9.0') {
        Ok 'a ready Hyper-V VM + an Enforce-eligible proposal -> captured on Hyper-V, no Problems sentence; the proposal stays eligible (8.9.9.0)'
    } else { Bad "hyper-v eligible: $($script:log -join '>') / $($script:lastResult.Problems -join ' | ') / $($hvProp.VersionMax) $($hvProp.EnforceEligible)" }
    # Only Enforce rules and Enforce-eligible proposals count: a Block or Report rule of a proposal that can never be
    # Enforce (GenericExe) costs nothing, so the capture runs in Windows Sandbox.
    foreach ($mode in 'Block', 'Report') {
        Reset-Case
        $p = New-PProject ("sbonly$mode")
        foreach ($a in $flaggedRecs) { $null = Write-TestSiblingRecord -ProjectPath $p -Record (New-TestSiblingRecord @a) }
        $null = Set-Win32ToolkitPriorInstall -ProjectPath $p -FromSiblingCapture -Mode $mode -ProposalId 'exe-x64' -Confirm:$false 6>$null
        $impact = @(Get-Win32ToolkitSiblingSandboxImpact -ProjectPath $p)
        $script:preBackend = 'Sandbox'
        Invoke-Final $p @{ CaptureSiblingTechnologies = $true; RunTest = @('InstallUninstall') }
        $rule = @((Get-Cfg $p).PriorInstalls.Entries | Where-Object Id -ceq 'exe-x64')[0]
        if ($rule.Mode -ceq $mode -and $impact.Count -eq 0 -and $script:log -contains 'capture:Sandbox' -and @($script:lastResult.Problems | Where-Object { $_ -match $skipRx }).Count -eq 0) {
            Ok "Sandbox only + a $mode rule of an ineligible proposal (GenericExe) -> nothing named, captured in Windows Sandbox"
        } else { Bad "sandbox $mode rule: impact=$($impact -join ', ') $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }
    }

    # == [4] Block ================================================================================================
    Write-Host '[4] -ApplySiblingCapture Block' -ForegroundColor Cyan
    Reset-Case
    $p = New-PProject 'block'
    $script:captureWrites = @($nsisRecs) + @($flaggedRecs)
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; ApplySiblingCapture = 'Block' }
    $cfg = Get-Cfg $p
    $ids = (@($cfg.PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ','
    if ($ids -ceq 'nsis-x64=Block' -and ($script:log -join '>') -match 'capture:HyperV>raise$' -and @($script:lastOut | Where-Object { $_ -match 'not applied: exe-x64 .*flags: GenericExe' }).Count -eq 1) { Ok 'only the High flag-free proposal became a Block rule (after the raise); the flagged one listed, never written' } else { Bad "block: $ids / $($script:log -join '>')" }
    # B27: the bulk Block never rewrites an existing rule of the same identity (here an approved Enforce rule, then proven).
    Reset-Case
    $p = New-PProject 'blockkeep'
    Add-Applied $p
    $script:captureWrites = @(@{ Version = '8.9.9'; Role = 'Newest' })
    Invoke-Final $p @{ CaptureSiblingTechnologies = $true; ApplySiblingCapture = 'Block'; RunTest = @('Update') }
    $ids = (@((Get-Cfg $p).PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ','
    if ($ids -ceq 'nsis-x64=Enforce' -and $script:log -contains 'proof:nsis-x64') { Ok '-ApplySiblingCapture Block keeps an existing Enforce rule of the same identity (B27); its proof runs' } else { Bad "block keep: $ids / $($script:log -join '>')" }
    # The next-version flow of the goal: a ready VM captures over a captured Enforce rule (the Windows Sandbox skip is for
    # a VM that is not ready only), and the newer capture raises the rule's VersionMax (D61).
    $keep = @((Get-Cfg $p).PriorInstalls.Entries | Where-Object Id -ceq 'nsis-x64')[0]
    if (($script:log -join '>') -match 'preflight:HyperV>plan>capture:HyperV>raise>' -and $keep.VersionMax -ceq '8.9.9.0' -and @($script:lastResult.Problems | Where-Object { $_ -match $skipRx }).Count -eq 0) {
        Ok 'a ready Hyper-V VM + a captured Enforce rule -> captured on Hyper-V (no Windows Sandbox skip), VersionMax raised to 8.9.9.0'
    } else { Bad "hyper-v over an Enforce rule: $($script:log -join '>') / VersionMax=$($keep.VersionMax) / $($script:lastResult.Problems -join ' | ')" }

    # == [5] proof and demotion ===================================================================================
    Write-Host '[5] proof and demotion (L37)' -ForegroundColor Cyan
    Reset-Case
    $p = New-PProject 'proof'
    Add-Applied $p
    Invoke-Final $p @{ RunTest = @('InstallUninstall', 'Update'); UpdateVersionsBack = 2 }
    $seq = $script:log -join '>'
    $tests = (@($script:lastResult.Tests) | ForEach-Object { "$($_.Scenario)=$($_.Verdict)" }) -join ','
    if ($seq -ceq 'assert:Finalize>document>process>proof:nsis-x64>test:InstallUninstall' -and $tests -ceq 'Update=Passed,InstallUninstall=Passed' -and @($script:lastOut | Where-Object { $_ -match '^Note: -UpdateVersionsBack, -UpdateSpecificVersion and -UpdateBaselineInstallerType apply only to the generic Update test' }).Count -eq 1) {
        Ok 'an unproven Enforce rule + -RunTest Update -> the proof run replaces the generic Update run (Update=Passed); the baseline options get one note'
    } else { Bad "proof: $seq / $tests" }
    if (@(Get-Win32ToolkitPriorProofState -ProjectPath $p | Where-Object { $_.Id -eq 'nsis-x64' -and $_.State -eq 'Proven' }).Count -eq 1) { Ok 'the rule ends Proven' } else { Bad 'not proven' }
    Reset-Case
    $p = New-PProject 'demote'
    Add-Applied $p
    $script:failIds = @('nsis-x64')
    Invoke-Final $p @{ RunTest = @('Update') }
    $cfg = Get-Cfg $p
    $ap = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $p | Where-Object { $_.Kind -eq 'Approval' -and $_.Latest })
    if (@($cfg.PriorInstalls.Entries).Count -eq 0 -and $ap[0].Demoted -and (@($script:lastResult.Tests) | ForEach-Object { "$($_.Scenario)=$($_.Verdict)" }) -join ',' -ceq 'Update=Failed' -and @($script:lastResult.Problems | Where-Object { $_ -match "rule 'nsis-x64' was not proven \(failing assertions: PriorAbsent-PostUpdate\.nsis-x64\) and was demoted" }).Count -eq 1 -and $script:log -notcontains 'test:Update') {
        Ok 'a failing proof -> the captured rule demoted (removed, approval Demoted, named with its failing assertion in Problems); Update=Failed; no generic Update run'
    } else { Bad "demote: $(@($cfg.PriorInstalls.Entries).Count) $($script:lastResult.Problems -join ' | ')" }
    Reset-Case
    $p = New-PProject 'oper'
    $cfg = Get-Cfg $p
    $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject]@{ SchemaVersion = '1.0'; Entries = @([pscustomobject][ordered]@{ Id = 'op-a'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = 'OpA'; View = 'Native'; Publisher = 'Op'; DisplayName = 'OpA'; DisplayNameTemplate = ''
                    VersionMin = '1.0'; VersionMax = '2.0'; UninstallerType = 'inno'; UninstallerFileName = 'u.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Op'; MainExe = 'op.exe'; ProcessNames = @('op'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' }) })
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $script:failIds = @('op-a')
    Invoke-Final $p @{ RunTest = @('Update') }
    if (@((Get-Cfg $p).PriorInstalls.Entries).Count -eq 1 -and @($script:lastResult.Problems | Where-Object { $_ -eq "The Enforce prior-install rule 'op-a' is not proven: Export refuses it until it is proven or waived (-Waive PROOF)." }).Count -eq 1) { Ok 'an operator Enforce rule is never demoted: the -Waive PROOF sentence' } else { Bad "operator: $($script:lastResult.Problems -join ' | ')" }
    Reset-Case
    $p = New-PProject 'noupdate'
    Add-Applied $p
    Invoke-Final $p @{ RunTest = @('InstallUninstall') }
    if (@($script:log | Where-Object { $_ -like 'proof:*' }).Count -eq 0 -and @((Get-Cfg $p).PriorInstalls.Entries).Count -eq 0 -and @($script:lastWarn | Where-Object { $_ -match 'run again with -RunTest Update\. Demoted to proposals: nsis-x64' }).Count -eq 1 -and $script:log -contains 'test:InstallUninstall') { Ok '-RunTest without Update -> no proof run; the captured rule demoted with the -RunTest Update hint' } else { Bad "noupdate: $($script:log -join '>') / $($script:lastWarn -join ' | ')" }
    Reset-Case
    $p = New-PProject 'nohv'
    Add-Applied $p
    $script:hvNotReady = @('the test VM win32tk-golden does not exist')
    Invoke-Final $p @{ RunTest = @('Update') }
    if (@($script:log | Where-Object { $_ -like 'proof:*' }).Count -eq 0 -and $script:log -contains 'test:Update' -and @($script:lastResult.Problems | Where-Object { $_ -match 'could not be proven: Hyper-V is not ready' }).Count -eq 1) { Ok 'Hyper-V not ready -> no proof (the rule demoted), the generic Update run as before' } else { Bad "nohv: $($script:log -join '>') / $($script:lastResult.Problems -join ' | ')" }

    Write-Host '[6] a rebuilt or next version: its Enforce rules run as Block in the install capture (own identity unknown), Enforce again after it' -ForegroundColor Cyan
    # Live rows DEMOTE and RAISE (2026-10-26): the restored/carried Enforce rule reached the install capture without the
    # package's own identity, the capture's deploy script refused it with 69105, so OwnIdentity was never recorded, the
    # sibling capture was skipped and the rule demoted. The capture now sees it as Block (nothing is present on the clean
    # guest); it is Enforce again afterwards, re-checked against the identity the capture recorded.
    $opEntry = { [pscustomobject][ordered]@{ Id = 'nsis-x64'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = 'Notepad++'; View = 'Native'; Publisher = 'Notepad++ Team'; DisplayName = 'Notepad++ (64-bit x64)'; DisplayNameTemplate = ''
            VersionMin = '8.0'; VersionMax = '8.9.8.1'; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Notepad++'; MainExe = 'notepad++.exe'; ProcessNames = @('notepad++'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' } }
    $newRebuilt = {
        param([string]$Name, [switch]$KeepOwn)
        $rp = New-PProject $Name
        $rc = Get-Cfg $rp
        if (-not $KeepOwn) { $rc.PSObject.Properties.Remove('OwnIdentity') }
        $rc | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject]@{ SchemaVersion = '1.0'; Entries = @((& $opEntry)) }) -Force
        [IO.File]::WriteAllText((Join-Path $rp 'SupportFiles\AppConfig.json'), ($rc | ConvertTo-Json -Depth 8), $utf8)
        $rp
    }
    $script:modeAtCapture = ''
    $script:docThrows = $false
    $savedDoc6 = ${function:New-TargetedDocumentation}
    $savedProc6 = ${function:Wait-ForDocumentationAndProcess}
    function New-TargetedDocumentation { param($ProjectPath, $ProjectName, $AppInfo, $Backend, $BasePath) $null = $ProjectName, $AppInfo, $Backend, $BasePath
        $script:modeAtCapture = (@((Get-Cfg $ProjectPath).PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ','
        if ($script:docThrows) { throw 'the capture sandbox could not start' }
        Join-Path $ProjectPath 'Documentation\InstallationChanges_x.json' }
    # The capture records the package's own identity (as Write-Win32ToolkitOwnIdentity does) and re-checks the rules.
    function Wait-ForDocumentationAndProcess { param($ProjectPath, $InstallerType, $ExpectedJsonPath) $null = $InstallerType, $ExpectedJsonPath
        $wc = Get-Cfg $ProjectPath
        $wc | Add-Member -NotePropertyName OwnIdentity -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([pscustomobject]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-27' }) -Force
        [IO.File]::WriteAllText((Join-Path $ProjectPath 'SupportFiles\AppConfig.json'), ($wc | ConvertTo-Json -Depth 8), $utf8)
        $null = Sync-Win32ToolkitPriorInstallOwnIdentity -ProjectPath $ProjectPath
        $true }
    try {
        Reset-Case
        $p = & $newRebuilt 'rebuilt'
        $entry0 = ConvertTo-Json -InputObject @((Get-Cfg $p).PriorInstalls.Entries) -Depth 5 -Compress
        Invoke-Final $p
        $after = (@((Get-Cfg $p).PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ','
        if ($script:modeAtCapture -ceq 'nsis-x64=Block' -and $after -ceq 'nsis-x64=Enforce' -and (ConvertTo-Json -InputObject @((Get-Cfg $p).PriorInstalls.Entries) -Depth 5 -Compress) -ceq $entry0 -and
            (Get-Cfg $p).OwnIdentity.ProductCode -ceq $PC -and @($script:lastResult.Problems | Where-Object { $_ -match 'Block|69105' }).Count -eq 0) {
            Ok 'own identity unknown: the capture sees the rule as Block, it is Enforce again afterwards (the entry byte for byte), the capture recorded OwnIdentity'
        } else { Bad "rebuilt: at capture '$($script:modeAtCapture)', after '$after', problems $($script:lastResult.Problems -join ' | ')" }
        Reset-Case
        $p = & $newRebuilt 'rebuilt-throw'
        $script:docThrows = $true
        $thrown = try { Invoke-Final $p; '' } catch { "$_" }
        $script:docThrows = $false
        $after = (@((Get-Cfg $p).PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ','
        if ($thrown -match 'could not start' -and $script:modeAtCapture -ceq 'nsis-x64=Block' -and $after -ceq 'nsis-x64=Enforce') { Ok 'the capture throws -> the rule is Enforce again before the error leaves Finalize' } else { Bad "throw: '$thrown' after '$after'" }
        Reset-Case
        $p = & $newRebuilt 'own-known' -KeepOwn
        Invoke-Final $p
        if ($script:modeAtCapture -ceq 'nsis-x64=Enforce' -and @($script:lastOut | Where-Object { $_ -match 'run as Block in the install capture' }).Count -eq 0) { Ok 'the own identity is known -> the rule stays Enforce in the capture (nothing set aside)' } else { Bad "own known: at capture '$($script:modeAtCapture)'" }
    }
    finally {
        ${function:New-TargetedDocumentation} = $savedDoc6
        ${function:Wait-ForDocumentationAndProcess} = $savedProc6
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingCapturePipeline tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingCapturePipeline test(s) FAILED." -ForegroundColor Red; exit 1 }
