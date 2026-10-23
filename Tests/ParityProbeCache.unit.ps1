<#
    Hyper-V speed-up PR 1 (D3, V-9, V-10, V-Fe12): the Intune-parity pre-check's answer cache.

      [1] Get-/Set-Win32ToolkitParityProbeCache with Get-/Set-Win32ToolkitConfigValue shadowed by an in-memory store:
          round trip; any identity mismatch, another probe version, a malformed value (an extra field, letters in the
          ticks, 100 sessions, a ';' payload, a trailing newline) -> a miss; Set refuses an unknown identity, emits
          nothing, writes through Set-Win32ToolkitConfigValue -WarningAction SilentlyContinue and turns a failed write
          into one verbose line.
      [2] Clear-Win32ToolkitParityProbeCache removes HyperVPrecheckProbe and HyperVCheckpointAttestation from the
          toolkit's key (Remove-ItemProperty shadowed: path and names asserted) and nothing else, forgets the process's
          advisory dedupe and checkpoint-setting memo, emits nothing.
      [3] Tripwire (V-9): the SHA256 of the whole Get-Win32ToolkitGuestSignedInUser definition (line endings normalised)
          is pinned; a change to the guest probe or to how its answer is read must raise ProbeVersion (and this pin).
          The hash of a CRLF and of an LF copy are equal. The -ProbeVersion defaults are equal.
      [4] Test-Win32ToolkitVMConnectOpen (Get-CimInstance shadowed): the VM's name as a whole token (quoted or not), its
          Id (braces or not); another VM, a longer name -> $false; a query that throws or an unreadable command line ->
          $true (fail-safe).
      [5] File hygiene of the four new files: ASCII, one function, every catch starts with the C-2 line.

    The developer's real HKCU is never touched: both config helpers and Remove-ItemProperty are shadowed, and a shadow
    that would fall through throws.

    Run:  pwsh -File Tests\ParityProbeCache.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows keep the real command names')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Get-Win32ToolkitParityProbeCache', 'Set-Win32ToolkitParityProbeCache', 'Clear-Win32ToolkitParityProbeCache', 'Test-Win32ToolkitVMConnectOpen') {
    . (Join-Path $repo "Private\$f.ps1")
}

# The in-memory config store (never the real HKCU).
$script:store = @{}
$script:setCalls = [System.Collections.Generic.List[object]]::new()
$script:setWarns = $false
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:store.ContainsKey($Name)) { $script:store[$Name] } else { $Default } }
function Set-Win32ToolkitConfigValue {
    [CmdletBinding()] param($Name, $Value)
    $script:setCalls.Add([pscustomobject]@{ Name = $Name; Value = $Value; WarningAction = $PSBoundParameters['WarningAction'] })
    if ($script:setWarns) { Write-Warning "Could not save '$Name' to the registry: access denied"; return }
    $script:store[$Name] = $Value
}
$script:removed = [System.Collections.Generic.List[string]]::new()
function Remove-ItemProperty {
    param($LiteralPath, $Name, $ErrorAction)
    if ($LiteralPath -ne 'HKCU:\Software\CloudFlow\win32-toolkit') { throw "real HKCU must not be touched (path $LiteralPath)" }
    $script:removed.Add([string]$Name); $script:store.Remove([string]$Name)
}

$vmId = '0e5f9e66-1111-2222-3333-444455556666'
$cpId = '29613cba-d62f-4998-a421-df2e124a2b4f'
$ticks = 638653893400000000
$get = { param([hashtable]$Over = @{}) $a = @{ VMId = $vmId; CheckpointId = $cpId; CreationTimeUtcTicks = $ticks }; foreach ($k in $Over.Keys) { $a[$k] = $Over[$k] }; Get-Win32ToolkitParityProbeCache @a }

