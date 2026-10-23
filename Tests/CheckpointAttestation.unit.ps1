<#
    Hyper-V speed-up PR 1 (D34, A-4, A-8, V-1, V-9, V-10, V-11): the per-checkpoint attestation and its advisories.

      [1] Get-Win32ToolkitCheckpointAttestation: a miss with -AllowLive asks the guest twice (sign-in, then Defender:
          the real Defender scriptblock runs locally against shadowed Get-MpComputerStatus / Get-MpPreference) and
          stores the answer; a hit asks nothing (FromCache $true); -SignedInAnswer saves the sign-in call; -AllowLive
          off returns $null with no guest call.
      [2] What it reads: real-time off, one exclusion, 40-day-old signatures are returned as read; Defender's
          'N/A: Must be an administrator' placeholder, a throw, a partial answer, an unreadable sign-in answer -> $null
          (fail-open); a signature age of 65535 or 9999 -> SignatureAgeDays $null, nothing stored, the next call asks again.
      [3] The cache: any identity mismatch, another AttestVersion, and a stored ProbeVersion that differs while the
          AttestVersion matches (V-9) -> asked again; a malformed value -> a miss; -AllowStore with a VM console attached
          at store time (V-10), no -AllowStore, an unknown identity -> nothing stored.
      [4] The guest scriptblock (C-6): Windows PowerShell 5.1 parse, ASCII, first statement $ErrorActionPreference =
          'Stop', every other assigned variable $w32t*, no -ArgumentList; the version tripwires (V-9): the SHA256 of the
          whole Get-Win32ToolkitCheckpointAttestation and Get-Win32ToolkitGuestSignedInUser definitions (line endings
          normalised) are pinned.
      [5] Write-Win32ToolkitCheckpointAdvisory: one warning per kind and key per process, emits nothing (V-1).
      [6] File hygiene of both files: ASCII, one function, every catch starts with the C-2 line.

    The real HKCU is never touched (Get-/Set-Win32ToolkitConfigValue shadowed by an in-memory store); no guest, no CIM.
    Needs Windows PowerShell 5.1 for the parse check (exit 3 = SKIP without it).

    Run:  pwsh -File Tests\CheckpointAttestation.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-Command is shadowed on purpose')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51)) { Write-Host 'SKIP: Windows PowerShell 5.1 (powershell.exe) is not available.' -ForegroundColor Yellow; exit 3 }

foreach ($f in 'Get-Win32ToolkitCheckpointAttestation', 'Write-Win32ToolkitCheckpointAdvisory', 'Get-Win32ToolkitGuestSignedInUser', 'ConvertTo-Win32ToolkitSafeText', 'Test-Win32ToolkitPS51Syntax') {
    . (Join-Path $repo "Private\$f.ps1")
}

# The in-memory config store (never the real HKCU).
$script:store = @{}
$script:sets = 0
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:store.ContainsKey($Name)) { $script:store[$Name] } else { $Default } }
function Set-Win32ToolkitConfigValue { [CmdletBinding()] param($Name, $Value) $script:sets++; $script:store[$Name] = $Value }
# The console check at store time (V-10): no console unless a case says so; counts its calls.
$script:vmcOpen = $false; $script:vmcCalls = 0
function Test-Win32ToolkitVMConnectOpen { param($VMName, $VMId) $script:vmcCalls++; $script:vmcOpen }
# The guest: the sign-in probe gets a fixed answer; the Defender scriptblock RUNS here against the Defender doubles below.
$script:guestCalls = 0; $script:guestThrows = $false; $script:defenderOverride = $null; $script:bound = $null
$script:signedAnswer = { [pscustomobject]@{ ConsoleUser = $true; ExplorerSessionIds = [int[]]@(1); UiSessionIds = [int[]]@(1) } }
function Invoke-Command {
    [CmdletBinding()] param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    $script:guestCalls++
    if ($ScriptBlock.ToString() -match 'Get-MpComputerStatus') {
        $script:bound = @{}; foreach ($k in $PSBoundParameters.Keys) { $script:bound[$k] = $PSBoundParameters[$k] }
        if ($script:guestThrows) { throw 'The WinRM client cannot process the request' }
        if ($script:defenderOverride) { return (& $script:defenderOverride) }
        return (& $ScriptBlock)
    }
    & $script:signedAnswer
}
$script:mpStatus = $null; $script:mpPref = $null
function Get-MpComputerStatus { $script:mpStatus }
function Get-MpPreference { $script:mpPref }
function Set-Guest {
    param([bool]$RealTime = $true, [int]$SignatureAge = 1, [object[]]$Paths = @(), [object[]]$Processes = @(), [object[]]$Extensions = @())
    $script:mpStatus = [pscustomobject]@{ RealTimeProtectionEnabled = $RealTime; AntivirusSignatureAge = [uint32]$SignatureAge }
    $script:mpPref = [pscustomobject]@{ ExclusionPath = $Paths; ExclusionProcess = $Processes; ExclusionExtension = $Extensions }
}

