<#
    Hyper-V speed-up PR 1 (D12): Get-Win32ToolkitHyperVLane, the Lane of a Hyper-V run's record and the identity the
    pre-check cache and the checkpoint attestation key on.

      [1] A full read: the VM's Id, processors and memory, the checkpoint's Id, creation time (UTC 'o'), age in days and
          creation ticks; -VM saves the Get-VM call.
      [2] Fail-open: Get-VM or Get-VMCheckpoint throwing, no checkpoint, two checkpoints of that name, a non-GUID Id ->
          '' / $null for what could not be read, one verbose line, never a throw.
      [3] File hygiene: ASCII, one function, every catch starts with the C-2 line.

    Get-VM and Get-VMCheckpoint are shadowed; nothing reaches Hyper-V.

    Run:  pwsh -File Tests\HyperVLane.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitHyperVLane.ps1')

$vmId = [guid]'0e5f9e66-1111-2222-3333-444455556666'
$cpId = [guid]'29613cba-d62f-4998-a421-df2e124a2b4f'
$script:getVm = 0; $script:vmThrows = $false; $script:cpThrows = $false
$script:created = (Get-Date).AddDays(-3).AddHours(-2)
$script:cps = $null
function Get-VM { param($Name, $ErrorAction) $script:getVm++; if ($script:vmThrows) { throw "Hyper-V was unable to find a virtual machine with name '$Name'." }; [pscustomobject]@{ Name = $Name; Id = $vmId; ProcessorCount = 4; MemoryStartup = 8GB } }
function Get-VMCheckpoint { param($VMName, $Name, $ErrorAction) if ($script:cpThrows) { throw 'checkpoint read failed' }; if ($null -ne $script:cps) { return $script:cps }; [pscustomobject]@{ Name = $Name; Id = $cpId; CreationTime = $script:created } }
$lane = { param([hashtable]$A = @{}) $o = $null; $v = $null; $t = $null; try { $o = Get-Win32ToolkitHyperVLane -VMName 'win32tk-measure' -CheckpointName 'clean-base' @A -Verbose 4>&1 } catch { $t = $_ }
    [pscustomobject]@{ Lane = @($o | Where-Object { $_ -is [hashtable] }); Verbose = @($o | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }); Threw = $t } }

Write-Host '[1] a full read' -ForegroundColor Cyan
$script:getVm = 0
$r = & $lane
$l = $r.Lane[0]
$createdUtc = $script:created.ToUniversalTime()
if ($r.Lane.Count -eq 1 -and $l.VMName -eq 'win32tk-measure' -and $l.VMId -eq [string]$vmId -and $l.CheckpointName -eq 'clean-base' -and $l.CheckpointId -eq [string]$cpId -and $l.CheckpointObjectId -eq [string]$cpId) { Ok 'names and Ids (GUID strings)' } else { Bad "ids: $($l | ConvertTo-Json -Compress)" }
if ($l.CheckpointCreatedUtc -eq $createdUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) -and $l.CheckpointCreationTicks -eq $createdUtc.Ticks -and $l.CheckpointAgeDays -eq 3) { Ok "creation time in UTC 'o' form, its UTC ticks, age 3 days (floor)" } else { Bad "time: $($l | ConvertTo-Json -Compress)" }
if ($l.ProcessorCount -eq 4 -and $l.MemoryGB -eq 8 -and $l.ConcurrentLanes -eq 1 -and -not $l.ContainsKey('Attestation') -and $script:getVm -eq 1 -and $r.Verbose.Count -eq 0 -and -not $r.Threw) { Ok '4 vCPU, 8 GB, ConcurrentLanes 1, no Attestation key (the caller adds it); one Get-VM, no verbose line' } else { Bad "hw: $($l | ConvertTo-Json -Compress) getVm=$($script:getVm) verbose=$($r.Verbose -join ' | ')" }
$script:getVm = 0
$r = & $lane @{ VM = [pscustomobject]@{ Id = $vmId; ProcessorCount = 2; MemoryStartup = 4GB } }
if ($script:getVm -eq 0 -and $r.Lane[0].ProcessorCount -eq 2 -and $r.Lane[0].MemoryGB -eq 4) { Ok '-VM: the given object is used, no Get-VM' } else { Bad "-VM: getVm=$($script:getVm) lane=$($r.Lane[0] | ConvertTo-Json -Compress)" }

