<#
    The toolkit extension checks where they run: the package gate at Finalize and Export, and Publish's Staging comparison
    (lean deploy script PR 2; design knowledge-base/designs/lean-deploy-script-extension.md section 4.7).

    Test-Win32ToolkitDeployExtension's findings are proven in DeployExtension.unit and GeneratedScriptGolden.unit; this
    suite proves the WIRING on real generated projects (the PSADT goldens + Set-PSADTDataDrivenScript + the org-ui rows of
    the block plan, as Apply-OrgTemplate places them):

      [1] a clean GeneratorVersion 3 project passes Finalize and Export with no extension line and no note.
      [2] the extension folder removed -> both stages throw W32T.PackageNotReady with 'Deploy extension (EXTENSION-MISSING)';
          -AllowLegacyScript does not downgrade it.
      [3] the project's psm1 edited -> EXTENSION-UNKNOWN; a call edited inside its block -> PLAN-MISMATCH (Export).
      [4] stray folders PSADT would import (unanchored match, the reserved prefix) -> errors for GeneratorVersion 3.
      [5] a GeneratorVersion 2 script: the stray folder is a warning only, the project stays Ready, and Export (not
          Finalize) prints one 'Note:' line that it is packaged as it is.
      [6] Assert-Win32ToolkitDeployExtensionPackaged (Publish): the Staging copy the .intunewin was built from must hold
          the same extension - same -> its path; changed, without the folder, or missing -> W32T.PackageNotReady
          ('export again'); a project without the folder -> '' (nothing to compare).

    The bundled-PSADT pair check, the Windows PowerShell 5.1 parse and the prior-install rows are shadowed (their own
    suites prove them); nothing is executed, temp folders only.

    Run:  pwsh -File Tests\DeployExtensionGate.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test helpers write temp folders only')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'repo is read by the nested helpers inside the module scriptblock')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$mod = Import-Module (Join-Path $repo 'win32-toolkit.psd1') -Force -PassThru
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32xg_' + [guid]::NewGuid().ToString('N').Substring(0, 6))

