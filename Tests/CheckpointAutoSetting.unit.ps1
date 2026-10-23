<#
    Hyper-V speed-up PR 1 (D5, B5): Get-Win32ToolkitCheckpointAutoSetting, the automatic-checkpoint setting a test VM
    checkpoint was taken with (root\virtualization\v2 Msvm_VirtualSystemSettingData.AutomaticSnapshotsEnabled).

      [1] Get-CimInstance shadowed: True / False / no instance ($null) / a throw ($null) / a non-boolean ($null); the exact
          namespace, class and filter (InstanceID = 'Microsoft:<ID upper-case>'); an Id that is not a GUID never reaches
          the query.
      [2] The per-process memo: a second call for the same checkpoint asks nothing; an unknown answer is not kept;
          Clear-Win32ToolkitParityProbeCache forgets the memo.
      [3] File hygiene: ASCII, one function, every catch starts with the C-2 line.

    Nothing reaches WMI or Hyper-V.

    Run:  pwsh -File Tests\CheckpointAutoSetting.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitCheckpointAutoSetting.ps1')
. (Join-Path $repo 'Private\Clear-Win32ToolkitParityProbeCache.ps1')
function Remove-ItemProperty { param($LiteralPath, $Name, $ErrorAction) }   # the real HKCU is never touched

$script:cim = [System.Collections.Generic.List[string]]::new()
$script:cimAnswer = { @() }
function Get-CimInstance { param($Namespace, $ClassName, $Filter, $ErrorAction) $script:cim.Add("$Namespace|$ClassName|$Filter"); & $script:cimAnswer }
$cpId = '0e5f9e66-aaaa-bbbb-cccc-444455556666'

Write-Host '[1] the answer and the query' -ForegroundColor Cyan
foreach ($case in @(
        @{ Tag = 'AutomaticSnapshotsEnabled True'; Answer = { [pscustomobject]@{ AutomaticSnapshotsEnabled = $true } }; Want = $true }
        @{ Tag = 'AutomaticSnapshotsEnabled False'; Answer = { [pscustomobject]@{ AutomaticSnapshotsEnabled = $false } }; Want = $false }
        @{ Tag = 'no instance'; Answer = { @() }; Want = $null }
        @{ Tag = 'two instances'; Answer = { [pscustomobject]@{ AutomaticSnapshotsEnabled = $true }; [pscustomobject]@{ AutomaticSnapshotsEnabled = $true } }; Want = $null }
        @{ Tag = 'a value that is not a boolean'; Answer = { [pscustomobject]@{ AutomaticSnapshotsEnabled = 'True' } }; Want = $null }
        @{ Tag = 'the query throws'; Answer = { throw 'Invalid namespace' }; Want = $null })) {
    $script:HyperVCheckpointAutoSetting = $null
    $script:cim.Clear(); $script:cimAnswer = $case.Answer
    $r = 'not-set'; $threw = $null
    try { $r = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $cpId } catch { $threw = $_ }
    $same = if ($null -eq $case.Want) { $null -eq $r } else { $r -is [bool] -and $r -eq $case.Want }
    if (-not $threw -and $same -and $script:cim.Count -eq 1) { Ok "$($case.Tag): $(if ($null -eq $r) { '$null' } else { "`$$r" })" } else { Bad "$($case.Tag): threw=$threw r=$r queries=$($script:cim.Count)" }
}
if ($script:cim[0] -ceq "root\virtualization\v2|Msvm_VirtualSystemSettingData|InstanceID = 'Microsoft:$($cpId.ToUpperInvariant())'") { Ok "the query: root\virtualization\v2, Msvm_VirtualSystemSettingData, InstanceID = 'Microsoft:<ID upper-case>'" } else { Bad "query: $($script:cim[0])" }
foreach ($bad in '', 'not-a-guid', "x' OR InstanceID LIKE '%", "$cpId' OR '1'='1") {
    $script:cim.Clear()
    $r = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $bad
    if ($null -eq $r -and $script:cim.Count -eq 0) { Ok "Id '$bad': `$null, no query" } else { Bad "Id '$bad': r=$r queries=$($script:cim.Count)" }
}

Write-Host '[2] the per-process memo' -ForegroundColor Cyan
$script:HyperVCheckpointAutoSetting = $null
$script:cim.Clear(); $script:cimAnswer = { [pscustomobject]@{ AutomaticSnapshotsEnabled = $true } }
$r1 = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $cpId
$r2 = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $cpId.ToUpperInvariant()
if ($r1 -eq $true -and $r2 -eq $true -and $script:cim.Count -eq 1) { Ok 'a second call for the same checkpoint (any case) asks nothing' } else { Bad "memo: $r1/$r2 queries=$($script:cim.Count)" }
$other = [guid]::NewGuid().ToString()
$script:cimAnswer = { @() }
$null = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $other
$null = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $other
if ($script:cim.Count -eq 3) { Ok 'an unknown answer is not kept (asked again)' } else { Bad "unknown memo: queries=$($script:cim.Count)" }
Clear-Win32ToolkitParityProbeCache
$script:cimAnswer = { [pscustomobject]@{ AutomaticSnapshotsEnabled = $false } }
$r3 = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId $cpId
if ($r3 -eq $false -and $script:cim.Count -eq 4) { Ok 'Clear-Win32ToolkitParityProbeCache (every VM command) forgets the memo' } else { Bad "after clear: $r3 queries=$($script:cim.Count)" }

Write-Host '[3] file hygiene' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$file = Join-Path $repo 'Private\Get-Win32ToolkitCheckpointAutoSetting.ps1'
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
$catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
$badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
$ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
$top = @($ast.EndBlock.Statements)
$oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq 'Get-Win32ToolkitCheckpointAutoSetting' -and -not $ast.ParamBlock
if (@($errs).Count -eq 0 -and $catches.Count -ge 1 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "ASCII, one function, $($catches.Count) catch(es) with the C-2 line" } else { Bad "errors $(@($errs).Count), catches $($catches.Count), bad $($badCatch.Count), ascii $ascii, one function $oneFunction" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All CheckpointAutoSetting tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail CheckpointAutoSetting test(s) FAILED." -ForegroundColor Red; exit 1 }