$vmId = '0e5f9e66-1111-2222-3333-444455556666'
$cpId = '29613cba-d62f-4998-a421-df2e124a2b4f'
$ticks = 638653893400000000
$att = {
    param([hashtable]$Over = @{})
    $a = @{ Session = 'SESSION'; VMName = 'win32tk-measure'; CheckpointName = 'clean-base'; VMId = $vmId; CheckpointId = $cpId; CreationTimeUtcTicks = $ticks; AllowLive = $true; AllowStore = $true }
    foreach ($k in $Over.Keys) { $a[$k] = $Over[$k] }
    $o = @(Get-Win32ToolkitCheckpointAttestation @a)
    if ($o.Count -eq 1) { $o[0] } elseif ($o.Count -eq 0) { $null } else { throw "the attestation emitted $($o.Count) objects" }
}
$reset = { $script:store = @{}; $script:sets = 0; $script:guestCalls = 0; $script:guestThrows = $false; $script:defenderOverride = $null; $script:vmcOpen = $false; $script:vmcCalls = 0
    $script:signedAnswer = { [pscustomobject]@{ ConsoleUser = $true; ExplorerSessionIds = [int[]]@(1); UiSessionIds = [int[]]@(1) } }; Set-Guest }

Write-Host '[1] miss, hit, -SignedInAnswer, -AllowLive off' -ForegroundColor Cyan
& $reset
$r = & $att
$stored = [string]$script:store['HyperVCheckpointAttestation']
if ($r -and $r.SignedIn -eq $true -and $r.DefenderRealTime -eq $true -and $r.DefenderExclusionCount -eq 0 -and $r.SignatureAgeDays -eq 1 -and $r.FromCache -eq $false -and $script:guestCalls -eq 2) { Ok 'miss + live: two guest calls (sign-in, Defender); signed in, real-time on, 0 exclusions, 1-day signatures' } else { Bad "miss: $($r | ConvertTo-Json -Compress) calls=$($script:guestCalls)" }
if ($stored -ceq "v1|1|1|$vmId|$cpId|$ticks|1|1|0|1" -and $script:sets -eq 1 -and $script:vmcCalls -eq 1) { Ok "stored once as '$stored' after one console check" } else { Bad "stored: '$stored' sets=$($script:sets) vmc=$($script:vmcCalls)" }
$script:guestCalls = 0
$h = & $att
if ($h -and $h.FromCache -eq $true -and $h.SignedIn -and $h.DefenderRealTime -and $h.DefenderExclusionCount -eq 0 -and $h.SignatureAgeDays -eq 1 -and $script:guestCalls -eq 0 -and $script:sets -eq 1) { Ok 'hit: FromCache $true, the same facts, no guest call, nothing rewritten' } else { Bad "hit: $($h | ConvertTo-Json -Compress) calls=$($script:guestCalls) sets=$($script:sets)" }
& $reset
$r = & $att @{ SignedInAnswer = [pscustomobject]@{ Checked = $true; SignedIn = $false; SessionCount = 0; Reason = '' } }
if ($r -and $r.SignedIn -eq $false -and $script:guestCalls -eq 1) { Ok '-SignedInAnswer (the pre-check''s): one guest call (Defender only), its SignedIn used' } else { Bad "signed-in answer: $($r | ConvertTo-Json -Compress) calls=$($script:guestCalls)" }
& $reset
$r = & $att @{ AllowLive = $false }
if ($null -eq $r -and $script:guestCalls -eq 0 -and $script:sets -eq 0) { Ok '-AllowLive off on a miss: $null, no guest call (a watched run, a skipped or cold open)' } else { Bad "no live: $($r | ConvertTo-Json -Compress) calls=$($script:guestCalls)" }
& $reset
$r = & $att @{ Session = $null }
if ($null -eq $r -and $script:guestCalls -eq 0) { Ok 'no session: $null, no guest call' } else { Bad "no session: $($r | ConvertTo-Json -Compress)" }