$fail = & $mod {
    param($repo, $tmp)
    $ErrorActionPreference = 'Stop'
    $script:W32TTestFail = 0
    function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
    function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:W32TTestFail++ }

    # ---- shadows (module scope, this process only) ----------------------------------------------------
    function script:Get-Win32ToolkitProjectPsadtVersion {
        param([string]$ProjectPath)
        $null = $ProjectPath
        [pscustomobject]@{ ModuleVersion = [version]'4.1.8'; Prerelease = ''; VersionText = '4.1.8'; DeployAppScriptVersion = '4.1.8'; Shape = 'Psadt41'; Support = 'Supported'; IsSupported = $true; IsLegacy = $false; Reason = ''; Warning = '' }
    }
    function script:Test-Win32ToolkitPS51Syntax { param([string]$Path) $null = $Path; [string[]]@() }
    function script:Get-Win32ToolkitPriorInstallFinding { param([string]$ProjectPath, [string]$Stage) $null = $ProjectPath, $Stage; @() }

    $extName = (Get-Win32ToolkitDeployExtension).Name

    # A generated GeneratorVersion 3 project: the 4.1.8 golden, an EXE AppConfig, the generator, the plan's org-ui rows
    # (what Apply-OrgTemplate places), and an empty launcher (only its presence is checked).
    function New-GateProject([string]$Path) {
        New-Item -ItemType Directory -Path (Join-Path $Path 'SupportFiles') -Force | Out-Null
        $script = Join-Path $Path 'Invoke-AppDeployToolkit.ps1'
        Copy-Item -LiteralPath (Join-Path $repo 'Tests\Fixtures\psadt-4.1.8\Invoke-AppDeployToolkit.ps1') -Destination $script
        Set-Content -LiteralPath (Join-Path $Path 'SupportFiles\AppConfig.json') -Value (@{ SchemaVersion = '1.0'; Installer = @{ Type = 'exe'; FileName = 'App.exe'; SilentArgs = '/S' } } | ConvertTo-Json) -Encoding UTF8
        $null = Set-PSADTDataDrivenScript -ScriptPath $script -WarningAction SilentlyContinue
        $shape = Get-Win32ToolkitDeployScriptShape -Path $script
        $text = [System.IO.File]::ReadAllText($script, [System.Text.Encoding]::UTF8)
        $bytes = [System.IO.File]::ReadAllBytes($script)
        foreach ($row in @(Get-Win32ToolkitDeployBlockPlan -Shape $shape.Shape -InstallerType exe | Where-Object Owner -eq 'OrgUi')) {
            $text = Remove-Win32ToolkitPhaseDefaultUi -Content $text -Phase $row.Phase
            $text = Set-Win32ToolkitPhaseBlock -Content $text -Phase $row.Phase -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name $row.Block)
        }
        Write-Win32ToolkitDeployScript -Path $script -Content $text -OriginalBytes $bytes
        [System.IO.File]::WriteAllBytes((Join-Path $Path 'Invoke-AppDeployToolkit.exe'), [byte[]]@())
        $Path
    }
    # Runs the gate; returns the result, the error (or $null), the warnings and the host lines.
    function Invoke-Gate([string]$ProjectPath, [string]$Stage, [switch]$AllowLegacyScript) {
        $all = @(); $err = $null; $wv = $null
        try { $all = @(Assert-Win32ToolkitPackageReady -ProjectPath $ProjectPath -Stage $Stage -AllowLegacyScript:$AllowLegacyScript -WarningVariable wv -WarningAction SilentlyContinue 6>&1) } catch { $err = $_ }
        $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $res = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }) | Select-Object -Last 1
        [pscustomobject]@{ Result = $res; Error = $err; Warnings = @($wv | ForEach-Object { "$_" }); Host = @($info | ForEach-Object { "$_" }) }
    }
    function Get-ExtensionLine($Gate) {
        $text = if ($Gate.Error) { $Gate.Error.Exception.Message } else { '' }
        @(@($text -split "`n") + $Gate.Warnings | Where-Object { $_ -match 'Deploy extension \(' })
    }

    try {
        $proj = New-GateProject (Join-Path $tmp 'Projects\Contoso\GateApp_x64_1.0')
        $psm1 = Join-Path $proj "$extName\$extName.psm1"
        $psm1Bytes = [System.IO.File]::ReadAllBytes($psm1)
        $script = Join-Path $proj 'Invoke-AppDeployToolkit.ps1'
        $scriptText = [System.IO.File]::ReadAllText($script, [System.Text.Encoding]::UTF8)

        Write-Host '[1] a clean GeneratorVersion 3 project' -ForegroundColor Cyan
        foreach ($stage in 'Finalize', 'Export') {
            $g = Invoke-Gate $proj $stage
            if (-not $g.Error -and $g.Result.Ready -and (Get-ExtensionLine $g).Count -eq 0 -and @($g.Warnings).Count -eq 0 -and -not ($g.Host -match 'Note:')) { Ok "$stage : Ready, no warning, no extension line, no note" }
            else { Bad "$stage : err=$($g.Error) warnings=[$($g.Warnings -join ' | ')] host=[$($g.Host -join ' | ')]" }
        }

        Write-Host '[2] the extension folder removed' -ForegroundColor Cyan
        $moved = Join-Path $tmp 'ext-aside'
        Move-Item -LiteralPath (Join-Path $proj $extName) -Destination $moved
        foreach ($c in @(@{ S = 'Finalize'; L = $false }, @{ S = 'Export'; L = $false }, @{ S = 'Export'; L = $true })) {
            $g = Invoke-Gate $proj $c.S -AllowLegacyScript:$c.L
            $label = "$($c.S)$(if ($c.L) { ' -AllowLegacyScript' })"
            if ($g.Error -and $g.Error.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and $g.Error.Exception.Message.Contains('Deploy extension (EXTENSION-MISSING)') -and $g.Error.Exception.Message.Contains('Re-create the project')) { Ok "$label : W32T.PackageNotReady, 'Deploy extension (EXTENSION-MISSING)'" }
            else { Bad "$label : $(if ($g.Error) { "$($g.Error.FullyQualifiedErrorId) $($g.Error.Exception.Message)" } else { 'no error' })" }
        }
        Move-Item -LiteralPath $moved -Destination (Join-Path $proj $extName)

        Write-Host '[3] an edited extension copy; an edited call' -ForegroundColor Cyan
        Add-Content -LiteralPath $psm1 -Value '# edited in the project'
        $g = Invoke-Gate $proj 'Finalize'
        if ($g.Error -and $g.Error.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and $g.Error.Exception.Message.Contains('Deploy extension (EXTENSION-UNKNOWN)')) { Ok 'Finalize: an edited psm1 -> EXTENSION-UNKNOWN' } else { Bad "edited psm1: $($g.Error)" }
        [System.IO.File]::WriteAllBytes($psm1, $psm1Bytes)
        [System.IO.File]::WriteAllText($script, $scriptText.Replace('-Technology Exe', '-Technology Appx'), (New-Object System.Text.UTF8Encoding($true)))
        $g = Invoke-Gate $proj 'Export'
        if ($g.Error -and $g.Error.Exception.Message.Contains('Deploy extension (PLAN-MISMATCH)') -and $g.Error.Exception.Message.Contains('Install:install')) { Ok 'Export: -Technology edited inside the install block -> PLAN-MISMATCH' } else { Bad "edited call: $($g.Error)" }
        [System.IO.File]::WriteAllText($script, $scriptText, (New-Object System.Text.UTF8Encoding($true)))

        Write-Host '[4] stray folders on a GeneratorVersion 3 project' -ForegroundColor Cyan
        $strays = 'Old.PSAppDeployToolkit.Contoso', "$extName.Old"
        foreach ($s in $strays) { New-Item -ItemType Directory -Path (Join-Path $proj $s) -Force | Out-Null }
        $g = Invoke-Gate $proj 'Finalize'
        $lines = @(Get-ExtensionLine $g | Where-Object { $_ -match 'EXTENSION-STRAY' })
        if ($g.Error -and $lines.Count -eq 2 -and @($g.Warnings | Where-Object { $_ -match 'EXTENSION-STRAY' }).Count -eq 0) { Ok 'two stray folders -> two EXTENSION-STRAY errors (none as a warning)' } else { Bad "strays gv3: lines=$($lines.Count) err=$($g.Error)" }

        Write-Host '[5] a GeneratorVersion 2 script: stray = warning, Export prints one note' -ForegroundColor Cyan
        $marker = "## win32-toolkit generator 3; extension $extName $((Get-Win32ToolkitDeployExtension).Version)"
        $gv2 = [regex]::Replace($scriptText, '(?m)^[ \t]*' + [regex]::Escape($marker) + '\r?\n', '')
        [System.IO.File]::WriteAllText($script, $gv2, (New-Object System.Text.UTF8Encoding($true)))
        if ((Get-Win32ToolkitDeployScriptShape -Path $script).GeneratorVersion -eq 2) { Ok 'the marker line removed -> GeneratorVersion 2' } else { Bad 'not GeneratorVersion 2' }
        $g = Invoke-Gate $proj 'Finalize'
        $warnStray = @($g.Warnings | Where-Object { $_ -match 'Deploy extension \(EXTENSION-STRAY\)' })
        if (-not $g.Error -and $g.Result.Ready -and $warnStray.Count -eq 2 -and -not ($g.Host -match 'Note:')) { Ok 'Finalize: Ready, two EXTENSION-STRAY warnings, no note' } else { Bad "gv2 Finalize: err=$($g.Error) warnings=[$($g.Warnings -join ' | ')]" }
        $g = Invoke-Gate $proj 'Export'
        $notes = @($g.Host | Where-Object { $_ -match "Note: .*generated before win32-toolkit's extension module" })
        if (-not $g.Error -and $g.Result.Ready -and $notes.Count -eq 1 -and -not ($g.Warnings -match 'generated before')) { Ok 'Export: Ready, one note (host line, not a warning) that it is packaged as it is' } else { Bad "gv2 Export: err=$($g.Error) notes=$($notes.Count) host=[$($g.Host -join ' | ')]" }
        foreach ($s in $strays) { Remove-Item -LiteralPath (Join-Path $proj $s) -Recurse -Force }
        [System.IO.File]::WriteAllText($script, $scriptText, (New-Object System.Text.UTF8Encoding($true)))

        Write-Host '[6] Publish: Assert-Win32ToolkitDeployExtensionPackaged' -ForegroundColor Cyan
        $staging = Join-Path $tmp 'Staging\Contoso\GateApp_x64_1.0'
        $intuneWin = Join-Path $tmp 'IntuneWin\Contoso\GateApp_x64_1.0.intunewin'
        New-Item -ItemType Directory -Path (Split-Path $staging) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $intuneWin) -Force | Out-Null
        Copy-Item -LiteralPath $proj -Destination $staging -Recurse
        [System.IO.File]::WriteAllBytes($intuneWin, [byte[]](1..8))
        $call = { try { [pscustomobject]@{ Out = (Assert-Win32ToolkitDeployExtensionPackaged -ProjectPath $proj -IntuneWinPath $intuneWin); Error = $null } } catch { [pscustomobject]@{ Out = $null; Error = $_ } } }
        $r = & $call
        if (-not $r.Error -and $r.Out -eq $staging) { Ok 'the same extension in Staging -> the Staging path' } else { Bad "same: out=$($r.Out) err=$($r.Error)" }
        Add-Content -LiteralPath (Join-Path $staging "$extName\$extName.psm1") -Value '# changed in Staging'
        $r = & $call
        if ($r.Error.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and $r.Error.Exception.Message.StartsWith('Deploy extension: ') -and $r.Error.Exception.Message.Contains('differs') -and $r.Error.Exception.Message.Contains('Export the project again')) { Ok 'a changed Staging copy -> W32T.PackageNotReady (export again)' } else { Bad "changed: $($r.Error)" }
        Remove-Item -LiteralPath (Join-Path $staging $extName) -Recurse -Force
        $r = & $call
        if ($r.Error.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and $r.Error.Exception.Message.Contains("has no '$extName' folder")) { Ok 'no toolkit folder in Staging -> W32T.PackageNotReady' } else { Bad "no folder: $($r.Error)" }
        Remove-Item -LiteralPath $staging -Recurse -Force
        $r = & $call
        if ($r.Error.FullyQualifiedErrorId -eq 'W32T.PackageNotReady' -and $r.Error.Exception.Message.Contains('is missing')) { Ok 'no Staging copy -> W32T.PackageNotReady' } else { Bad "no staging: $($r.Error)" }
        Remove-Item -LiteralPath (Join-Path $proj $extName) -Recurse -Force
        $r = & $call
        if (-not $r.Error -and $r.Out -eq '') { Ok "a project without the toolkit folder -> '' (nothing to compare; Export already refused a GeneratorVersion 3 one)" } else { Bad "no project folder: out=$($r.Out) err=$($r.Error)" }
    }
    catch { Bad "unexpected error: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))" }
    $script:W32TTestFail
} $repo $tmp

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'All DeployExtensionGate tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail DeployExtensionGate test(s) FAILED." -ForegroundColor Red
exit 1
