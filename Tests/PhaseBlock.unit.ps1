<#
    Unit tests for the pure phase-block helpers (implementation spec 2.6):
      Set-Win32ToolkitPhaseBlock, Remove-Win32ToolkitPhaseBlock, Remove-Win32ToolkitPhaseDefaultUi.

    Per golden (PSADT 4.1.8, 4.2.0 default, 4.2.0 Zero-Config): every slot inserted in a shuffled order
    lands in canonical order; replace in place; idempotent; operator text between blocks survives a
    re-render; corrupt blocks / missing anchors -> W32T.PhaseAnchorMissing; 4.1 insertion right after the
    marker; 4.2 Post-* first / Pre-* last; Session loader directly above $adtSession; CRLF and LF line
    endings preserved; PSADT default dialogs removed outside toolkit blocks only.

    Run:  pwsh -File Tests\PhaseBlock.unit.ps1
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
foreach ($f in 'Get-Win32ToolkitDeployScriptShape', 'Set-Win32ToolkitPhaseBlock', 'Remove-Win32ToolkitPhaseBlock', 'Remove-Win32ToolkitPhaseDefaultUi') {
    . (Join-Path $repo "Private\$f.ps1")
}

function Get-Fixture([string]$Name) {
    ([System.IO.File]::ReadAllText((Join-Path $repo "Tests\Fixtures\$Name\Invoke-AppDeployToolkit.ps1"), [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
}
# Slots of a phase in document order.
function Get-SlotOrder([string]$Text, [string]$Phase) {
    @([regex]::Matches($Text, '(?m)^[ \t]*## win32-toolkit:' + [regex]::Escape($Phase) + ':(?<s>[\w-]+) \(begin\)') | ForEach-Object { $_.Groups['s'].Value })
}
# Runs a script block and returns the FullyQualifiedErrorId / exception type it threw ('' when none).
function Get-Thrown([scriptblock]$Action) {
    try { $null = & $Action; return '' }
    catch { if ($_.FullyQualifiedErrorId -like 'W32T.*') { return $_.FullyQualifiedErrorId } return $_.Exception.GetType().Name }
}

$canonical = [ordered]@{
    'Session'        = @('loader')
    'Pre-Install'    = @('org-ui', 'hook')
    'Install'        = @('msp', 'install', 'install-done')
    'Post-Install'   = @('hook', 'tattoo', 'org-ui')
    'Pre-Uninstall'  = @('org-ui', 'hook')
    'Uninstall'      = @('uninstall')
    'Post-Uninstall' = @('hook', 'tattoo')
    'Pre-Repair'     = @('org-ui', 'hook')
    'Post-Repair'    = @('hook', 'org-ui')
}
$goldens = [ordered]@{ 'psadt-4.1.8' = (Get-Fixture 'psadt-4.1.8'); 'psadt-4.2.0' = (Get-Fixture 'psadt-4.2.0'); 'psadt-4.2.0-zeroconfig' = (Get-Fixture 'psadt-4.2.0-zeroconfig') }

# -- [1] shuffled inserts -> canonical order; idempotent; replace in place -------------------------
Write-Host '[1] every slot, inserted in a shuffled order, ends in canonical order' -ForegroundColor Cyan
foreach ($g in $goldens.Keys) {
    $t = $goldens[$g]
    $pairs = foreach ($p in $canonical.Keys) { foreach ($s in $canonical[$p]) { [pscustomobject]@{ P = $p; S = $s } } }
    $shuffled = $pairs | Get-Random -Count $pairs.Count -SetSeed 4242
    foreach ($x in $shuffled) { $t = Set-Win32ToolkitPhaseBlock -Content $t -Phase $x.P -Slot $x.S -Code "# block $($x.P)/$($x.S)`nWrite-Verbose '$($x.S)'" }
    $wrong = @(foreach ($p in $canonical.Keys) { if (((Get-SlotOrder $t $p) -join ',') -ne ($canonical[$p] -join ',')) { "$p=[$((Get-SlotOrder $t $p) -join ',')]" } })
    if ($wrong.Count -eq 0) { Ok "$g : canonical slot order in all phases" } else { Bad "$g : $($wrong -join '; ')" }
    $err = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$err)
    if (@($err).Count -eq 0) { Ok "$g : result parses" } else { Bad "$g : parse error $(@($err)[0].Message)" }
    $sh = Get-Win32ToolkitDeployScriptShape -Content $t
    if ($sh.Shape -eq (Get-Win32ToolkitDeployScriptShape -Content $goldens[$g]).Shape) { Ok "$g : shape unchanged ($($sh.Shape))" } else { Bad "$g : shape became $($sh.Shape)" }

    # idempotent: a second pass with the same code is byte-identical
    $t2 = $t
    foreach ($x in $pairs) { $t2 = Set-Win32ToolkitPhaseBlock -Content $t2 -Phase $x.P -Slot $x.S -Code "# block $($x.P)/$($x.S)`nWrite-Verbose '$($x.S)'" }
    if ($t2 -ceq $t) { Ok "$g : re-render with the same code is byte-identical" } else { Bad "$g : re-render changed the text" }

    # replace in place: new code, same position, no duplicate
    $before = $t.IndexOf('## win32-toolkit:Install:install (begin)')
    $t3 = Set-Win32ToolkitPhaseBlock -Content $t -Phase 'Install' -Slot 'install' -Code "# replaced`nWrite-Verbose 'new'"
    if ($t3.IndexOf('## win32-toolkit:Install:install (begin)') -eq $before -and $t3.Contains("    # replaced") -and -not $t3.Contains("# block Install/install`n") -and
        ([regex]::Matches($t3, 'win32-toolkit:Install:install \(begin\)')).Count -eq 1) { Ok "$g : changed code is replaced in place" }
    else { Bad "$g : replace in place failed" }

    # operator text between blocks survives a re-render
    $op = "    Write-Host 'operator code'`n"
    $at = $t.IndexOf('    ## win32-toolkit:Install:install-done (begin)')
    $t4 = $t.Substring(0, $at) + $op + $t.Substring($at)
    foreach ($x in $pairs) { $t4 = Set-Win32ToolkitPhaseBlock -Content $t4 -Phase $x.P -Slot $x.S -Code "# v2 $($x.P)/$($x.S)" }
    $iEnd = $t4.IndexOf('## win32-toolkit:Install:install (end)'); $iOp = $t4.IndexOf("Write-Host 'operator code'"); $iDone = $t4.IndexOf('## win32-toolkit:Install:install-done (begin)')
    if ($iOp -gt $iEnd -and $iOp -lt $iDone -and ([regex]::Matches($t4, 'operator code')).Count -eq 1) { Ok "$g : operator text between blocks survives a re-render" }
    else { Bad "$g : operator text lost or moved" }
}

# -- [2] insertion points --------------------------------------------------------------------------
Write-Host '[2] insertion points per layout' -ForegroundColor Cyan
$g418 = $goldens['psadt-4.1.8']; $g42z = $goldens['psadt-4.2.0-zeroconfig']
$t = Set-Win32ToolkitPhaseBlock -Content $g418 -Phase 'Pre-Install' -Slot 'hook' -Code '# h'
if ($t.Contains("    ## <Perform Pre-Installation tasks here>`n    ## win32-toolkit:Pre-Install:hook (begin)")) { Ok '4.1: block lands on the line right after the phase marker (marker kept)' } else { Bad '4.1 insertion not after the marker' }
$t = Set-Win32ToolkitPhaseBlock -Content $g418 -Phase 'Post-Uninstall' -Slot 'tattoo' -Code '# t'
if ($t.Contains("    ## <Perform Post-Uninstallation tasks here>`n    ## win32-toolkit:Post-Uninstall:tattoo (begin)")) { Ok '4.1: Post-* block right after its marker' } else { Bad '4.1 Post-* insertion wrong' }
$t = Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Post-Install' -Slot 'org-ui' -Code '# c'
if ($t.Contains("New-Variable -Name Post-Install -Force -Value {`n    ## win32-toolkit:Post-Install:org-ui (begin)")) { Ok '4.2: Post-* block is FIRST (line after the opening brace)' } else { Bad '4.2 Post-* not first' }
$t = Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Pre-Install' -Slot 'hook' -Code '# h'
if ($t.Contains("    Show-ADTInstallationProgress`n    ## win32-toolkit:Pre-Install:hook (begin)") -and $t.Contains("## win32-toolkit:Pre-Install:hook (end)`n}")) { Ok '4.2: Pre-* block is LAST (before the closing brace)' } else { Bad '4.2 Pre-* not last' }
$t = Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Install' -Slot 'install' -Code '# i'
if ($t.Contains("        Start-ADTMsiProcess @ExecuteDefaultMSISplat`n    }`n    ## win32-toolkit:Install:install (begin)")) { Ok '4.2: main-phase block after the Zero-Config block' } else { Bad '4.2 main insertion wrong' }

# -- [3] Session loader ----------------------------------------------------------------------------
Write-Host '[3] Session:loader stays top level, directly above $adtSession = @{' -ForegroundColor Cyan
foreach ($g in 'psadt-4.1.8', 'psadt-4.2.0-zeroconfig') {
    $t = Set-Win32ToolkitPhaseBlock -Content $goldens[$g] -Phase 'Session' -Slot 'loader' -Code "`$x = 1`n`n`$y = 2"
    if ($t -match "(?m)^## win32-toolkit:Session:loader \(begin\)[^\n]*\n\`$x = 1\n\n\`$y = 2\n## win32-toolkit:Session:loader \(end\)\n\`$adtSession = @\{") { Ok "$g : loader at column 0, blank line kept empty, directly above `$adtSession" }
    else { Bad "$g : loader not directly above `$adtSession" }
    $same = Set-Win32ToolkitPhaseBlock -Content $t -Phase 'Session' -Slot 'loader' -Code "`$x = 1`n`n`$y = 2"
    if ($same -ceq $t) { Ok "$g : unchanged loader text -> byte-identical" } else { Bad "$g : unchanged loader re-render changed the text" }
    $chg = Set-Win32ToolkitPhaseBlock -Content $t -Phase 'Session' -Slot 'loader' -Code '$x = 2'
    if ($chg.Contains("Session:loader (begin) - managed by win32-toolkit; regenerated, do not edit inside`n`$x = 2`n## win32-toolkit:Session:loader (end)`n`$adtSession = @{") -and ([regex]::Matches($chg, 'Session:loader \(begin\)')).Count -eq 1) {
        Ok "$g : changed loader text replaced in place"
    } else { Bad "$g : changed loader not replaced in place" }
    # move the loader into a phase -> anchor error
    $block = ([regex]::Match($t, '(?s)## win32-toolkit:Session:loader \(begin\).*?## win32-toolkit:Session:loader \(end\)\n')).Value
    $moved = $t.Replace($block, '')
    $moved = if ($g -eq 'psadt-4.1.8') { $moved.Replace("    ## <Perform Repair tasks here>`n", "    ## <Perform Repair tasks here>`n" + $block) } else { $moved.Replace("New-Variable -Name Repair -Force -Value {`n", "New-Variable -Name Repair -Force -Value {`n" + $block) }
    $r = Get-Thrown { Set-Win32ToolkitPhaseBlock -Content $moved -Phase 'Session' -Slot 'loader' -Code '$x = 1' }
    if ($r -eq 'W32T.PhaseAnchorMissing') { Ok "$g : a loader block moved inside a phase -> W32T.PhaseAnchorMissing" } else { Bad "$g : moved loader -> '$r'" }
}

# -- [4] corrupt blocks / missing anchors ----------------------------------------------------------
Write-Host '[4] corrupt blocks and missing anchors are fatal (W32T.PhaseAnchorMissing)' -ForegroundColor Cyan
$t = Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Install' -Slot 'install' -Code '# i'
$noEnd = $t.Replace("    ## win32-toolkit:Install:install (end)`n", '')
foreach ($c in @(
        @{ N = 'missing (end) line';           A = { Set-Win32ToolkitPhaseBlock -Content $noEnd -Phase 'Install' -Slot 'install-done' -Code '$d = 1' } }
        @{ N = 'missing (end) line (remove)';  A = { Remove-Win32ToolkitPhaseBlock -Content $noEnd -Phase 'Install' -Slot 'install' } }
        @{ N = 'duplicate block';              A = { $dup = $t.Replace('    ## win32-toolkit:Install:install (end)', "    ## win32-toolkit:Install:install (end)`n    ## win32-toolkit:Install:install (begin) - x`n    ## win32-toolkit:Install:install (end)"); Set-Win32ToolkitPhaseBlock -Content $dup -Phase 'Install' -Slot 'install' -Code '# i' } }
        @{ N = 'block outside its 4.2 phase';  A = { $out = $t.Replace("## MARK: Post-Install", "## win32-toolkit:Install:msp (begin) - x`n## win32-toolkit:Install:msp (end)`n## MARK: Post-Install"); Set-Win32ToolkitPhaseBlock -Content $out -Phase 'Install' -Slot 'msp' -Code '# m' } }
        @{ N = 'unknown slot in the content';  A = { $unk = $t.Replace('## win32-toolkit:Install:install (', '## win32-toolkit:Install:bogus ('); Set-Win32ToolkitPhaseBlock -Content $unk -Phase 'Install' -Slot 'install-done' -Code '# d' } }
        @{ N = '4.1 phase with its marker missing';    A = { Set-Win32ToolkitPhaseBlock -Content ($g418.Replace("    ## <Perform Pre-Repair tasks here>`n", '')) -Phase 'Pre-Repair' -Slot 'hook' -Code '# h' } }
        @{ N = '4.1 phase with its marker duplicated'; A = { Set-Win32ToolkitPhaseBlock -Content ($g418.Replace("    ## <Perform Post-Repair tasks here>`n", "    ## <Perform Post-Repair tasks here>`n    ## <Perform Post-Repair tasks here>`n")) -Phase 'Post-Repair' -Slot 'hook' -Code '# h' } }
        @{ N = "4.2 phase '{' and '}' on one line";   A = { Set-Win32ToolkitPhaseBlock -Content ($g42z.Replace("New-Variable -Name Post-Uninstall -Force -Value {`n}", 'New-Variable -Name Post-Uninstall -Force -Value { }')) -Phase 'Post-Uninstall' -Slot 'tattoo' -Code '# t' } })) {
    $r = Get-Thrown $c.A
    if ($r -eq 'W32T.PhaseAnchorMissing') { Ok "$($c.N) -> W32T.PhaseAnchorMissing" } else { Bad "$($c.N) -> '$r'" }
}
$r = Get-Thrown { Set-Win32ToolkitPhaseBlock -Content ($g42z + "`nif (`n") -Phase 'Install' -Slot 'install' -Code '# i' }
if ($r -eq 'W32T.UnsupportedTemplateShape') { Ok 'Unknown shape -> W32T.UnsupportedTemplateShape' } else { Bad "Unknown shape -> '$r'" }
try { $null = Set-Win32ToolkitPhaseBlock -Content ($g42z + "`nif (`n") -Phase 'Install' -Slot 'install' -Code '# i' }
catch { if ($_.Exception.Message.StartsWith('Unsupported PSADT template shape: ') -and $_.Exception.Message.EndsWith('Nothing was changed.')) { Ok 'its message uses the stable C-1 wording' } else { Bad "message: $($_.Exception.Message)" } }

# -- [5] programming errors ------------------------------------------------------------------------
Write-Host '[5] programming errors are ArgumentExceptions' -ForegroundColor Cyan
foreach ($c in @(
        @{ N = 'unknown slot';            A = { Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Install' -Slot 'tattoo' -Code '#' } }
        @{ N = 'Repair has no slots';     A = { Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Repair' -Slot 'install' -Code '#' } }
        @{ N = 'unknown phase';           A = { Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Deploy' -Slot 'hook' -Code '#' } }
        @{ N = 'code with a sentinel';    A = { Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Install' -Slot 'install' -Code "x`n## win32-toolkit:Install:msp (begin)" } }
        @{ N = 'remove: invalid phase';   A = { Remove-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Deploy' -Slot 'hook' } })) {
    $r = Get-Thrown $c.A
    if ($r -eq 'ArgumentException') { Ok "$($c.N) -> ArgumentException" } else { Bad "$($c.N) -> '$r'" }
}
$manual = Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Install' -Slot 'manual-install' -Code "## Never edit inside a '## win32-toolkit:' block"
if ($manual.Contains("    ## Never edit inside a '## win32-toolkit:' block")) { Ok "a sentinel quoted inside a comment line is allowed (manual-install text)" } else { Bad 'manual-install text rejected' }

# -- [6] line endings ------------------------------------------------------------------------------
Write-Host '[6] line endings follow the content' -ForegroundColor Cyan
$crlf = $g42z -replace "`n", "`r`n"
$t = Set-Win32ToolkitPhaseBlock -Content $crlf -Phase 'Post-Install' -Slot 'hook' -Code "# a`n`n# b"
$t = Set-Win32ToolkitPhaseBlock -Content $t -Phase 'Session' -Slot 'loader' -Code "`$l = 1"
if (($t -replace "`r`n", '') -notmatch "`n" -and $t.Contains("    # a`r`n`r`n    # b`r`n")) { Ok 'CRLF input: every inserted line ends in CRLF' } else { Bad 'CRLF input produced a bare LF' }
$t = Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Post-Install' -Slot 'hook' -Code "# a`r`n# b"
if (-not $t.Contains("`r")) { Ok 'LF input: no CR introduced (even from CRLF code)' } else { Bad 'LF input got a CR' }

# -- [7] Remove-Win32ToolkitPhaseBlock -------------------------------------------------------------
Write-Host '[7] Remove-Win32ToolkitPhaseBlock' -ForegroundColor Cyan
$t = Set-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Post-Install' -Slot 'hook' -Code '# h'
$r = Remove-Win32ToolkitPhaseBlock -Content $t -Phase 'Post-Install' -Slot 'hook'
if ($r -ceq $g42z) { Ok 'removing the only block restores the original text exactly' } else { Bad 'remove left residue' }
if ((Remove-Win32ToolkitPhaseBlock -Content $g42z -Phase 'Post-Install' -Slot 'hook') -ceq $g42z) { Ok 'absent block -> no-op' } else { Bad 'no-op changed text' }

# -- [8] Remove-Win32ToolkitPhaseDefaultUi ---------------------------------------------------------
Write-Host '[8] Remove-Win32ToolkitPhaseDefaultUi removes PSADT dialogs outside toolkit blocks only' -ForegroundColor Cyan
$uiPhases = 'Pre-Install', 'Pre-Uninstall', 'Pre-Repair', 'Post-Install', 'Post-Repair'
foreach ($g in 'psadt-4.1.8', 'psadt-4.2.0-zeroconfig') {
    # A toolkit block that calls the dialogs must survive.
    $t = Set-Win32ToolkitPhaseBlock -Content $goldens[$g] -Phase 'Post-Install' -Slot 'org-ui' -Code "if (`$x) { Show-ADTInstallationPrompt -Message 'kept' }"
    foreach ($p in $uiPhases) { $t = Remove-Win32ToolkitPhaseDefaultUi -Content $t -Phase $p }
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$null)
    $spans = @([regex]::Matches($t, '(?ms)^[ \t]*## win32-toolkit:(?<p>[\w-]+):(?<s>[\w-]+) \(begin\).*?## win32-toolkit:\k<p>:\k<s> \(end\)'))
    $outside = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -like 'Show-ADTInstallation*' }, $true) |
            Where-Object { $o = $_.Extent.StartOffset; -not ($spans | Where-Object { $o -ge $_.Index -and $o -lt $_.Index + $_.Length }) })
    $saiw = ([regex]::Matches($t, '\$saiwParams')).Count
    if ($outside.Count -eq 0 -and $saiw -eq 0) { Ok "$g : no Show-ADT* / `$saiwParams left outside toolkit blocks" } else { Bad "$g : $($outside.Count) dialog call(s), $saiw `$saiwParams left: $(($outside | ForEach-Object { $_.Extent.Text }) -join ' | ')" }
    if ($t.Contains("Show-ADTInstallationPrompt -Message 'kept'")) { Ok "$g : the dialog inside a toolkit block survives" } else { Bad "$g : toolkit block dialog removed" }
    $again = $t; foreach ($p in $uiPhases) { $again = Remove-Win32ToolkitPhaseDefaultUi -Content $again -Phase $p }
    if ($again -ceq $t) { Ok "$g : idempotent" } else { Bad "$g : second removal changed the text" }
    $sh = Get-Win32ToolkitDeployScriptShape -Content $t
    if ($sh.Shape -eq (Get-Win32ToolkitDeployScriptShape -Content $goldens[$g]).Shape -and @($sh.MarkerIssues).Count -eq 0) { Ok "$g : shape, InstallPhase assignments and all markers intact" } else { Bad "$g : shape $($sh.Shape) markers [$($sh.MarkerIssues -join ';')]" }
    if ($t -notmatch '(?m)^[ \t]*## (Show Welcome Message|Show Progress Message|If there are processes to close|Display a message at the end)') { Ok "$g : the PSADT dialog comments went with their statements" } else { Bad "$g : a dialog comment was left behind" }
    $bannerOk = ($g -ne 'psadt-4.1.8') -or ([regex]::Matches($t, '##================================================')).Count -eq ([regex]::Matches($goldens[$g], '##================================================')).Count
    if ($bannerOk -and ([regex]::Matches($t, '## Handle Zero-Config MSI')).Count -eq 3) { Ok "$g : banners and the Zero-Config blocks untouched" } else { Bad "$g : banners/Zero-Config touched" }
}
$t = $goldens['psadt-4.1.8']; foreach ($p in $uiPhases) { $t = Remove-Win32ToolkitPhaseDefaultUi -Content $t -Phase $p }
if ($t.Contains("    `$adtSession.InstallPhase = `"Pre-`$(`$adtSession.DeploymentType)`"`n`n    ## <Perform Pre-Installation tasks here>")) { Ok '4.1: no doubled blank lines left in Pre-Install' } else { Bad '4.1 Pre-Install layout after removal unexpected' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'PhaseBlock unit test PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
