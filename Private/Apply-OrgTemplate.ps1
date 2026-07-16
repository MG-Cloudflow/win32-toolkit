function Apply-OrgTemplate {
    [CmdletBinding()]
    param(
        [string]$ProjectPath,
        [PSCustomObject]$Template
    )

    try {
        # Set-TextBlock (replace first regex match via index maths; -Label warns on a miss = PSADT
        # template drift) lives in Private\Set-Win32ToolkitTextBlock.ps1, dot-sourced by the loader.
        # Scope note: the config.psd1 patches below use broad `-replace` patterns and are deliberately
        # not label-verified here.

        # Escape single quotes so a free-text template value (company name, dialog messages, log path,
        # author) stays a valid single-quoted literal in the generated config.psd1 / strings.psd1 /
        # deploy script. Used everywhere a value is spliced into a '...' literal below. [string]$null -> ''.
        function Esc { param([string]$s) $s -replace "'", "''" }

        #── config.psd1 (data-driven, F1) ──────────────────────────────────
        # REPLACE the scaffolded full config.psd1 with a SPARSE file carrying only the template's
        # deltas. PSADT superimposes it over its signed module default key-by-key, so every omitted
        # key keeps the default — no more regex-patching a full copy (which drifted on PSADT text
        # changes). New config knobs are now one hashtable entry in New-Win32ToolkitSparseConfig.
        $configPath = Join-Path $ProjectPath 'Config\config.psd1'
        if (Test-Path $configPath) {
            $cfg = New-Win32ToolkitSparseConfig -Template $Template
            # UTF-8 WITH BOM — read on-device by Windows PowerShell 5.1 (Import-PowerShellDataFile),
            # which decodes a BOM-less file as ANSI and would mojibake a non-ASCII CompanyName. PS7's
            # Set-Content -Encoding UTF8 writes NO BOM, so write the bytes ourselves.
            [System.IO.File]::WriteAllText($configPath, $cfg, (New-Object System.Text.UTF8Encoding($true)))
            Write-Verbose '  config.psd1 replaced with sparse template config'
        }

        #── strings.psd1 ───────────────────────────────────────────────────
        $strPath = Join-Path $ProjectPath 'Strings\strings.psd1'
        if (Test-Path $strPath) {
            $str = Get-Content $strPath -Raw -Encoding UTF8

            # BalloonTip.Complete sub-block
            $newBalloon = "        # Text displayed in the balloon tip for successful completion of a deployment type.`r`n        Complete = @{`r`n            Install = '$(Esc $Template.BalloonComplete.Install)'`r`n            Repair = '$(Esc $Template.BalloonComplete.Repair)'`r`n            Uninstall = '$(Esc $Template.BalloonComplete.Uninstall)'`r`n        }"
            $str = Set-TextBlock -Text $str `
                -Pattern '(?s)        # Text displayed in the balloon tip for successful completion of a deployment type\.\r?\n        Complete = @\{[^}]*\}' `
                -Replacement $newBalloon -Multiline -Label 'balloon-complete messages'

            # ProgressPrompt — entire block up to RestartPrompt
            $nl = if ($str -match '\r\n') { "`r`n" } else { "`n" }
            $newProg = "    ProgressPrompt = @{${nl}        # Default message displayed in the progress bar.${nl}        Message = @{${nl}            Install = '$(Esc $Template.ProgressMessage.Install)'${nl}            Repair = '$(Esc $Template.ProgressMessage.Repair)'${nl}            Uninstall = '$(Esc $Template.ProgressMessage.Uninstall)'${nl}        }${nl}${nl}        # Default message detail displayed in the progress bar.${nl}        MessageDetail = @{${nl}            Install = '$(Esc $Template.ProgressMessageDetail.Install)'${nl}            Repair = '$(Esc $Template.ProgressMessageDetail.Repair)'${nl}            Uninstall = '$(Esc $Template.ProgressMessageDetail.Uninstall)'${nl}        }${nl}${nl}        # The subtitle underneath the Install Title, e.g. Company Name. Only for Fluent dialogs.${nl}        Subtitle = @{${nl}            Install = '{Toolkit\CompanyName} - App Installation'${nl}            Repair = '{Toolkit\CompanyName} - App Repair'${nl}            Uninstall = '{Toolkit\CompanyName} - App Uninstallation'${nl}        }${nl}    }"
            $str = Set-TextBlock -Text $str `
                -Pattern '(?s)    ProgressPrompt = @\{.*?(?=\r?\n    RestartPrompt)' `
                -Replacement $newProg -Multiline -Label 'progress-prompt messages'

            # UTF-8 WITH BOM (see config.psd1 above) — dialog strings are the most likely place for
            # non-ASCII text (accents, curly quotes, ™/®), and they render on the user's screen.
            [System.IO.File]::WriteAllText($strPath, $str, (New-Object System.Text.UTF8Encoding($true)))
            Write-Verbose '  strings.psd1 updated'
        }

        #── Invoke-AppDeployToolkit.ps1 ─────────────────────────────────────
        $scriptPath = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        if (Test-Path $scriptPath) {
            $scr = Get-Content $scriptPath -Raw -Encoding UTF8

            # AppScriptAuthor — escape single quotes so a free-text author like "O'Brien IT" stays a
            # valid single-quoted literal. This value now drives the on-device install tattoo and the
            # Intune detection key (see Set-PSADTDataDrivenScript / Get-Win32DetectionRules), so a
            # broken literal here would fail the whole deploy script on the device. Set-TextBlock does
            # literal insertion (index math), so a '$' in the author is never treated as a backreference.
            $authorLiteral = "AppScriptAuthor = '" + ($Template.AppScriptAuthor -replace "'", "''") + "'"
            $scr = Set-TextBlock -Text $scr -Pattern "AppScriptAuthor = '[^']*'" -Replacement $authorLiteral -Label 'AppScriptAuthor'

            # ── Install Welcome dialog ──
            if ($Template.WelcomeDialog.Enabled) {
                $saiwLines       = [System.Collections.Generic.List[string]]::new()  # base hashtable entries
                $saiwCloseLines  = [System.Collections.Generic.List[string]]::new()  # only valid with CloseProcesses
                if ($Template.WelcomeDialog.AllowDefer) {
                    $saiwLines.Add("        AllowDefer = `$true")
                    $saiwLines.Add("        DeferTimes = $($Template.WelcomeDialog.DeferTimes)")
                }
                if ($Template.WelcomeDialog.CheckDiskSpace) { $saiwLines.Add("        CheckDiskSpace = `$true") }
                if ($Template.WelcomeDialog.PersistPrompt)  { $saiwLines.Add("        PersistPrompt = `$true") }
                if ($Template.WelcomeDialog.CustomText) {
                    # Only emit CustomText if strings.psd1 actually has a non-empty CustomMessage
                    $strPathForCheck = Join-Path $ProjectPath 'Strings\strings.psd1'
                    $hasCustomMsg = (Test-Path $strPathForCheck) -and ((Get-Content $strPathForCheck -Raw) -match "CustomMessage\s*=\s*'[^']+'")
                    if ($hasCustomMsg) { $saiwLines.Add("        CustomText = `$true") }
                }
                # BlockExecution and CloseProcessesCountdown only belong to 'with processes to close' parameter sets
                if ($Template.WelcomeDialog.BlockExecution) {
                    $saiwCloseLines.Add("        `$saiwParams.Add('BlockExecution', `$true)")
                }
                if ($Template.WelcomeDialog.CloseProcessesCountdown -gt 0) {
                    $saiwCloseLines.Add("        `$saiwParams.Add('CloseProcessesCountdown', $($Template.WelcomeDialog.CloseProcessesCountdown))")
                }
                $saiwBody       = $saiwLines -join "`n"
                $saiwCloseBody  = if ($saiwCloseLines.Count -gt 0) { "`n" + ($saiwCloseLines -join "`n") } else { '' }
                $newWelcome = "    ## Show Welcome Message, close processes if specified.`n    `$saiwParams = @{`n$saiwBody`n    }`n    if (`$adtSession.AppProcessesToClose.Count -gt 0)`n    {`n        `$saiwParams.Add('CloseProcesses', `$adtSession.AppProcessesToClose)$saiwCloseBody`n    }`n    Show-ADTInstallationWelcome @saiwParams"
            } else {
                $newWelcome = "    ## Welcome dialog disabled by org template."
            }
            # Pattern matches both original PSADT format and our re-applied format
            $scr = Set-TextBlock -Text $scr `
                -Pattern '(?s)    ## (?:Show Welcome Message[^\n]*\r?\n    \$saiwParams = @\{.*?    Show-ADTInstallationWelcome @saiwParams|Welcome dialog disabled by org template\.)' `
                -Replacement $newWelcome -Multiline -Label 'install welcome dialog'

            # ── Uninstall Welcome dialog ──
            $uwSettings = if ($Template.PSObject.Properties['UninstallWelcomeDialog']) { $Template.UninstallWelcomeDialog } else { $null }
            if ($uwSettings -and $uwSettings.Enabled) {
                $uArgs = [System.Collections.Generic.List[string]]::new()
                if ($uwSettings.CloseProcessesCountdown -gt 0) { $uArgs.Add("-CloseProcessesCountdown $($uwSettings.CloseProcessesCountdown)") }
                if ($uwSettings.PersistPrompt)                 { $uArgs.Add('-PersistPrompt') }
                if ($uwSettings.BlockExecution)                { $uArgs.Add('-BlockExecution') }
                $uArgStr = if ($uArgs.Count -gt 0) { ' ' + ($uArgs -join ' ') } else { '' }
                $newUninstallWelcome = "    ## If there are processes to close, show Welcome Message before uninstalling.`n    if (`$adtSession.AppProcessesToClose.Count -gt 0)`n    {`n        Show-ADTInstallationWelcome -CloseProcesses `$adtSession.AppProcessesToClose$uArgStr`n    }"
            } else {
                $newUninstallWelcome = "    ## Uninstall welcome dialog disabled by org template."
            }
            $scr = Set-TextBlock -Text $scr `
                -Pattern '(?s)    ## (?:If there are processes to close.*?\r?\n    \}|Uninstall welcome dialog disabled by org template\.)' `
                -Replacement $newUninstallWelcome -Multiline -Label 'uninstall welcome dialog'

            # ── Progress dialog (all 3 occurrences: Install, Uninstall, Repair) ──
            if ($Template.ProgressDialog.Enabled) {
                $progressArgs = ''
                if ($Template.ProgressDialog.StatusMessage -and $Template.ProgressDialog.StatusMessage.Trim() -ne '') {
                    $progressArgs += " -StatusMessage '$(Esc $Template.ProgressDialog.StatusMessage)'"
                }
                if ($Template.ProgressDialog.StatusMessageDetail -and $Template.ProgressDialog.StatusMessageDetail.Trim() -ne '') {
                    $progressArgs += " -StatusMessageDetail '$(Esc $Template.ProgressDialog.StatusMessageDetail)'"
                }
                $newProgress = "    ## Show Progress Message (with the default message).`n    Show-ADTInstallationProgress$progressArgs"
            } else {
                $newProgress = "    ## Progress dialog disabled by org template."
            }
            $progPattern = '    ## (?:Show Progress Message[^\n]*\n    Show-ADTInstallationProgress[^\n]*|Progress dialog disabled by org template\.)'
            $offset = 0; $replaced = 0
            while ($replaced -lt 5) {
                $m = [regex]::Match($scr.Substring($offset), $progPattern)
                if (-not $m.Success) { break }
                $absIdx = $offset + $m.Index
                $scr = $scr.Substring(0, $absIdx) + $newProgress + $scr.Substring($absIdx + $m.Length)
                $offset = $absIdx + $newProgress.Length
                $replaced++
            }
            if ($replaced -eq 0) {
                Write-Warning "Org template: 'progress dialog' pattern not found — section skipped (PSADT template drift?)."
            }

            # ── Completion prompt (Post-Install) ──
            if ($Template.CompletionPrompt.Enabled) {
                $msg = $Template.CompletionPrompt.Message -replace "'", "''"
                $btn = $Template.CompletionPrompt.ButtonRightText -replace "'", "''"
                $newCompletion = "    ## Display a message at the end of the install.`n    if (!`$adtSession.UseDefaultMsi)`n    {`n        Show-ADTInstallationPrompt -Message '$msg' -ButtonRightText '$btn' -NoWait`n    }"
            } else {
                $newCompletion = "    ## Completion prompt disabled by org template."
            }
            $scr = Set-TextBlock -Text $scr `
                -Pattern '(?s)    ## (?:Display a message at the end[^\n]*\r?\n    if \(!\$adtSession\.UseDefaultMsi\)\r?\n    \{[\s\S]*?\}|Completion prompt disabled by org template\.)' `
                -Replacement $newCompletion -Multiline -Label 'completion prompt'

            # UTF-8 WITH BOM (see config.psd1 above) — this script is executed on the device by Windows
            # PowerShell 5.1; a BOM-less non-ASCII AppScriptAuthor/prompt message would mojibake there.
            [System.IO.File]::WriteAllText($scriptPath, $scr, (New-Object System.Text.UTF8Encoding($true)))
            Write-Verbose '  Invoke-AppDeployToolkit.ps1 updated'
        }

        Write-Host "✓ Org template '$($Template.TemplateName)' applied to project" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to apply org template: $($_.Exception.Message)"
        return $false
    }
}