Write-Host '[2] what it reads' -ForegroundColor Cyan
foreach ($case in @(
        @{ Tag = 'real-time protection off'; Guest = @{ RealTime = $false }; Check = { param($x) $x.DefenderRealTime -eq $false } }
        @{ Tag = 'one exclusion path'; Guest = @{ Paths = @('C:\Temp') }; Check = { param($x) $x.DefenderExclusionCount -eq 1 } }
        @{ Tag = 'a path, a process and an extension'; Guest = @{ Paths = @('C:\a'); Processes = @('x.exe'); Extensions = @('.tmp') }; Check = { param($x) $x.DefenderExclusionCount -eq 3 } }
        @{ Tag = '$null and empty exclusion entries'; Guest = @{ Paths = @($null, ''); Processes = $null }; Check = { param($x) $x.DefenderExclusionCount -eq 0 } }
        @{ Tag = 'signatures 40 days old'; Guest = @{ SignatureAge = 40 }; Check = { param($x) $x.SignatureAgeDays -eq 40 } })) {
    & $reset
    $g = $case.Guest
    Set-Guest @g
    $r = & $att
    if ($r -and (& $case.Check $r) -and $r.FromCache -eq $false -and $script:sets -eq 1) { Ok "$($case.Tag): returned as read, stored" } else { Bad "$($case.Tag): $($r | ConvertTo-Json -Compress) sets=$($script:sets)" }
}
foreach ($case in @(
        @{ Tag = "Defender's 'N/A: Must be an administrator' placeholder"; Set = { Set-Guest -Paths @('N/A: Must be an administrator to view exclusions') } }
        @{ Tag = 'the Defender call throws'; Set = { $script:guestThrows = $true } }
        @{ Tag = 'a partial Defender answer (no SignatureAgeDays)'; Set = { $script:defenderOverride = { [pscustomobject]@{ RealTime = $true; Exclusions = 0; Hidden = $false } } } }
        @{ Tag = 'two Defender answers'; Set = { $script:defenderOverride = { [pscustomobject]@{ RealTime = $true; Exclusions = 0; Hidden = $false; SignatureAgeDays = 1 }; [pscustomobject]@{ RealTime = $true; Exclusions = 0; Hidden = $false; SignatureAgeDays = 1 } } } }
        @{ Tag = 'RealTime that is not a boolean'; Set = { $script:defenderOverride = { [pscustomobject]@{ RealTime = 'yes'; Exclusions = 0; Hidden = $false; SignatureAgeDays = 1 } } } }
        @{ Tag = 'an unreadable sign-in answer (Checked $false)'; Set = { $script:signedAnswer = { $null } } })) {
    & $reset
    & $case.Set
    $r = 'not-set'; $threw = $null
    try { $r = & $att } catch { $threw = $_ }
    if (-not $threw -and $null -eq $r -and $script:sets -eq 0) { Ok "$($case.Tag): `$null, nothing stored, no throw" } else { Bad "$($case.Tag): threw=$threw r=$($r | ConvertTo-Json -Compress) sets=$($script:sets)" }
}
foreach ($age in 65535, 9999) {
    & $reset
    Set-Guest -SignatureAge $age
    $r = & $att
    $calls1 = $script:guestCalls
    $r2 = & $att
    if ($r -and $null -eq $r.SignatureAgeDays -and $r.DefenderRealTime -eq $true -and $r.FromCache -eq $false -and $script:sets -eq 0 -and $r2 -and $r2.FromCache -eq $false -and $script:guestCalls -eq 2 * $calls1) {
        Ok "signature age $age (never updated or unknown, V-11): SignatureAgeDays `$null, the rest as read, nothing stored, the next call asks again"
    } else { Bad "age ${age}: $($r | ConvertTo-Json -Compress) sets=$($script:sets) calls=$($script:guestCalls)" }
}
& $reset
Set-Guest -SignatureAge 9998
$r = & $att
if ($r.SignatureAgeDays -eq 9998 -and $script:sets -eq 1) { Ok 'signature age 9998: kept and stored (the largest storable age)' } else { Bad "9998: $($r | ConvertTo-Json -Compress) sets=$($script:sets)" }

