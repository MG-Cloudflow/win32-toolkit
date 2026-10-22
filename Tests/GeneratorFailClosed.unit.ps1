<#
    Unit tests for the shape-aware, fail-closed generator Set-PSADTDataDrivenScript (spec 2.8, 3.2 task 4)
    and its writer Write-Win32ToolkitDeployScript.

      * 4.1.8 and 4.2.0 Zero-Config goldens: $true, no warnings, host + Windows PowerShell 5.1 parse clean,
        UTF-8 BOM, idempotent; the generated-code contract (spec 5.1/5.2) reproduced byte-for-byte on 4.2;
        the install/uninstall routines are today's (1.1.6) routines, comments included.
      * legacy 1.1.6 fixtures: $true and byte-identical.
      * fail closed: 4.2 default template, missing 4.1 marker, DeployAppScriptVersion 4.3.0, unknown shape,
        missing file, missing session anchor -> W32T.UnsupportedTemplateShape with the stable C-1 wording,
        file byte-identical; a forced 5.1 parse error -> W32T.GeneratedScriptInvalid, original bytes restored.
      * gen-2 re-render (loader text changed -> catalog text), AppScriptDate miss -> $false + warning,
        msp only on 4.2, -ManualInstall toggling, MSI Zero-Config anchors kept, ExitWithMsiCodes once,
        hostile AppConfig values never reach the script.

    Run:  pwsh -File Tests\GeneratorFailClosed.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# C-5 range + WP-A contract shadow (spec 2.2).
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
function Test-Win32ToolkitPsadtVersionSupported {
    param([Parameter(Position = 0)][object]$Version)
    if ($null -eq $script:PsadtSupportedRange) { throw [System.InvalidOperationException]::new('win32-toolkit internal error: PsadtSupportedRange is not initialised') }
    if ($null -eq $Version) { return $false }
    $v = $null
    if ($Version -is [version]) { $v = $Version } elseif (-not [version]::TryParse((([string]$Version) -split '-', 2)[0], [ref]$v)) { return $false }
    return ($v -ge $script:PsadtSupportedRange.Min -and $v -lt $script:PsadtSupportedRange.MaxExclusive)
}
foreach ($f in 'Get-Win32ToolkitDeployScriptShape', 'Set-Win32ToolkitPhaseBlock', 'Remove-Win32ToolkitPhaseBlock',
    'Get-Win32ToolkitDeployScriptBlock', 'Write-Win32ToolkitDeployScript', 'Test-Win32ToolkitPS51Syntax', 'Set-PSADTDataDrivenScript') {
    . (Join-Path $repo "Private\$f.ps1")
}
# The real 5.1 checker, with a switch to force a 5.1 parse error.
$script:Real51 = ${function:Test-Win32ToolkitPS51Syntax}
$script:Force51 = $false
function Test-Win32ToolkitPS51Syntax { param([string]$Path) if ($script:Force51) { 'forced 5.1 parse error' } else { & $script:Real51 -Path $Path } }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32gf_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $TMP -Force | Out-Null

