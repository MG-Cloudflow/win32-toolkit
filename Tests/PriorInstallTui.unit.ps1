<#
    Installer-identity PR 3b, commit P2 (spec 2.18; D24, D57, V15, SV11, SV30): the TUI of prior installs, with Spectre
    shadows that record every prompt (the winget wizard's capture question is in WingetWizardTechnology.unit [10]).

      [1] the review screen (Show-Win32ToolkitSiblingCaptureReview): one card per proposal; Block is the first choice (the
          highlighted default, D57), never Enforce; Enforce is offered only for an Enforce-eligible proposal and a ready
          Hyper-V test VM (else the card says why); a captured
          string reaches the screen escaped (Get-SpectreEscapedText); Skip writes nothing; Block writes a Block rule.
      [2] Enforce from the review: a second confirmation (default No); No writes nothing; Yes writes the rule and its
          approval, then runs the proof loop (Invoke-Win32ToolkitPriorDemotion -Prove) and shows its result (red only when
          this rule was demoted); No shows the card again; a data-losing uninstaller -> the DATA-LOSS acknowledgement; a sibling
          signed by someone else -> the SIGNER-MISMATCH acknowledgement.
      [3] the prior-install screen (Show-Win32ToolkitPriorInstallScreen): the rules table (mode, source, capture and
          approval dates, proof state); declaring from the last Update test lists Block first (V15), Enforce never first;
          prove now runs the loop.
      [4] the project actions list a 'prior' row with the number of rules and how many are proven.

    Run:  pwsh -File Tests\PriorInstallTui.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32pt_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
$golden = [IO.File]::ReadAllText((Join-Path $repo 'Tests\Fixtures\psadt-4.1.8\Invoke-AppDeployToolkit.ps1'), [Text.Encoding]::UTF8)

# ---- Spectre shadows that record ----
function Clear-Host { }
function Write-SpectreRule { param($Title, $Color) $null = $Title, $Color }
$script:hostLines = [System.Collections.Generic.List[string]]::new()
function Write-SpectreHost { param($Message) $script:hostLines.Add([string]$Message) }
$script:panels = [System.Collections.Generic.List[object]]::new()
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) $null = $Border; $script:panels.Add([pscustomobject]@{ Data = [string]$Data; Header = [string]$Header; Color = [string]$Color }) }
function Out-SpectreHost { param([Parameter(ValueFromPipeline)]$InputObject) process { $null = $InputObject } }
function Read-SpectrePause { param($Message, [switch]$AnyKey) $null = $Message, $AnyKey }
function Get-SpectreEscapedText { param($Text) ([string]$Text).Replace('[', '[[').Replace(']', ']]') }
$script:tableRows = [System.Collections.Generic.List[object]]::new()
$script:tableMarkup = [System.Collections.Generic.List[bool]]::new()
function Format-SpectreTable { param([Parameter(ValueFromPipeline)]$InputObject, $Border, $Color, $Title, [switch]$AllowMarkup) begin { $script:tableMarkup.Add([bool]$AllowMarkup) } process { $script:tableRows.Add($InputObject) } }
$script:selections = [System.Collections.Generic.List[object]]::new()
$script:pick = { param($Message, $Choices) $null = $Message; @($Choices)[0] }
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, [switch]$EnableSearch, $PageSize)
    $null = $Color, $EnableSearch, $PageSize
    $labels = @($Choices | ForEach-Object { if ($ChoiceLabelProperty) { [string]$_.$ChoiceLabelProperty } else { [string]$_ } })
    $keys = @($Choices | ForEach-Object { if ($_.PSObject.Properties['Key']) { [string]$_.Key } else { [string]$_ } })
    $script:selections.Add([pscustomobject]@{ Message = [string]$Message; Labels = $labels; Keys = $keys })
    & $script:pick ([string]$Message) @($Choices)
}
$script:confirms = [System.Collections.Generic.List[object]]::new()
$script:confirmYes = $false
function Read-SpectreConfirm { param($Message, $DefaultAnswer) $script:confirms.Add([pscustomobject]@{ Message = [string]$Message; Default = [string]$DefaultAnswer }); [bool]$script:confirmYes }
$script:textAnswer = ''
function Read-SpectreText { param($Message) $null = $Message; $script:textAnswer }
# ---- the rest ----
function Get-AuthenticodeSignature { [CmdletBinding()] param([string]$LiteralPath) $null = $LiteralPath; [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:TestSiblingSigner } } }
$script:hvNotReady = @()
function Test-Win32ToolkitHyperVReady { @($script:hvNotReady) }
$script:demotions = [System.Collections.Generic.List[object]]::new()
$script:demoteResult = $null
function Invoke-Win32ToolkitPriorDemotion { param($ProjectPath, [switch]$Prove, $MaxRounds) $null = $MaxRounds; $script:demotions.Add([pscustomobject]@{ ProjectPath = $ProjectPath; Prove = [bool]$Prove }); if ($script:demoteResult) { return $script:demoteResult }; [pscustomobject]@{ Rounds = 1; Proven = [string[]]@('nsis-x64'); Demoted = @(); Unproven = [string[]]@() } }