Write-Host '[3] the cache identity, versions and the store rules' -ForegroundColor Cyan
foreach ($case in @(
        @{ Tag = 'another VM Id'; V = "v1|1|1|$([guid]::NewGuid())|$cpId|$ticks|1|1|0|1" }
        @{ Tag = 'another checkpoint Id'; V = "v1|1|1|$vmId|$([guid]::NewGuid())|$ticks|1|1|0|1" }
        @{ Tag = 'another creation time'; V = "v1|1|1|$vmId|$cpId|$($ticks + 1)|1|1|0|1" }
        @{ Tag = 'another AttestVersion'; V = "v1|2|1|$vmId|$cpId|$ticks|1|1|0|1" }
        @{ Tag = 'the same AttestVersion but another ProbeVersion (V-9)'; V = "v1|1|2|$vmId|$cpId|$ticks|1|1|0|1" }
        @{ Tag = 'an extra field'; V = "v1|1|1|$vmId|$cpId|$ticks|1|1|0|1|x" }
        @{ Tag = 'a signature age of 9999'; V = "v1|1|1|$vmId|$cpId|$ticks|1|1|0|9999" }
        @{ Tag = "a ';' payload"; V = "v1|1|1|$vmId|$cpId|$ticks|1|1|0|1;x" })) {
    & $reset
    $script:store['HyperVCheckpointAttestation'] = $case.V
    $r = & $att
    if ($r -and $r.FromCache -eq $false -and $script:guestCalls -eq 2) { Ok "$($case.Tag): a miss, asked again" } else { Bad "$($case.Tag): $($r | ConvertTo-Json -Compress) calls=$($script:guestCalls)" }
}
& $reset
$script:store['HyperVCheckpointAttestation'] = "v1|1|1|$($vmId.ToUpperInvariant())|$($cpId.ToUpperInvariant())|$ticks|0|0|3|50"
$r = & $att
if ($r.FromCache -and $r.SignedIn -eq $false -and $r.DefenderRealTime -eq $false -and $r.DefenderExclusionCount -eq 3 -and $r.SignatureAgeDays -eq 50) { Ok 'a stored answer with upper-case GUIDs: a hit, its facts read back' } else { Bad "upper: $($r | ConvertTo-Json -Compress)" }
& $reset
$script:vmcOpen = $true
$r = & $att
if ($r -and $script:sets -eq 0 -and $script:vmcCalls -eq 1) { Ok '-AllowStore with a VM console attached at store time (V-10): returned, not stored' } else { Bad "console at store: sets=$($script:sets) vmc=$($script:vmcCalls)" }
& $reset
$r = & $att @{ AllowStore = $false }
if ($r -and $script:sets -eq 0 -and $script:vmcCalls -eq 0) { Ok 'no -AllowStore: returned, not stored, no console check' } else { Bad "no store: sets=$($script:sets)" }
& $reset
$r = & $att @{ VMId = '' }
if ($r -and $script:sets -eq 0) { Ok 'an unknown VM identity: asked live, not stored (no cache key)' } else { Bad "unknown identity: $($r | ConvertTo-Json -Compress) sets=$($script:sets)" }
& $reset
Set-Guest -Paths (1..1000 | ForEach-Object { "C:\x$_" })
$r = & $att
if ($r -and $r.DefenderExclusionCount -eq 1000 -and $script:sets -eq 0) { Ok '1000 exclusions: returned, not stored (the stored field holds at most 999)' } else { Bad "1000: $($r.DefenderExclusionCount) sets=$($script:sets)" }

