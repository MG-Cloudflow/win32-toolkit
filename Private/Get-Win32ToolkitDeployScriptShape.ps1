function Get-Win32ToolkitDeployScriptShape {
    <#
    .SYNOPSIS
        Classifies a PSADT deploy script (Invoke-AppDeployToolkit.ps1) by its template layout and states
        whether win32-toolkit supports it.
    .DESCRIPTION
        The single source of the template-shape / version / generator policy. Detection is done on the
        PowerShell AST (host parser), never on comment markers:

          Psadt41            - the PSADT 4.1.x template: top-level Install-/Uninstall-/Repair-ADTDeployment
                               functions, each with the three $adtSession.InstallPhase assignments
                               ("Pre-$(...)", $adtSession.DeploymentType, "Post-$(...)") in that order.
          Psadt42ZeroConfig  - the PSADT 4.2 template scaffolded with New-ADTTemplate -ZeroConfig: nine
                               top-level 'New-Variable -Name <Phase> -Value { }' phases, the Get-Variable
                               dispatcher, and an 'if ($adtSession.UseDefaultMsi)' Zero-Config block that
                               calls Start-ADTMsiProcess in Install, Uninstall and Repair.
          Psadt42Default     - the same 4.2 layout without any Zero-Config block (recognised; the generator
                               refuses it).
          Unknown            - anything else (including a parse error, a missing file, both layouts mixed).

        Support (evaluated in this order):
          1. Unknown / Psadt42Default                                   -> Unsupported
          2. DeployAppScriptVersion outside the supported range, or not
             matching the layout (Psadt41 needs 4.1.x, ZeroConfig 4.2.x) -> Unsupported
          3. GeneratorVersion 0 (patched by win32-toolkit 1.1.6 or older):
             Psadt41 -> Legacy (supported with a warning); Psadt42ZeroConfig -> Unsupported
          4. otherwise                                                    -> Supported

        The nine PSADT 4.1 '## <Perform ... tasks here>' markers only feed MarkerIssues: win32-toolkit
        1.1.6 replaced two of them, so they cannot decide the shape.

        UninstallRevision reads the toolkit uninstall block ('## win32-toolkit:Uninstall:uninstall'): 0 = no
        such block (unpatched or Legacy), 1 = a block without the '## Uninstall revision <n> (win32-toolkit)'
        marker (GeneratorVersion 2 before the hardened uninstall), else <n> (2 = the hardened uninstall:
        time limit, child processes, NSIS in place, cleanup paths re-checked on the device). A marker outside
        the block, or one with more than 4 digits, does not count.

        RemovePriorRevision (installer-identity PR 3): 0 unless both the '## win32-toolkit:Pre-Install:prior-check' and
        the '...:remove-prior' blocks exist and the prior-check block holds '## remove-prior catalog revision <n>
        (win32-toolkit)' (at most 4 digits); then <n>. PriorCheckFirst: true only when RemovePriorRevision >= 1, the
        Pre-Install toolkit blocks are ordered prior-check < org-ui < remove-prior (a hook block, when present, between
        org-ui and remove-prior) and no Show-ADTInstallationWelcome / Show-ADTInstallationProgress statement lies in
        Pre-Install outside a toolkit block. A script created before PR 3 has 0 / false: it gets no prior-install rules
        (re-create it, D12).

        With -IncludeLayout the result also carries the offsets the phase-block helpers need (phase
        scriptblock braces on 4.2, marker/region per phase on 4.1, the $adtSession line, and every
        '## win32-toolkit:<Phase>:<Slot>' block with its integrity problems). Offsets are relative to the
        analysed text (-Content as given; -Path read as UTF-8 without the BOM).

        Never throws for script content: a missing file or parse errors give Shape 'Unknown' with Reason.
    .PARAMETER Path
        Path to an Invoke-AppDeployToolkit.ps1 (a relative path resolves against the PowerShell location).
    .PARAMETER Content
        The deploy-script text (no BOM).
    .PARAMETER IncludeLayout
        Also return the Layout used by Set-/Remove-Win32ToolkitPhaseBlock and Remove-Win32ToolkitPhaseDefaultUi.
    .OUTPUTS
        [pscustomobject] Shape, DeployAppScriptVersion, IsSupportedVersion, IsPatched, GeneratorVersion,
        HasTattoo, ParseErrors, MarkerIssues, Support, SupportReason, Reason, Layout, UninstallRevision,
        RemovePriorRevision, PriorCheckFirst.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Content')]
        [AllowEmptyString()]
        [string]$Content,

        [switch]$IncludeLayout
    )

    $phaseNames = @('Pre-Install', 'Install', 'Post-Install', 'Pre-Uninstall', 'Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Repair', 'Post-Repair')
    $markers = [ordered]@{
        'Pre-Install'    = '## <Perform Pre-Installation tasks here>'
        'Install'        = '## <Perform Installation tasks here>'
        'Post-Install'   = '## <Perform Post-Installation tasks here>'
        'Pre-Uninstall'  = '## <Perform Pre-Uninstallation tasks here>'
        'Uninstall'      = '## <Perform Uninstallation tasks here>'
        'Post-Uninstall' = '## <Perform Post-Uninstallation tasks here>'
        'Pre-Repair'     = '## <Perform Pre-Repair tasks here>'
        'Repair'         = '## <Perform Repair tasks here>'
        'Post-Repair'    = '## <Perform Post-Repair tasks here>'
    }
    $legacyText = 'Deploy script generated by an older win32-toolkit (1.1.6 or earlier): its uninstall does not remove the legacy WOW6432Node tattoo; re-create the project with this win32-toolkit version to get it.'

    $shape = 'Unknown'; $reason = ''; $version = $null; $parseErrors = 0
    $isPatched = $false; $generatorVersion = $null; $hasTattoo = $false; $uninstallRevision = 0
    $removePriorRevision = 0; $priorCheckFirst = $false
    $markerIssues = [System.Collections.Generic.List[string]]::new()
    $layout = $null

    # ---- read ----
    $text = $null
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        # Resolve once against the PowerShell location: the .NET reader below would resolve a relative
        # path against the process directory, which Set-Location does not move.
        try { $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path) }
        catch { Write-Verbose "Path not resolved ($($_.Exception.Message)); used as given: $Path" }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $reason = "file not found: $Path" }
        else {
            # ReadAllText(UTF8) honours and strips a BOM; the PSADT templates are UTF-8 with BOM.
            try { $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
            catch { $reason = "file could not be read: $($_.Exception.Message)" }
        }
    }
    else { $text = $Content }

    if ($null -ne $text) {
        # ---- text facts (ordinal) ----
        $isPatched        = $text.Contains('$appConfig =')
        $hasTattoo        = $text.Contains('win32-toolkit install tattoo - records')
        $generatorVersion = if ($text.Contains('## win32-toolkit:Session:loader (begin)')) { 2 } elseif ($isPatched) { 0 } else { $null }
        $um = [regex]::Match($text, '(?s)## win32-toolkit:Uninstall:uninstall \(begin\)[^\r\n]*\r?\n(.*?)## win32-toolkit:Uninstall:uninstall \(end\)')
        if ($um.Success) {
            # At most 4 digits: a hand-edited 'revision 99999999999' does not match (-> 1) instead of overflowing [int] and
            # failing the shape reader (used by the Export gate, the Set-PSADTDataDrivenScript post-patch check and the parity
            # risk reader) with a raw, non-W32T error.
            $rm = [regex]::Match($um.Groups[1].Value, '## Uninstall revision (\d{1,4}) \(win32-toolkit\)')
            $uninstallRevision = if ($rm.Success) { [int]$rm.Groups[1].Value } else { 1 }
        }
        # Installer-identity PR 3: the remove-prior pair. 0 unless BOTH Pre-Install blocks exist and the prior-check block
        # holds the catalog revision marker (at most 4 digits, as the uninstall revision).
        $pcm = [regex]::Match($text, '(?s)## win32-toolkit:Pre-Install:prior-check \(begin\)[^\r\n]*\r?\n(.*?)## win32-toolkit:Pre-Install:prior-check \(end\)')
        if ($pcm.Success -and $text.Contains('## win32-toolkit:Pre-Install:remove-prior (begin)')) {
            $rpm = [regex]::Match($pcm.Groups[1].Value, '## remove-prior catalog revision (\d{1,4}) \(win32-toolkit\)')
            if ($rpm.Success) { $removePriorRevision = [int]$rpm.Groups[1].Value }
        }

        # ---- AST ----
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $parseErrors = @($errors).Count
        $top = if ($ast.EndBlock) { @($ast.EndBlock.Statements) } else { @() }

        # Top-level '$adtSession = @{ ... }'.
        $sessionAsg = @($top | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left.Extent.Text -eq '$adtSession' -and
                $_.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $_.Right.Expression -is [System.Management.Automation.Language.HashtableAst]
            })
        $hashtable = if ($sessionAsg.Count -eq 1) { $sessionAsg[0].Right.Expression } else { $null }
        if ($hashtable) {
            foreach ($kv in $hashtable.KeyValuePairs) {
                $keyName = if ($kv.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $kv.Item1.Value } else { $kv.Item1.Extent.Text }
                if ($keyName -ne 'DeployAppScriptVersion') { continue }
                $str = $kv.Item2.Find({
                        param($n)
                        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                    }, $true)
                if ($str) { $version = [string]$str.Value }
            }
        }

        # 4.1: top-level *-ADTDeployment functions.
        $deployFunctions = [ordered]@{ 'Install' = 'Install-ADTDeployment'; 'Uninstall' = 'Uninstall-ADTDeployment'; 'Repair' = 'Repair-ADTDeployment' }
        $topFunctions = @($top | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
        $functions41 = @{}
        $has41 = $true
        foreach ($base in $deployFunctions.Keys) {
            $found = @($topFunctions | Where-Object { $_.Name -eq $deployFunctions[$base] })
            if ($found.Count -eq 1) { $functions41[$base] = $found[0] } else { $has41 = $false }
        }
        $anyDeploymentFunction = [bool]$ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like '*-ADTDeployment' }, $true)

        # 4.2: top-level 'New-Variable -Name <Phase> -Value { }' pipelines.
        $phaseBlocks = @{}; $phaseCounts = @{}
        foreach ($st in $top) {
            if ($st -isnot [System.Management.Automation.Language.PipelineAst] -or $st.PipelineElements.Count -ne 1) { continue }
            $cmd = $st.PipelineElements[0]
            if ($cmd -isnot [System.Management.Automation.Language.CommandAst] -or $cmd.GetCommandName() -ne 'New-Variable') { continue }
            $nameArg = $null; $valueArg = $null
            for ($i = 1; $i -lt $cmd.CommandElements.Count; $i++) {
                $el = $cmd.CommandElements[$i]
                if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $arg = $el.Argument
                if (-not $arg -and $i + 1 -lt $cmd.CommandElements.Count -and
                    $cmd.CommandElements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    $arg = $cmd.CommandElements[$i + 1]
                }
                if ($el.ParameterName -eq 'Name') { $nameArg = $arg }
                elseif ($el.ParameterName -eq 'Value') { $valueArg = $arg }
            }
            if (-not $nameArg) { continue }
            $name = if ($nameArg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $nameArg.Value } else { $nameArg.Extent.Text }
            if ($name -notin $phaseNames) { continue }
            $phaseCounts[$name] = 1 + [int]$phaseCounts[$name]
            if ($valueArg -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $phaseBlocks[$name] = $valueArg }
        }
        $dispatcher = $ast.Find({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Variable' -and
                $n.Extent.Text.Contains('"Pre-$($adtSession.DeploymentType)"')
            }, $true)
        $looks42 = ($phaseCounts.Count -gt 0) -or [bool]$dispatcher

        # 4.1 phase assignments (sorted by position) per deploy function.
        $assignments41 = @{}

        # ---- shape decision ----
        if ($parseErrors -gt 0) {
            $first = @($errors)[0]
            $reason = "parse error at line $($first.Extent.StartLineNumber): $($first.Message.TrimEnd('.'))"
        }
        elseif ($sessionAsg.Count -ne 1) {
            $reason = if ($sessionAsg.Count -eq 0) { 'no top-level $adtSession = @{ ... } assignment' } else { 'more than one top-level $adtSession = @{ ... } assignment' }
        }
        elseif ($has41 -and $looks42) { $reason = 'both the PSADT 4.1 and the PSADT 4.2 layouts are present' }
        elseif ($has41) {
            $expected = @('"Pre-$($adtSession.DeploymentType)"', '$adtSession.DeploymentType', '"Post-$($adtSession.DeploymentType)"')
            foreach ($base in $deployFunctions.Keys) {
                $fn = $functions41[$base]
                $as = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$adtSession.InstallPhase' }, $true) |
                        Sort-Object { $_.Extent.StartOffset })
                $texts = @($as | ForEach-Object { $_.Right.Extent.Text })
                if ($as.Count -ne 3 -or ($texts -join "`n") -cne ($expected -join "`n")) {
                    $reason = "$($fn.Name) does not have the three PSADT 4.1 InstallPhase assignments (Pre-, main, Post-) in order"
                    break
                }
                $assignments41[$base] = $as
            }
            if (-not $reason) { $shape = 'Psadt41' }
        }
        elseif ($looks42) {
            $missing = @($phaseNames | Where-Object { -not $phaseBlocks.ContainsKey($_) })
            $dupes   = @($phaseNames | Where-Object { [int]$phaseCounts[$_] -gt 1 })
            if ($missing.Count -or $dupes.Count) {
                $parts = @()
                if ($missing.Count) { $parts += "missing or not a scriptblock: $($missing -join ', ')" }
                if ($dupes.Count) { $parts += "duplicated: $($dupes -join ', ')" }
                $reason = "PSADT 4.2 phase variables incomplete ($($parts -join '; '))"
            }
            elseif (-not $dispatcher) { $reason = 'PSADT 4.2 phase dispatcher (Get-Variable -Name "Pre-$($adtSession.DeploymentType)", ...) not found' }
            elseif ($anyDeploymentFunction) { $reason = 'both the PSADT 4.1 and the PSADT 4.2 layouts are present' }
            else {
                $zeroConfig = @(foreach ($p in 'Install', 'Uninstall', 'Repair') {
                        $hit = $phaseBlocks[$p].ScriptBlock.Find({
                                param($n)
                                $n -is [System.Management.Automation.Language.IfStatementAst] -and
                                $n.Clauses[0].Item1.Extent.Text -eq '$adtSession.UseDefaultMsi' -and
                                [bool]$n.Clauses[0].Item2.Find({ param($m) $m -is [System.Management.Automation.Language.CommandAst] -and $m.GetCommandName() -eq 'Start-ADTMsiProcess' }, $true)
                            }, $true)
                        if ($hit) { $p }
                    })
                if ($zeroConfig.Count -eq 3) { $shape = 'Psadt42ZeroConfig' }
                elseif ($zeroConfig.Count -eq 0) { $shape = 'Psadt42Default' }
                else { $reason = "the PSADT Zero-Config MSI block is present in only some of Install/Uninstall/Repair ($($zeroConfig -join ', '))" }
            }
        }
        else { $reason = 'no known PSADT template layout (neither the 4.1 *-ADTDeployment functions nor the 4.2 phase variables)' }

        # ---- 4.1 marker census (never decides the shape) ----
        if ($shape -eq 'Psadt41') {
            foreach ($p in $markers.Keys) {
                $count = 0; $at = $text.IndexOf($markers[$p], [System.StringComparison]::Ordinal)
                while ($at -ge 0) { $count++; $at = $text.IndexOf($markers[$p], $at + 1, [System.StringComparison]::Ordinal) }
                if ($count -eq 0) { $markerIssues.Add("missing: $($markers[$p])") }
                elseif ($count -gt 1) { $markerIssues.Add("duplicate: $($markers[$p])") }
            }
        }

        # ---- PriorCheckFirst (installer-identity PR 3, L39) ----
        # True only when the Pre-Install toolkit blocks run prior-check < org-ui < [hook <] remove-prior and no PSADT
        # default welcome/progress statement is left in Pre-Install outside a toolkit block: then nothing closes or
        # shows anything before prior-check has refused, and the org welcome closes the prior's app before remove-prior.
        if ($removePriorRevision -ge 1 -and $shape -in 'Psadt41', 'Psadt42ZeroConfig') {
            $pre = @{}
            $spans = [System.Collections.Generic.List[object]]::new()
            foreach ($bm in [regex]::Matches($text, '(?m)^[ \t]*## win32-toolkit:Pre-Install:(?<slot>[\w-]+) \(begin\)')) {
                $slot = $bm.Groups['slot'].Value
                if (-not $pre.ContainsKey($slot)) { $pre[$slot] = [System.Collections.Generic.List[int]]::new() }
                $pre[$slot].Add($bm.Index)
                $em = [regex]::Match($text.Substring($bm.Index), '(?m)^[ \t]*## win32-toolkit:Pre-Install:' + [regex]::Escape($slot) + ' \(end\)[^\r\n]*')
                if ($em.Success) { $spans.Add(@{ Start = $bm.Index; End = $bm.Index + $em.Index + $em.Length }) }
            }
            $one = { param([string]$Slot) if ($pre.ContainsKey($Slot) -and $pre[$Slot].Count -eq 1) { $pre[$Slot][0] } else { -1 } }
            $pc = & $one 'prior-check'; $ou = & $one 'org-ui'; $rp = & $one 'remove-prior'
            $hk = if (-not $pre.ContainsKey('hook')) { $null } else { & $one 'hook' }
            $ordered = $pc -ge 0 -and $ou -gt $pc -and $rp -gt $ou -and ($null -eq $hk -or ($hk -gt $ou -and $hk -lt $rp))
            if ($ordered) {
                $phaseStart = -1; $phaseEnd = -1
                if ($shape -eq 'Psadt42ZeroConfig') {
                    $phaseStart = $phaseBlocks['Pre-Install'].Extent.StartOffset; $phaseEnd = $phaseBlocks['Pre-Install'].Extent.EndOffset
                }
                else {
                    $phaseStart = $assignments41['Install'][0].Extent.EndOffset; $phaseEnd = $assignments41['Install'][1].Extent.StartOffset
                }
                $dialogs = @($ast.FindAll({
                            param($n)
                            $n -is [System.Management.Automation.Language.CommandAst] -and
                            @('Show-ADTInstallationWelcome', 'Show-ADTInstallationProgress') -contains $n.GetCommandName()
                        }, $true) | Where-Object {
                        $s = $_.Extent.StartOffset
                        $s -ge $phaseStart -and $s -lt $phaseEnd -and -not ($spans | Where-Object { $s -ge $_.Start -and $s -lt $_.End })
                    })
                $priorCheckFirst = $dialogs.Count -eq 0
            }
        }

        # ---- layout (phase-block helpers only) ----
        if ($IncludeLayout) {
            $layout = @{ Session = $null; Phases = @{}; Blocks = @(); BlockIssues = @() }
            $issues = [System.Collections.Generic.List[object]]::new()
            if ($sessionAsg.Count -eq 1) {
                $so = $sessionAsg[0].Extent.StartOffset
                $ls = if ($so -gt 0) { $text.LastIndexOf("`n", $so - 1) + 1 } else { 0 }
                $before = $text.Substring($ls, $so - $ls)
                $layout.Session = @{ LineStart = $ls; Indent = ($before -replace '\S.*$', '') }
                if ($before.Trim()) { $issues.Add(@{ Phase = 'Session'; Message = 'the $adtSession = @{ assignment does not start its line' }) }
            }
            if ($shape -in 'Psadt42ZeroConfig', 'Psadt42Default') {
                foreach ($p in $phaseNames) {
                    $sb = $phaseBlocks[$p]
                    $layout.Phases[$p] = @{ Open = $sb.Extent.StartOffset; Close = $sb.Extent.EndOffset - 1; Ast = $sb }
                }
            }
            elseif ($shape -eq 'Psadt41') {
                foreach ($base in $deployFunctions.Keys) {
                    $fn = $functions41[$base]; $as = $assignments41[$base]
                    $names = @("Pre-$base", $base, "Post-$base")
                    for ($i = 0; $i -lt 3; $i++) {
                        $p = $names[$i]
                        $mk = $markers[$p]
                        $first = $text.IndexOf($mk, [System.StringComparison]::Ordinal)
                        $unique = $first -ge 0 -and $text.IndexOf($mk, $first + 1, [System.StringComparison]::Ordinal) -lt 0
                        $layout.Phases[$p] = @{
                            Marker       = $mk
                            MarkerOffset = if ($unique) { $first } else { $null }
                            FunctionAst  = $fn
                            RegionStart  = $as[$i].Extent.EndOffset
                            RegionEnd    = if ($i -lt 2) { $as[$i + 1].Extent.StartOffset } else { $fn.Body.Extent.EndOffset - 1 }
                        }
                    }
                }
            }

            # Toolkit blocks: '## win32-toolkit:<Phase>:<Slot> (begin)' ... '(end)' line pairs.
            $rxBegin = [regex]'(?m)^[ \t]*## win32-toolkit:(?<phase>[\w-]+):(?<slot>[\w-]+) \(begin\)[^\r\n]*(?:\r?\n|\z)'
            $rxEnd   = [regex]'(?m)^[ \t]*## win32-toolkit:(?<phase>[\w-]+):(?<slot>[\w-]+) \(end\)[^\r\n]*(?:\r?\n|\z)'
            $events = @(@($rxBegin.Matches($text) | ForEach-Object { [pscustomobject]@{ Kind = 'begin'; M = $_ } }) +
                @($rxEnd.Matches($text) | ForEach-Object { [pscustomobject]@{ Kind = 'end'; M = $_ } }) |
                Sort-Object { $_.M.Index })
            $blocks = [System.Collections.Generic.List[object]]::new()
            $open = $null
            foreach ($ev in $events) {
                $ph = $ev.M.Groups['phase'].Value; $sl = $ev.M.Groups['slot'].Value
                if ($ev.Kind -eq 'begin') {
                    if ($open) { $issues.Add(@{ Phase = $open.Phase; Message = "block '$($open.Phase):$($open.Slot)' has no (end) line before the next block begins" }) }
                    $open = @{ Phase = $ph; Slot = $sl; Start = $ev.M.Index }
                    continue
                }
                if (-not $open -or $open.Phase -ne $ph -or $open.Slot -ne $sl) {
                    $issues.Add(@{ Phase = $ph; Message = "stray (end) line for block '${ph}:$sl'" })
                    if ($open) { $issues.Add(@{ Phase = $open.Phase; Message = "block '$($open.Phase):$($open.Slot)' is not closed by its own (end) line" }) }
                    $open = $null
                    continue
                }
                if (@($blocks | Where-Object { $_.Phase -eq $ph -and $_.Slot -eq $sl }).Count) {
                    $issues.Add(@{ Phase = $ph; Message = "block '${ph}:$sl' occurs more than once" })
                }
                $blocks.Add([pscustomobject]@{ Phase = $ph; Slot = $sl; Start = $open.Start; End = $ev.M.Index + $ev.M.Length })
                $open = $null
            }
            if ($open) { $issues.Add(@{ Phase = $open.Phase; Message = "block '$($open.Phase):$($open.Slot)' has no (end) line" }) }

            # Containment: a phase block must lie inside its phase; the loader must stay top level, above $adtSession.
            foreach ($b in $blocks) {
                if ($b.Phase -eq 'Session') {
                    $insideStatement = @($top | Where-Object { $b.Start -ge $_.Extent.StartOffset -and $b.Start -lt $_.Extent.EndOffset }).Count -gt 0
                    if ($insideStatement -or -not $layout.Session -or $b.End -gt $layout.Session.LineStart) {
                        $issues.Add(@{ Phase = 'Session'; Message = "block 'Session:$($b.Slot)' must stay at top level, directly above `$adtSession = @{" })
                    }
                    continue
                }
                if ($b.Phase -notin $phaseNames) { $issues.Add(@{ Phase = $b.Phase; Message = "block '$($b.Phase):$($b.Slot)' names an unknown phase" }); continue }
                $pl = $layout.Phases[$b.Phase]
                if (-not $pl) { continue }   # Unknown shape: no phase layout to check against
                $inside = if ($pl.ContainsKey('Open')) { $b.Start -gt $pl.Open -and $b.End -le $pl.Close } else { $b.Start -ge $pl.RegionStart -and $b.End -le $pl.RegionEnd }
                if (-not $inside) { $issues.Add(@{ Phase = $b.Phase; Message = "block '$($b.Phase):$($b.Slot)' lies outside its phase" }) }
            }
            $layout.Blocks = @($blocks)
            $layout.BlockIssues = @($issues)
        }
    }

    # ---- support policy ----
    $isSupportedVersion = [bool](Test-Win32ToolkitPsadtVersionSupported -Version $version)
    $majorMinor = $null
    if ($version) {
        $parsed = $null
        if ([version]::TryParse(($version -split '-', 2)[0], [ref]$parsed)) { $majorMinor = '{0}.{1}' -f $parsed.Major, $parsed.Minor }
    }
    $support = 'Unsupported'; $supportReason = ''
    if ($shape -in 'Unknown', 'Psadt42Default') {
        $supportReason = if ($shape -eq 'Unknown') { "unknown template layout ($reason)" } else { 'PSADT 4.2 default template without Zero-Config' }
    }
    elseif (-not $isSupportedVersion -or ($shape -eq 'Psadt41' -and $majorMinor -ne '4.1') -or ($shape -eq 'Psadt42ZeroConfig' -and $majorMinor -ne '4.2')) {
        $shown = if ($version) { $version } else { 'none' }
        $supportReason = "DeployAppScriptVersion $shown is outside the supported range or does not match the $shape layout"
    }
    elseif ($generatorVersion -eq 0) {
        if ($shape -eq 'Psadt41') { $support = 'Legacy'; $supportReason = $legacyText }
        else { $supportReason = 'the script contains an AppConfig loader that win32-toolkit did not write' }
    }
    else { $support = 'Supported' }

    [pscustomobject]@{
        Shape                  = $shape
        DeployAppScriptVersion = $version
        IsSupportedVersion     = $isSupportedVersion
        IsPatched              = $isPatched
        GeneratorVersion       = $generatorVersion
        HasTattoo              = $hasTattoo
        ParseErrors            = $parseErrors
        MarkerIssues           = [string[]]@($markerIssues)
        Support                = $support
        SupportReason          = $supportReason
        Reason                 = $reason
        Layout                 = $layout
        UninstallRevision      = $uninstallRevision
        RemovePriorRevision    = $removePriorRevision
        PriorCheckFirst        = $priorCheckFirst
    }
}