Write-Host '[1] Get / Set round trip and misses' -ForegroundColor Cyan
$out = @(Set-Win32ToolkitParityProbeCache -VMId $vmId -CheckpointId $cpId -CreationTimeUtcTicks $ticks -SignedIn $true -SessionCount 2)
$stored = [string]$script:store['HyperVPrecheckProbe']
if ($out.Count -eq 0 -and $stored -ceq "v1|1|$vmId|$cpId|$ticks|1|2" -and $script:setCalls.Count -eq 1 -and $script:setCalls[0].WarningAction -eq 'SilentlyContinue') { Ok "Set writes '$stored' through Set-Win32ToolkitConfigValue -WarningAction SilentlyContinue and emits nothing" } else { Bad "set: out=$($out.Count) stored='$stored' calls=$($script:setCalls | ConvertTo-Json -Compress)" }
$hit = & $get
if ($hit -and $hit.SignedIn -eq $true -and $hit.SessionCount -eq 2 -and @($hit).Count -eq 1) { Ok 'Get with the same identity: SignedIn $true, SessionCount 2' } else { Bad "hit: $($hit | ConvertTo-Json -Compress)" }
$hitUpper = & $get @{ VMId = $vmId.ToUpperInvariant(); CheckpointId = $cpId.ToUpperInvariant() }
if ($hitUpper) { Ok 'GUIDs compare case-insensitively' } else { Bad 'upper-case GUIDs missed' }
foreach ($case in @(
        @{ Tag = 'another VM Id'; Over = @{ VMId = [guid]::NewGuid().ToString() } }
        @{ Tag = 'another checkpoint Id (a re-taken checkpoint)'; Over = @{ CheckpointId = [guid]::NewGuid().ToString() } }
        @{ Tag = 'another creation time'; Over = @{ CreationTimeUtcTicks = $ticks + 1 } }
        @{ Tag = 'probe version 2 against a stored 1'; Over = @{ ProbeVersion = 2 } }
        @{ Tag = 'no creation time'; Over = @{ CreationTimeUtcTicks = 0 } }
        @{ Tag = 'an empty VM Id'; Over = @{ VMId = '' } })) {
    if ($null -eq (& $get $case.Over)) { Ok "$($case.Tag): miss" } else { Bad "$($case.Tag): hit" }
}
foreach ($case in @(
        @{ Tag = 'an extra field'; V = "v1|1|$vmId|$cpId|$ticks|1|2|x" }
        @{ Tag = 'letters in the ticks'; V = "v1|1|$vmId|$cpId|63865389340000000a|1|2" }
        @{ Tag = '100 sessions'; V = "v1|1|$vmId|$cpId|$ticks|1|100" }
        @{ Tag = "a ';' payload"; V = "v1|1|$vmId|$cpId|$ticks|1|2;Remove-Item C:\" }
        @{ Tag = 'a trailing newline'; V = "v1|1|$vmId|$cpId|$ticks|1|2`n" }
        @{ Tag = 'format v2'; V = "v2|1|$vmId|$cpId|$ticks|1|2" }
        @{ Tag = 'SignedIn 2'; V = "v1|1|$vmId|$cpId|$ticks|2|2" }
        @{ Tag = 'ticks beyond a long'; V = "v1|1|$vmId|$cpId|9999999999999999999|1|2" }
        @{ Tag = 'empty'; V = '' })) {
    $script:store['HyperVPrecheckProbe'] = $case.V
    $r = 'not-set'; $threw = $null
    try { $r = & $get } catch { $threw = $_ }
    if (-not $threw -and $null -eq $r) { Ok "a malformed value ($($case.Tag)): miss, no throw" } else { Bad "$($case.Tag): threw=$threw result=$($r | ConvertTo-Json -Compress)" }
}
# Set refuses what it cannot key; a failed write is one verbose line.
$script:store.Clear(); $script:setCalls.Clear()
foreach ($case in @(@{ Tag = 'a VM Id that is not a GUID'; A = @{ VMId = 'vm; drop' } }, @{ Tag = 'no creation time'; A = @{ CreationTimeUtcTicks = 0 } }, @{ Tag = 'an empty checkpoint Id'; A = @{ CheckpointId = '' } })) {
    $a = @{ VMId = $vmId; CheckpointId = $cpId; CreationTimeUtcTicks = $ticks; SignedIn = $true; SessionCount = 1 }
    foreach ($k in $case.A.Keys) { $a[$k] = $case.A[$k] }
    $null = Set-Win32ToolkitParityProbeCache @a
}
if ($script:setCalls.Count -eq 0) { Ok 'Set with an unknown identity (not a GUID, no creation time, empty Id) writes nothing' } else { Bad "unknown identity wrote: $($script:setCalls | ConvertTo-Json -Compress)" }
$script:setWarns = $true
$v = @(Set-Win32ToolkitParityProbeCache -VMId $vmId -CheckpointId $cpId -CreationTimeUtcTicks $ticks -SignedIn $false -SessionCount 0 -Verbose 4>&1 3>&1)
$script:setWarns = $false
$verb = @($v | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like '*was not stored*' })
$warnShown = @($v | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
if ($verb.Count -eq 1 -and $warnShown.Count -eq 0 -and @($v | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count -eq 0) { Ok 'a failed write: one verbose line, no warning shown, no output' } else { Bad "failed write: verbose=$($verb.Count) warnings=$($warnShown.Count) out=$($v | Out-String)" }
$threw = $null
try { Set-Win32ToolkitParityProbeCache -VMId $vmId -CheckpointId $cpId -CreationTimeUtcTicks $ticks -SignedIn $true -SessionCount 100 } catch { $threw = $_ }
if ($threw -and $threw.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*') { Ok 'SessionCount 100 is refused at binding (0-99; the pre-check catches it and stores nothing)' } else { Bad "100 sessions: $threw" }

Write-Host '[2] Clear-Win32ToolkitParityProbeCache' -ForegroundColor Cyan
$script:store = @{ HyperVPrecheckProbe = 'a'; HyperVCheckpointAttestation = 'b'; HyperVVMName = 'win32tk-measure'; HyperVCheckpoint = 'clean-base'; TestBackend = 'HyperV' }
$script:HyperVAdvised = @{ 'Age|x' = $true }
$script:HyperVCheckpointAutoSetting = @{ 'X' = $true }
$script:removed.Clear()
$outC = @(Clear-Win32ToolkitParityProbeCache)
if ($outC.Count -eq 0 -and ($script:removed -join ',') -eq 'HyperVPrecheckProbe,HyperVCheckpointAttestation' -and (@($script:store.Keys | Sort-Object) -join ',') -eq 'HyperVCheckpoint,HyperVVMName,TestBackend') {
    Ok 'removes HyperVPrecheckProbe and HyperVCheckpointAttestation from the toolkit key and nothing else; emits nothing'
} else { Bad "clear: removed=$($script:removed -join ',') left=$(@($script:store.Keys) -join ',') out=$($outC.Count)" }
if ($null -eq $script:HyperVAdvised -and $null -eq $script:HyperVCheckpointAutoSetting) { Ok 'forgets the process''s advisory dedupe and checkpoint-setting memo' } else { Bad 'process memos survived' }
${function:Remove-ItemProperty_Saved} = ${function:Remove-ItemProperty}
function Remove-ItemProperty { param($LiteralPath, $Name, $ErrorAction) throw 'the registry key is locked' }
$threw = $null
try { Clear-Win32ToolkitParityProbeCache } catch { $threw = $_ }
${function:Remove-ItemProperty} = ${function:Remove-ItemProperty_Saved}
Remove-Item Function:\Remove-ItemProperty_Saved
if (-not $threw) { Ok 'a failing Remove-ItemProperty: no throw (fail-open)' } else { Bad "clear threw: $threw" }

Write-Host '[3] tripwire: the guest sign-in probe and its reading are pinned to ProbeVersion 1 (V-9)' -ForegroundColor Cyan
$pinnedProbe = 'B916FB0B1047BAB7203C4CC56777D3A1A983A872A4ECD0B03EE95A879C75DB4E'
function Get-DefinitionHash([string]$Text, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $fd = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [System.Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($fd.Extent.Text -replace "`r`n", "`n")))) } finally { $sha.Dispose() }
}
$probeText = [System.IO.File]::ReadAllText((Join-Path $repo 'Private\Get-Win32ToolkitGuestSignedInUser.ps1'))
$probeHash = Get-DefinitionHash $probeText 'Get-Win32ToolkitGuestSignedInUser'
if ($probeHash -ceq $pinnedProbe) { Ok 'Get-Win32ToolkitGuestSignedInUser matches the pinned hash (a change needs a new ProbeVersion and pin)' } else { Bad "the sign-in probe changed ($probeHash): raise ProbeVersion in Get-/Set-Win32ToolkitParityProbeCache and Get-Win32ToolkitCheckpointAttestation, then update this pin" }
$lf = $probeText -replace "`r`n", "`n"
$crlf = $lf -replace "`n", "`r`n"
if ((Get-DefinitionHash $lf 'Get-Win32ToolkitGuestSignedInUser') -ceq (Get-DefinitionHash $crlf 'Get-Win32ToolkitGuestSignedInUser')) { Ok 'the hash of an LF and of a CRLF copy are equal (core.autocrlf does not matter)' } else { Bad 'line endings change the hash' }
$defaults = foreach ($name in 'Get-Win32ToolkitParityProbeCache', 'Set-Win32ToolkitParityProbeCache', 'Get-Win32ToolkitCheckpointAttestation') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "Private\$name.ps1"), [ref]$null, [ref]$null)
    $p = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'ProbeVersion' }, $true)
    if ($p -and $p.DefaultValue) { $p.DefaultValue.Extent.Text } else { '<none>' }
}
if (@($defaults).Count -eq 3 -and @($defaults | Select-Object -Unique).Count -eq 1 -and $defaults[0] -eq '1') { Ok "the three -ProbeVersion defaults (Get-/Set-Win32ToolkitParityProbeCache, Get-Win32ToolkitCheckpointAttestation) are equal ($($defaults -join ', '))" } else { Bad "ProbeVersion defaults: $($defaults -join ', ')" }