Write-Host '[4] the guest scriptblock (C-6) and the version tripwires (V-9)' -ForegroundColor Cyan
& $reset
$null = & $att
$sb = $script:bound.ScriptBlock
if ($script:bound.ErrorAction -eq 'Stop' -and -not $script:bound.ContainsKey('ArgumentList') -and $script:bound.Session -eq 'SESSION' -and $sb) { Ok 'Invoke-Command -Session <the session> -ErrorAction Stop -ScriptBlock { ... }, no -ArgumentList' } else { Bad "bound: $(@($script:bound.Keys) -join ',')" }
$sbText = $sb.ToString()
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32cat_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $TMP -Force | Out-Null
try {
    $sbFile = Join-Path $TMP 'defender-scriptblock.ps1'
    [System.IO.File]::WriteAllText($sbFile, $sbText, [System.Text.UTF8Encoding]::new($false))
    $err51 = @(Test-Win32ToolkitPS51Syntax -Path $sbFile)
    if ($err51.Count -eq 0) { Ok 'the Defender scriptblock parses under Windows PowerShell 5.1' } else { Bad "5.1 parse: $($err51 -join ' | ')" }
}
finally { Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue }
if (@([System.Text.Encoding]::UTF8.GetBytes($sbText) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the scriptblock is ASCII' } else { Bad 'non-ASCII scriptblock' }
$tokens = $null
$sbAst = [System.Management.Automation.Language.Parser]::ParseInput($sbText, [ref]$tokens, [ref]$null)
$first = @($sbAst.EndBlock.Statements)[0]
if ($first -and $first.Extent.Text -ceq "`$ErrorActionPreference = 'Stop'") { Ok "its first statement is `$ErrorActionPreference = 'Stop'" } else { Bad "first: $($first.Extent.Text)" }
$assigned = @($sbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | Where-Object { -not [object]::ReferenceEquals($_, $first) } | ForEach-Object { $_.Left.VariablePath.UserPath })
if ($assigned.Count -ge 4 -and @($assigned | Where-Object { $_ -notlike 'w32t*' }).Count -eq 0) { Ok "every other assigned variable is `$w32t* ($($assigned -join ', '))" } else { Bad "assigned: $($assigned -join ', ')" }
if ($sbText -notmatch '(?i)Set-Mp|Add-Mp|Remove-Mp|Update-Mp|Start-Mp') { Ok 'read-only: no Set-/Add-/Remove-/Update-/Start-Mp* call' } else { Bad 'a Defender-changing call in the scriptblock' }
function Get-DefinitionHash([string]$File, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
    $fd = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [System.Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($fd.Extent.Text -replace "`r`n", "`n")))) } finally { $sha.Dispose() }
}
$pinnedAttest = 'C8F2DDA0A6D1281993C1AE6B3E2EF02148A221E026E18F772D4B44B4D15A1D29'
$pinnedProbe = 'B916FB0B1047BAB7203C4CC56777D3A1A983A872A4ECD0B03EE95A879C75DB4E'
$hAttest = Get-DefinitionHash (Join-Path $repo 'Private\Get-Win32ToolkitCheckpointAttestation.ps1') 'Get-Win32ToolkitCheckpointAttestation'
$hProbe = Get-DefinitionHash (Join-Path $repo 'Private\Get-Win32ToolkitGuestSignedInUser.ps1') 'Get-Win32ToolkitGuestSignedInUser'
if ($hAttest -ceq $pinnedAttest) { Ok 'Get-Win32ToolkitCheckpointAttestation matches its pinned hash (a change needs a new AttestVersion and pin)' } else { Bad "the attestation changed ($hAttest): raise AttestVersion, then update this pin" }
if ($hProbe -ceq $pinnedProbe) { Ok 'Get-Win32ToolkitGuestSignedInUser matches the probe pin (a probe change re-attests through ProbeVersion)' } else { Bad "the sign-in probe changed ($hProbe): raise ProbeVersion everywhere, then update the pins" }

