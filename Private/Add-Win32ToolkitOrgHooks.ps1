function New-Win32ToolkitOrgHookStub {
    <#
    .SYNOPSIS
        Builds the CONSTANT deploy-script stub for one org-hook phase (no template values spliced).

    .DESCRIPTION
        Every argument is a fixed constant from the phase table in Add-Win32ToolkitOrgHooks (phase key,
        the pristine PSADT marker, one of six fixed hook filenames, and the Fail|Continue policy). No
        operator/template free-text ever reaches this text — the module's "never splice untrusted values
        into SYSTEM-run code" rule is satisfied structurally: operator script CONTENT is copied as a file
        and merely DOT-SOURCED at runtime; only this compile-time-constant stub is injected.

        The stub keeps the original marker as its LAST line so (a) re-apply stays idempotent (the pattern
        in Add-Win32ToolkitOrgHooks matches "begin…end + marker") and (b) on the Post-Install /
        Post-Uninstall phases the win32-toolkit tattoo — which the data-driven pass re-emitted directly
        below the marker — is preserved and still runs AFTER the hook. Hook-throws-before-tattoo is the
        safe order: a failed hook then prevents the detection tattoo from being written.

        All emitted syntax is Windows PowerShell 5.1-safe (Join-Path/Test-Path/dot-source/try-catch).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Marker,
        [ValidateSet('Fail', 'Continue')][string]$FailureAction = 'Fail',
        [string]$NewLine = "`r`n"
    )

    $ind = '    '   # 4-space indent, matching the PSADT deploy-function body
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$ind## Org hook: $Phase (begin — managed by org template; edit the file in SupportFiles\OrgHooks, not this stub)")
    $lines.Add("$ind`$orgHookScript = Join-Path -Path `$adtSession.DirSupportFiles -ChildPath 'OrgHooks\$File'")
    if ($FailureAction -eq 'Continue') {
        $lines.Add("$ind`if (Test-Path -LiteralPath `$orgHookScript)")
        $lines.Add("$ind{")
        $lines.Add("$ind    try { . `$orgHookScript }")
        $lines.Add("$ind    catch { Write-ADTLogEntry -Message ""Org hook $File failed (continuing): `$(`$_.Exception.Message)"" -Severity 2 }")
        $lines.Add("$ind}")
    } else {
        $lines.Add("$ind`if (Test-Path -LiteralPath `$orgHookScript) { . `$orgHookScript }")
    }
    $lines.Add("$ind## Org hook: $Phase (end)")
    $lines.Add("$ind$Marker")
    return ($lines -join $NewLine)
}