$generated = $null
function New-TProject([string]$Name) {
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
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = 'Notepad++'; DisplayName = 'Notepad++'; Version = '8.9.9'; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.msi'; SilentArgs = '' }; ProcessesToClose = @('zeta')
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Architecture = 'x64'; ProductCode = $PC }
        OrgUi = [ordered]@{ Welcome = [ordered]@{ Enabled = $true } }
        OwnIdentity = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $p
}
function Add-Records([string]$P, [hashtable]$A = @{}) {
    foreach ($v in @(@{ Version = '8.7.9'; Role = 'Floor' }, @{ Version = '8.9.8' })) { $x = $A.Clone(); foreach ($k in $v.Keys) { $x[$k] = $v[$k] }; $null = Write-TestSiblingRecord -ProjectPath $P -Record (New-TestSiblingRecord @x) }
}
$genericExe = @{ Type = 'exe'; NoNsis = $true; Key = 'NppPortable'; ProductCodes = @('NppPortable'); DisplayName = 'Npp Portable'; Dir = 'NppPortable'; Main = 'npp.exe'; DefaultInstallLocation = '' }
function Reset-Ui { $script:hostLines.Clear(); $script:panels.Clear(); $script:selections.Clear(); $script:confirms.Clear(); $script:tableRows.Clear(); $script:demotions.Clear(); $script:confirmYes = $false; $script:hvNotReady = @(); $script:textAnswer = '' }
function Get-Cfg([string]$P) { Get-Content -LiteralPath (Join-Path $P 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json }
$cards = { @($script:selections | Where-Object { $_.Message -like 'What should the package do with*' }) }

try {
    # == [1] the review screen ==================================================================================
    Write-Host '[1] the review screen' -ForegroundColor Cyan
    $p = New-TProject 'review'
    Add-Records $p
    Add-Records $p $genericExe
    Reset-Ui
    $script:pick = { param($Message, $Choices) if ($Message -like 'What should the package do with*') { @($Choices | Where-Object Key -eq 'Skip')[0] } else { @($Choices)[0] } }
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $p
    $c = & $cards
    $nsis = @($c | Where-Object { $_.Message -like '*Notepad++?' })[0]; $exe = @($c | Where-Object { $_.Message -like '*NppPortable?' })[0]
    if ($c.Count -eq 2 -and $nsis.Keys[0] -eq 'Block' -and $exe.Keys[0] -eq 'Block' -and $nsis.Labels[0] -like 'Block (recommended)*' -and $nsis.Keys -contains 'Enforce' -and $exe.Keys -notcontains 'Enforce') {
        Ok 'one card per proposal; Block is the first choice (the default, D57); Enforce only for the eligible proposal'
    } else { Bad "cards: $($c | ConvertTo-Json -Compress)" }
    $card = @($script:panels | Where-Object { $_.Header -like 'Proposal nsis-x64*' })[0]
    if ($card.Data -match 'Window       : 8\.7\.9\.0 <= version <= 8\.9\.8\.0' -and $card.Data -match 'Not covered  : devices with a version below 8\.7\.9\.0 keep it next to this package' -and $card.Data -match 'Removal      : uninstall\.exe /S _\?=<its folder>' -and $card.Data -match 'Block   : devices with this nullsoft install FAIL this install \(69101\) until the rule is Enforce') {
        Ok 'the card: the window, the uncovered range, the constant removal command, the device consequence of each choice (SV30)'
    } else { Bad "card: $($card.Data)" }
    $exeCard = @($script:panels | Where-Object { $_.Header -like 'Proposal exe-x64*' })[0]
    if ($exeCard.Data -match 'Enforce      : not offered \(GenericExe:') { Ok 'an ineligible proposal says why Enforce is not offered' } else { Bad "exe card: $($exeCard.Data)" }
    if (-not (Get-Cfg $p).PSObject.Properties['PriorInstalls']) { Ok 'Skip writes nothing' } else { Bad 'skip wrote' }
    # Hyper-V not ready: an Enforce rule could not be proven (it would be demoted at once), so Enforce is not offered.
    Reset-Ui
    $script:hvNotReady = @('the test VM win32tk-golden does not exist')
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $p
    $nr = @(& $cards | Where-Object { $_.Message -like '*Notepad++?' })[0]
    $nrCard = @($script:panels | Where-Object { $_.Header -like 'Proposal nsis-x64*' })[0]
    if ($nr.Keys -notcontains 'Enforce' -and $nr.Keys[0] -eq 'Block' -and $nrCard.Data -match 'Enforce      : not offered now: the Hyper-V test VM is not ready \(the test VM win32tk-golden does not exist\)' -and $nrCard.Data -notmatch 'Enforce : the package runs') {
        Ok 'Hyper-V not ready -> no Enforce choice on an eligible proposal; the card says why'
    } else { Bad "not ready: $($nr | ConvertTo-Json -Compress) / $($nrCard.Data)" }
    $ph = New-TProject 'hostile'
    Add-Records $ph @{ Key = 'Npp[red]X'; ProductCodes = @('Npp[red]X'); DisplayName = 'Npp [blink]'; Publisher = 'Evil [bold]Co' }
    Reset-Ui
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $ph
    $hc = @($script:panels | Where-Object { $_.Header -like 'Proposal *' })[0]
    if ($hc.Header -match 'Npp\[\[red\]\]X' -and $hc.Data -match 'Npp\[\[red\]\]X' -and $hc.Data -match 'Evil \[\[bold\]\]Co' -and $hc.Data -notmatch 'Npp\[red\]' -and @(& $cards)[0].Message -match 'Npp\[\[red\]\]X') { Ok 'captured strings reach the screen escaped (Get-SpectreEscapedText): the card, its header and the question' } else { Bad "hostile: $($hc.Header) / $($hc.Data)" }
    Reset-Ui
    $script:pick = { param($Message, $Choices) @($Choices)[0] }
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $p
    $ids = (@((Get-Cfg $p).PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ','
    if ($ids -ceq 'exe-x64=Block,nsis-x64=Block') { Ok 'Block (the first choice) on both cards -> two Block rules' } else { Bad "block: $ids" }

    # == [2] Enforce from the review =============================================================================
    Write-Host '[2] Enforce from the review' -ForegroundColor Cyan
    $pe = New-TProject 'enforce'
    Add-Records $pe
    Reset-Ui
    # Enforce, then No at the confirmation: the same card comes back (Block first); Skip on it ends the review.
    $script:cardShown = 0
    $script:pick = { param($Message, $Choices) if ($Message -like 'What should the package do with*') { $script:cardShown++; $k = if ($script:cardShown -eq 1) { 'Enforce' } else { 'Skip' }; @($Choices | Where-Object Key -eq $k)[0] } else { @($Choices)[0] } }
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $pe
    $cf = @($script:confirms)
    $again = @(& $cards)
    if ($cf.Count -eq 1 -and $cf[0].Message -match '^Remove Notepad\+\+ as SYSTEM on every device before installing\?' -and $cf[0].Default -eq 'n' -and -not (Get-Cfg $pe).PSObject.Properties['PriorInstalls'] -and $script:demotions.Count -eq 0) { Ok 'Enforce asks a second confirmation (default No); No writes nothing and proves nothing' } else { Bad "no: $($cf | ConvertTo-Json -Compress)" }
    if ($again.Count -eq 2 -and $again[1].Message -like '*Notepad++?' -and $again[1].Keys[0] -eq 'Block') { Ok 'No at the confirmation shows the same card again, Block first (the proposal is never skipped silently)' } else { Bad "again: $($again | ConvertTo-Json -Compress)" }
    Reset-Ui
    $script:cardShown = 0
    $script:pick = { param($Message, $Choices) if ($Message -like 'What should the package do with*') { $script:cardShown++; $k = if ($script:cardShown -eq 1) { 'Enforce' } else { 'Block' }; @($Choices | Where-Object Key -eq $k)[0] } else { @($Choices)[0] } }
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $pe
    $ids = (@((Get-Cfg $pe).PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ','
    if ($ids -ceq 'nsis-x64=Block' -and @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $pe | Where-Object Kind -eq 'Approval').Count -eq 0 -and $script:demotions.Count -eq 0) { Ok 'Enforce, No, then Block on the card again -> one Block rule, no approval, no proof run' } else { Bad "no then block: $ids" }
    $null = Set-Win32ToolkitPriorInstall -ProjectPath $pe -Remove 'nsis-x64' -Confirm:$false 6>$null
    Reset-Ui
    $script:pick = { param($Message, $Choices) if ($Message -like 'What should the package do with*') { @($Choices | Where-Object Key -eq 'Enforce')[0] } else { @($Choices)[0] } }
    $script:confirmYes = $true
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $pe
    $e = @((Get-Cfg $pe).PriorInstalls.Entries)[0]
    $ap = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $pe | Where-Object Kind -eq 'Approval')
    $proof = @($script:panels | Where-Object Header -eq 'Proof')[0]
    if ($e.Id -eq 'nsis-x64' -and $e.Mode -eq 'Enforce' -and $ap.Count -eq 1 -and $script:demotions.Count -eq 1 -and $script:demotions[0].Prove -and $proof.Data -match '^Proven: nsis-x64 removes Notepad\+\+ before installing\.') {
        Ok 'Yes -> the Enforce rule and its approval, then the proof loop (Invoke-Win32ToolkitPriorDemotion -Prove) and its result'
    } else { Bad "yes: $($e | ConvertTo-Json -Compress) approvals=$($ap.Count) demotions=$($script:demotions.Count) proof=$($proof.Data)" }
    if (@($script:panels | Where-Object Header -eq 'Data loss').Count -eq 0 -and @($script:panels | Where-Object { $_.Header -like 'Proposal nsis-x64*' -and $_.Data -match 'Data loss' }).Count -eq 0) { Ok 'no data loss -> no data-loss line on the card and no acknowledgement question' } else { Bad 'data-loss panel without data loss' }
    if ($proof.Color -eq 'Green') { Ok 'the Proof panel of a proven rule is green' } else { Bad "proof colour: $($proof.Color)" }
    # Another rule demoted in the same loop does not turn this rule's proven result red.
    $pc = New-TProject 'colour'
    Add-Records $pc
    Reset-Ui
    $script:confirmYes = $true
    $script:demoteResult = [pscustomobject]@{ Rounds = 2; Proven = [string[]]@('nsis-x64'); Demoted = @([pscustomobject]@{ Id = 'other-x64'; Reason = 'failing assertions: x' }); Unproven = [string[]]@() }
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $pc
    $script:demoteResult = $null
    $pcProof = @($script:panels | Where-Object Header -eq 'Proof')[0]
    if ($pcProof.Color -eq 'Green' -and $pcProof.Data -match '^Proven: nsis-x64') { Ok 'another rule demoted in the same loop -> this proven rule''s panel stays green' } else { Bad "colour: $($pcProof.Color) $($pcProof.Data)" }

    # A vendor uninstaller that deletes configuration (the capture's probe saw it): the card says so, and after the proof
    # the DATA-LOSS acknowledgement Export needs is asked for, with a reason.
    $pl = New-TProject 'loss'
    Add-Records $pl @{ RootConfigRemoved = $true }
    Reset-Ui
    $script:confirmYes = $true
    $script:textAnswer = 'user settings live in AppData'
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $pl
    $lossCard = @($script:panels | Where-Object { $_.Header -like 'Proposal nsis-x64*' })[0]
    $lossPanel = @($script:panels | Where-Object Header -eq 'Data loss')[0]
    $ack = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $pl | Where-Object { $_.Kind -eq 'Acknowledgement' -and $_.Code -eq 'DATA-LOSS' -and $_.Target -eq 'nsis-x64' })
    $exportLoss = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $pl -Stage Export | Where-Object Code -eq 'PRIOR-DATA-LOSS')
    if ($lossCard.Data -match 'Data loss    : its uninstaller deleted configuration files' -and $lossPanel.Data -match "uninstaller of 'nsis-x64' delete configuration" -and @($script:confirms | Where-Object { $_.Message -like 'Acknowledge that removing Notepad++ deletes*' -and $_.Default -eq 'n' }).Count -eq 1 -and $ack.Count -eq 1 -and $ack[0].Reason -eq 'user settings live in AppData' -and $exportLoss.Count -eq 0) {
        Ok 'data loss: the card says so; after the proof the acknowledgement (default No) is recorded with its reason and Export no longer refuses PRIOR-DATA-LOSS'
    } else { Bad "loss: card=$($lossCard.Data -match 'Data loss') panel=$($lossPanel.Data) ack=$($ack.Count) export=$($exportLoss.Count)" }
    $pl2 = New-TProject 'loss2'
    Add-Records $pl2 @{ RootConfigRemoved = $true }
    Reset-Ui
    $script:confirmYes = $true
    $script:textAnswer = ''
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $pl2
    if (@(Get-Win32ToolkitPriorInstallDecision -ProjectPath $pl2 | Where-Object Kind -eq 'Acknowledgement').Count -eq 0 -and @($script:hostLines | Where-Object { $_ -match 'Not acknowledged: no reason was given' }).Count -eq 1) { Ok 'no reason -> nothing acknowledged, one line says Export refuses it' } else { Bad 'loss without a reason' }
    # A sibling signed by someone else than the package (SignerMismatch is a flag, never an Enforce reason): after the
    # proof the SIGNER-MISMATCH acknowledgement Export needs (PRIOR-SIGNER) is asked for, with a reason.
    $ps = New-TProject 'signer'
    Add-Records $ps @{ InstallerSigner = 'CN=Someone Else'; MainSigner = 'CN=Someone Else' }
    Reset-Ui
    $script:confirmYes = $true
    $script:textAnswer = 'checked the vendor page: the MSI and the NSIS setup are both from Notepad++'
    Show-Win32ToolkitSiblingCaptureReview -ProjectPath $ps
    $sigPanel = @($script:panels | Where-Object Header -eq 'Signer')[0]
    $sigAck = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ps | Where-Object { $_.Kind -eq 'Acknowledgement' -and $_.Code -eq 'SIGNER-MISMATCH' -and $_.Target -eq 'nsis-x64' })
    if ($sigPanel.Data -match "signer of the captured install 'nsis-x64'" -and @($script:confirms | Where-Object { $_.Message -like 'Acknowledge that Notepad++ is the same vendor''s app*' -and $_.Default -eq 'n' }).Count -eq 1 -and $sigAck.Count -eq 1 -and @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $ps -Stage Export | Where-Object Code -eq 'PRIOR-SIGNER').Count -eq 0 -and @($script:panels | Where-Object Header -eq 'Data loss').Count -eq 0) {
        Ok 'signer mismatch: after the proof the SIGNER-MISMATCH acknowledgement (default No) is recorded with its reason; no data-loss question'
    } else { Bad "signer: panel=$($sigPanel.Data) ack=$($sigAck.Count)" }

    # == [3] the prior-install screen ============================================================================
    Write-Host '[3] the prior-install screen' -ForegroundColor Cyan
    Reset-Ui
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($k in 'candidates', 'Block', 'prove', 'back') { $queue.Enqueue($k) }
    $script:pick = { param($Message, $Choices) $want = $queue.Dequeue(); @($Choices | Where-Object { $_.PSObject.Properties['Key'] -and $_.Key -eq $want })[0] }
    $cand = [ordered]@{ SchemaVersion = '1.0'; Baseline = [ordered]@{ Version = '8.8.9'; InstallerType = 'nullsoft' }; Candidates = @([ordered]@{ ProposedId = 'nsis-x86'; Confidence = 'High'; Key = 'NppOld'; View = 'Wow6432'; Publisher = 'Npp'
                DisplayName = 'Npp Old'; DisplayNameTemplate = ''; ObservedVersion = '8.8.9'; WindowsInstaller = $false; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; InstallDir = '%ProgramFiles(x86)%\NppOld'; MainExe = 'npp.exe'; ProcessNames = @('npp') }) }
    [IO.File]::WriteAllText((Join-Path $pe 'Documentation\PriorInstallCandidates.json'), ($cand | ConvertTo-Json -Depth 6), $utf8)
    Show-Win32ToolkitPriorInstallScreen -ProjectPath $pe
    $modeQ = @($script:selections | Where-Object { $_.Message -like 'Declare the High candidate*' })[0]
    $rows = @($script:tableRows)
    $nsisRow = @($rows | Where-Object Id -eq 'nsis-x64')[0]
    if ($modeQ.Keys[0] -eq 'Block' -and $modeQ.Keys[-1] -eq 'Enforce' -and @((Get-Cfg $pe).PriorInstalls.Entries | Where-Object { $_.Id -eq 'nsis-x86' -and $_.Mode -eq 'Block' -and $_.Source -eq 'UpdateTest' }).Count -eq 1) {
        Ok 'declare from the last Update test: Block listed first (V15), Enforce last; the rule written as Block'
    } else { Bad "candidates: $($modeQ | ConvertTo-Json -Compress)" }
    if ($nsisRow -and $nsisRow.Mode -eq 'Enforce' -and $nsisRow.Source -eq 'SiblingCapture' -and $nsisRow.Approved -match '^\d{4}-\d{2}-\d{2}$' -and $nsisRow.Proof -eq 'NotProven') { Ok 'the table: mode, source, the approval date and the proof state per rule' } else { Bad "rows: $($rows | ConvertTo-Json -Compress)" }
    # Live row TUI (2026-10-26): the escaped cells were rendered as plain text, so every bracket showed doubled ('Notepad++ [[Native]]').
    if ($script:tableMarkup.Count -ge 1 -and @($script:tableMarkup | Where-Object { -not $_ }).Count -eq 0 -and $nsisRow.Key -ceq 'Notepad++ [[Native]]') { Ok 'the table renders its escaped cells as markup (-AllowMarkup): [Native] shows once' } else { Bad "markup: $($script:tableMarkup -join ',') key=$($nsisRow.Key)" }
    if ($script:demotions.Count -eq 1 -and $script:demotions[0].Prove -and @($script:panels | Where-Object { $_.Header -eq 'Proof' -and $_.Data -match '^Proven: nsis-x64' }).Count -eq 1) { Ok 'prove now -> the proof loop and its result' } else { Bad "prove: $($script:demotions.Count)" }

    # == [4] the project actions row ==============================================================================
    Write-Host '[4] the project actions list the prior-install rules' -ForegroundColor Cyan
    Reset-Ui
    function Get-PSADTProjects { param($BasePath) $null = $BasePath; @([pscustomobject]@{ Template = 'T'; Name = 'enforce'; Path = $pe }) }
    function Get-Win32ToolkitDependencies { [CmdletBinding()] param($ProjectPath) $null = $ProjectPath; @() }
    function Get-Win32ToolkitBackendInfo { [pscustomobject]@{ Label = 'Windows Sandbox'; Resolved = 'Sandbox'; FellBack = $false; Reasons = @() } }
    $script:pick = { param($Message, $Choices) if ($Message -eq 'What would you like to do?') { @($Choices | Where-Object Key -eq 'back')[0] } else { @($Choices)[0] } }
    Show-Win32ToolkitProjectActions -BasePath $root
    $menu = @($script:selections | Where-Object { $_.Message -eq 'What would you like to do?' })[0]
    $row = @($menu.Labels | Where-Object { $_ -like 'Prior installs*' })
    if ($row.Count -eq 1 -and $row[0] -eq 'Prior installs - other technologies removed before install (2 rules, 0 proven)' -and $menu.Keys -contains 'prior') { Ok "the 'prior' row: $($row[0])" } else { Bad "menu: $($menu.Labels -join ' | ')" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorInstallTui tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorInstallTui test(s) FAILED." -ForegroundColor Red; exit 1 }
