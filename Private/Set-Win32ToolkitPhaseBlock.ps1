function Set-Win32ToolkitPhaseBlock {
    <#
    .SYNOPSIS
        Inserts or replaces one toolkit-owned block in a PSADT deploy-script phase (pure string transform).
    .DESCRIPTION
        win32-toolkit owns code in the deploy script only inside sentinel-delimited blocks:

            ## win32-toolkit:<Phase>:<Slot> (begin) - managed by win32-toolkit; regenerated, do not edit inside
            <code>
            ## win32-toolkit:<Phase>:<Slot> (end)

        This helper places such a block in a phase of a PSADT 4.1 (Install-/Uninstall-/Repair-ADTDeployment
        functions) or PSADT 4.2 ('New-Variable -Name <Phase> -Value { }') script:

          * the block exists      -> it is replaced in place (byte-identical when the code is unchanged);
          * the phase has blocks  -> the new block goes before the first block with a higher slot order,
                                     else right after the last block of the phase;
          * the phase has none    -> 4.1: right after the phase's '## <Perform ... tasks here>' marker line;
                                     4.2: Pre-*/main phases at the start of the line holding the closing '}',
                                     Post-* phases at the start of the line after the opening '{';
                                     Session (the AppConfig loader): at the start of the '$adtSession = @{' line.

        Text between blocks (operator code) is never touched. Code lines are indented 4 spaces (Session:
        the indentation of the $adtSession line); blank lines stay empty; the line ending follows the
        content (CRLF when it contains CRLF, else LF).

        Slot order: Session loader(10); Pre-Install prior-check(5) org-ui(10) hook(20) remove-prior(30);
        Pre-Uninstall and Pre-Repair org-ui(10) hook(20); Install msp(10) install|manual-install(20) install-done(90);
        Uninstall uninstall(20); Post-Install hook(10) tattoo(20) org-ui(30); Post-Repair hook(10) org-ui(30);
        Post-Uninstall hook(10) tattoo(20). Repair has no slots. In Pre-Install only the remove-prior block follows the
        org hook (installer-identity PR 3).

        Errors: an unknown phase/slot pair or code containing a sentinel line -> ArgumentException (a
        programming error); an Unknown template shape -> W32T.UnsupportedTemplateShape; a missing, duplicated
        or misplaced anchor or a corrupt block -> W32T.PhaseAnchorMissing.
    .PARAMETER Content
        The deploy-script text (no BOM).
    .PARAMETER Phase
        PSADT phase name, or the pseudo-phase 'Session' for the AppConfig loader.
    .PARAMETER Slot
        The block slot within the phase.
    .PARAMETER Code
        The block body (from Get-Win32ToolkitDeployScriptBlock), zero base indentation.
    .OUTPUTS
        [string] the new content.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'pure string transform; no system state')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Slot,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Code
    )

    $preSlots = @{ 'org-ui' = 10; 'hook' = 20 }
    $slotOrder = @{
        'Session'        = @{ 'loader' = 10 }
        'Pre-Install'    = @{ 'prior-check' = 5; 'org-ui' = 10; 'hook' = 20; 'remove-prior' = 30 }
        'Pre-Uninstall'  = $preSlots
        'Pre-Repair'     = $preSlots
        'Install'        = @{ 'msp' = 10; 'install' = 20; 'manual-install' = 20; 'install-done' = 90 }
        'Uninstall'      = @{ 'uninstall' = 20 }
        'Repair'         = @{}
        'Post-Install'   = @{ 'hook' = 10; 'tattoo' = 20; 'org-ui' = 30 }
        'Post-Repair'    = @{ 'hook' = 10; 'org-ui' = 30 }
        'Post-Uninstall' = @{ 'hook' = 10; 'tattoo' = 20 }
    }
    if (-not $slotOrder.ContainsKey($Phase) -or -not $slotOrder[$Phase].ContainsKey($Slot)) {
        throw [System.ArgumentException]::new("'${Phase}:$Slot' is not a win32-toolkit deploy-script block slot.")
    }
    if ($Code -match '(?m)^[ \t]*## win32-toolkit:') {
        throw [System.ArgumentException]::new("The code for block '${Phase}:$Slot' must not contain a '## win32-toolkit:' sentinel line.")
    }
    $order = $slotOrder[$Phase]

    $shape = Get-Win32ToolkitDeployScriptShape -Content $Content -IncludeLayout
    if ($shape.Shape -eq 'Unknown') {
        $v = if ($shape.DeployAppScriptVersion) { $shape.DeployAppScriptVersion } else { 'none' }
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Unsupported PSADT template shape: (deploy script text); shape Unknown; DeployAppScriptVersion $v; supported: $($script:PsadtSupportedRange.Display). Cannot place block '${Phase}:$Slot' ($($shape.Reason)). Nothing was changed."),
            'W32T.UnsupportedTemplateShape', [System.Management.Automation.ErrorCategory]::InvalidData, $Phase)
    }
    $layout = $shape.Layout

    # Throws W32T.PhaseAnchorMissing (C-1) with a uniform message.
    $anchorError = {
        param([string]$Why)
        [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("win32-toolkit cannot place the '${Phase}:$Slot' block in the deploy script: $Why. Re-create the project with this win32-toolkit version if the script was edited by hand."),
            'W32T.PhaseAnchorMissing', [System.Management.Automation.ErrorCategory]::InvalidData, "${Phase}:$Slot")
    }

    $issue = @($layout.BlockIssues | Where-Object { $_.Phase -eq $Phase }) | Select-Object -First 1
    if ($issue) { throw (& $anchorError $issue.Message) }
    $blocks = @($layout.Blocks | Where-Object { $_.Phase -eq $Phase } | Sort-Object Start)
    foreach ($b in $blocks) {
        if (-not $order.ContainsKey($b.Slot)) { throw (& $anchorError "unknown toolkit block '${Phase}:$($b.Slot)'") }
    }

    # ---- format ----
    $nl = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $indent = if ($Phase -eq 'Session') { if ($layout.Session) { $layout.Session.Indent } else { '' } } else { '    ' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$indent## win32-toolkit:${Phase}:$Slot (begin) - managed by win32-toolkit; regenerated, do not edit inside")
    foreach ($ln in (($Code -replace "`r`n", "`n").TrimEnd("`n") -split "`n")) {
        if ($ln.Trim()) { $lines.Add($indent + $ln) } else { $lines.Add('') }
    }
    $lines.Add("$indent## win32-toolkit:${Phase}:$Slot (end)")
    $block = ($lines -join $nl) + $nl

    # ---- replace in place ----
    $own = $blocks | Where-Object { $_.Slot -eq $Slot } | Select-Object -First 1
    if ($own) { return $Content.Substring(0, $own.Start) + $block + $Content.Substring($own.End) }

    # ---- insert ----
    $higher = $blocks | Where-Object { $order[$_.Slot] -gt $order[$Slot] } | Select-Object -First 1
    if ($higher) { $at = $higher.Start }
    elseif ($blocks.Count) { $at = $blocks[-1].End }
    elseif ($Phase -eq 'Session') {
        if (-not $layout.Session) { throw (& $anchorError 'the $adtSession = @{ assignment was not found') }
        $at = $layout.Session.LineStart
    }
    else {
        $ph = $layout.Phases[$Phase]
        if (-not $ph) { throw (& $anchorError "phase '$Phase' was not found") }
        if ($ph.ContainsKey('Marker')) {
            # PSADT 4.1: right after the phase's marker line (the marker is kept).
            if ($null -eq $ph.MarkerOffset) { throw (& $anchorError "the PSADT 4.1 marker '$($ph.Marker)' is missing or not unique") }
            if ($ph.MarkerOffset -lt $ph.RegionStart -or $ph.MarkerOffset -gt $ph.RegionEnd) {
                throw (& $anchorError "the PSADT 4.1 marker '$($ph.Marker)' is not inside its phase")
            }
            $eol = $Content.IndexOf("`n", $ph.MarkerOffset)
            if ($eol -lt 0) { throw (& $anchorError "the PSADT 4.1 marker '$($ph.Marker)' does not end its line") }
            $at = $eol + 1
        }
        else {
            # PSADT 4.2: the phase scriptblock's braces must sit on their own lines.
            $openEol = $Content.IndexOf("`n", $ph.Open)
            if ($openEol -lt 0 -or $openEol -gt $ph.Close) { throw (& $anchorError "the '{' and '}' of phase '$Phase' are on the same line") }
            if ($Phase -like 'Post-*') {
                if ($Content.Substring($ph.Open + 1, $openEol - $ph.Open - 1).Trim()) {
                    throw (& $anchorError "the opening '{' of phase '$Phase' is followed by code on its line")
                }
                $at = $openEol + 1
            }
            else {
                $closeLine = $Content.LastIndexOf("`n", $ph.Close) + 1
                if ($Content.Substring($closeLine, $ph.Close - $closeLine).Trim()) {
                    throw (& $anchorError "the closing '}' of phase '$Phase' does not start its line")
                }
                $at = $closeLine
            }
        }
    }
    return $Content.Substring(0, $at) + $block + $Content.Substring($at)
}
