<#
    Hyper-V speed-up PR 3 (D11, A-10): Get-Win32ToolkitHyperVTarget, the one reader of the test VM and its base checkpoint.

      [1] Precedence per value: W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT -> HKCU HyperVVMName / HyperVCheckpoint ->
          'win32tk-golden' / 'clean-base'; Source and CheckpointSource say which; Pinned = the VM comes from the
          environment (a checkpoint pin alone does not pin the VM); blank registry values count as absent.
      [2] A pin is trimmed; 1-100 characters, no control character: 100 characters and a non-ASCII name pass.
      [3] An invalid pin (blank after the trim, 101 characters, a control character inside, DEL) throws
          W32T.HyperVTargetNotReady (ResourceUnavailable, target the variable's name) naming the variable; -NoThrow
          reports it in Problem with the name $null instead.
      [4] Exactly one object; file hygiene (ASCII, one function, no catch that could swallow a W32T error).

    The environment variables are set in this process only and removed at the end; HKCU is shadowed.

    Run:  pwsh -File Tests\HyperVTarget.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitHyperVTarget.ps1')
$script:cfg = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$script:cfg[$Name])) { $script:cfg[$Name] } else { $Default } }

function Set-Pin { param($Vm, $Cp)
    if ($null -eq $Vm) { Remove-Item Env:\W32T_HYPERV_VM -ErrorAction SilentlyContinue } else { [System.Environment]::SetEnvironmentVariable('W32T_HYPERV_VM', $Vm) }
    if ($null -eq $Cp) { Remove-Item Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue } else { [System.Environment]::SetEnvironmentVariable('W32T_HYPERV_CHECKPOINT', $Cp) }
}
function Get-T { param([switch]$NoThrow)
    $o = @(); $threw = $null
    try { $o = @(Get-Win32ToolkitHyperVTarget -NoThrow:$NoThrow) } catch { $threw = $_ }
    [pscustomobject]@{ Out = $o; T = $(if ($o.Count) { $o[0] } else { $null }); Threw = $threw }
}