function Get-Fixture([string]$Name) {
    ([System.IO.File]::ReadAllText((Join-Path $repo "Tests\Fixtures\$Name\Invoke-AppDeployToolkit.ps1"), [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
}
# Copy a fixture into its own scratch project; CRLF + BOM like a real scaffold. Returns the script path.
function Copy-FixtureCase([string]$Fixture, [string]$Label, [scriptblock]$Mutate) {
    $d = Join-Path $TMP $Label; New-Item -ItemType Directory -Path $d -Force | Out-Null
    $text = Get-Fixture $Fixture
    if ($Mutate) { $text = & $Mutate $text }
    $p = Join-Path $d 'Invoke-AppDeployToolkit.ps1'
    [System.IO.File]::WriteAllText($p, ($text -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    return $p
}
function Get-Text([string]$Path) { ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n" }
function Test-Bom([string]$Path) { $b = [System.IO.File]::ReadAllBytes($Path); $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF }
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
# Runs the generator; returns @{ Result; Fqid; Message; Warnings }.
function Invoke-Gen([string]$Path, [switch]$Manual) {
    $wv = $null
    try {
        $r = Set-PSADTDataDrivenScript -ScriptPath $Path -ManualInstall:$Manual -WarningVariable wv -WarningAction SilentlyContinue
        [pscustomobject]@{ Result = $r; Fqid = ''; Message = ''; Warnings = @($wv) }
    }
    catch { [pscustomobject]@{ Result = $null; Fqid = $_.FullyQualifiedErrorId; Message = $_.Exception.Message; Warnings = @($wv) } }
}
function Test-C1([string]$Message) { $Message.StartsWith('Unsupported PSADT template shape: ') -and $Message.EndsWith('Nothing was changed.') }

# -- [1] happy path --------------------------------------------------------------------------------
Write-Host '[1] 4.1.8 and 4.2.0 Zero-Config: patched cleanly, parses under both parsers, BOM, idempotent' -ForegroundColor Cyan
$patched = @{}
foreach ($g in 'psadt-4.1.8', 'psadt-4.2.0-zeroconfig') {
    foreach ($mode in 'auto', 'manual') {
        $p = Copy-FixtureCase $g "$g-$mode"
        $r = Invoke-Gen $p -Manual:($mode -eq 'manual')
        if ($r.Result -eq $true -and $r.Warnings.Count -eq 0 -and -not $r.Fqid) { Ok "$g ($mode): `$true, 0 warnings" } else { Bad "$g ($mode): result=$($r.Result) warnings=$($r.Warnings.Count) error=$($r.Fqid) $($r.Message)" }
        $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
        $ps51 = @(& $script:Real51 -Path $p)
        if (@($errs).Count -eq 0 -and $ps51.Count -eq 0) { Ok "$g ($mode): host parser and Windows PowerShell 5.1 parser clean" } else { Bad "$g ($mode): host=$(@($errs).Count) 5.1=[$($ps51 -join '; ')]" }
        if (Test-Bom $p) { Ok "$g ($mode): UTF-8 with BOM" } else { Bad "$g ($mode): no BOM" }
        $h = Get-Hash $p
        $r2 = Invoke-Gen $p -Manual:($mode -eq 'manual')
        if ($r2.Result -eq $true -and (Get-Hash $p) -eq $h) { Ok "$g ($mode): second run returns `$true and is byte-identical" } else { Bad "$g ($mode): second run changed the file or failed ($($r2.Fqid))" }
        $patched["$g-$mode"] = $p
    }
}

# -- [2] the generated-code contract (spec 5.1, 5.2) on 4.2 Zero-Config ----------------------------
Write-Host '[2] spec 5.1 / 5.2 reproduced byte-for-byte (4.2 Zero-Config, automated mode)' -ForegroundColor Cyan
$expectedSession = @'
## MARK: Variables
## win32-toolkit:Session:loader (begin) - managed by win32-toolkit; regenerated, do not edit inside
# Data-driven deployment values (win32-toolkit): read app-specific settings as DATA.
$appConfig = if (Test-Path -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json") {
    # -Encoding UTF8: AppConfig.json is BOM-less UTF-8 and this runs under Windows PowerShell 5.1 on the
    # device, whose Get-Content default decodes a BOM-less file as ANSI. 5.1's -Encoding UTF8 reader handles
    # both BOM and BOM-less input.
    Get-Content -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json" -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{ App = [pscustomobject]@{}; Installer = $null; Uninstall = $null; ProcessesToClose = @() }
}
# Tattoo gate: the Install phase sets this to $true as its LAST statement; Post-Install writes the detection
# tattoo only when it is $true. Initialised here because the script runs under Set-StrictMode -Version 1.
$w32tInstallDone = $false
## win32-toolkit:Session:loader (end)
$adtSession = @{
    AppVendor = $appConfig.App.Vendor
    AppName = $appConfig.App.Name
    AppVersion = $appConfig.App.Version
    AppArch = $appConfig.App.Arch
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @($appConfig.ProcessesToClose | Where-Object { $_ })  # Example: @('excel', @{ Name = 'winword'; Description = 'Microsoft Word' })

    AppScriptVersion = '1.0.0'
    AppScriptDate = $appConfig.App.ScriptDate
    AppScriptAuthor = $appConfig.App.ScriptAuthor

    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.2.0'
    ExitWithMsiCodes = $true
}
'@ -replace "`r`n", "`n" | ForEach-Object { $_ + "`n" }
$expectedInstallHead = @'
## MARK: Install
New-Variable -Name Install -Force -Value {
    ## Handle Zero-Config MSI actions.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }
    ## win32-toolkit:Install:msp (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## PSADT 4.2's Zero-Config block no longer applies .msp patches (4.1.8 did): keep 4.1.8 parity.
    if ($adtSession.UseDefaultMsi) {
        foreach ($w32tMsp in @($adtSession.DefaultMspFiles)) {
            if ($w32tMsp) { Start-ADTMsiProcess -Action Patch -FilePath $w32tMsp.FullName }
        }
    }
    ## win32-toolkit:Install:msp (end)
    ## win32-toolkit:Install:install (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Data-driven install (values from SupportFiles\AppConfig.json).
    if ($appConfig.Installer -and $appConfig.Installer.Type -in @('msix', 'appx')) {
'@ -replace "`r`n", "`n"
$expectedInstallTail = @'
    elseif ($appConfig.Installer -and $appConfig.Installer.Type -ne 'msi') {
'@ -replace "`r`n", "`n"
$expectedInstallEnd = @'
    ## win32-toolkit:Install:install (end)
    ## win32-toolkit:Install:install-done (begin) - managed by win32-toolkit; regenerated, do not edit inside
    $w32tInstallDone = $true
    ## win32-toolkit:Install:install-done (end)
}
'@ -replace "`r`n", "`n" | ForEach-Object { $_ + "`n" }
$z = Get-Text $patched['psadt-4.2.0-zeroconfig-auto']
$s0 = $z.IndexOf('## MARK: Variables'); $s1 = $z.IndexOf("`n}`n", $z.IndexOf('$adtSession = @{', $s0)) + 3
if ($z.Substring($s0, $s1 - $s0) -ceq $expectedSession) { Ok 'session area (loader + $adtSession edits + ExitWithMsiCodes) = spec 5.1 byte-for-byte' } else { Bad "session area differs from spec 5.1:`n$($z.Substring($s0, $s1 - $s0))" }
$i0 = $z.IndexOf('## MARK: Install'); $i1 = $z.IndexOf("`n}`n", $i0) + 3
$install = $z.Substring($i0, $i1 - $i0)
if ($install.StartsWith($expectedInstallHead) -and $install.Contains($expectedInstallTail) -and $install.EndsWith($expectedInstallEnd)) { Ok 'Install phase = spec 5.2 (Zero-Config block, msp, install, install-done)' }
else { Bad "Install phase differs from spec 5.2:`n$install" }

# The routines are today's (1.1.6) routines, comments included (re-based; em dash -> ' - ' for ASCII).
$legacy = Get-Fixture 'legacy-1.1.6-auto'
$oldInstall = ([regex]::Match($legacy, '(?s)    ## Data-driven install \(values from SupportFiles\\AppConfig\.json\)\.\n.*?\n    \}\n(?=\n)')).Value
$oldUninstall = ([regex]::Match($legacy, '(?s)    ## Data-driven uninstall \(values from SupportFiles\\AppConfig\.json\)\.\n.*?\n    \}\n(?=\n)')).Value
$g41 = Get-Text $patched['psadt-4.1.8-auto']
$newInstall = ([regex]::Match($g41, '(?s)## win32-toolkit:Install:install \(begin\)[^\n]*\n(.*?)    ## win32-toolkit:Install:install \(end\)')).Groups[1].Value
$newUninstall = ([regex]::Match($g41, '(?s)## win32-toolkit:Uninstall:uninstall \(begin\)[^\n]*\n(.*?)    ## win32-toolkit:Uninstall:uninstall \(end\)')).Groups[1].Value
if ($oldInstall -and $newInstall -ceq $oldInstall) { Ok 'install block = the 1.1.6 install routine line for line' } else { Bad 'install block differs from the 1.1.6 routine' }
# The uninstall block is revision 2 (installer-identity PR 2): it keeps the 1.1.6 lines of the ProductCodes loop,
# the msi and msix branches and the no-success guard (line for line), and adds the revision marker.
$oldU = $oldUninstall -replace [char]0x2014, '-'
$keptParts = [ordered]@{
    'first line'          = ([regex]::Match($oldU, '^    ## Data-driven uninstall [^\n]*\n')).Value
    'ProductCodes loop'   = ([regex]::Match($oldU, '(?ms)^        foreach \(\$pc in @\(\$appConfig\.Uninstall\.ProductCodes\)\) \{\n.*?\n        \}\n')).Value
    'msi branch'          = ([regex]::Match($oldU, "(?m)^                'msi' \{[^\n]*\n")).Value
    'msix branch'         = ([regex]::Match($oldU, "(?ms)^                'msix' \{\n.*?\n                \}\n")).Value
    'no-success guard'    = ([regex]::Match($oldU, '(?ms)^        # Fail loudly when nothing actually uninstalled\..*?\n        \}\n')).Value
}
$missingParts = @($keptParts.Keys | Where-Object { -not $keptParts[$_] -or -not $newUninstall.Contains($keptParts[$_]) })
if ($oldUninstall -and $missingParts.Count -eq 0 -and $newUninstall.StartsWith($keptParts['first line'])) { Ok 'uninstall block keeps the 1.1.6 lines of the ProductCodes loop, the msi and msix branches and the no-success guard (em dash -> ASCII)' }
else { Bad "uninstall block lost 1.1.6 lines: $($missingParts -join ', ')" }
if (([regex]::Matches($newUninstall, [regex]::Escape('    ## Uninstall revision 2 (win32-toolkit)'))).Count -eq 1 -and $newUninstall -cne $oldU) { Ok 'uninstall block adds the revision-2 marker (installer-identity PR 2)' } else { Bad 'uninstall block has no single revision-2 marker' }

# -- [3] legacy fixtures are never modified --------------------------------------------------------
Write-Host '[3] projects patched by win32-toolkit 1.1.6: $true and byte-identical' -ForegroundColor Cyan
foreach ($n in 'legacy-1.1.6-auto', 'legacy-1.1.6-manual', 'legacy-1.1.6-org') {
    $p = Join-Path $TMP "$n.ps1"
    Copy-Item -LiteralPath (Join-Path $repo "Tests\Fixtures\$n\Invoke-AppDeployToolkit.ps1") -Destination $p
    $h = Get-Hash $p
    foreach ($m in $false, $true) {
        $r = Invoke-Gen $p -Manual:$m
        if ($r.Result -eq $true -and (Get-Hash $p) -eq $h -and $r.Warnings.Count -eq 0) { Ok "$n (ManualInstall=$m): `$true, byte-identical" } else { Bad "$n (ManualInstall=$m): result=$($r.Result) $($r.Fqid) changed=$((Get-Hash $p) -ne $h)" }
    }
}

# -- [4] fail closed -------------------------------------------------------------------------------
Write-Host '[4] fail closed: W32T.UnsupportedTemplateShape, stable wording, file byte-identical' -ForegroundColor Cyan
$cases = @(
    @{ N = '4.2 default template';                 P = (Copy-FixtureCase 'psadt-4.2.0' 'f-42d');      M = $false; Expect = 'without Zero-Config' }
    @{ N = '4.2 default template, -ManualInstall';  P = (Copy-FixtureCase 'psadt-4.2.0' 'f-42dm');     M = $true;  Expect = 'Copy your Install code out' }
    @{ N = 'unpatched 4.1.8 with a marker removed'; P = (Copy-FixtureCase 'psadt-4.1.8' 'f-mk' { param($t) $t.Replace("    ## <Perform Uninstallation tasks here>`n", '') }); M = $false; Expect = 'markers missing or duplicated: missing: ## <Perform Uninstallation tasks here>' }
    @{ N = '4.2 Zero-Config with DeployAppScriptVersion 4.3.0'; P = (Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'f-43' { param($t) $t.Replace("DeployAppScriptVersion = '4.2.0'", "DeployAppScriptVersion = '4.3.0'") }); M = $false; Expect = 'outside the supported range' }
    @{ N = 'unknown layout (parse error)';          P = (Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'f-pe' { param($t) $t + "`nif (`n" }); M = $false; Expect = 'Not a template layout' }
    @{ N = 'session anchor not unique';            P = (Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'f-dup' { param($t) $t.Replace("    AppLang = 'EN'", "    AppLang = 'EN'`n    AppExtra = @{`n        AppVendor = ''`n    }") }); M = $false; Expect = "AppVendor = ''" }
    @{ N = 'session anchor missing';               P = (Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'f-miss' { param($t) $t.Replace("    AppArch = ''", "    AppArch = 'x64'") }); M = $false; Expect = "AppArch = ''" }
    @{ N = 'DeployAppScriptVersion double-quoted (ExitWithMsiCodes anchor)'; P = (Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'f-dq' { param($t) $t.Replace("DeployAppScriptVersion = '4.2.0'", 'DeployAppScriptVersion = "4.2.0"') }); M = $false; Expect = "The session anchor DeployAppScriptVersion = '<version>' is missing or not unique" }
    @{ N = 'foreign $appConfig loader';            P = (Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'f-fl' { param($t) $t.Replace('$adtSession = @{', "`$appConfig = @{}`n`$adtSession = @{") }); M = $false; Expect = 'did not write' }
)
foreach ($c in $cases) {
    $h = Get-Hash $c.P
    $r = Invoke-Gen $c.P -Manual:$c.M
    if ($r.Fqid -eq 'W32T.UnsupportedTemplateShape') { Ok "$($c.N) -> W32T.UnsupportedTemplateShape" } else { Bad "$($c.N) -> result=$($r.Result) fqid='$($r.Fqid)'" }
    if (Test-C1 $r.Message) { Ok "$($c.N): message starts 'Unsupported PSADT template shape: ', ends 'Nothing was changed.'" } else { Bad "$($c.N): message '$($r.Message)'" }
    if ($r.Message.Contains($c.Expect)) { Ok "$($c.N): hint '$($c.Expect)'" } else { Bad "$($c.N): hint missing in '$($r.Message)'" }
    if ((Get-Hash $c.P) -eq $h) { Ok "$($c.N): file byte-identical" } else { Bad "$($c.N): file was modified" }
}
$r = Invoke-Gen (Join-Path $TMP 'missing\Invoke-AppDeployToolkit.ps1')
if ($r.Fqid -eq 'W32T.UnsupportedTemplateShape' -and (Test-C1 $r.Message)) { Ok 'missing file -> W32T.UnsupportedTemplateShape (C-1 wording)' } else { Bad "missing file -> '$($r.Fqid)' $($r.Message)" }
$r42 = Invoke-Gen $cases[0].P
if ($r42.Message -notmatch 'Copy your Install code out') { Ok 'the "copy your Install code out" hint is for -ManualInstall only' } else { Bad 'manual hint shown in automated mode' }

# -- [5] gen-2 re-render reaches the loader --------------------------------------------------------
Write-Host '[5] a gen-2 script whose loader differs from the catalog is re-rendered to the catalog text' -ForegroundColor Cyan
$p = $patched['psadt-4.2.0-zeroconfig-auto']
$good = [System.IO.File]::ReadAllBytes($p)
$text = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
$old = $text.Replace('# Data-driven deployment values (win32-toolkit): read app-specific settings as DATA.', '# an older loader comment').Replace('$w32tInstallDone = $false', '$w32tOld = 1')
[System.IO.File]::WriteAllText($p, $old, (New-Object System.Text.UTF8Encoding($true)))
$r = Invoke-Gen $p
if ($r.Result -eq $true -and [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p)) -ceq [System.Convert]::ToBase64String($good)) { Ok 'loader block replaced by the catalog text, nothing else changed' }
else { Bad "loader re-render: result=$($r.Result) $($r.Fqid)" }

# -- [6] non-critical anchor -----------------------------------------------------------------------
Write-Host '[6] AppScriptDate anchor missing -> $false + warning, script still written and valid' -ForegroundColor Cyan
$p = Copy-FixtureCase 'psadt-4.1.8' 'nodate' { param($t) $t -replace "AppScriptDate = '\d{4}-\d{2}-\d{2}'", "AppScriptDate = (Get-Date -Format 'yyyy-MM-dd')" }
$r = Invoke-Gen $p
$errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
if ($r.Result -eq $false -and ($r.Warnings -join ' ') -match 'AppScriptDate' -and (Get-Text $p).Contains('## win32-toolkit:Session:loader (begin)') -and @($errs).Count -eq 0) {
    Ok '$false, one AppScriptDate warning, file patched and parsing'
} else { Bad "result=$($r.Result) warnings=[$($r.Warnings -join '; ')] $($r.Fqid)" }

# -- [7] writer restores the original bytes --------------------------------------------------------
Write-Host '[7] a 5.1 parse error after writing -> W32T.GeneratedScriptInvalid, original bytes restored' -ForegroundColor Cyan
$p = Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'force51'
$h = Get-Hash $p
$script:Force51 = $true
$r = Invoke-Gen $p
$script:Force51 = $false
if ($r.Fqid -eq 'W32T.GeneratedScriptInvalid' -and $r.Message -match 'forced 5\.1 parse error' -and (Get-Hash $p) -eq $h) { Ok 'W32T.GeneratedScriptInvalid; the file holds its original bytes again' }
else { Bad "fqid='$($r.Fqid)' restored=$((Get-Hash $p) -eq $h) $($r.Message)" }

# -- [8] block selection ---------------------------------------------------------------------------
Write-Host '[8] msp only on 4.2; -ManualInstall swaps install / manual-install' -ForegroundColor Cyan
foreach ($k in $patched.Keys) {
    $t = Get-Text $patched[$k]
    $hasMsp = $t.Contains('## win32-toolkit:Install:msp (begin)')
    $want = $k -like 'psadt-4.2.0-zeroconfig*'
    if ($hasMsp -eq $want) { Ok "$k : msp block present=$hasMsp" } else { Bad "$k : msp present=$hasMsp" }
    $isManual = $k -like '*-manual'
    if ($t.Contains('## win32-toolkit:Install:manual-install (begin)') -eq $isManual -and $t.Contains('## win32-toolkit:Install:install (begin)') -eq (-not $isManual)) { Ok "$k : the right install block" } else { Bad "$k : wrong install block" }
}
$p = $patched['psadt-4.2.0-zeroconfig-auto']
$null = Invoke-Gen $p -Manual
$t = Get-Text $p
if ($t.Contains('Install:manual-install (begin)') -and -not $t.Contains('Install:install (begin)')) { Ok 'auto -> manual: install replaced by manual-install' } else { Bad 'auto -> manual toggle failed' }
$null = Invoke-Gen $p
$t = Get-Text $p
if ($t.Contains('Install:install (begin)') -and -not $t.Contains('Install:manual-install (begin)') -and ([regex]::Matches($t, 'Install:install-done \(begin\)')).Count -eq 1) { Ok 'manual -> auto: back to install, one install-done' } else { Bad 'manual -> auto toggle failed' }

# -- [9] MSI anchors (V7 guard), ExitWithMsiCodes, session -----------------------------------------
Write-Host '[9] the Install phase keeps PSADT''s Zero-Config MSI block AND carries the toolkit blocks' -ForegroundColor Cyan
foreach ($k in 'psadt-4.1.8-auto', 'psadt-4.2.0-zeroconfig-auto') {
    $t = Get-Text $patched[$k]
    $sh = Get-Win32ToolkitDeployScriptShape -Content $t -IncludeLayout
    $ph = $sh.Layout.Phases['Install']
    if ($ph.ContainsKey('Ast')) { $lo = $ph.Open; $hi = $ph.Close; $scope = $ph.Ast } else { $lo = $ph.RegionStart; $hi = $ph.RegionEnd; $scope = $ph.FunctionAst }
    $zc = @($scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$adtSession.UseDefaultMsi' -and
                [bool]$n.Clauses[0].Item2.Find({ param($m) $m -is [System.Management.Automation.Language.CommandAst] -and $m.GetCommandName() -eq 'Start-ADTMsiProcess' }, $true) }, $true) |
            Where-Object { $_.Extent.StartOffset -ge $lo -and $_.Extent.EndOffset -le $hi })
    $blocks = @($sh.Layout.Blocks | Where-Object { $_.Phase -eq 'Install' } | ForEach-Object Slot)
    if ($zc.Count -ge 1 -and $blocks -contains 'install' -and $blocks -contains 'install-done') { Ok "$k : Zero-Config if + Start-ADTMsiProcess and the install/install-done blocks in the Install phase" }
    else { Bad "$k : zc=$($zc.Count) blocks=[$($blocks -join ',')]" }
    if (([regex]::Matches($t, '(?m)^\s*ExitWithMsiCodes = \$true')).Count -eq 1) { Ok "$k : ExitWithMsiCodes = `$true exactly once" } else { Bad "$k : ExitWithMsiCodes count wrong" }
    if ($t.Contains('AppScriptAuthor = $appConfig.App.ScriptAuthor') -and -not $t.Contains('<author name>')) { Ok "$k : AppScriptAuthor is data (no template value left)" } else { Bad "$k : AppScriptAuthor not data-driven" }
    if ($t.Contains('win32-toolkit install tattoo - records') -and $t.Contains('-Wow6432Node -Recurse') -and $t.Contains('(Test-Path -LiteralPath $w32tLegacyKey)')) { Ok "$k : tattoo + legacy WOW6432Node cleanup (only when that key exists)" } else { Bad "$k : tattoo blocks missing" }
}

# -- [10] value-free -------------------------------------------------------------------------------
Write-Host '[10] no value from a hostile AppConfig.json ever reaches the script' -ForegroundColor Cyan
$p = Copy-FixtureCase 'psadt-4.2.0-zeroconfig' 'hostile'
$sf = Join-Path (Split-Path $p) 'SupportFiles'; New-Item -ItemType Directory -Path $sf -Force | Out-Null
$evil = "Evil'; Start-Process calc; '"
([pscustomobject]@{ App = [pscustomobject]@{ Vendor = $evil; Name = $evil; DisplayName = $evil; Version = '$(calc)'; ScriptAuthor = '`$x' }; Installer = [pscustomobject]@{ Type = 'exe'; FileName = 'a.exe'; SilentArgs = '/S & calc' } } | ConvertTo-Json -Depth 5) |
    Set-Content -LiteralPath (Join-Path $sf 'AppConfig.json') -Encoding UTF8
$null = Invoke-Gen $p
$t = Get-Text $p
if (-not $t.Contains('Start-Process calc') -and -not $t.Contains('$(calc)') -and -not $t.Contains('/S & calc')) { Ok 'the generated script contains none of the AppConfig values' } else { Bad 'an AppConfig value was spliced into the script' }

Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'GeneratorFailClosed unit test PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
