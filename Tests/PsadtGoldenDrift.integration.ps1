<#
    PSADT golden drift test (spec 3.6 task 4; DOC-03).

    Regenerates the pristine deploy-script template(s) with the PSAppDeployToolkit the selector picks and
    compares them with the committed goldens in Tests\Fixtures\psadt-<version>\ - the files every
    shape-detector, phase-block and generator suite is built on. A difference means PSADT changed its
    template: review the change (does the shape detector still recognise it? do the toolkit anchors still
    exist?), then refresh the golden together with that review (Tests\Fixtures\README.md).

      * PSADT 4.1.x: New-ADTTemplate (default)              -> Tests\Fixtures\psadt-<ver>\
      * PSADT 4.2.x: New-ADTTemplate (default)              -> Tests\Fixtures\psadt-<ver>\
                     New-ADTTemplate -ZeroConfig            -> Tests\Fixtures\psadt-<ver>-zeroconfig\
      * a prerelease is compared with the golden of its base version (4.2.0-rc2 -> psadt-4.2.0).

    Comparison after normalising: UTF-8 BOM, line endings, and the AppScriptDate value (the scaffold date).
    The template is generated in a CHILD pwsh that imports the selected module by path, into %TEMP%.

    No supported PSADT selected, or no golden for the selected version -> SKIP (exit 3); with
    $env:W32T_REQUIRE_PSADT set both are failures (exit 1). Nothing is installed; nothing is executed but
    New-ADTTemplate.

    Refreshing a golden (only together with a reviewed template-shape change, Tests\Fixtures\README.md):
    -UpdateGolden writes the fresh New-ADTTemplate output (its bytes as written: UTF-8 BOM, CRLF) over a
    golden that differs or is missing, and reports it instead of failing. Review 'git diff Tests/Fixtures'.
    Run-All never passes it.

    Run:  pwsh -File Tests\PsadtGoldenDrift.integration.ps1 [-UpdateGolden]
#>
[CmdletBinding()]
param(
    # Maintainer use only: overwrite / create the golden(s) of the selected PSADT version with fresh output.
    [switch]$UpdateGolden
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }
function Exit-Skip([string]$Why) {
    if ($env:W32T_REQUIRE_PSADT) { Write-Host "FAIL: $Why (W32T_REQUIRE_PSADT is set)" -ForegroundColor Red; exit 1 }
    Write-Host "SKIP: $Why" -ForegroundColor DarkYellow
    exit 3
}

$mod = Import-Module (Join-Path $repo 'win32-toolkit.psd1') -Force -PassThru
$sel = & $mod { Select-Win32ToolkitPsadtModule }
if ($sel.Status -ne 'Selected') { Exit-Skip "no supported PSAppDeployToolkit selected: $($sel.Reason)" }
Write-Host "PSAppDeployToolkit $($sel.VersionText) ($($sel.Module.Path))" -ForegroundColor DarkGray

# Golden folder per template variant; a prerelease uses its base version's goldens.
$base = '{0}.{1}.{2}' -f $sel.Version.Major, $sel.Version.Minor, [Math]::Max(0, $sel.Version.Build)
$is42 = $sel.Version -ge [version]'4.2.0'
$variants = [ordered]@{ 'default' = @{ Golden = "psadt-$base"; ZeroConfig = $false; Shape = $(if ($is42) { 'Psadt42Default' } else { 'Psadt41' }) } }
if ($is42) { $variants['zeroconfig'] = @{ Golden = "psadt-$base-zeroconfig"; ZeroConfig = $true; Shape = 'Psadt42ZeroConfig' } }
$missing = @($variants.Values | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repo "Tests\Fixtures\$($_.Golden)\Invoke-AppDeployToolkit.ps1")) } | ForEach-Object { $_.Golden })
if ($missing.Count -and -not $UpdateGolden) { Exit-Skip "no golden for PSAppDeployToolkit $($sel.VersionText) (Tests\Fixtures\$($missing -join ', Tests\Fixtures\'))" }

function ConvertTo-NormalisedTemplate([string]$Text) {
    $t = $Text.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"
    [regex]::Replace($t, "AppScriptDate = '\d{4}-\d{2}-\d{2}'", "AppScriptDate = '<date>'")
}

