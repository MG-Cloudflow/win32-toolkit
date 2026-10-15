<#
    Publish app-body shape — arm64 architecture (G12), the MSIX min-OS floor (G8), and the Intune
    command lines / return codes (PKG-01: launched via Invoke-AppDeployToolkit.exe, never a bare
    32-bit powershell.exe).

    THE BUG (G12): the body sent 'applicableArchitectures' = $arch, and $arch can be 'arm64'
    (New-Win32ToolkitManualApp's ValidateSet and the '_arm64_' project-folder parse both produce it).
    Per Microsoft Learn, applicableArchitectures is a windowsArchitecture flags enum whose members are
    none/x86/x64/arm/neutral — 'arm64' is NOT one of them (the member is 'arm') — and its documented
    values are only none/x86/x64. So every arm64 publish sent an undocumented enum value to Graph.
    The modern property is allowedArchitectures, documented null/x86/x64/arm64; setting it makes Intune
    set applicableArchitectures to 'none' itself. This affects ALL installer types, not just MSIX.

    PKG-04: an app with NO detection rule (no install tattoo, no capture) used to be published anyway
    with an empty rule list - after the sign-in and the upload - so Intune could never tell whether it
    installed. Publish now refuses it with a W32T.NoDetectionRule error BEFORE any Graph call, unless
    -AllowNoDetectionRule is given (then detectionRules = @()).

    Graph is fully shadowed; nothing hits a tenant. The POST body is captured at the /mobileApps call
    and the run is aborted with a sentinel right after. The fixtures carry a deploy script with the
    install-tattoo marker, so the REAL Get-Win32DetectionRules builds the tattoo rule; -NoTattoo drops it.

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
$script:capturedJson = $null
# Every shadow that stands for a tenant/Graph step counts itself, so a gate can be proven to fire
# BEFORE any of them.
$script:graphCalls = 0
function Connect-Win32ToolkitGraph { $script:graphCalls++ }
# Publish now verifies WHICH TENANT it is about to write to (Assert-Win32ToolkitTenant) before the app
# shell is created. These fixtures pin no tenant, so the guard warns and proceeds; it still needs a
# live session to report, and the tenant-name lookup must not attempt a real Graph call from a test.
function Get-MgContext { $script:graphCalls++; [pscustomobject]@{ TenantId = 'tenant-1'; Account = 'test@contoso.com'; Scopes = @('DeviceManagementApps.ReadWrite.All'); ContextScope = 'Process'; AuthType = 'Delegated' } }
function Get-Win32ToolkitTenantInfo { $null }
function Get-Win32IntuneWinMetadata { param($IntuneWinPath) $script:graphCalls++; [pscustomobject]@{ UnencryptedSize = 1MB; SizeEncrypted = 1MB; FileName = 'x.intunewin'; EncryptionInfo = @{} } }
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    $script:graphCalls++
    if ($Uri -match '/mobileApps$' -and $Method -eq 'POST') {
        $script:capturedJson = [string]$Body
        $script:capturedBody = $Body | ConvertFrom-Json
        throw 'W32T_TEST_SENTINEL'   # stop before content upload — we only need the body
    }
    return [pscustomobject]@{ id = 'fake' }
}

