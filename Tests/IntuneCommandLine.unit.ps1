<#
    Get-Win32ToolkitIntuneCommandLine - the ONE source of the Intune install/uninstall command lines.

    THE BUG (PKG-01 / PKG-02): Publish sent
        powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install
    The Intune Management Extension is 32-bit, so that bare powershell.exe resolves to SysWOW64 on a 64-bit
    device: PSADT 4.2 exits 60008 before any phase runs, and PSADT 4.1 runs 32-bit and writes the install
    tattoo under WOW6432Node, where the 64-bit detection rule never finds it. The fix is PSADT's AnyCPU
    launcher, Invoke-AppDeployToolkit.exe - never AllowWowProcess, never a Sysnative path, and never a
    forced -DeployMode (D4, D6).

    Asserts the exact strings, the forbidden tokens, that the helper is constant and parameterless, and
    that Publish / Export-Documentation take their command lines from it (no product file still carries
    the old 'powershell.exe ... -File' command line).

    Run:  pwsh -File Tests\IntuneCommandLine.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$helperPath = Join-Path $repo 'Private\Get-Win32ToolkitIntuneCommandLine.ps1'
. $helperPath

Write-Host '[1] exact command lines' -ForegroundColor Cyan
$cl = Get-Win32ToolkitIntuneCommandLine
if ($cl.Install -ceq 'Invoke-AppDeployToolkit.exe -DeploymentType Install') { Ok "Install   = '$($cl.Install)'" } else { Bad "Install = '$($cl.Install)'" }
if ($cl.Uninstall -ceq 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall') { Ok "Uninstall = '$($cl.Uninstall)'" } else { Bad "Uninstall = '$($cl.Uninstall)'" }
if ($cl.Launcher -ceq 'Invoke-AppDeployToolkit.exe') { Ok "Launcher  = '$($cl.Launcher)'" } else { Bad "Launcher = '$($cl.Launcher)'" }
if ($cl.Script -ceq 'Invoke-AppDeployToolkit.ps1') { Ok "Script    = '$($cl.Script)'" } else { Bad "Script = '$($cl.Script)'" }
$names = @($cl.PSObject.Properties.Name)
if (($names -join ',') -eq 'Install,Uninstall,Launcher,Script') { Ok 'exactly the four contract properties, in contract order' } else { Bad "properties: $($names -join ',')" }
if ($cl.Install.StartsWith($cl.Launcher + ' ') -and $cl.Uninstall.StartsWith($cl.Launcher + ' ')) { Ok 'both command lines start with the launcher (no interpreter in front of it)' } else { Bad 'a command line does not start with the launcher' }

Write-Host '[2] forbidden tokens (D4 / D6)' -ForegroundColor Cyan
$forbiddenHits = 0
foreach ($p in $names) {
    $v = [string]$cl.$p
    foreach ($bad in @('powershell', 'pwsh', '-DeployMode', 'AllowWowProcess', 'Sysnative', 'SysWOW64', '-File', '-ExecutionPolicy')) {
        if ($v.IndexOf($bad, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { Bad "$p contains '$bad': $v"; $forbiddenHits++ }
    }
}
if ($forbiddenHits -eq 0) { Ok 'no powershell.exe, -DeployMode, AllowWowProcess, Sysnative, SysWOW64, -File or -ExecutionPolicy anywhere' }

Write-Host '[3] constant and parameterless' -ForegroundColor Cyan
$cl2 = Get-Win32ToolkitIntuneCommandLine
if (($cl2 | ConvertTo-Json -Compress) -eq ($cl | ConvertTo-Json -Compress)) { Ok 'two calls return identical values' } else { Bad 'the helper is not constant' }
$cl2.Install = 'tampered'
if ((Get-Win32ToolkitIntuneCommandLine).Install -ceq 'Invoke-AppDeployToolkit.exe -DeploymentType Install') { Ok 'every call returns a fresh object (a caller cannot change the source)' } else { Bad 'a caller mutated the shared value' }
$common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
$own = @((Get-Command Get-Win32ToolkitIntuneCommandLine).Parameters.Keys | Where-Object { $_ -notin $common })
if ($own.Count -eq 0) { Ok 'no parameters (nothing can be spliced into a command line)' } else { Bad "parameters: $($own -join ', ')" }

Write-Host '[4] the helper file is ASCII-only (C-4)' -ForegroundColor Cyan
$bytes = [System.IO.File]::ReadAllBytes($helperPath)
if (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'ASCII-only' } else { Bad 'non-ASCII bytes in the helper' }

Write-Host '[5] Publish and Export-Documentation take their command lines from the helper' -ForegroundColor Cyan
foreach ($rel in @('Public\Publish-Win32ToolkitIntuneApp.ps1', 'Public\Export-Win32ToolkitDocumentation.ps1')) {
    $path = Join-Path $repo $rel
    $ast  = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Win32ToolkitIntuneCommandLine' }, $true)
    if ($calls.Count -ge 1) { Ok "$rel calls Get-Win32ToolkitIntuneCommandLine" } else { Bad "$rel does not call the helper" }
    # No string constant in the file may be a command line of its own (comments may still explain the old one).
    $strings = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
    $hard = @($strings | Where-Object { $_.Extent.Text -match '-DeploymentType\s+(Install|Uninstall)' })
    if ($hard.Count -eq 0) { Ok "$rel hard-codes no '-DeploymentType Install|Uninstall' command line" } else { Bad "$rel still hard-codes: $($hard[0].Extent.Text)" }
}

Write-Host '[6] no product file carries the old powershell.exe -File command line' -ForegroundColor Cyan
$old = 'powershell.exe -ExecutionPolicy Bypass -File'
$hits = @(Get-ChildItem -Path (Join-Path $repo 'Public'), (Join-Path $repo 'Private') -Filter '*.ps1' -File |
    Select-String -SimpleMatch -Pattern $old)
if ($hits.Count -eq 0) { Ok "no '$old' in Public\ or Private\" } else { Bad "still present: $(($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All IntuneCommandLine tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail IntuneCommandLine test(s) FAILED." -ForegroundColor Red; exit 1 }
