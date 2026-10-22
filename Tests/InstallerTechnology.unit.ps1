<#
    Get-Win32ToolkitInstallerTechnology: the installer technology from the installer file's signature
    (installer-identity PR 2 spec 2.2, L13, B2 #1).

    THE GAP: a manual app (or a winget package labelled only 'exe') carries no installer technology, so an
    EXE uninstaller whose uninstall entry has no silent switch got none and ran with its UI as SYSTEM. The
    helper reads the NSIS first header / the Inno Setup loader id from the file itself, never executes it.

    Covered here (synthetic files written to %TEMP% at run time - no binary fixture, no real installer):
      [1]  NSIS signature at 512*k+4 for k = 1, 371, 2047 -> 'nullsoft'; unaligned (512*k+5) -> ''; beyond
           the first 1 MiB -> ''.
      [2]  'rDlPtS02' at 900 000 -> 'inno'; beyond the first 4 MiB -> ''; both signatures -> ''.
      [3]  empty file, missing path, '' / $null, a folder, a file the test holds open exclusively -> '', no
           throw, one verbose line.
      [4]  a 6 MB file reads at most 4 MiB (an Inno id at 5 MB is not seen) within 2 s.
      [5]  C-4 / K1: the file is ASCII-only, defines only its function, [OutputType([string])], and its only
           catch starts with the C-2 re-throw.

    Nothing is installed or executed; nothing touches the network; everything is written below %TEMP%.

    Run:  pwsh -File Tests\InstallerTechnology.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$helperPath = Join-Path $repo 'Private\Get-Win32ToolkitInstallerTechnology.ps1'
if (-not (Test-Path -LiteralPath $helperPath)) { Write-Host "FAIL: $helperPath is missing" -ForegroundColor Red; exit 1 }
. $helperPath

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32it_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$nsis = [byte[]](0xEF, 0xBE, 0xAD, 0xDE) + [System.Text.Encoding]::ASCII.GetBytes('NullsoftInst')
$inno = [System.Text.Encoding]::ASCII.GetBytes('rDlPtS02')

# 'MZ' + zeros of -Size bytes, with each byte array of -Patch written at its offset.
function Write-SyntheticFile {
    param([string]$Name, [int]$Size, [hashtable]$Patch = @{})
    $bytes = [byte[]]::new($Size)
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
    foreach ($offset in $Patch.Keys) { [Array]::Copy([byte[]]$Patch[$offset], 0, $bytes, [int]$offset, $Patch[$offset].Length) }
    $file = Join-Path $root $Name
    [System.IO.File]::WriteAllBytes($file, $bytes)
    $file
}

# The helper's result and verbose lines; a throw is reported, never propagated.
function Invoke-Tech([AllowNull()][AllowEmptyString()][string]$Path) {
    $verbose = @()
    $result = $null
    $threw = ''
    try {
        $result = Get-Win32ToolkitInstallerTechnology -Path $Path -Verbose 4>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.VerboseRecord]) { $verbose += $_.Message } else { $_ }
        }
    }
    catch { $threw = $_.Exception.Message }
    [pscustomobject]@{ Result = $result; Verbose = $verbose; Threw = $threw }
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # == [1] NSIS ======================================================================================
    Write-Host '[1] NSIS first header at a 512-byte aligned offset within the first 1 MiB' -ForegroundColor Cyan
    foreach ($k in 1, 371, 2047) {
        $file = Write-SyntheticFile -Name "nsis$k.exe" -Size (1MB + 4096) -Patch @{ (512 * $k + 4) = $nsis }
        $r = Invoke-Tech $file
        if ($r.Result -ceq 'nullsoft' -and -not $r.Threw) { Ok "signature at 512*$k+4 -> 'nullsoft'" } else { Bad "k=$k -> '$($r.Result)' threw='$($r.Threw)'" }
    }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'nsisAtEnd.exe' -Size (512 * 2047 + 20) -Patch @{ (512 * 2047 + 4) = $nsis })
    if ($r.Result -ceq 'nullsoft') { Ok 'a header that ends exactly at the end of the file (512*k+20 = length) is read' } else { Bad "header at the very end -> '$($r.Result)'" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'nsisUnaligned.exe' -Size 400000 -Patch @{ (512 * 371 + 5) = $nsis })
    if ($r.Result -ceq '' -and -not $r.Threw) { Ok "unaligned signature (512*371+5) -> ''" } else { Bad "unaligned -> '$($r.Result)'" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'nsisAtZero.exe' -Size 4096 -Patch @{ 4 = $nsis })
    if ($r.Result -ceq '') { Ok "signature at offset 0+4 (k = 0 is not a first header) -> ''" } else { Bad "k=0 -> '$($r.Result)'" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'nsisBeyond.exe' -Size (1MB + 8192) -Patch @{ (512 * 2048 + 4) = $nsis })
    if ($r.Result -ceq '' -and @($r.Verbose | Where-Object { $_ -match 'no NSIS or Inno Setup signature' }).Count -eq 1) { Ok "signature beyond the first 1 MiB (512*2048+4) -> '' with one verbose line" } else { Bad "beyond 1 MiB -> '$($r.Result)' verbose=$($r.Verbose -join ' | ')" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'nsisTruncated.exe' -Size (512 * 3 + 12) -Patch @{ (512 * 3 + 4) = $nsis[0..7] })
    if ($r.Result -ceq '' -and -not $r.Threw) { Ok "a header cut off by the end of the file -> '', no index error" } else { Bad "truncated -> '$($r.Result)' threw='$($r.Threw)'" }

    # == [2] Inno Setup + both =========================================================================
    Write-Host '[2] Inno Setup loader id within the first 4 MiB; both signatures -> unknown' -ForegroundColor Cyan
    $r = Invoke-Tech (Write-SyntheticFile -Name 'inno.exe' -Size 1000000 -Patch @{ 900000 = $inno })
    if ($r.Result -ceq 'inno') { Ok "'rDlPtS02' at 900 000 -> 'inno'" } else { Bad "inno -> '$($r.Result)'" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'innoEdge.exe' -Size (4MB + 64) -Patch @{ (4MB - 6) = $inno[0..5] })
    if ($r.Result -ceq 'inno') { Ok "'rDlPtS' ending exactly at 4 MiB -> 'inno'" } else { Bad "inno at the 4 MiB edge -> '$($r.Result)'" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'innoBeyond.exe' -Size (4MB + 4096) -Patch @{ (4MB + 100) = $inno })
    if ($r.Result -ceq '') { Ok "'rDlPtS02' beyond the first 4 MiB -> ''" } else { Bad "inno beyond 4 MiB -> '$($r.Result)'" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'both.exe' -Size 1000000 -Patch @{ (512 * 10 + 4) = $nsis; 900000 = $inno })
    if ($r.Result -ceq '' -and @($r.Verbose | Where-Object { $_ -match 'both an NSIS and an Inno Setup signature' }).Count -eq 1) { Ok "both signatures -> '' with one verbose line" } else { Bad "both -> '$($r.Result)' verbose=$($r.Verbose -join ' | ')" }
    $r = Invoke-Tech (Write-SyntheticFile -Name 'lower.exe' -Size 4096 -Patch @{ 1000 = [System.Text.Encoding]::ASCII.GetBytes('rdlpts') })
    if ($r.Result -ceq '') { Ok "the Inno id is case-sensitive ('rdlpts' -> '')" } else { Bad "lower-case id -> '$($r.Result)'" }

    # == [3] no file / unreadable ======================================================================
    Write-Host '[3] empty, missing, blank, a folder, a locked file -> unknown, never a throw' -ForegroundColor Cyan
    $empty = Join-Path $root 'empty.exe'
    [System.IO.File]::WriteAllBytes($empty, [byte[]]@())
    $folder = Join-Path $root 'a-folder.exe'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    foreach ($case in @(
            @{ Label = 'an empty file'; Path = $empty }
            @{ Label = 'a missing path'; Path = (Join-Path $root 'missing.exe') }
            @{ Label = "''"; Path = '' }
            @{ Label = '$null'; Path = $null }
            @{ Label = 'a folder'; Path = $folder }
        )) {
        $r = Invoke-Tech $case.Path
        if ($r.Result -ceq '' -and -not $r.Threw -and $r.Verbose.Count -eq 1) { Ok "$($case.Label) -> '', no throw, one verbose line" } else { Bad "$($case.Label) -> '$($r.Result)' threw='$($r.Threw)' verbose=$($r.Verbose -join ' | ')" }
    }
    $locked = Write-SyntheticFile -Name 'locked.exe' -Size 4096 -Patch @{ 516 = $nsis }
    $hold = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $r = Invoke-Tech $locked }
    finally { $hold.Dispose() }
    if ($r.Result -ceq '' -and -not $r.Threw -and @($r.Verbose | Where-Object { $_ -match 'could not be read' }).Count -eq 1) { Ok "a file held open exclusively by the test -> '', no throw, 'could not be read'" } else { Bad "locked -> '$($r.Result)' threw='$($r.Threw)' verbose=$($r.Verbose -join ' | ')" }
    $r = Invoke-Tech $locked
    if ($r.Result -ceq 'nullsoft') { Ok "the same file, released -> 'nullsoft' (the lock was the only reason)" } else { Bad "released -> '$($r.Result)'" }
    $ctl = Join-Path $root "ctl$([char]7)name.exe"
    $r = Invoke-Tech $ctl
    if ($r.Result -ceq '' -and @($r.Verbose | Where-Object { $_ -match 'ctl\?name\.exe' -and $_ -notmatch [char]7 }).Count -eq 1) { Ok 'a control character in the path prints as ? in the verbose line' } else { Bad "control character: $($r.Verbose -join ' | ')" }

    # == [4] bounded read ==============================================================================
    Write-Host '[4] a 6 MB file: at most the first 4 MiB are read, within 2 s' -ForegroundColor Cyan
    $big = Write-SyntheticFile -Name 'big.exe' -Size 6000000 -Patch @{ 5000000 = $inno }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tech $big
    $clock.Stop()
    if ($r.Result -ceq '' -and $clock.Elapsed.TotalSeconds -lt 2) { Ok "an Inno id at 5 MB is not read -> '' in $([int]$clock.Elapsed.TotalMilliseconds) ms" } else { Bad "6 MB file -> '$($r.Result)' in $([int]$clock.Elapsed.TotalMilliseconds) ms" }
    $big2 = Write-SyntheticFile -Name 'big2.exe' -Size 6000000 -Patch @{ (512 * 1000 + 4) = $nsis }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tech $big2
    $clock.Stop()
    if ($r.Result -ceq 'nullsoft' -and $clock.Elapsed.TotalSeconds -lt 2) { Ok "a 6 MB NSIS file -> 'nullsoft' in $([int]$clock.Elapsed.TotalMilliseconds) ms" } else { Bad "6 MB NSIS -> '$($r.Result)' in $([int]$clock.Elapsed.TotalMilliseconds) ms" }

    # == [5] C-4 / K1 ==================================================================================
    Write-Host '[5] the file: ASCII-only, one function, [OutputType([string])], its catch starts with the C-2 re-throw' -ForegroundColor Cyan
    if (@([System.IO.File]::ReadAllBytes($helperPath) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'Get-Win32ToolkitInstallerTechnology.ps1 is ASCII-only' } else { Bad 'non-ASCII bytes' }
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$null, [ref]$errs)
    $top = @($ast.EndBlock.Statements)
    if (-not ($errs -and $errs.Count) -and $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and -not $ast.BeginBlock -and -not $ast.ProcessBlock) { Ok 'parses and defines only its function (no top-level code)' } else { Bad "top-level statements: $($top.Count)" }
    $outType = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] -and $n.TypeName.Name -eq 'OutputType' }, $true))
    if ($outType.Count -eq 1 -and $outType[0].Extent.Text -ceq '[OutputType([string])]') { Ok '[OutputType([string])]' } else { Bad "OutputType: $($outType.Extent.Text)" }
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    if ($catches.Count -eq 1 -and $catches[0].Body.Statements.Count -and $catches[0].Body.Statements[0].Extent.Text -ceq "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }") { Ok 'exactly one catch, starting with the C-2 line' } else { Bad "catches: $($catches.Count)" }
    $runs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Start-Process', 'Invoke-Expression', 'iex', '&', 'Start-ADTProcess') }, $true))
    if ($runs.Count -eq 0) { Ok 'starts no process (reads only)' } else { Bad "process calls: $($runs.Extent.Text -join ' | ')" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All InstallerTechnology tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail InstallerTechnology test(s) FAILED." -ForegroundColor Red; exit 1 }