Write-Host '[2] fail-open' -ForegroundColor Cyan
$script:vmThrows = $true
$r = & $lane
$script:vmThrows = $false
if (-not $r.Threw -and $r.Lane[0].VMId -eq '' -and $null -eq $r.Lane[0].ProcessorCount -and $r.Lane[0].CheckpointId -eq [string]$cpId -and $r.Verbose.Count -eq 1) { Ok 'Get-VM throws: VMId '''', no hardware, the checkpoint still read, one verbose line' } else { Bad "vm throws: $($r.Lane[0] | ConvertTo-Json -Compress) verbose=$($r.Verbose -join ' | ') threw=$($r.Threw)" }
$script:cpThrows = $true
$r = & $lane
$script:cpThrows = $false
if (-not $r.Threw -and $r.Lane[0].CheckpointId -eq '' -and $r.Lane[0].CheckpointCreatedUtc -eq '' -and $null -eq $r.Lane[0].CheckpointCreationTicks -and $null -eq $r.Lane[0].CheckpointAgeDays -and $r.Lane[0].VMId -eq [string]$vmId -and $r.Verbose.Count -eq 1) { Ok 'Get-VMCheckpoint throws: no checkpoint identity, the VM still read, one verbose line' } else { Bad "cp throws: $($r.Lane[0] | ConvertTo-Json -Compress)" }
foreach ($case in @(
        @{ Tag = 'no checkpoint of that name'; Cps = @() }
        @{ Tag = 'two checkpoints of that name'; Cps = @([pscustomobject]@{ Id = $cpId; CreationTime = $script:created }, [pscustomobject]@{ Id = [guid]::NewGuid(); CreationTime = $script:created }) })) {
    $script:cps = $case.Cps
    $r = & $lane
    if (-not $r.Threw -and $r.Lane[0].CheckpointId -eq '' -and $null -eq $r.Lane[0].CheckpointCreationTicks -and $r.Verbose.Count -eq 1) { Ok "$($case.Tag): no checkpoint identity, one verbose line" } else { Bad "$($case.Tag): $($r.Lane[0] | ConvertTo-Json -Compress)" }
}
$script:cps = [pscustomobject]@{ Id = 'not-a-guid'; CreationTime = 'yesterday' }
$r = & $lane
$script:cps = $null
if (-not $r.Threw -and $r.Lane[0].CheckpointId -eq '' -and $r.Lane[0].CheckpointCreatedUtc -eq '' -and $null -eq $r.Lane[0].CheckpointCreationTicks) { Ok 'a non-GUID Id and a non-datetime creation time are not used' } else { Bad "odd values: $($r.Lane[0] | ConvertTo-Json -Compress)" }

Write-Host '[3] file hygiene' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$file = Join-Path $repo 'Private\Get-Win32ToolkitHyperVLane.ps1'
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
$catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
$badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
$ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
$top = @($ast.EndBlock.Statements)
$oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq 'Get-Win32ToolkitHyperVLane' -and -not $ast.ParamBlock
if (@($errs).Count -eq 0 -and $catches.Count -ge 2 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "ASCII, one function, $($catches.Count) catches with the C-2 line" } else { Bad "errors $(@($errs).Count), catches $($catches.Count), bad $($badCatch.Count), ascii $ascii, one function $oneFunction" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All HyperVLane tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail HyperVLane test(s) FAILED." -ForegroundColor Red; exit 1 }