Write-Host '[5] Write-Win32ToolkitCheckpointAdvisory: once per kind and key, emits nothing (V-1)' -ForegroundColor Cyan
$script:HyperVAdvised = $null
$o1 = @(Write-Win32ToolkitCheckpointAdvisory -Kind Age -Key 'k1' -Message 'old checkpoint' 3>&1)
$o2 = @(Write-Win32ToolkitCheckpointAdvisory -Kind Age -Key 'k1' -Message 'old checkpoint' 3>&1)
$o3 = @(Write-Win32ToolkitCheckpointAdvisory -Kind Signatures -Key 'k1' -Message 'old signatures' 3>&1)
$o4 = @(Write-Win32ToolkitCheckpointAdvisory -Kind Age -Key 'k2' -Message 'old checkpoint 2' 3>&1)
$w = { param($o) @($o | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) }
$nw = { param($o) @($o | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }) }
if ((& $w $o1).Count -eq 1 -and (& $w $o2).Count -eq 0 -and (& $w $o3).Count -eq 1 -and (& $w $o4).Count -eq 1) { Ok 'one warning per kind and key: a repeat prints nothing; another kind or key prints' } else { Bad "warnings: $((& $w $o1).Count)/$((& $w $o2).Count)/$((& $w $o3).Count)/$((& $w $o4).Count)" }
if ((& $nw $o1).Count -eq 0 -and (& $nw $o2).Count -eq 0 -and @(Write-Win32ToolkitCheckpointAdvisory -Kind RealTime -Key 'k9' -Message 'x' 3>$null).Count -eq 0) { Ok 'it emits nothing, also on the printing call' } else { Bad 'the advisory emitted output' }
if ($script:HyperVAdvised.ContainsKey('Age|k1') -and $script:HyperVAdvised.ContainsKey('Signatures|k1')) { Ok 'the dedupe lives in $script:HyperVAdvised' } else { Bad "advised: $(@($script:HyperVAdvised.Keys) -join ',')" }

Write-Host '[6] file hygiene' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
foreach ($name in 'Get-Win32ToolkitCheckpointAttestation', 'Write-Win32ToolkitCheckpointAdvisory') {
    $file = Join-Path $repo "Private\$name.ps1"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    $top = @($ast.EndBlock.Statements)
    $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $name -and -not $ast.ParamBlock
    if (@($errs).Count -eq 0 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "$name : ASCII, one function, $($catches.Count) catch(es) with the C-2 line" } else { Bad "$name : errors $(@($errs).Count), bad catches $($badCatch.Count), ascii $ascii, one function $oneFunction" }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All CheckpointAttestation tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail CheckpointAttestation test(s) FAILED." -ForegroundColor Red; exit 1 }
