function Set-PSADTDataDrivenScript {
    <#
    .SYNOPSIS
        Rewrites a scaffolded PSADT deploy script (Invoke-AppDeployToolkit.ps1) to be data-driven.
    .DESCRIPTION
        Shape-aware, fail-closed generator for the PSADT 4.1.x template and the PSADT 4.2 template
        scaffolded with New-ADTTemplate -ZeroConfig (Get-Win32ToolkitDeployScriptShape). Every code line
        it adds comes from the block catalog (Get-Win32ToolkitDeployScriptBlock) and contains NO
        app-specific value, so untrusted winget/registry/template values never enter a code position: the
        script reads them at runtime from SupportFiles\AppConfig.json (as data).

          1. $adtSession hashtable: AppVendor/AppName/AppVersion/AppArch/AppProcessesToClose/
             AppScriptAuthor/AppScriptDate point at $appConfig; ExitWithMsiCodes = $true is added.
          2. Session:loader block (above $adtSession): loads AppConfig.json and initialises the tattoo gate.
          3. Install: the data-driven install routine (msix/appx via provisioning, everything else non-MSI
             via Start-ADTProcess with the configured SilentArgs) - or, with -ManualInstall, the
             manual-install note marking where the operator writes the install - then 'install-done'.
             MSI installers are installed by PSADT's own Zero-Config block (the 4.1.x default template;
             4.2 New-ADTTemplate -ZeroConfig; App.Name stays empty); on 4.2 the toolkit adds an 'msp'
             block because 4.2's Zero-Config block no longer applies .msp patches (4.1.8 did).
          4. Uninstall: the data-driven uninstall routine (msi product codes, exe uninstallers, msix
             identity-based removal).
          5. Post-Install / Post-Uninstall: the install "tattoo" (HKLM:\SOFTWARE\<Author>\<Vendor>\<Name>
             \Version) that the Intune detection rule keys on; Post-Install writes it only when the Install
             phase reached its end; Post-Uninstall also removes a legacy WOW6432Node copy.
          6. Pre-Install: the remove-prior pair (installer-identity PR 3) - 'prior-check' (slot 5, before the org
             dialogs: evaluates AppConfig.PriorInstalls and refuses with a 691xx exit code before any app is closed)
             and 'remove-prior' (slot 30, after the org dialogs and hook: removes only the proven priors). Without
             PriorInstalls entries both do nothing. Placed on every new project, never re-rendered later (D12).

        Each block sits between '## win32-toolkit:<Phase>:<Slot>' sentinels (Set-Win32ToolkitPhaseBlock),
        so a re-run re-renders every block in place - byte-identical when nothing changed - and never
        touches code outside the blocks.

        Fail closed: a missing file, an unknown or unsupported template shape (incl. the PSADT 4.2 default
        template without Zero-Config), a DeployAppScriptVersion outside the supported range, missing PSADT
        4.1 markers, a missing session anchor or a script that would not parse throws a W32T.* error and
        leaves the file untouched. Only a missing AppScriptDate anchor is non-critical: the script is
        written and $false is returned with a warning.

        A script patched by win32-toolkit 1.1.6 or older (Support 'Legacy') is returned unchanged ($true).

        See knowledge-base/designs/data-driven-generation.md and psadt-4.2-implementation-spec.md.
    .PARAMETER ScriptPath
        Path to the project's Invoke-AppDeployToolkit.ps1 (a relative path resolves against the PowerShell
        location).
    .PARAMETER ManualInstall
        Hard apps: place the manual-install note instead of the data-driven install routine. The
        uninstall and the tattoo stay automated.
    .OUTPUTS
        [bool] $true = patched cleanly or already patched; $false = written and valid, with warnings.
    .EXAMPLE
        Set-PSADTDataDrivenScript -ScriptPath 'C:\...\Projects\Contoso\Git_x64_2.53.0\Invoke-AppDeployToolkit.ps1'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,

        # Hard apps: leave the Install region for the operator to author instead of
        # inserting the data-driven install routine. Uninstall stays automated.
        [switch]$ManualInstall
    )

    $display = $script:PsadtSupportedRange.Display

    # C-1 fail-closed error for this script (stable 'Unsupported PSADT template shape: ' wording).
    $shapeError = {
        param($Shape, [string]$Hint)
        $v = if ($Shape -and $Shape.DeployAppScriptVersion) { $Shape.DeployAppScriptVersion } else { 'none' }
        $s = if ($Shape) { $Shape.Shape } else { 'Unknown' }
        [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Unsupported PSADT template shape: $ScriptPath; shape $s; DeployAppScriptVersion $v; supported: $display. $Hint Nothing was changed."),
            'W32T.UnsupportedTemplateShape', [System.Management.Automation.ErrorCategory]::InvalidData, $ScriptPath)
    }

    # Resolve once against the PowerShell location: the .NET file APIs below would resolve a relative
    # path against the process directory, which Set-Location does not move.
    try { $ScriptPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ScriptPath) }
    catch { Write-Verbose "ScriptPath not resolved ($($_.Exception.Message)); used as given: $ScriptPath" }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw (& $shapeError $null 'The deploy script was not found.')
    }

    # ---- 1. read (keep the original bytes for the writer's restore) ----
    $originalBytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    $content = [System.IO.File]::ReadAllText($ScriptPath, [System.Text.Encoding]::UTF8)
    $shape = Get-Win32ToolkitDeployScriptShape -Content $content -IncludeLayout

    # Patched by win32-toolkit <= 1.1.6: packaged as-is, never re-validated or modified.
    if ($shape.Support -eq 'Legacy') {
        Write-Verbose "Deploy script was generated by an older win32-toolkit (GeneratorVersion 0) - left unchanged: $ScriptPath"
        return $true
    }

    # ---- 2. policy gate ----
    $markerProblem = $shape.Shape -eq 'Psadt41' -and $null -eq $shape.GeneratorVersion -and @($shape.MarkerIssues).Count -gt 0
    if ($shape.Support -ne 'Supported' -or $markerProblem) {
        $mm = $null; $parsed = $null
        if ($shape.DeployAppScriptVersion -and [version]::TryParse(($shape.DeployAppScriptVersion -split '-', 2)[0], [ref]$parsed)) { $mm = '{0}.{1}' -f $parsed.Major, $parsed.Minor }
        $versionOk = $shape.IsSupportedVersion -and (($shape.Shape -eq 'Psadt41' -and $mm -eq '4.1') -or ($shape.Shape -eq 'Psadt42ZeroConfig' -and $mm -eq '4.2'))
        $hint = switch ($true) {
            ($shape.Shape -eq 'Psadt42Default') {
                $h = 'Scaffolded from the PSADT 4.2 default template without Zero-Config - re-create the project with this win32-toolkit version (it scaffolds 4.2 with New-ADTTemplate -ZeroConfig).'
                if ($ManualInstall) { $h += ' Copy your Install code out of Invoke-AppDeployToolkit.ps1 first: re-creating the project deletes its folder. Or finalise it unchanged with Complete-Win32ToolkitManualApp -AllowLegacyScript.' }
                $h; break
            }
            ($shape.Shape -eq 'Unknown') {
                "Not a template layout this win32-toolkit version knows (newer PSADT?) - use a supported PSADT (see the health check). Detail: $($shape.Reason)."; break
            }
            (-not $versionOk) {
                "The script's DeployAppScriptVersion is outside the supported range or does not match its layout."; break
            }
            ($shape.Support -ne 'Supported') {
                "The deploy script contains an AppConfig loader that win32-toolkit did not write - re-create the project with this win32-toolkit version."; break
            }
            default { "PSADT 4.1 template markers missing or duplicated: $(@($shape.MarkerIssues) -join ', ')." }
        }
        throw (& $shapeError $shape $hint)
    }

    $nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $warnings = [System.Collections.Generic.List[string]]::new()

    # ---- 3. session edits, inside the $adtSession hashtable extent only ----
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
    $sessionAsg = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$adtSession' -and
            $_.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $_.Right.Expression -is [System.Management.Automation.Language.HashtableAst]
        })
    if ($sessionAsg.Count -ne 1) { throw (& $shapeError $shape 'The $adtSession = @{ } session anchor is missing or not unique.') }
    $htAst = $sessionAsg[0].Right.Expression
    $htStart = $htAst.Extent.StartOffset; $htEnd = $htAst.Extent.EndOffset
    $ht = $content.Substring($htStart, $htEnd - $htStart)

    # Line-anchored, ordinal anchors; each exactly once; skipped when already data-driven.
    $edits = [ordered]@{
        'AppVendor'           = @("AppVendor = ''", 'AppVendor = $appConfig.App.Vendor')
        'AppName'             = @("AppName = ''", 'AppName = $appConfig.App.Name')
        'AppVersion'          = @("AppVersion = ''", 'AppVersion = $appConfig.App.Version')
        'AppArch'             = @("AppArch = ''", 'AppArch = $appConfig.App.Arch')
        'AppProcessesToClose' = @('AppProcessesToClose = @()', 'AppProcessesToClose = @($appConfig.ProcessesToClose | Where-Object { $_ })')
        'AppScriptAuthor'     = @("AppScriptAuthor = '<author name>'", 'AppScriptAuthor = $appConfig.App.ScriptAuthor')
    }
    foreach ($label in $edits.Keys) {
        $from = $edits[$label][0]; $to = $edits[$label][1]
        $fromHits = [regex]::Matches($ht, '(?m)^[ \t]*(' + [regex]::Escape($from) + ')')
        $toHits   = [regex]::Matches($ht, '(?m)^[ \t]*(' + [regex]::Escape($to) + ')')
        if ($fromHits.Count -eq 1 -and $toHits.Count -eq 0) {
            $g = $fromHits[0].Groups[1]
            $ht = $ht.Substring(0, $g.Index) + $to + $ht.Substring($g.Index + $g.Length)
        }
        elseif (-not ($fromHits.Count -eq 0 -and $toHits.Count -eq 1)) {
            throw (& $shapeError $shape "The session anchor '$from' is missing or not unique in the `$adtSession hashtable.")
        }
    }
    # AppScriptDate: the only non-critical anchor (its default value is the scaffold date).
    $dateTo = 'AppScriptDate = $appConfig.App.ScriptDate'
    $dateHits = [regex]::Matches($ht, "(?m)^[ \t]*(AppScriptDate = '\d{4}-\d{2}-\d{2}')")
    $dateDone = [regex]::Matches($ht, '(?m)^[ \t]*(' + [regex]::Escape($dateTo) + ')')
    if ($dateHits.Count -eq 1 -and $dateDone.Count -eq 0) {
        $g = $dateHits[0].Groups[1]
        $ht = $ht.Substring(0, $g.Index) + $dateTo + $ht.Substring($g.Index + $g.Length)
    }
    elseif (-not ($dateHits.Count -eq 0 -and $dateDone.Count -eq 1)) {
        $warnings.Add("Data-driven patch anchor not found: AppScriptDate - the deploy script keeps its scaffolded AppScriptDate.")
    }
    # D13: MSI exit codes pass through (4.1.8 ignores the unknown key, 4.2 binds the switch).
    $hasExitKey = @($htAst.KeyValuePairs | Where-Object {
            $k = $_.Item1; $kn = if ($k -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $k.Value } else { $k.Extent.Text }
            $kn -eq 'ExitWithMsiCodes'
        }).Count -gt 0
    if (-not $hasExitKey) {
        $verLine = [regex]::Matches($ht, "(?m)^(?<ind>[ \t]*)DeployAppScriptVersion = '[^'\r\n]*'[^\r\n]*")
        if ($verLine.Count -ne 1) { throw (& $shapeError $shape "The session anchor DeployAppScriptVersion = '<version>' is missing or not unique in the `$adtSession hashtable.") }
        $m = $verLine[0]
        $insert = $nl + $m.Groups['ind'].Value + 'ExitWithMsiCodes = $true'
        $ht = $ht.Substring(0, $m.Index + $m.Length) + $insert + $ht.Substring($m.Index + $m.Length)
    }
    $content = $content.Substring(0, $htStart) + $ht + $content.Substring($htEnd)

    # ---- 4./5. loader + generator blocks (catalog text only) ----
    $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Session' -Slot 'loader' -Code (Get-Win32ToolkitDeployScriptBlock -Name Loader)
    if ($ManualInstall) {
        $content = Remove-Win32ToolkitPhaseBlock -Content $content -Phase 'Install' -Slot 'install'
        $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Install' -Slot 'manual-install' -Code (Get-Win32ToolkitDeployScriptBlock -Name ManualInstall)
    }
    else {
        $content = Remove-Win32ToolkitPhaseBlock -Content $content -Phase 'Install' -Slot 'manual-install'
        $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Install' -Slot 'install' -Code (Get-Win32ToolkitDeployScriptBlock -Name Install)
    }
    if ($shape.Shape -eq 'Psadt42ZeroConfig') {
        $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Install' -Slot 'msp' -Code (Get-Win32ToolkitDeployScriptBlock -Name Msp)
    }
    else {
        $content = Remove-Win32ToolkitPhaseBlock -Content $content -Phase 'Install' -Slot 'msp'
    }
    $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Install' -Slot 'install-done' -Code (Get-Win32ToolkitDeployScriptBlock -Name InstallDone)
    $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Uninstall' -Slot 'uninstall' -Code (Get-Win32ToolkitDeployScriptBlock -Name Uninstall)
    # Installer-identity PR 3: the remove-prior pair on EVERY new project. With no PriorInstalls entries in AppConfig.json
    # both blocks do nothing; entries are data read at run time, so adding one later never changes this script (D12).
    $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Pre-Install' -Slot 'prior-check' -Code (Get-Win32ToolkitDeployScriptBlock -Name RemovePriorCheck)
    $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Pre-Install' -Slot 'remove-prior' -Code (Get-Win32ToolkitDeployScriptBlock -Name RemovePrior)
    $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Post-Install' -Slot 'tattoo' -Code (Get-Win32ToolkitDeployScriptBlock -Name TattooInstall)
    $content = Set-Win32ToolkitPhaseBlock -Content $content -Phase 'Post-Uninstall' -Slot 'tattoo' -Code (Get-Win32ToolkitDeployScriptBlock -Name TattooUninstall)

    # The result must still be the same template layout, now generated by this version.
    $after = Get-Win32ToolkitDeployScriptShape -Content $content
    if ($after.Shape -ne $shape.Shape -or $after.GeneratorVersion -ne 2) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("The patched deploy script no longer matches its template layout (was $($shape.Shape), now $($after.Shape); $($after.Reason)). $ScriptPath was not changed."),
            'W32T.GeneratedScriptInvalid', [System.Management.Automation.ErrorCategory]::InvalidResult, $ScriptPath)
    }

    # ---- 6. write (UTF-8 with BOM; host + 5.1 parse; original bytes restored on failure) ----
    Write-Win32ToolkitDeployScript -Path $ScriptPath -Content $content -OriginalBytes $originalBytes

    foreach ($w in $warnings) { Write-Warning $w }
    return ($warnings.Count -eq 0)
}
