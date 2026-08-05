function Test-Win32ToolkitProjectUI {
    <#
    .SYNOPSIS
        Drives and validates a project's PSADT dialogs in the Hyper-V test VM — standalone, no operator.
    .DESCRIPTION
        Runs the app's PSADT deploy in the local Hyper-V test VM (see New-Win32ToolkitTestVM) and drives
        every dialog automatically with UI Automation: it launches the deploy in the interactive user
        session, clicks Install (or Defer), screenshots each dialog, and records a structured state-log.
        The results are copied back and validated against the org template the app was branded from —
        company subtitle, deferrals, countdown, the progress and completion dialogs — producing a
        PASS / WARN / FAIL / GAP report. GAP checks are the visual ones UI Automation cannot read from a
        window (accent color, the logo image, rendered language, the toast); judge those from the captured
        PNGs in Sandbox\Shots.

        Nothing here needs a human: no vmconnect window opens and no phase pauses. This is the automated
        counterpart of a hands-on "watch the PSADT GUI" run. Hyper-V ONLY — Windows Sandbox has no
        persistent interactive session to drive.

        Each requested run reverts the VM to its clean checkpoint first, so Install, Defer, and Uninstall
        runs are independent and never contaminate one another.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (the one containing Invoke-AppDeployToolkit.ps1). If omitted,
        a numbered selection menu lists the projects under BasePath.
    .PARAMETER BasePath
        Root folder to scan for projects when ProjectPath is omitted. Defaults to the registry-saved value.
    .PARAMETER TemplateName
        Org template to validate against. If omitted, it is resolved from the project's parent folder (the
        template segment) — pass this explicitly if that lookup can't find it.
    .PARAMETER IncludeDefer
        Also run a Defer pass: click Defer on the Welcome dialog and confirm the deferral path is offered.
    .PARAMETER IncludeUninstall
        Also run an Uninstall pass and validate the uninstall Welcome dialog.
    .PARAMETER CaptureHostConsole
        Additionally capture the VM console framebuffer from the host on a cadence (best-effort fallback
        view into Sandbox\HostShots). Off by default — the in-guest screenshots are the primary evidence.
    .PARAMETER VMName / Credential / CheckpointName
        Override the Hyper-V VM, guest credential, and checkpoint. Resolved from config / the stored guest
        credential when omitted.
    .EXAMPLE
        Test-Win32ToolkitProjectUI -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
    .EXAMPLE
        # Install + Defer + Uninstall, with a host-side console capture as well
        Test-Win32ToolkitProjectUI -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -IncludeDefer -IncludeUninstall -CaptureHostConsole
    .OUTPUTS
        [PSCustomObject] with one entry per run (.Install, .Defer, .Uninstall), each the validation report.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)] [string]$ProjectPath,
        [Parameter(Mandatory = $false)] [string]$BasePath,
        [Parameter(Mandatory = $false)] [string]$TemplateName,
        [Parameter(Mandatory = $false)] [switch]$IncludeDefer,
        [Parameter(Mandatory = $false)] [switch]$IncludeUninstall,
        [Parameter(Mandatory = $false)] [switch]$CaptureHostConsole,
        [Parameter(Mandatory = $false)] [string]$VMName,
        [Parameter(Mandatory = $false)] [pscredential]$Credential,
        [Parameter(Mandatory = $false)] [string]$CheckpointName = 'clean-base'
    )

    try {
        # ── Resolve the project ─────────────────────────────────────────────────────────────────
        if (-not $ProjectPath) {
            $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath
            $projects = Get-PSADTProjects -BasePath $BasePath
            if ($projects.Count -eq 0) {
                throw "No PSADT projects found in: $BasePath. Ensure project folders contain Invoke-AppDeployToolkit.ps1."
            }
            $ProjectPath = (Show-ProjectSelection -Projects $projects).Path
        }
        if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "Project path not found: $ProjectPath" }
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'))) {
            throw "Not a PSADT project (no Invoke-AppDeployToolkit.ps1): $ProjectPath"
        }
        $projectName = Split-Path -Leaf $ProjectPath

        # ── Hyper-V only ────────────────────────────────────────────────────────────────────────
        $backend = Get-Win32ToolkitTestBackend -Backend HyperV
        if ($backend -ne 'HyperV') {
            throw "UI validation runs on the Hyper-V test VM only, but Hyper-V isn't ready (resolved backend: $backend). Run New-Win32ToolkitTestVM first — Windows Sandbox has no persistent interactive session to drive."
        }

        # ── Resolve the org template (no prompt — this must stay standalone) ─────────────────────
        $template = $null
        if ($TemplateName) {
            $template = Get-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath
        }
        else {
            $segment = Split-Path -Leaf (Split-Path -Parent $ProjectPath)
            $resolvedBase = Get-Win32ToolkitBasePath -BasePath $BasePath -NonInteractive
            if ($resolvedBase) {
                $templatesRoot = (Get-Win32ToolkitPaths -BasePath $resolvedBase).Templates
                if (Test-Path -LiteralPath $templatesRoot) {
                    foreach ($tj in Get-ChildItem -LiteralPath $templatesRoot -Filter '*.json' -ErrorAction SilentlyContinue) {
                        try { $cand = Get-Content -LiteralPath $tj.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                        if ($cand.TemplateName -and (Sanitize-ProjectName -Name $cand.TemplateName) -eq $segment) { $template = $cand; break }
                    }
                }
            }
        }
        if (-not $template) {
            throw "Could not resolve the org template for '$projectName' (looked for a template whose sanitized name matches the parent folder). Pass -TemplateName explicitly."
        }

        Write-Host "`nProject   : $projectName" -ForegroundColor Green
        Write-Host "Template  : $($template.TemplateName)  (style: $($template.DialogStyle))" -ForegroundColor Cyan
        Write-Host 'Backend   : HyperV (interactive session, driven by UI Automation)' -ForegroundColor Cyan

        # Runs to perform. Install always; Defer / Uninstall opt-in.
        $runs = [ordered]@{}
        $runs['Install'] = @{ DeploymentType = 'Install'; Actions = @('Install') }
        if ($IncludeDefer) { $runs['Defer'] = @{ DeploymentType = 'Install'; Actions = @('Defer') } }
        if ($IncludeUninstall) { $runs['Uninstall'] = @{ DeploymentType = 'Uninstall'; Actions = @('Install') } }

        $common = @{ ProjectPath = $ProjectPath; Template = $template; CaptureHostConsole = $CaptureHostConsole; CheckpointName = $CheckpointName }
        if ($VMName) { $common['VMName'] = $VMName }
        if ($Credential) { $common['Credential'] = $Credential }

        $out = [ordered]@{}
        foreach ($name in $runs.Keys) {
            Write-Host "`n=== $name run ===" -ForegroundColor Magenta
            $r = Invoke-Win32ToolkitUiValidation @common -DeploymentType $runs[$name].DeploymentType -Actions $runs[$name].Actions
            Show-Win32ToolkitUiValidationSummary -RunName $name -Result $r
            $out[$name] = $r
        }

        Write-Host "`nScreenshots: $((Join-Path $ProjectPath 'Sandbox\Shots'))" -ForegroundColor Gray
        Write-Host 'GAP checks (accent color / logo / language / toast) are visual — review the PNGs above.' -ForegroundColor DarkGray

        return [PSCustomObject]$out
    }
    catch {
        Write-Error "Test-Win32ToolkitProjectUI failed: $($_.Exception.Message)"
    }
}