$out = Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-gd-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
New-Item -ItemType Directory -Path $out -Force | Out-Null
try {
    Write-Host "[1] Regenerate the template(s) with PSAppDeployToolkit $($sel.VersionText) in a child process" -ForegroundColor Cyan
    # The child gets every value through environment variables (no command-line quoting of paths).
    $child = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module -Name $env:W32T_GD_MODULE
$null = New-ADTTemplate -Destination $env:W32T_GD_OUT -Name 'default'
if ($env:W32T_GD_ZEROCONFIG -eq '1') { $null = New-ADTTemplate -Destination $env:W32T_GD_OUT -Name 'zeroconfig' -ZeroConfig }
'W32T-GD-DONE'
'@
    $pwsh = (Get-Process -Id $PID).Path
    $env:W32T_GD_MODULE = $sel.Module.Path
    $env:W32T_GD_OUT = $out
    $env:W32T_GD_ZEROCONFIG = if ($is42) { '1' } else { '0' }
    try { $childOut = & $pwsh -NoProfile -NonInteractive -Command $child 2>&1 }
    finally { Remove-Item Env:\W32T_GD_MODULE, Env:\W32T_GD_OUT, Env:\W32T_GD_ZEROCONFIG -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -eq 0 -and (@($childOut | ForEach-Object { "$_" }) -contains 'W32T-GD-DONE')) { Ok "New-ADTTemplate ran ($($variants.Keys -join ', '))" }
    else { Bad "child New-ADTTemplate failed (exit $LASTEXITCODE): $(@($childOut) -join ' | ')" }

    foreach ($name in $variants.Keys) {
        $v = $variants[$name]
        Write-Host "[2] $name -> Tests\Fixtures\$($v.Golden)" -ForegroundColor Cyan
        $fresh = Join-Path $out "$name\Invoke-AppDeployToolkit.ps1"
        $golden = Join-Path $repo "Tests\Fixtures\$($v.Golden)\Invoke-AppDeployToolkit.ps1"
        if (-not (Test-Path -LiteralPath $fresh)) { Bad "$name : New-ADTTemplate wrote no Invoke-AppDeployToolkit.ps1"; continue }
        $a = ConvertTo-NormalisedTemplate ([System.IO.File]::ReadAllText($fresh, [System.Text.Encoding]::UTF8))
        $b = if (Test-Path -LiteralPath $golden) { ConvertTo-NormalisedTemplate ([System.IO.File]::ReadAllText($golden, [System.Text.Encoding]::UTF8)) } else { $null }
        if ($a -ceq $b) { Ok "$name : identical to the golden (BOM, line endings and AppScriptDate normalised)" }
        elseif ($UpdateGolden) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $golden) -Force | Out-Null
            [System.IO.File]::WriteAllBytes($golden, [System.IO.File]::ReadAllBytes($fresh))
            Write-Host "  UPDATED: Tests\Fixtures\$($v.Golden)\Invoke-AppDeployToolkit.ps1 from PSAppDeployToolkit $($sel.VersionText) - review 'git diff Tests/Fixtures' and Tests\Fixtures\README.md before committing" -ForegroundColor Yellow
        }
        elseif ($null -eq $b) { Bad "$name : no golden at Tests\Fixtures\$($v.Golden)" }
        else {
            $la = $a -split "`n"; $lb = $b -split "`n"
            $first = 0
            while ($first -lt [Math]::Min($la.Count, $lb.Count) -and $la[$first] -ceq $lb[$first]) { $first++ }
            Bad ("$name : PSADT template DRIFT against Tests\Fixtures\$($v.Golden) ({0} vs {1} lines); first difference at line {2}:`n      golden: {3}`n      fresh : {4}`n      Review the template change (shape detector, toolkit anchors), then refresh the golden (Tests\Fixtures\README.md)." -f
                $lb.Count, $la.Count, ($first + 1), $(if ($first -lt $lb.Count) { $lb[$first] } else { '<end of file>' }), $(if ($first -lt $la.Count) { $la[$first] } else { '<end of file>' }))
        }
        # The fresh template must still be the layout the detector expects for it.
        $shape = & $mod { param($p) Get-Win32ToolkitDeployScriptShape -Path $p } $fresh
        if ($shape.Shape -eq $v.Shape) { Ok "$name : detected as $($shape.Shape) (DeployAppScriptVersion $($shape.DeployAppScriptVersion))" }
        else { Bad "$name : detected as $($shape.Shape), expected $($v.Shape) ($($shape.Reason))" }
    }
}
catch {
    Bad "unexpected error: $($_.Exception.Message)"
}
finally {
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host "PSADT golden drift test PASSED (PSAppDeployToolkit $($sel.VersionText))" -ForegroundColor Green; exit 0 }
Write-Host "$fail check(s) FAILED (PSAppDeployToolkit $($sel.VersionText))" -ForegroundColor Red
exit 1