# Bundled-PSADT read for the F-05 prerelease warning: the fixtures carry no module, so pin what the helper
# reports ('' = a stable PSADT, the default for every other case).
$script:pvPrerelease = ''
$script:pvThrow = $false
function Get-Win32ToolkitProjectPsadtVersion {
    param([string]$ProjectPath)
    $null = $ProjectPath
    if ($script:pvThrow) { throw 'manifest locked' }
    [pscustomobject]@{ Prerelease = $script:pvPrerelease; VersionText = $(if ($script:pvPrerelease) { "4.2.0-$script:pvPrerelease" } else { '4.1.8' }) }
}

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('w32body_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $base -Force | Out-Null

function New-Proj {
    param([string]$Name, [string]$Arch, [string]$InstallerType, [string]$MinRelease, [switch]$NoTattoo)
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
    # The deploy script only needs the tattoo marker the real Get-Win32DetectionRules keys on (never run).
    if (-not $NoTattoo) {
        Set-Content -LiteralPath (Join-Path $p 'Invoke-AppDeployToolkit.ps1') -Value '## win32-toolkit install tattoo - records the installed version (test stub)'
    }
    $iw = Join-Path $base "$Name.intunewin"; Set-Content -LiteralPath $iw -Value 'stub'
    return @{ Project = $p; IntuneWin = $iw }
}

function Get-Body {
    param($Proj, [switch]$AllowNoDetectionRule)
    $script:capturedBody = $null
    $script:capturedJson = $null
    try {
        Publish-Win32ToolkitIntuneApp -ProjectPath $Proj.Project -IntuneWinPath $Proj.IntuneWin `
            -AllowNoDetectionRule:$AllowNoDetectionRule -Confirm:$false -ErrorAction Stop 6>$null 3>$null | Out-Null
    } catch {
        if ("$($_.Exception.Message)" -notmatch 'W32T_TEST_SENTINEL') { throw }
    }
    return $script:capturedBody
}

# Runs Publish and returns the ErrorRecord it threw (or $null), the Graph-step count and the body (if any).
function Invoke-PublishGate {
    param($Proj, [switch]$DryRun)
    $script:graphCalls = 0
    $script:capturedBody = $null
    $err = $null
    try {
        Publish-Win32ToolkitIntuneApp -ProjectPath $Proj.Project -IntuneWinPath $Proj.IntuneWin `
            -WhatIf:$DryRun -Confirm:$false -ErrorAction Stop 6>$null 3>$null | Out-Null
    } catch { $err = $_ }
    [pscustomobject]@{ Error = $err; GraphCalls = $script:graphCalls; Body = $script:capturedBody }
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

    Write-Host '[3b] neutral / arm keep using applicableArchitectures (they are NOT allowedArchitectures values)' -ForegroundColor Cyan
    # winget reports 'neutral' for many MSIX packages. Collapsing it to x64 (as the first cut of the
    # arch guard did) would silently make those apps not-applicable on x86 and arm64 devices.
    foreach ($a in 'neutral', 'arm') {
        $bn = Get-Body (New-Proj -Name "N$a" -Arch $a -InstallerType 'msix')
        if ($bn.applicableArchitectures -eq $a -and $bn.PSObject.Properties.Name -notcontains 'allowedArchitectures') {
            Ok "'$a' -> applicableArchitectures = '$a' (not coerced to x64)"
        } else { Bad "'$a': applicable=[$($bn.applicableArchitectures)] allowed=[$($bn.allowedArchitectures)]" }
    }

    Write-Host '[3c] Architecture case is canonicalized before it is sent' -ForegroundColor Cyan
    # -notin is case-insensitive, so an AppConfig 'X64' passed the guard and was POSTed verbatim.
    $bc = Get-Body (New-Proj -Name 'Upper' -Arch 'X64' -InstallerType 'msi')
    if ($bc.allowedArchitectures -eq 'x64') { Ok "'X64' -> 'x64'" } else { Bad "case not canonicalized: [$($bc.allowedArchitectures)]" }

    Write-Host '[4] G8: an MSIX floors minimumSupportedWindowsRelease at 1809' -ForegroundColor Cyan
    # 1607 predates MSIX (needs 1709) and the -Regions provisioning flag (needs 1803).
    $bm = Get-Body (New-Proj -Name 'Msix' -Arch 'x64' -InstallerType 'msix' -MinRelease '1607')
    if ($bm.minimumSupportedWindowsRelease -eq '1809') { Ok 'msix + 1607 default -> raised to 1809' } else { Bad "msix minOS = [$($bm.minimumSupportedWindowsRelease)]" }

    $bm2 = Get-Body (New-Proj -Name 'Msix22' -Arch 'x64' -InstallerType 'msix' -MinRelease '22H2')
    if ($bm2.minimumSupportedWindowsRelease -eq '22H2') { Ok 'a higher org value is never lowered (22H2 kept)' } else { Bad "msix minOS = [$($bm2.minimumSupportedWindowsRelease)]" }

    Write-Host '[5] A non-MSIX keeps the configured floor (no unintended raise)' -ForegroundColor Cyan
    $bi = Get-Body (New-Proj -Name 'Msi' -Arch 'x64' -InstallerType 'msi' -MinRelease '1607')
    if ($bi.minimumSupportedWindowsRelease -eq '1607') { Ok 'msi + 1607 -> unchanged' } else { Bad "msi minOS = [$($bi.minimumSupportedWindowsRelease)]" }

    Write-Host '[6] PKG-01/PKG-02: the app is launched via Invoke-AppDeployToolkit.exe (the helper''s command lines)' -ForegroundColor Cyan
    # The 32-bit Intune Management Extension resolved the old bare 'powershell.exe' to SysWOW64: PSADT 4.2
    # exits 60008 there and PSADT 4.1 tattooed WOW6432Node. The body must carry exactly the helper's lines.
    $cl = Get-Win32ToolkitIntuneCommandLine
    $be = Get-Body (New-Proj -Name 'Exe' -Arch 'x64' -InstallerType 'exe')
    if ($be.installCommandLine -ceq $cl.Install) { Ok "installCommandLine = '$($be.installCommandLine)'" } else { Bad "installCommandLine = '$($be.installCommandLine)'" }
    if ($be.uninstallCommandLine -ceq $cl.Uninstall) { Ok "uninstallCommandLine = '$($be.uninstallCommandLine)'" } else { Bad "uninstallCommandLine = '$($be.uninstallCommandLine)'" }
    if ("$($be.installCommandLine)" -notmatch '^\s*powershell' -and "$($be.uninstallCommandLine)" -notmatch '^\s*powershell') { Ok 'neither command line starts with powershell.exe' } else { Bad 'a command line still starts with powershell' }
    if ("$($be.installCommandLine) $($be.uninstallCommandLine)" -notmatch '-DeployMode|AllowWowProcess|Sysnative') { Ok 'no -DeployMode / AllowWowProcess / Sysnative (D4, D6)' } else { Bad 'forbidden token in a command line' }
    if ($be.setupFilePath -ceq 'Invoke-AppDeployToolkit.ps1' -and $be.fileName -ceq 'Invoke-AppDeployToolkit.ps1') { Ok 'setupFilePath / fileName stay Invoke-AppDeployToolkit.ps1' } else { Bad "setupFilePath='$($be.setupFilePath)' fileName='$($be.fileName)'" }
    if ($be.installExperience.runAsAccount -eq 'system') { Ok 'still runs as SYSTEM' } else { Bad "runAsAccount = '$($be.installExperience.runAsAccount)'" }

    Write-Host '[7] returnCodes are exactly 0/1707 success, 3010 soft, 1641 hard, 1618 retry (1602 stays unmapped, D13)' -ForegroundColor Cyan
    $rc = @($be.returnCodes | ForEach-Object { "$($_.returnCode)=$($_.type)" } | Sort-Object)
    $expected = @('0=success', '1618=retry', '1641=hardReboot', '1707=success', '3010=softReboot') | Sort-Object
    if (($rc -join ',') -ceq ($expected -join ',')) { Ok "returnCodes: $($rc -join ', ')" } else { Bad "returnCodes: $($rc -join ', ')" }

    Write-Host '[8] the tattoo fixture publishes WITH its detection rule (the gate below is not a false positive)' -ForegroundColor Cyan
    $det = @($be.detectionRules)
    if ($det.Count -eq 1 -and $det[0].keyPath -eq 'HKEY_LOCAL_MACHINE\SOFTWARE\IT\Contoso\App' -and $det[0].detectionValue -eq '1.0') {
        Ok 'one tattoo version rule (HKLM\SOFTWARE\IT\Contoso\App, Version = 1.0)'
    } else { Bad "detectionRules: $($be.detectionRules | ConvertTo-Json -Compress -Depth 5)" }

    Write-Host '[9] PKG-04: no detection rule -> W32T.NoDetectionRule BEFORE any Graph call' -ForegroundColor Cyan
    $noDet = New-Proj -Name 'NoDet' -Arch 'x64' -InstallerType 'exe' -NoTattoo
    $g = Invoke-PublishGate $noDet
    if ($g.Error -and $g.Error.FullyQualifiedErrorId -eq 'W32T.NoDetectionRule') { Ok 'throws W32T.NoDetectionRule (FQID survives the Publish catch, C-2)' }
    else { Bad "error: FQID='$($g.Error.FullyQualifiedErrorId)' message='$($g.Error.Exception.Message)'" }
    if ($g.GraphCalls -eq 0) { Ok 'no sign-in, no tenant check, no .intunewin read, no Graph request' } else { Bad "$($g.GraphCalls) Graph step(s) ran before the refusal" }
    if ($null -eq $g.Body) { Ok 'no app shell was POSTed' } else { Bad 'an app shell was POSTed' }
    if ($g.Error -and $g.Error.CategoryInfo.Category -eq 'InvalidData' -and "$($g.Error.TargetObject)" -eq $noDet.Project) { Ok 'category InvalidData, target = the project path' }
    else { Bad "category='$($g.Error.CategoryInfo.Category)' target='$($g.Error.TargetObject)'" }
    $gm = "$($g.Error.Exception.Message)"
    if ($gm -match 'tattoo' -and $gm -match 'InstallationChanges_' -and $gm -match '-AllowNoDetectionRule' -and $gm -match 'Nothing was published') {
        Ok 'the message explains tattoo vs capture, names -AllowNoDetectionRule and says nothing was published'
    } else { Bad "message: $gm" }
    if (@([System.Text.Encoding]::UTF8.GetBytes($gm) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the message is ASCII' } else { Bad 'the message has non-ASCII characters' }

    Write-Host '[10] the refusal also fires under -WhatIf (the rule is built before the -WhatIf gate)' -ForegroundColor Cyan
    $gw = Invoke-PublishGate $noDet -DryRun
    if ($gw.Error -and $gw.Error.FullyQualifiedErrorId -eq 'W32T.NoDetectionRule' -and $gw.GraphCalls -eq 0) { Ok 'a dry run reports the missing rule too, still without Graph' }
    else { Bad "WhatIf: FQID='$($gw.Error.FullyQualifiedErrorId)' graph=$($gw.GraphCalls)" }
    $gok = Invoke-PublishGate (New-Proj -Name 'WhatIfOk' -Arch 'x64' -InstallerType 'exe') -DryRun
    if (-not $gok.Error -and $gok.GraphCalls -eq 0) { Ok 'a project WITH a rule still dry-runs cleanly under -WhatIf (no Graph)' }
    else { Bad "WhatIf with a rule: error='$($gok.Error)' graph=$($gok.GraphCalls)" }

    Write-Host '[11] -AllowNoDetectionRule publishes with detectionRules = @()' -ForegroundColor Cyan
    $warn = $null
    $script:capturedBody = $null; $script:capturedJson = $null
    try {
        Publish-Win32ToolkitIntuneApp -ProjectPath $noDet.Project -IntuneWinPath $noDet.IntuneWin -AllowNoDetectionRule `
            -Confirm:$false -ErrorAction Stop -WarningVariable warn 6>$null 3>$null | Out-Null
    } catch { if ("$($_.Exception.Message)" -notmatch 'W32T_TEST_SENTINEL') { Bad "unexpected error: $($_.Exception.Message)" } }
    if ($script:capturedBody) { Ok 'the app shell was POSTed' } else { Bad 'no body captured with -AllowNoDetectionRule' }
    if ($script:capturedJson -match '"detectionRules"\s*:\s*\[\s*\]') { Ok 'body carries "detectionRules": [] (an empty list, not null/missing)' }
    else { Bad "detectionRules in the JSON: $([regex]::Match([string]$script:capturedJson, '"detectionRules"[^\]]*\]').Value)" }
    if (@($warn | Where-Object { "$_" -cmatch 'WITHOUT' -and "$_" -match 'portal' }).Count -eq 1) { Ok 'warns once: add a detection rule in the Intune portal before assigning' }
    else { Bad "warnings: $(@($warn) -join ' | ')" }

    Write-Host '[12] F-05: a prerelease bundled PSADT warns before the -WhatIf gate and never blocks' -ForegroundColor Cyan
    $preProj = New-Proj -Name 'PreRel' -Arch 'x64' -InstallerType 'exe'
    foreach ($case in @(@{ Pre = 'rc2'; Want = 1 }, @{ Pre = ''; Want = 0 })) {
        $script:pvPrerelease = $case.Pre; $script:graphCalls = 0; $warn = $null; $err = $null
        try {
            Publish-Win32ToolkitIntuneApp -ProjectPath $preProj.Project -IntuneWinPath $preProj.IntuneWin -WhatIf `
                -Confirm:$false -ErrorAction Stop -WarningVariable warn 6>$null 3>$null | Out-Null
        } catch { $err = $_ }
        $pw = @($warn | Where-Object { "$_" -match 'PRERELEASE' })
        $label = if ($case.Pre) { "prerelease '$($case.Pre)'" } else { 'stable PSADT' }
        if (-not $err -and $script:graphCalls -eq 0 -and $pw.Count -eq $case.Want -and ($case.Want -eq 0 -or "$($pw[0])" -match [regex]::Escape('PSAppDeployToolkit 4.2.0-rc2'))) {
            Ok "$label -> $($case.Want) prerelease warning(s), dry run still clean (no Graph)"
        }
        else { Bad "$label -> error='$err' graph=$($script:graphCalls) warnings=$(@($warn) -join ' | ')" }
    }
    # A failure to READ the bundled module must never block a publish (and must not invent a warning).
    $script:pvThrow = $true; $script:pvPrerelease = 'rc2'; $script:graphCalls = 0; $warn = $null; $err = $null
    try {
        Publish-Win32ToolkitIntuneApp -ProjectPath $preProj.Project -IntuneWinPath $preProj.IntuneWin -WhatIf `
            -Confirm:$false -ErrorAction Stop -WarningVariable warn 6>$null 3>$null | Out-Null
    } catch { $err = $_ }
    $script:pvThrow = $false
    if (-not $err -and $script:graphCalls -eq 0 -and @($warn | Where-Object { "$_" -match 'PRERELEASE' }).Count -eq 0) {
        Ok 'unreadable bundled module -> no error, no prerelease warning, dry run still clean'
    }
    else { Bad "unreadable module -> error='$err' graph=$($script:graphCalls) warnings=$(@($warn) -join ' | ')" }
    # The live path continues past the gate with a prerelease project (warning only; reaches the app POST).
    $script:pvPrerelease = 'rc2'; $script:capturedBody = $null; $warn = $null
    try {
        Publish-Win32ToolkitIntuneApp -ProjectPath $preProj.Project -IntuneWinPath $preProj.IntuneWin `
            -Confirm:$false -ErrorAction Stop -WarningVariable warn 6>$null 3>$null | Out-Null
    } catch { if ("$($_.Exception.Message)" -notmatch 'W32T_TEST_SENTINEL') { Bad "unexpected error: $($_.Exception.Message)" } }
    if ($script:capturedBody -and @($warn | Where-Object { "$_" -match 'PRERELEASE' }).Count -eq 1) { Ok 'live publish of a prerelease project: one warning, the app shell is still POSTed' }
    else { Bad "live prerelease publish -> body=$([bool]$script:capturedBody) warnings=$(@($warn) -join ' | ')" }
    $script:pvPrerelease = ''
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PublishAppBody tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PublishAppBody test(s) FAILED." -ForegroundColor Red; exit 1 }
