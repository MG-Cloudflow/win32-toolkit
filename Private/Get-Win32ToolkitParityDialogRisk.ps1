function Get-Win32ToolkitParityDialogRisk {
    <#
    .SYNOPSIS
        Tells whether an unattended Intune-parity run of a project would wait on a PSADT 4.1 welcome dialog.
    .DESCRIPTION
        Installer-identity PR 2, spec 2.5(a) (A1 hv r1.2). Read-only, host side, never throws.

        The Intune command line has no deploy mode, so PSADT runs in Auto mode. PSADT 4.2 resolves Auto to
        Silent when no listed process is running (or the list is empty). PSADT 4.1 shows its Pre-Install
        welcome dialog to a signed-in user in Auto mode, and with no processes to close it opens that
        dialog only when the user may defer (with no deferral and no running process it continues without
        a dialog). A project is AT RISK when all of these hold:
          1. its deploy script has the PSADT 4.1 template shape (Get-Win32ToolkitDeployScriptShape);
          2. SupportFiles\AppConfig.json lists no process to close (ProcessesToClose, the non-empty entries,
             as the deploy script filters them);
          3. its Pre-Install phase has a welcome dialog that can defer:
             - OrgUi:  the toolkit 'Pre-Install:org-ui' block, with AppConfig OrgUi.Welcome.Enabled and
                       OrgUi.Welcome.AllowDefer set;
             - Script: a Show-ADTInstallationWelcome call outside the toolkit blocks (the template default
                       or hand-written code) that passes -AllowDefer (a switch, or any value but a literal
                       $false) or a splatted argument (for example the template default @saiwParams, whose
                       hashtable cannot be judged statically). A literal call without either cannot defer.
        Whether a user is signed in to the test VM is not checked here (Invoke-Win32ToolkitParityPrecheck).
        Any read or parse problem gives AtRisk $false (Write-Verbose): the run then starts as before.
    .PARAMETER ProjectPath
        The PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1).
    .OUTPUTS
        [pscustomobject] AtRisk [bool], Shape [string], ProcessCount [int], Welcome ('OrgUi', 'Script' or ''),
        WelcomeDefers [bool], Reason [string].
    .EXAMPLE
        if ((Get-Win32ToolkitParityDialogRisk -ProjectPath $proj).AtRisk) { 'a PSADT 4.1 dialog would wait' }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $atRisk = $false; $shapeName = ''; $processCount = 0; $welcome = ''; $welcomeDefers = $false; $reason = ''
    try {
        $scriptPath = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        $configPath = Join-Path $ProjectPath 'SupportFiles\AppConfig.json'
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { $reason = 'the project has no Invoke-AppDeployToolkit.ps1' }
        else {
            # One text for the shape reader and the parser below, so their offsets match (UTF-8, BOM stripped).
            # The shape is returned on every later path (AtRisk, not Shape, picks the caller's exit-code-1460 hint).
            $text = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
            $shape = Get-Win32ToolkitDeployScriptShape -Content $text -IncludeLayout
            $shapeName = [string]$shape.Shape
            if ($shapeName -ne 'Psadt41') {
                $reason = "the deploy script is not a PSADT 4.1 template ($shapeName): PSADT 4.2 resolves Auto mode to Silent when no listed process is running"
            }
            elseif (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { $reason = 'the project has no SupportFiles\AppConfig.json' }
            else {
                $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath -ErrorAction Stop
                $listed = if ($cfg -and $cfg.PSObject.Properties['ProcessesToClose']) { $cfg.ProcessesToClose } else { $null }
                $processCount = @($listed | Where-Object { $_ }).Count
                if ($processCount -gt 0) {
                    $reason = 'the app has processes to close: PSADT 4.1 asks only while one of them is running'
                }
                else {
                    $region = $shape.Layout.Phases['Pre-Install']
                    $orgUiBlock = @($shape.Layout.Blocks | Where-Object { $_.Phase -eq 'Pre-Install' -and $_.Slot -eq 'org-ui' }) | Select-Object -First 1
                    # The shape reader parsed the same text without errors (Psadt41 needs a clean parse).
                    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
                    $calls = @($ast.FindAll({
                                param($n)
                                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Show-ADTInstallationWelcome'
                            }, $true) | Where-Object { $region -and $_.Extent.StartOffset -ge $region.RegionStart -and $_.Extent.StartOffset -lt $region.RegionEnd })
                    $hasOrgUi = $false; $orgUiDefers = $false; $hasScript = $false; $scriptDefers = $false
                    foreach ($call in $calls) {
                        $at = $call.Extent.StartOffset
                        $inBlock = @($shape.Layout.Blocks | Where-Object { $at -ge $_.Start -and $at -lt $_.End }) | Select-Object -First 1
                        if ($inBlock) {
                            if ($orgUiBlock -and $inBlock.Start -eq $orgUiBlock.Start) {
                                $hasOrgUi = $true
                                $ui = if ($cfg.PSObject.Properties['OrgUi']) { $cfg.OrgUi } else { $null }
                                $wd = if ($ui -and $ui.PSObject.Properties['Welcome']) { $ui.Welcome } else { $null }
                                if ($wd -and [bool]$wd.Enabled -and [bool]$wd.AllowDefer) { $orgUiDefers = $true }
                            }
                            continue
                        }
                        $hasScript = $true
                        foreach ($el in $call.CommandElements) {
                            if ($el -is [System.Management.Automation.Language.VariableExpressionAst] -and $el.Splatted) { $scriptDefers = $true }
                            elseif ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'AllowDefer') {
                                $literalFalse = $el.Argument -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                    $el.Argument.VariablePath.UserPath -eq 'false'
                                if (-not $literalFalse) { $scriptDefers = $true }
                            }
                        }
                    }
                    $welcomeDefers = $orgUiDefers -or $scriptDefers
                    $welcome = if ($orgUiDefers) { 'OrgUi' } elseif ($scriptDefers) { 'Script' } elseif ($hasOrgUi) { 'OrgUi' } elseif ($hasScript) { 'Script' } else { '' }
                    if ($welcomeDefers) {
                        $atRisk = $true
                        $reason = "a PSADT 4.1 package with no processes to close and a deferrable welcome dialog ($welcome)"
                    }
                    elseif ($welcome) { $reason = "the Pre-Install welcome dialog ($welcome) cannot defer: with no process to close PSADT 4.1 continues without it" }
                    else { $reason = 'the Pre-Install phase shows no welcome dialog' }
                }
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Intune-parity dialog check skipped (the project could not be read): $($_.Exception.Message)"
        $atRisk = $false; $welcomeDefers = $false
        $reason = 'the project could not be read'
    }
    if ($reason) { Write-Verbose "Intune-parity dialog check: $(if ($atRisk) { 'at risk' } else { 'not at risk' }) - $reason." }

    [pscustomobject]@{
        AtRisk        = [bool]$atRisk
        Shape         = $shapeName
        ProcessCount  = [int]$processCount
        Welcome       = $welcome
        WelcomeDefers = [bool]$welcomeDefers
        Reason        = $reason
    }
}
