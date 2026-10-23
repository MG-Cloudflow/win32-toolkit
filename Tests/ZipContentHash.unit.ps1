<#
    Hyper-V speed-up PR 1 (A-3): Get-Win32ToolkitZipContentHash, the CopyInSha256 of a Hyper-V run's record.

      [1] The value: SHA256 (upper-case hex) over the ordinal-sorted lines "<entry>`t<SHA256 of its bytes>`n" (a folder
          entry "<name>/`t-`n"), recomputed here independently; the same entries in another order or with other
          timestamps give the same value; a changed byte, a renamed entry or an extra folder entry gives another.
      [2] Edge cases: an empty zip (the hash of nothing), a file that is not a zip, a missing path and an empty path ->
          $null for the last three, never a throw.
      [3] File hygiene: ASCII, one function, every catch starts with the C-2 line.

    Temp files only; nothing else is touched.

    Run:  pwsh -File Tests\ZipContentHash.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitZipContentHash.ps1')
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32zch_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $TMP -Force | Out-Null

# Writes a zip with the given entries, in the given order: a name ending in '/' is a folder entry, any other a file
# with the given UTF-8 text; every entry gets the given write time.
function New-TestZip {
    param([string]$Name, [object[]]$Entries, [datetime]$Stamp = [datetime]'2026-10-23T10:00:00')
    $path = Join-Path $TMP $Name
    $zip = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($e in $Entries) {
            $entry = $zip.CreateEntry($e.Name, [System.IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = [datetimeoffset]$Stamp
            if (-not $e.Name.EndsWith('/')) {
                $s = $entry.Open()
                try { $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$e.Text); $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
            }
        }
    }
    finally { $zip.Dispose() }
    $path
}
function Get-Sha([byte[]]$Bytes) { $sha = [System.Security.Cryptography.SHA256]::Create(); try { [System.Convert]::ToHexString($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() } }

try {
    Write-Host '[1] the value and what changes it' -ForegroundColor Cyan
    $entries = @(
        @{ Name = 'Files/'; Text = '' }
        @{ Name = 'Files/setup.exe'; Text = 'binary' }
        @{ Name = 'Invoke-AppDeployToolkit.ps1'; Text = '# deploy' }
        @{ Name = 'Sandbox/Logs/'; Text = '' }
    )
    $z1 = New-TestZip 'a.zip' $entries
    $h1 = Get-Win32ToolkitZipContentHash -ZipPath $z1
    $lines = @(
        "Files/`t-`n"
        "Files/setup.exe`t$(Get-Sha ([System.Text.Encoding]::UTF8.GetBytes('binary')))`n"
        "Invoke-AppDeployToolkit.ps1`t$(Get-Sha ([System.Text.Encoding]::UTF8.GetBytes('# deploy')))`n"
        "Sandbox/Logs/`t-`n"
    )
    [System.Array]::Sort($lines, [System.StringComparer]::Ordinal)
    $want = Get-Sha ([System.Text.Encoding]::UTF8.GetBytes([string]::Concat($lines)))
    if ($h1 -is [string] -and $h1 -ceq $want) { Ok "the documented formula, recomputed independently ($($h1.Substring(0, 12))...)" } else { Bad "hash $h1, expected $want" }
    $z2 = New-TestZip 'b.zip' @($entries[3], $entries[1], $entries[2], $entries[0]) -Stamp ([datetime]'2001-01-01T00:00:00')
    if ((Get-Win32ToolkitZipContentHash -ZipPath $z2) -ceq $h1) { Ok 'the same entries in another order, with other timestamps: the same value' } else { Bad 'order or timestamps changed the value' }
    $z3 = New-TestZip 'c.zip' @($entries[0], @{ Name = 'Files/setup.exe'; Text = 'binarY' }, $entries[2], $entries[3])
    if ((Get-Win32ToolkitZipContentHash -ZipPath $z3) -cne $h1) { Ok 'one changed byte: another value' } else { Bad 'a changed byte kept the value' }
    $z4 = New-TestZip 'd.zip' @($entries[0], @{ Name = 'Files/setup2.exe'; Text = 'binary' }, $entries[2], $entries[3])
    if ((Get-Win32ToolkitZipContentHash -ZipPath $z4) -cne $h1) { Ok 'a renamed entry: another value' } else { Bad 'a renamed entry kept the value' }
    $z5 = New-TestZip 'e.zip' (@($entries) + @(@{ Name = 'Files/Empty/'; Text = '' }))
    if ((Get-Win32ToolkitZipContentHash -ZipPath $z5) -cne $h1) { Ok 'an extra (empty) folder entry: another value' } else { Bad 'a folder entry is not counted' }

    Write-Host '[2] edge cases: never a throw' -ForegroundColor Cyan
    $zEmpty = New-TestZip 'empty.zip' @()
    $hEmpty = Get-Win32ToolkitZipContentHash -ZipPath $zEmpty
    if ($hEmpty -ceq (Get-Sha ([byte[]]@()))) { Ok 'an empty zip: the SHA256 of nothing' } else { Bad "empty zip: $hEmpty" }
    $notZip = Join-Path $TMP 'not-a-zip.zip'
    Set-Content -LiteralPath $notZip -Value 'this is not a zip'
    foreach ($case in @(@{ Tag = 'a file that is not a zip'; P = $notZip }, @{ Tag = 'a missing path'; P = (Join-Path $TMP 'missing.zip') }, @{ Tag = 'an empty path'; P = '' })) {
        $r = 'not-set'; $threw = $null
        try { $r = Get-Win32ToolkitZipContentHash -ZipPath $case.P } catch { $threw = $_ }
        if (-not $threw -and $null -eq $r) { Ok "$($case.Tag): `$null, no throw" } else { Bad "$($case.Tag): threw=$threw result=$r" }
    }
    $lock = [System.IO.File]::Open($z1, 'Open', 'Read', 'None')
    try {
        $r = 'not-set'; $threw = $null
        try { $r = Get-Win32ToolkitZipContentHash -ZipPath $z1 } catch { $threw = $_ }
        if (-not $threw -and $null -eq $r) { Ok 'a zip another process holds open exclusively: $null, no throw' } else { Bad "locked: threw=$threw result=$r" }
    }
    finally { $lock.Dispose() }

    Write-Host '[3] file hygiene' -ForegroundColor Cyan
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    $file = Join-Path $repo 'Private\Get-Win32ToolkitZipContentHash.ps1'
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    $top = @($ast.EndBlock.Statements)
    $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq 'Get-Win32ToolkitZipContentHash' -and -not $ast.ParamBlock
    if (@($errs).Count -eq 0 -and $catches.Count -ge 1 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "ASCII, one function, $($catches.Count) catch(es) with the C-2 line" } else { Bad "errors $(@($errs).Count), catches $($catches.Count), bad $($badCatch.Count), ascii $ascii, one function $oneFunction" }
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -like '*-Win32Toolkit*' })
    if ($calls.Count -eq 0) { Ok 'it calls no module function (the prebuild thread job rebuilds it from its text)' } else { Bad "module calls: $($calls -join ', ')" }
}
finally {
    Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All ZipContentHash tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail ZipContentHash test(s) FAILED." -ForegroundColor Red; exit 1 }
