<#
    Publish app-body shape — arm64 architecture (G12) and the MSIX min-OS floor (G8).

    THE BUG (G12): the body sent 'applicableArchitectures' = $arch, and $arch can be 'arm64'
    (New-Win32ToolkitManualApp's ValidateSet and the '_arm64_' project-folder parse both produce it).
    Per Microsoft Learn, applicableArchitectures is a windowsArchitecture flags enum whose members are
    none/x86/x64/arm/neutral — 'arm64' is NOT one of them (the member is 'arm') — and its documented
    values are only none/x86/x64. So every arm64 publish sent an undocumented enum value to Graph.
    The modern property is allowedArchitectures, documented null/x86/x64/arm64; setting it makes Intune
    set applicableArchitectures to 'none' itself. This affects ALL installer types, not just MSIX.

    Graph is fully shadowed; nothing hits a tenant. The POST body is captured at the /mobileApps call
    and the run is aborted with a sentinel right after.

    Run:  pwsh -File Tests\PublishAppBody.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Publish-Win32ToolkitIntuneApp.ps1')

# ── Graph shadows ────────────────────────────────────────────────────────────────────────────────
$script:capturedBody = $null
function Connect-Win32ToolkitGraph { }
function Get-Win32IntuneWinMetadata { param($IntuneWinPath) [pscustomobject]@{ UnencryptedSize = 1MB; SizeEncrypted = 1MB; FileName = 'x.intunewin'; EncryptionInfo = @{} } }
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    if ($Uri -match '/mobileApps$' -and $Method -eq 'POST') {
        $script:capturedBody = $Body | ConvertFrom-Json
        throw 'W32T_TEST_SENTINEL'   # stop before content upload — we only need the body
    }
    return [pscustomobject]@{ id = 'fake' }
}

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('w32body_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $base -Force | Out-Null

function New-Proj {
    param([string]$Name, [string]$Arch, [string]$InstallerType, [string]$MinRelease)
    $p = Join-Path $base $Name
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
    $cfg = [ordered]@{
        App       = [ordered]@{ Vendor='Contoso'; Name='App'; DisplayName='App'; Version='1.0'; Arch=$Arch; ScriptAuthor='IT' }
        Installer = [ordered]@{ Type=$InstallerType; FileName="App.$InstallerType"; SilentArgs='' }
    }
    if ($MinRelease) { $cfg['IntuneDefaults'] = [ordered]@{ MinimumWindowsRelease = $MinRelease } }
    ($cfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p "Files\App.$InstallerType") -Value 'stub'
    $iw = Join-Path $base "$Name.intunewin"; Set-Content -LiteralPath $iw -Value 'stub'
    return @{ Project = $p; IntuneWin = $iw }
}

function Get-Body {
    param($Proj)
    $script:capturedBody = $null
    try {
        Publish-Win32ToolkitIntuneApp -ProjectPath $Proj.Project -IntuneWinPath $Proj.IntuneWin `
            -Confirm:$false -ErrorAction Stop 6>$null 3>$null | Out-Null
    } catch {
        if ("$($_.Exception.Message)" -notmatch 'W32T_TEST_SENTINEL') { throw }
    }
    return $script:capturedBody
}

try {
    Write-Host '[1] G12: an arm64 app publishes via allowedArchitectures (not the invalid enum)' -ForegroundColor Cyan
    $b = Get-Body (New-Proj -Name 'Arm' -Arch 'arm64' -InstallerType 'msi')
    if (-not $b) { Bad 'no body captured — the shadow did not intercept the POST'; }
    else {
        if ($b.PSObject.Properties.Name -contains 'allowedArchitectures' -and $b.allowedArchitectures -eq 'arm64') {
            Ok "allowedArchitectures = 'arm64'"
        } else { Bad "allowedArchitectures = [$($b.allowedArchitectures)]" }
        # The old field must not carry arm64 — 'arm64' is not a windowsArchitecture member.
        if ($b.PSObject.Properties.Name -notcontains 'applicableArchitectures') {
            Ok 'applicableArchitectures is not sent (Intune sets it to none itself)'
        } else { Bad "applicableArchitectures still sent = [$($b.applicableArchitectures)]" }
    }

    Write-Host '[2] NO REGRESSION: x64 / x86 still publish correctly' -ForegroundColor Cyan
    foreach ($a in 'x64', 'x86') {
        $bx = Get-Body (New-Proj -Name "A$a" -Arch $a -InstallerType 'msi')
        if ($bx.allowedArchitectures -eq $a) { Ok "'$a' -> allowedArchitectures = '$a'" } else { Bad "'$a' -> [$($bx.allowedArchitectures)]" }
    }

    Write-Host '[3] An unrecognized architecture degrades to x64 + warns' -ForegroundColor Cyan
    $bj = Get-Body (New-Proj -Name 'Junk' -Arch 'sparc' -InstallerType 'msi')
    if ($bj.allowedArchitectures -eq 'x64') { Ok "junk arch -> x64" } else { Bad "junk arch -> [$($bj.allowedArchitectures)]" }

    Write-Host '[4] G8: an MSIX floors minimumSupportedWindowsRelease at 1809' -ForegroundColor Cyan
    # 1607 predates MSIX (needs 1709) and the -Regions provisioning flag (needs 1803).
    $bm = Get-Body (New-Proj -Name 'Msix' -Arch 'x64' -InstallerType 'msix' -MinRelease '1607')
    if ($bm.minimumSupportedWindowsRelease -eq '1809') { Ok 'msix + 1607 default -> raised to 1809' } else { Bad "msix minOS = [$($bm.minimumSupportedWindowsRelease)]" }

    $bm2 = Get-Body (New-Proj -Name 'Msix22' -Arch 'x64' -InstallerType 'msix' -MinRelease '22H2')
    if ($bm2.minimumSupportedWindowsRelease -eq '22H2') { Ok 'a higher org value is never lowered (22H2 kept)' } else { Bad "msix minOS = [$($bm2.minimumSupportedWindowsRelease)]" }

    Write-Host '[5] A non-MSIX keeps the configured floor (no unintended raise)' -ForegroundColor Cyan
    $bi = Get-Body (New-Proj -Name 'Msi' -Arch 'x64' -InstallerType 'msi' -MinRelease '1607')
    if ($bi.minimumSupportedWindowsRelease -eq '1607') { Ok 'msi + 1607 -> unchanged' } else { Bad "msi minOS = [$($bi.minimumSupportedWindowsRelease)]" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PublishAppBody tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PublishAppBody test(s) FAILED." -ForegroundColor Red; exit 1 }