try {
    # ============================== [1] precedence ==============================
    Write-Host '[1] precedence: environment -> registry -> default, per value' -ForegroundColor Cyan
    foreach ($case in @(
            @{ Tag = 'nothing set'; Vm = $null; Cp = $null; Cfg = @{}; Want = 'win32tk-golden|clean-base|Default|Default|False' }
            @{ Tag = 'registry only'; Vm = $null; Cp = $null; Cfg = @{ HyperVVMName = 'lab-vm'; HyperVCheckpoint = 'warm-x' }; Want = 'lab-vm|warm-x|Registry|Registry|False' }
            @{ Tag = 'blank registry values'; Vm = $null; Cp = $null; Cfg = @{ HyperVVMName = '  '; HyperVCheckpoint = '' }; Want = 'win32tk-golden|clean-base|Default|Default|False' }
            @{ Tag = 'both pinned over the registry'; Vm = 'win32tk-measure'; Cp = 'clean-auto'; Cfg = @{ HyperVVMName = 'lab-vm'; HyperVCheckpoint = 'warm-x' }; Want = 'win32tk-measure|clean-auto|Environment|Environment|True' }
            @{ Tag = 'the VM pinned, the checkpoint from the registry'; Vm = 'win32tk-measure'; Cp = $null; Cfg = @{ HyperVCheckpoint = 'warm-x' }; Want = 'win32tk-measure|warm-x|Environment|Registry|True' }
            @{ Tag = 'only the checkpoint pinned (the VM is not)'; Vm = $null; Cp = 'clean-auto'; Cfg = @{ HyperVVMName = 'lab-vm' }; Want = 'lab-vm|clean-auto|Registry|Environment|False' })) {
        Set-Pin $case.Vm $case.Cp; $script:cfg = $case.Cfg
        $x = Get-T
        $got = if ($x.T) { '{0}|{1}|{2}|{3}|{4}' -f $x.T.VMName, $x.T.CheckpointName, $x.T.Source, $x.T.CheckpointSource, $x.T.Pinned } else { "threw $($x.Threw)" }
        if (-not $x.Threw -and $got -ceq $case.Want -and $null -eq $x.T.Problem) { Ok "$($case.Tag): $got" } else { Bad "$($case.Tag): $got (want $($case.Want))" }
    }
    Set-Pin $null $null; $script:cfg = @{}

    # ============================== [2] valid pins ==============================
    Write-Host '[2] a pin is trimmed; 100 characters and non-ASCII names pass' -ForegroundColor Cyan
    foreach ($case in @(
            @{ Tag = 'spaces around'; Vm = '  win32tk-measure  '; Want = 'win32tk-measure' }
            @{ Tag = 'a tab around'; Vm = "`twin32tk-measure`t"; Want = 'win32tk-measure' }
            @{ Tag = '100 characters'; Vm = ('v' * 100); Want = ('v' * 100) }
            @{ Tag = 'spaces inside'; Vm = 'lane vm 2'; Want = 'lane vm 2' }
            @{ Tag = 'a non-ASCII name'; Vm = "lab-$([char]0x00E9)t$([char]0x00E9)"; Want = "lab-$([char]0x00E9)t$([char]0x00E9)" })) {
        Set-Pin $case.Vm $null
        $x = Get-T
        if (-not $x.Threw -and $x.T.VMName -ceq $case.Want -and $x.T.Pinned) { Ok "$($case.Tag): '$($x.T.VMName.Substring(0, [Math]::Min(20, $x.T.VMName.Length)))...' pinned" } else { Bad "$($case.Tag): $($x.Threw) $($x.T.VMName)" }
    }
    Set-Pin $null $null

    # ============================== [3] invalid pins ==============================
    Write-Host '[3] an invalid pin throws W32T.HyperVTargetNotReady; -NoThrow reports it' -ForegroundColor Cyan
    foreach ($case in @(
            @{ Tag = 'blank after the trim'; Vm = '   '; Cp = $null; Var = 'W32T_HYPERV_VM'; What = 'VM' }
            @{ Tag = '101 characters'; Vm = ('v' * 101); Cp = $null; Var = 'W32T_HYPERV_VM'; What = 'VM' }
            @{ Tag = 'a control character inside'; Vm = "win32tk$([char]27)[31m"; Cp = $null; Var = 'W32T_HYPERV_VM'; What = 'VM' }
            @{ Tag = 'a newline inside'; Vm = "a`nb"; Cp = $null; Var = 'W32T_HYPERV_VM'; What = 'VM' }
            @{ Tag = 'DEL inside'; Vm = "a$([char]0x7F)b"; Cp = $null; Var = 'W32T_HYPERV_VM'; What = 'VM' }
            @{ Tag = 'an invalid checkpoint pin'; Vm = 'win32tk-measure'; Cp = "  `t "; Var = 'W32T_HYPERV_CHECKPOINT'; What = 'checkpoint' })) {
        Set-Pin $case.Vm $case.Cp
        $x = Get-T
        $e = $x.Threw
        $msg = "$($case.Var) is not a valid $($case.What) name (1 to 100 characters, no control character). Nothing was started. Fix the variable, or remove it to use the registry's test VM."
        if ($e -and $e.FullyQualifiedErrorId -eq 'W32T.HyperVTargetNotReady' -and $e.CategoryInfo.Category -eq 'ResourceUnavailable' -and $e.TargetObject -eq $case.Var -and "$e" -ceq $msg -and $x.Out.Count -eq 0) {
            Ok "$($case.Tag): W32T.HyperVTargetNotReady naming $($case.Var)"
        } else { Bad "$($case.Tag): $($e.FullyQualifiedErrorId) / $($e.CategoryInfo.Category) / $($e.TargetObject) / $e" }
        $y = Get-T -NoThrow
        $nullName = if ($case.What -eq 'VM') { $null -eq $y.T.VMName } else { $null -eq $y.T.CheckpointName }
        if (-not $y.Threw -and $y.T.Problem -ceq "$($case.Var) is not a valid $($case.What) name (1 to 100 characters, no control character)" -and $nullName) {
            Ok "$($case.Tag), -NoThrow: Problem set, the invalid name `$null"
        } else { Bad "$($case.Tag) -NoThrow: $($y.Threw) $($y.T | ConvertTo-Json -Compress)" }
    }
    Set-Pin $null $null

    # ============================== [4] shape, hygiene ==============================
    Write-Host '[4] exactly one object; file hygiene' -ForegroundColor Cyan
    $x = Get-T
    if ($x.Out.Count -eq 1 -and (@($x.T.PSObject.Properties.Name) -join ',') -eq 'VMName,CheckpointName,Source,CheckpointSource,Pinned,Problem' -and $x.T.Pinned -is [bool]) { Ok 'one object: VMName, CheckpointName, Source, CheckpointSource, Pinned [bool], Problem' } else { Bad "shape: $($x.T | ConvertTo-Json -Compress)" }
    $file = Join-Path $repo 'Private\Get-Win32ToolkitHyperVTarget.ps1'
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    $top = @($ast.EndBlock.Statements)
    $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq 'Get-Win32ToolkitHyperVTarget' -and -not $ast.ParamBlock
    if (@($errs).Count -eq 0 -and $catches.Count -eq 0 -and $ascii -and $oneFunction) { Ok 'ASCII, one function, no catch' } else { Bad "errors $(@($errs).Count), catches $($catches.Count), ascii $ascii, one function $oneFunction" }
}
finally {
    Set-Pin $null $null
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All HyperVTarget tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail HyperVTarget test(s) FAILED." -ForegroundColor Red; exit 1 }
