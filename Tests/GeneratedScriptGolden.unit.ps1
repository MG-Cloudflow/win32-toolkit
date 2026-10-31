<#
    Generated deploy scripts, byte for byte (lean deploy script PR 2; design knowledge-base/designs/lean-deploy-script-extension.md
    section 8, decision LD17).

    A GeneratorVersion 3 script carries only the blocks its project needs, most of them one module-qualified call into
    win32-toolkit's PSADT extension module, so the whole generated script is short and stable enough to pin. Each golden in
    Tests\Fixtures\generated-gv3\ is the PSADT golden (Tests\Fixtures\psadt-4.1.8 / psadt-4.2.0-zeroconfig) after:

      * Set-PSADTDataDrivenScript with the kind's installer type (msi, exe, msix; manual = an EXE with -ManualInstall);
      * for the '-org' kinds, the deploy-script part of Apply-OrgTemplate (PSADT's default dialogs out, the org-ui blocks
        of the block plan in) and Add-Win32ToolkitOrgHooks' hook blocks for Pre-Install (FailureAction Continue) and
        Post-Install (Fail).

    Covered: the bytes (line endings normalised to LF; UTF-8 BOM checked separately), GeneratorVersion 3 with the current
    extension version, the slot set equal to Get-Win32ToolkitDeployBlockPlan, the extension folder next to the script, and
    no block the plan does not name. A generator change that alters a script fails here first; rewrite the goldens with
    -UpdateGolden and review the diff like the PSADT goldens.

    Run:  pwsh -File Tests\GeneratedScriptGolden.unit.ps1 [-UpdateGolden]