function Add-Win32ToolkitOrgHooks {
    <#
    .SYNOPSIS
        A1/A3 — inject org deploy-phase hook stubs + copy hook files and the org PSADT extension module
        into a configured project.

    .DESCRIPTION
        Called from Apply-OrgTemplate AFTER Set-PSADTDataDrivenScript, so the six target markers exist:
        Pre-Install / Pre-Uninstall / Pre-Repair / Repair-Post are pristine, and Post-Install /
        Post-Uninstall were re-emitted directly above the tattoo blocks.

        For each of the six phases, if the template has hooks enabled AND that phase's file exists in
        Templates\<name>\Hooks\, the file is COPIED into SupportFiles\OrgHooks\ and a constant stub is
        injected at the marker (idempotent: the pattern matches either the pristine marker or a
        previously-injected begin…end+marker region). Phases without a file (or with hooks disabled) are
        restored to their pristine marker — so removing a hook file and re-applying cleanly removes its
        stub. Everything is copy-not-splice; the only injected text is a compile-time constant.

        A3: any Templates\<name>\PSAppDeployToolkit.<Org>\ folder is copied to the project root, where the
        v4 frontend auto-imports every sibling dir matching 'PSAppDeployToolkit\..+'.

        Every copied file is parse-checked under real Windows PowerShell 5.1 (warn-only) because it runs
        on-device as 5.1.

    .PARAMETER ProjectPath
        The configured PSADT project.

    .PARAMETER Template
        The org-template object (schema 3.0+). Read defensively — Hooks/ExtensionModule may be absent on
        older templates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][PSCustomObject]$Template
    )

    $scriptPath = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { return }

    # ── read feature flags defensively (no registry unless a feature is on) ──
    $hooksEnabled = $false; $failureAction = 'Fail'
    $hp = $Template.PSObject.Properties['Hooks']
    if ($hp -and $hp.Value) {
        if ($hp.Value.PSObject.Properties['Enabled']) { $hooksEnabled = [bool]$hp.Value.Enabled }
        if ($hooksEnabled -and $hp.Value.PSObject.Properties['FailureAction'] -and $hp.Value.FailureAction -in @('Fail', 'Continue')) {
            $failureAction = [string]$hp.Value.FailureAction
        }
    }
    $extEnabled = $false
    if ($Template.PSObject.Properties['ExtensionModule']) { $extEnabled = [bool]$Template.ExtensionModule }

    # ── resolve the template's asset folder only when a feature needs it ──
    $assetFolder = $null
    if ($hooksEnabled -or $extEnabled) {
        $tn = if ($Template.PSObject.Properties['TemplateName']) { [string]$Template.TemplateName } else { '' }
        if ($tn) {
            try { $assetFolder = Get-Win32ToolkitTemplateAssetFolder -TemplateName $tn } catch {
                Write-Verbose "Org hooks/module: could not resolve template asset folder — skipping ($($_.Exception.Message))"
            }
        }
    }

    # Phase → (pristine marker, fixed hook filename).
    $phases = @(
        @{ Key = 'PreInstall';    Marker = '## <Perform Pre-Installation tasks here>';    File = 'PreInstall.ps1' }
        @{ Key = 'PostInstall';   Marker = '## <Perform Post-Installation tasks here>';   File = 'PostInstall.ps1' }
        @{ Key = 'PreUninstall';  Marker = '## <Perform Pre-Uninstallation tasks here>';  File = 'PreUninstall.ps1' }
        @{ Key = 'PostUninstall'; Marker = '## <Perform Post-Uninstallation tasks here>'; File = 'PostUninstall.ps1' }
        @{ Key = 'PreRepair';     Marker = '## <Perform Pre-Repair tasks here>';          File = 'PreRepair.ps1' }
        @{ Key = 'PostRepair';    Marker = '## <Perform Post-Repair tasks here>';         File = 'PostRepair.ps1' }
    )

    $scr = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    $nl  = if ($scr -match "`r`n") { "`r`n" } else { "`n" }
    $hooksSrc = if ($assetFolder) { Join-Path $assetFolder 'Hooks' } else { $null }
    $destHookDir = Join-Path $ProjectPath 'SupportFiles\OrgHooks'
    $changed = $false

    foreach ($ph in $phases) {
        $srcFile  = if ($hooksSrc) { Join-Path $hooksSrc $ph.File } else { $null }
        $wantHook = $hooksEnabled -and $srcFile -and (Test-Path -LiteralPath $srcFile)

        # Idempotent anchor: a previously-injected "begin … end + marker" region, OR the pristine marker.
        # Longer alternative first so it wins at the begin-tag position. Singleline (-Multiline) lets
        # .*? span newlines; the marker string is unique in the file so neither branch over-reaches.
        $mkEsc    = [regex]::Escape($ph.Marker)
        $beginEsc = [regex]::Escape("## Org hook: $($ph.Key) (begin")
        $pattern  = "[ \t]*$beginEsc.*?\(end\)\r?\n[ \t]*$mkEsc" + '|' + "[ \t]*$mkEsc"

        if ($wantHook) {
            if (-not (Test-Path -LiteralPath $destHookDir)) { New-Item -ItemType Directory -Path $destHookDir -Force | Out-Null }
            $destFile = Join-Path $destHookDir $ph.File
            Copy-Item -LiteralPath $srcFile -Destination $destFile -Force

            $errs = @(Test-Win32ToolkitPS51Syntax -Path $destFile)
            if ($errs.Count) {
                Write-Warning "Org hook '$($ph.File)' has Windows PowerShell 5.1 syntax issue(s) — it runs on-device as 5.1: $($errs -join ' | ')"
            }

            $stub    = New-Win32ToolkitOrgHookStub -Phase $ph.Key -File $ph.File -Marker $ph.Marker -FailureAction $failureAction -NewLine $nl
            $newScr  = Set-TextBlock -Text $scr -Pattern $pattern -Replacement $stub -Multiline -Label "org hook: $($ph.Key)"
        } else {
            # No hook for this phase → ensure the marker is pristine (removes any stale stub). Silent:
            # a pristine marker replaces itself (no-op) and a missing marker must not warn when the
            # feature is off.
            $newScr = Set-TextBlock -Text $scr -Pattern $pattern -Replacement ("    " + $ph.Marker) -Multiline
        }

        if ($newScr -ne $scr) { $changed = $true; $scr = $newScr }
    }

    if ($changed) {
        # UTF-8 WITH BOM — the deploy script runs on-device under Windows PowerShell 5.1.
        [System.IO.File]::WriteAllText($scriptPath, $scr, (New-Object System.Text.UTF8Encoding($true)))
        Write-Verbose '  org hook stubs updated in Invoke-AppDeployToolkit.ps1'
    }

    # ── A3: org PSADT extension module(s) ──
    if ($extEnabled -and $assetFolder -and (Test-Path -LiteralPath $assetFolder)) {
        $modDirs = @(Get-ChildItem -LiteralPath $assetFolder -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^PSAppDeployToolkit\..+' })
        foreach ($md in $modDirs) {
            $dest = Join-Path $ProjectPath $md.Name
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item -LiteralPath $md.FullName -Destination $dest -Recurse -Force
            Get-ChildItem -LiteralPath $dest -Recurse -File -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue | ForEach-Object {
                $e = @(Test-Win32ToolkitPS51Syntax -Path $_.FullName)
                if ($e.Count) { Write-Warning "Org extension module file '$($_.Name)' has 5.1 syntax issue(s): $($e -join ' | ')" }
            }
            Write-Verbose "  org extension module '$($md.Name)' copied into project root"
        }
    }
}