Write-Host '[4] Test-Win32ToolkitVMConnectOpen' -ForegroundColor Cyan
$script:cimProcs = @(); $script:cimThrows = $false; $script:cimFilter = $null
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) $script:cimFilter = "$ClassName|$Filter"; if ($script:cimThrows) { throw 'WMI is not available' }; $script:cimProcs }
$vmc = { param([string[]]$Lines, [string]$Name = 'win32tk-measure', [string]$Id = $vmId) $script:cimProcs = @($Lines | ForEach-Object { [pscustomobject]@{ CommandLine = $_ } }); Test-Win32ToolkitVMConnectOpen -VMName $Name -VMId $Id }
foreach ($case in @(
        @{ Tag = 'no vmconnect'; Lines = @(); Want = $false }
        @{ Tag = 'vmconnect localhost <name>'; Lines = @('"C:\Windows\system32\vmconnect.exe" localhost win32tk-measure'); Want = $true }
        @{ Tag = 'the name in another case'; Lines = @('vmconnect.exe localhost WIN32TK-MEASURE'); Want = $true }
        @{ Tag = 'a quoted name with spaces'; Lines = @('vmconnect.exe "HOST" "my test vm"'); Name = 'my test vm'; Want = $true }
        @{ Tag = '-G <Id> in braces'; Lines = @("vmconnect.exe HOST -G {$($vmId.ToUpperInvariant())}"); Want = $true }
        @{ Tag = 'another VM'; Lines = @('vmconnect.exe localhost win32tk-golden'); Want = $false }
        @{ Tag = 'a longer name (not a whole token)'; Lines = @('vmconnect.exe localhost win32tk-measure2'); Want = $false }
        @{ Tag = 'a command line that cannot be read'; Lines = @(''); Want = $true })) {
    $a = @{ Lines = $case.Lines }
    if ($case.Name) { $a['Name'] = $case.Name }
    $r = & $vmc @a
    if ($r -is [bool] -and $r -eq $case.Want) { Ok "$($case.Tag): $r" } else { Bad "$($case.Tag): $r" }
}
if ($script:cimFilter -eq "Win32_Process|Name = 'vmconnect.exe'") { Ok 'one Win32_Process query filtered on vmconnect.exe' } else { Bad "query: $($script:cimFilter)" }
$script:cimThrows = $true
$r = & $vmc @()
$script:cimThrows = $false
if ($r -eq $true) { Ok 'the query throws: $true (fail-safe)' } else { Bad "throw: $r" }

Write-Host '[5] file hygiene of the four new files' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
foreach ($name in 'Get-Win32ToolkitParityProbeCache', 'Set-Win32ToolkitParityProbeCache', 'Clear-Win32ToolkitParityProbeCache', 'Test-Win32ToolkitVMConnectOpen') {
    $file = Join-Path $repo "Private\$name.ps1"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    $top = @($ast.EndBlock.Statements)
    $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $name -and -not $ast.ParamBlock
    if (@($errs).Count -eq 0 -and $catches.Count -ge 1 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "$name : ASCII, one function, $($catches.Count) catch(es) with the C-2 line" } else { Bad "$name : errors $(@($errs).Count), catches $($catches.Count), bad $($badCatch.Count), ascii $ascii, one function $oneFunction" }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All ParityProbeCache tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail ParityProbeCache test(s) FAILED." -ForegroundColor Red; exit 1 }