#>
[CmdletBinding()]
param([switch]$UpdateGolden)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m) { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$mod = Import-Module (Join-Path $repo 'win32-toolkit.psd1') -Force -PassThru
$goldDir = Join-Path $repo 'Tests\Fixtures\generated-gv3'
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32gg_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$kinds = [ordered]@{
    'msi'     = @{ Type = 'msi'; Manual = $false; Org = $false }
    'exe'     = @{ Type = 'exe'; Manual = $false; Org = $false }
    'msix'    = @{ Type = 'msix'; Manual = $false; Org = $false }
    'manual'  = @{ Type = 'exe'; Manual = $true; Org = $false }
    'exe-org' = @{ Type = 'exe'; Manual = $false; Org = $true }
    'msi-org' = @{ Type = 'msi'; Manual = $false; Org = $true }
}
$ext = & $mod { Get-Win32ToolkitDeployExtension }

try {
    if ($UpdateGolden) { New-Item -ItemType Directory -Path $goldDir -Force | Out-Null }
    foreach ($golden in 'psadt-4.1.8', 'psadt-4.2.0-zeroconfig') {
        $ver = if ($golden -eq 'psadt-4.1.8') { '4.1.8' } else { '4.2.0' }
        Write-Host "`n=== $golden ===" -ForegroundColor White
        foreach ($kind in $kinds.Keys) {
            $k = $kinds[$kind]
            $proj = Join-Path $TMP "$golden-$kind"
            New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
            $script = Join-Path $proj 'Invoke-AppDeployToolkit.ps1'
            Copy-Item -LiteralPath (Join-Path $repo "Tests\Fixtures\$golden\Invoke-AppDeployToolkit.ps1") -Destination $script
            Set-Content -LiteralPath (Join-Path $proj 'SupportFiles\AppConfig.json') -Value (@{ SchemaVersion = '1.0'; Installer = @{ Type = $k.Type; FileName = "App.$($k.Type)" } } | ConvertTo-Json) -Encoding UTF8
            $hooks = @()
            & $mod {
                param($Script, $Manual, $Org)
                $null = Set-PSADTDataDrivenScript -ScriptPath $Script -ManualInstall:$Manual -WarningAction SilentlyContinue
                if ($Org) {
                    # The deploy-script part of Apply-OrgTemplate and Add-Win32ToolkitOrgHooks, without template files.
                    $shape = Get-Win32ToolkitDeployScriptShape -Path $Script
                    $cfg = Get-Win32ToolkitAppConfig -ProjectPath (Split-Path -Parent $Script)
                    $text = [System.IO.File]::ReadAllText($Script, [System.Text.Encoding]::UTF8)
                    $bytes = [System.IO.File]::ReadAllBytes($Script)
                    foreach ($row in @(Get-Win32ToolkitDeployBlockPlan -Shape $shape.Shape -InstallerType $cfg.Installer.Type -ManualInstall:$Manual -HookPhases 'Pre-Install', 'Post-Install' | Where-Object { $_.Owner -ne 'Generator' })) {
                        if ($row.Owner -eq 'OrgUi') {
                            $text = Remove-Win32ToolkitPhaseDefaultUi -Content $text -Phase $row.Phase
                            $text = Set-Win32ToolkitPhaseBlock -Content $text -Phase $row.Phase -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name $row.Block)
                        }
                        else {
                            $file = ($row.Phase -replace '-', '') + '.ps1'
                            $action = if ($row.Phase -eq 'Pre-Install') { 'Continue' } else { 'Fail' }
                            $text = Set-Win32ToolkitPhaseBlock -Content $text -Phase $row.Phase -Slot 'hook' -Code (Get-Win32ToolkitDeployScriptBlock -Name Hook -Phase $row.Phase -HookFile $file -FailureAction $action)
                        }
                    }
                    Write-Win32ToolkitDeployScript -Path $Script -Content $text -OriginalBytes $bytes
                }
            } $script $k.Manual $k.Org
            if ($k.Org) { $hooks = @('Pre-Install', 'Post-Install') }

            $name = "$ver-$kind.ps1"
            $goldPath = Join-Path $goldDir $name
            $bytes = [System.IO.File]::ReadAllBytes($script)
            if ($UpdateGolden) { [System.IO.File]::WriteAllBytes($goldPath, $bytes); Write-Host "  wrote $name" -ForegroundColor Yellow }
            if (-not (Test-Path -LiteralPath $goldPath)) { Bad "$name : no golden (run with -UpdateGolden)"; continue }
            $now = ([System.IO.File]::ReadAllText($script, [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
            $want = ([System.IO.File]::ReadAllText($goldPath, [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
            if ($now -ceq $want) { Ok "$name : the generated script equals the golden" }
            else {
                $a = $now -split "`n"; $b = $want -split "`n"; $i = 0
                while ($i -lt [Math]::Min($a.Count, $b.Count) -and $a[$i] -ceq $b[$i]) { $i++ }
                Bad "$name : differs from the golden at line $($i + 1): now '$(if ($i -lt $a.Count) { $a[$i] })' golden '$(if ($i -lt $b.Count) { $b[$i] })'"
            }
            if ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Ok "$name : UTF-8 with BOM" } else { Bad "$name : no UTF-8 BOM" }
            $shape = & $mod { param($p) Get-Win32ToolkitDeployScriptShape -Path $p } $script
            $plan = @(& $mod { param($s, $t, $m, $h) Get-Win32ToolkitDeployBlockPlan -Shape $s -InstallerType $t -ManualInstall:$m -HookPhases $h } $shape.Shape $k.Type $k.Manual $hooks)
            if (-not $k.Org) { $plan = @($plan | Where-Object { $_.Owner -eq 'Generator' }) }
            $slots = @([regex]::Matches($now, '(?m)^[ \t]*## win32-toolkit:([\w-]+:[\w-]+) \(begin\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
            $want = @($plan | ForEach-Object { "$($_.Phase):$($_.Slot)" } | Sort-Object)
            if ($shape.GeneratorVersion -eq 3 -and $shape.ExtensionName -ceq $ext.Name -and $shape.ExtensionVersion -eq $ext.Version -and $shape.Support -eq 'Supported') { Ok "$name : GeneratorVersion 3, extension $($ext.Name) $($ext.Version), Supported" } else { Bad "$name : shape GV=$($shape.GeneratorVersion) ext=$($shape.ExtensionName) $($shape.ExtensionVersion) $($shape.Support)" }
            if (($slots -join '|') -ceq ($want -join '|')) { Ok "$name : exactly the $($want.Count) blocks of the block plan" } else { Bad "$name : blocks $($slots -join ', ') - plan $($want -join ', ')" }
            if (Test-Path -LiteralPath (Join-Path $proj "$($ext.Name)\$($ext.Name).psm1")) { Ok "$name : the extension module sits next to the script" } else { Bad "$name : no extension folder" }
            if ($k.Org) {
                New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles\OrgHooks') -Force | Out-Null
                foreach ($h in 'PreInstall.ps1', 'PostInstall.ps1') { Set-Content -LiteralPath (Join-Path $proj "SupportFiles\OrgHooks\$h") -Value '# hook' }
            }
            $findings = @(& $mod { param($p) Test-Win32ToolkitDeployExtension -ProjectPath $p } $proj)
            if (-not $k.Org -or $findings.Count -eq 0) {
                # Without an org template the org-ui rows are missing on purpose (Apply-OrgTemplate places them): only PLAN-MISMATCH may report it.
                $other = @($findings | Where-Object { $_.Code -ne 'PLAN-MISMATCH' -or $k.Org })
                if ($other.Count -eq 0) { Ok "$name : Test-Win32ToolkitDeployExtension finds nothing else" } else { Bad "$name : findings $($other.Code -join ', ')" }
            } else { Bad "$name : findings $($findings | ForEach-Object { "$($_.Code): $($_.Message)" })" }
        }
    }

    # PLAN-MISMATCH: the checks Finalize and Export run on a GeneratorVersion 3 project (design section 4.7).
    Write-Host "`n=== PLAN-MISMATCH ===" -ForegroundColor White
    $base = Join-Path $TMP 'psadt-4.2.0-zeroconfig-exe-org'
    $script = Join-Path $base 'Invoke-AppDeployToolkit.ps1'
    $orig = [System.IO.File]::ReadAllText($script, [System.Text.Encoding]::UTF8)
    $cfgPath = Join-Path $base 'SupportFiles\AppConfig.json'
    $cfgOrig = Get-Content -LiteralPath $cfgPath -Raw
    $cases = @(
        @{ L = 'the install block removed by hand'; Do = { [System.IO.File]::WriteAllText($script, [regex]::Replace($orig, '(?s)[ \t]*## win32-toolkit:Install:install \(begin\).*?## win32-toolkit:Install:install \(end\)\r?\n', ''), (New-Object System.Text.UTF8Encoding($true))) }; W = 'lacks the block(s) Install:install' }
        @{ L = 'a call edited inside its block'; Do = { [System.IO.File]::WriteAllText($script, $orig.Replace('Install-W32TApp -AppConfig $appConfig -Technology Exe', 'Install-W32TApp -AppConfig $appConfig -Technology Appx'), (New-Object System.Text.UTF8Encoding($true))) }; W = "do not hold this toolkit's call: Install:install" }
        @{ L = 'AppConfig switched to msi'; Do = { Set-Content -LiteralPath $cfgPath -Value ($cfgOrig.Replace('"exe"', '"msi"')) }; W = 'has block(s) this project does not need' }
        @{ L = 'a hook file removed'; Do = { Remove-Item -LiteralPath (Join-Path $base 'SupportFiles\OrgHooks\PostInstall.ps1') }; W = 'this project does not need: Post-Install:hook' }
        @{ L = 'an unknown installer type'; Do = { Set-Content -LiteralPath $cfgPath -Value ($cfgOrig.Replace('"exe"', '"zip"')) }; W = "no deploy-script blocks" }
    )
    foreach ($c in $cases) {
        & $c.Do
        $f = @(& $mod { param($p) Test-Win32ToolkitDeployExtension -ProjectPath $p } $base)
        if ($f.Count -eq 1 -and $f[0].Code -eq 'PLAN-MISMATCH' -and $f[0].Severity -eq 'Error' -and $f[0].Message.Contains($c.W)) { Ok "$($c.L) -> PLAN-MISMATCH" } else { Bad "$($c.L): $($f | ForEach-Object { "$($_.Code): $($_.Message)" })" }
        [System.IO.File]::WriteAllText($script, $orig, (New-Object System.Text.UTF8Encoding($true)))
        Set-Content -LiteralPath $cfgPath -Value $cfgOrig
        Set-Content -LiteralPath (Join-Path $base 'SupportFiles\OrgHooks\PostInstall.ps1') -Value '# hook'
    }
    $msiBase = Join-Path $TMP 'psadt-4.1.8-msi-org'
    $msiCfg = Join-Path $msiBase 'SupportFiles\AppConfig.json'
    $msiObj = Get-Content -LiteralPath $msiCfg -Raw | ConvertFrom-Json
    $msiObj | Add-Member -NotePropertyName Uninstall -NotePropertyValue ([pscustomobject]@{ ProductCodes = @('{11111111-2222-3333-4444-555555555555}'); Uninstallers = @(); CleanupPaths = @() })
    Set-Content -LiteralPath $msiCfg -Value ($msiObj | ConvertTo-Json -Depth 5)
    $f = @(& $mod { param($p) Test-Win32ToolkitDeployExtension -ProjectPath $p } $msiBase)
    if ($f.Count -eq 1 -and $f[0].Code -eq 'PLAN-MISMATCH' -and $f[0].Message.Contains("an Uninstall section, but a(n) 'msi' project has no uninstall call")) { Ok 'an MSI project whose AppConfig gained an Uninstall section -> PLAN-MISMATCH (Zero-Config owns the uninstall)' } else { Bad "msi uninstall data: $($f | ForEach-Object { $_.Message })" }
    if (-not $UpdateGolden) {
        $extra = @(Get-ChildItem -LiteralPath $goldDir -File | Where-Object { $_.Name -notmatch '^4\.(1\.8|2\.0)-(msi|exe|msix|manual|exe-org|msi-org)\.ps1$' })
        if ($extra.Count -eq 0 -and @(Get-ChildItem -LiteralPath $goldDir -File).Count -eq 12) { Ok 'Tests\Fixtures\generated-gv3 holds exactly the 12 goldens' } else { Bad "golden folder: $(@(Get-ChildItem -LiteralPath $goldDir -File).Name -join ', ')" }
    }
}
finally { Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All GeneratedScriptGolden tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail GeneratedScriptGolden test(s) FAILED." -ForegroundColor Red
exit 1
