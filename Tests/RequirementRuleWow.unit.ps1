<#
    Update requirement rule - the 32-bit (WOW6432Node) tattoo view (D5 transition, PKG-02).

    THE BUG: win32-toolkit 1.1.6 and older published 'powershell.exe -File ...'. The Intune Management
    Extension is 32-bit, so that ran the 32-bit Windows PowerShell and the install tattoo landed under
    HKLM\SOFTWARE\WOW6432Node\<Author>\<Vendor>\<App>. The update requirement only checked the native
    64-bit view, so a device installed by such a package did not count as "already installed" and the
    update app never applied to it. The rule now accepts the WOW6432Node copy of the tattoo too, with the
    same single-quote escaping as the native line (hostile names stay data). That escaping doubles every
    PowerShell single-quote character, including the typographic U+2018/U+2019/U+201A/U+201B that also
    end a '...' literal under 5.1 and 7 ([2b]).

    No requirement script is ever executed: assertions are on the AST of the generated text, plus a
    parse-only check under the real Windows PowerShell 5.1 (skipped when powershell.exe is absent).

    Run:  pwsh -File Tests\RequirementRuleWow.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\ConvertTo-PSSingleQuoted.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitProductCode.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitRequirementRule.ps1')
# No MSI in these projects; never touch the WindowsInstaller COM object from a unit test.
function Get-Win32ToolkitMsiProperty { param([string]$Path, [string]$Property) $null = $Path, $Property; '' }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32rw_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Build-ReqProject {
    param([string]$Name, [hashtable]$App)
    $p = Join-Path $root $Name
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = $App; Installer = [ordered]@{ Type = 'exe'; FileName = 'setup.exe' } }
    [System.IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $p
}

function Get-ReqScript {
    param($Rule)
    $bytes = [System.Convert]::FromBase64String($Rule['scriptContent'])
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text.TrimStart([char]0xFEFF)
}

# Every 'Test-Path -LiteralPath <single-quoted constant>' in the script, in source order.
function Get-LiteralProbe {
    param([string]$Text)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-Path' }, $true)
    foreach ($c in $cmds) {
        $els = $c.CommandElements
        for ($i = 1; $i -lt $els.Count - 1; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'LiteralPath' -and
                $els[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                [pscustomobject]@{ Value = $els[$i + 1].Value; Kind = [string]$els[$i + 1].StringConstantType; Offset = $c.Extent.StartOffset }
            }
        }
    }
}

try {
    # == [1] plain names: both views, native first ===================================================
    Write-Host '[1] the tattoo is checked in the native view AND the WOW6432Node view' -ForegroundColor Cyan
    $p1 = Build-ReqProject -Name 'Plain' -App ([ordered]@{ Vendor = 'Vendorly'; Name = 'WidgetPro'; DisplayName = 'Widget Pro'; Version = '3.2.1'; ScriptAuthor = 'Contoso IT' })
    $r1 = Get-Win32ToolkitRequirementRule -ProjectPath $p1 3>$null
    $s1 = Get-ReqScript $r1
    $probes = @(Get-LiteralProbe $s1)
    $native = @($probes | Where-Object { $_.Value -ceq 'HKLM:\SOFTWARE\Contoso IT\Vendorly\Widget Pro' })
    $wow    = @($probes | Where-Object { $_.Value -ceq 'HKLM:\SOFTWARE\WOW6432Node\Contoso IT\Vendorly\Widget Pro' })
    if ($native.Count -eq 1) { Ok 'native 64-bit tattoo probe present (exact literal path)' } else { Bad "native probes: $($native.Count)" }
    if ($wow.Count -eq 1) { Ok 'WOW6432Node tattoo probe present (exact literal path)' } else { Bad "WOW6432Node probes: $($wow.Count)`n$s1" }
    if ($native.Count -eq 1 -and $wow.Count -eq 1 -and $native[0].Offset -lt $wow[0].Offset) { Ok 'native view first, legacy 32-bit view second' } else { Bad 'probe order wrong' }
    $wowLine = @($s1 -split "`r?`n" | Where-Object { $_ -match 'WOW6432Node\\Contoso IT' })
    if ($wowLine.Count -eq 1 -and $wowLine[0] -match '^if \(-not \$found -and \(Test-Path -LiteralPath ''[^\r\n]+''\)\) \{ \$found = \$true \}$') {
        Ok 'same guarded one-line shape as the native probe'
    } else { Bad "WOW line shape: $($wowLine -join ' | ')" }

    # == [2] hostile names stay data =================================================================
    Write-Host '[2] hostile author / vendor / name are escaped as data in BOTH probes' -ForegroundColor Cyan
    $author = "O'Brien IT"
    $vendor = "Evil'); Start-Process calc.exe; ('"
    $name   = 'App [x64] $(Invoke-Expression ''calc'') `whoami` '';exit 0;'''
    $p2 = Build-ReqProject -Name 'Hostile' -App ([ordered]@{ Vendor = $vendor; Name = 'App'; DisplayName = $name; Version = '1.0'; ScriptAuthor = $author })
    $r2 = Get-Win32ToolkitRequirementRule -ProjectPath $p2 3>$null
    $s2 = Get-ReqScript $r2
    $tk = $null; $pe = $null
    $ast2 = [System.Management.Automation.Language.Parser]::ParseInput($s2, [ref]$tk, [ref]$pe)
    if (@($pe).Count -eq 0) { Ok 'the generated script parses (host parser) with hostile values' } else { Bad "parse errors: $($pe[0].Message)" }
    $probes2 = @(Get-LiteralProbe $s2)
    $want64  = "HKLM:\SOFTWARE\$author\$vendor\$name"
    $want32  = "HKLM:\SOFTWARE\WOW6432Node\$author\$vendor\$name"
    $h64 = @($probes2 | Where-Object { $_.Value -ceq $want64 })
    $h32 = @($probes2 | Where-Object { $_.Value -ceq $want32 })
    if ($h64.Count -eq 1 -and $h64[0].Kind -eq 'SingleQuoted') { Ok 'native probe round-trips the hostile path verbatim inside ONE single-quoted literal' } else { Bad 'native hostile path did not round-trip' }
    if ($h32.Count -eq 1 -and $h32[0].Kind -eq 'SingleQuoted') { Ok 'WOW6432Node probe round-trips the hostile path verbatim inside ONE single-quoted literal' } else { Bad "WOW6432Node hostile path did not round-trip`n$s2" }
    $allowed = @('Test-Path', 'New-Object', 'Get-ItemProperty', 'Where-Object', 'Write-Output')
    $cmdNames = @($ast2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Select-Object -Unique)
    $unexpected = @($cmdNames | Where-Object { $_ -notin $allowed })
    if ($unexpected.Count -eq 0) { Ok "only the expected commands exist ($($cmdNames -join ', ')) - no injected Start-Process / Invoke-Expression / calc" } else { Bad "unexpected commands: $($unexpected -join ', ')" }
    $exits = @($ast2.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
    if ($exits.Count -eq 2) { Ok 'no injected exit statement (only the final exit 0 / exit 1)' } else { Bad "exit statements: $($exits.Count)" }

    # == [2b] typographic single quotes (U+2018/U+2019/U+201A/U+201B) stay data too ==================
    # PowerShell 5.1 and 7 also END a single-quoted literal at these four characters, so escaping only
    # the ASCII apostrophe let a winget PackageName/Publisher break out of the tattoo literal (security-01).
    # Source stays ASCII: every typographic quote is built with [char].
    Write-Host '[2b] typographic single quotes in author / vendor / name stay data in BOTH probes (host + 5.1)' -ForegroundColor Cyan
    $q2018 = [string][char]0x2018; $q2019 = [string][char]0x2019; $q201A = [string][char]0x201A; $q201B = [string][char]0x201B
    foreach ($q in @([string][char]0x27, $q2018, $q2019, $q201A, $q201B)) {
        $in = 'a' + $q + 'b'
        $lit = "'" + (ConvertTo-PSSingleQuoted $in) + "'"
        $qpe = $null
        $qast = [System.Management.Automation.Language.Parser]::ParseInput($lit, [ref]$null, [ref]$qpe)
        $qexpr = $qast.EndBlock.Statements[0].PipelineElements[0].Expression
        if (@($qpe).Count -eq 0 -and $qexpr -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $qexpr.Value -ceq $in) {
            Ok ("ConvertTo-PSSingleQuoted: U+{0:X4} is doubled and parses back to the input" -f [int][char]$q)
        } else { Bad ("ConvertTo-PSSingleQuoted: U+{0:X4} did not round-trip: {1}" -f [int][char]$q, $lit) }
    }

    # 5.1 parse of a written UpdateRequirement.ps1: error count + every Test-Path -LiteralPath constant as
    # UTF-8 base64 (ASCII-safe across the console), so the device parser's view is compared exactly.
    $ps51q = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function Get-PS51Probe {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $ps51q)) { return $null }
        $prevQ = $env:W32T_REQCHECK
        try {
            $env:W32T_REQCHECK = $Path
            $cmd = '$e = $null; $a = [System.Management.Automation.Language.Parser]::ParseFile($env:W32T_REQCHECK, [ref]$null, [ref]$e); ' +
                '(''ERR '' + @($e).Count); ' +
                'foreach ($c in $a.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq ''Test-Path'' }, $true)) { ' +
                '$els = $c.CommandElements; for ($i = 1; $i -lt $els.Count - 1; $i++) { ' +
                'if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq ''LiteralPath'' -and $els[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { ' +
                '(''LIT '' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($els[$i + 1].Value))) } } }'
            $out = @(& $ps51q -NoProfile -NonInteractive -Command $cmd)
        }
        finally { $env:W32T_REQCHECK = $prevQ }
        [pscustomobject]@{
            Errors = [int](@($out | Where-Object { $_ -like 'ERR *' } | ForEach-Object { $_.Substring(4) }) + @('-1'))[0]
            Values = @($out | Where-Object { $_ -like 'LIT *' } | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(4))) })
        }
    }

    $typoCases = @(
        @{ Label = 'benign U+2019 name';  Author = 'Contoso IT'; Vendor = 'Larian'; Name = 'Baldur' + $q2019 + 's Gate' }
        @{ Label = 'all five quote kinds'; Author = 'O' + $q2018 + 'Brien' + $q201B + ' IT'; Vendor = 'V' + "'" + $q201A + 'x'; Name = 'Mix ' + "'" + $q2018 + $q2019 + $q201A + $q201B + ' End' }
    )
    $i2b = 0
    foreach ($tc in $typoCases) {
        $i2b++
        $pq = Build-ReqProject -Name "Typo$i2b" -App ([ordered]@{ Vendor = $tc.Vendor; Name = 'App'; DisplayName = $tc.Name; Version = '1.0'; ScriptAuthor = $tc.Author })
        $sq = Get-ReqScript (Get-Win32ToolkitRequirementRule -ProjectPath $pq 3>$null)
        $qpe = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($sq, [ref]$null, [ref]$qpe)
        if (@($qpe).Count -eq 0) { Ok "$($tc.Label): host parse - 0 errors" } else { Bad "$($tc.Label): host parse errors: $($qpe[0].Message)" }
        $want64q = "HKLM:\SOFTWARE\$($tc.Author)\$($tc.Vendor)\$($tc.Name)"
        $want32q = "HKLM:\SOFTWARE\WOW6432Node\$($tc.Author)\$($tc.Vendor)\$($tc.Name)"
        $pr = @(Get-LiteralProbe $sq)
        $n64 = @($pr | Where-Object { $_.Value -ceq $want64q -and $_.Kind -eq 'SingleQuoted' })
        $n32 = @($pr | Where-Object { $_.Value -ceq $want32q -and $_.Kind -eq 'SingleQuoted' })
        if ($n64.Count -eq 1 -and $n32.Count -eq 1) { Ok "$($tc.Label): native and WOW6432Node probes each ONE single-quoted literal equal to the path" } else { Bad "$($tc.Label): native=$($n64.Count) wow=$($n32.Count)`n$sq" }
        $r51 = Get-PS51Probe (Join-Path $pq 'SupportFiles\UpdateRequirement.ps1')
        if ($null -eq $r51) { Write-Host '  SKIP: Windows PowerShell 5.1 not found (parse-only check not possible here)' -ForegroundColor DarkGray }
        elseif ($r51.Errors -eq 0 -and @($r51.Values | Where-Object { $_ -ceq $want64q }).Count -eq 1 -and @($r51.Values | Where-Object { $_ -ceq $want32q }).Count -eq 1) {
            Ok "$($tc.Label): Windows PowerShell 5.1 parse - 0 errors, both tattoo literals read back verbatim"
        } else { Bad "$($tc.Label): 5.1 errors=$($r51.Errors) values=[$($r51.Values -join ' | ')]" }
    }

    $payload = 'Foo' + $q2019 + ' + (Write-Output INJECTED) + ' + $q2019 + 'x'
    $pj = Build-ReqProject -Name 'TypoInject' -App ([ordered]@{ Vendor = 'Vendorly'; Name = 'App'; DisplayName = $payload; Version = '1.0'; ScriptAuthor = 'Contoso IT' })
    $sj = Get-ReqScript (Get-Win32ToolkitRequirementRule -ProjectPath $pj 3>$null)
    $jpe = $null
    $astj = [System.Management.Automation.Language.Parser]::ParseInput($sj, [ref]$null, [ref]$jpe)
    $injected = @($astj.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Output' -and $n.Extent.Text -match 'INJECTED' }, $true))
    if (@($jpe).Count -eq 0 -and $injected.Count -eq 0) { Ok 'U+2019 break-out payload: no Write-Output INJECTED command in the script' } else { Bad "injected Write-Output: $(@($injected | ForEach-Object { $_.Extent.Text }) -join ' | ')`n$sj" }
    $cmdNamesJ = @($astj.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Select-Object -Unique)
    $unexpectedJ = @($cmdNamesJ | Where-Object { $_ -notin $allowed })
    if ($unexpectedJ.Count -eq 0) { Ok "U+2019 break-out payload: only the expected commands exist ($($cmdNamesJ -join ', '))" } else { Bad "unexpected commands: $($unexpectedJ -join ', ')" }
    $exitsJ = @($astj.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
    if ($exitsJ.Count -eq 2) { Ok 'U+2019 break-out payload: exactly 2 exit statements' } else { Bad "exit statements: $($exitsJ.Count)" }
    $pj64 = @(Get-LiteralProbe $sj | Where-Object { $_.Value -ceq "HKLM:\SOFTWARE\Contoso IT\Vendorly\$payload" -and $_.Kind -eq 'SingleQuoted' })
    if ($pj64.Count -eq 1) { Ok 'U+2019 break-out payload: the whole name is ONE literal (data)' } else { Bad "payload literal count: $($pj64.Count)" }

    # == [3] Windows PowerShell 5.1 parse of the written plaintext copy ==============================
    Write-Host '[3] SupportFiles\UpdateRequirement.ps1 parses under Windows PowerShell 5.1' -ForegroundColor Cyan
    $reqFile = Join-Path $p2 'SupportFiles\UpdateRequirement.ps1'
    $raw = [System.IO.File]::ReadAllBytes($reqFile)
    if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { Ok 'written with a UTF-8 BOM' } else { Bad 'no UTF-8 BOM' }
    if ([System.IO.File]::ReadAllText($reqFile) -ceq $s2) { Ok 'the plaintext copy equals the base64 payload' } else { Bad 'plaintext copy differs from the payload' }
    $ps51 = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps51) {
        $prev = $env:W32T_REQCHECK
        try {
            $env:W32T_REQCHECK = $reqFile
            $count = & $ps51 -NoProfile -NonInteractive -Command '$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:W32T_REQCHECK, [ref]$null, [ref]$e); @($e).Count'
        }
        finally { $env:W32T_REQCHECK = $prev }
        if ("$count".Trim() -eq '0') { Ok '0 parse errors under Windows PowerShell 5.1' } else { Bad "5.1 parse errors: $count" }
    }
    else { Write-Host '  SKIP: Windows PowerShell 5.1 not found (parse-only check not possible here)' -ForegroundColor DarkGray }

    # == [4] no tattoo signal -> no tattoo probe in either view ======================================
    Write-Host '[4] without a tattoo key there is no tattoo probe in either view' -ForegroundColor Cyan
    $p4 = Build-ReqProject -Name 'NoAuthor' -App ([ordered]@{ Vendor = 'Vendorly'; Name = 'WidgetPro'; DisplayName = 'Widget Pro'; Version = '3.2.1' })
    $r4 = Get-Win32ToolkitRequirementRule -ProjectPath $p4 3>$null
    $s4 = Get-ReqScript $r4
    $tattooProbes = @(Get-LiteralProbe $s4 | Where-Object { $_.Value -match 'Vendorly' })
    if ($r4 -and $tattooProbes.Count -eq 0) { Ok 'name-only rule: no tattoo probe (native or WOW6432Node)' } else { Bad "unexpected tattoo probes: $($tattooProbes.Value -join ', ')" }
    if ($s4 -match [regex]::Escape("'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'")) { Ok 'the existing 32-bit ARP name check is unchanged' } else { Bad 'ARP WOW6432Node check missing' }

    # == [5] the rule object keeps its shape (DataDriven [8]) ========================================
    Write-Host '[5] the requirement rule keeps its Graph shape and presence semantics' -ForegroundColor Cyan
    if ($r1['@odata.type'] -eq '#microsoft.graph.win32LobAppPowerShellScriptRequirement' -and $r1['detectionType'] -eq 'integer' -and
        $r1['operator'] -eq 'equal' -and $r1['detectionValue'] -eq '1' -and $r1['runAsAccount'] -eq 'system' -and $r1['runAs32Bit'] -eq $false) {
        Ok 'script requirement, integer/equal/1, system, 64-bit'
    } else { Bad "rule: $($r1 | ConvertTo-Json -Compress)" }
    if ($s1 -match [regex]::Escape('Write-Output 1; exit 0') -and $s1 -match 'ErrorActionPreference' -and $s1 -notmatch '-like') {
        Ok 'presence logic, STDERR suppression, no substring -like'
    } else { Bad 'presence logic changed' }

    # == [6] source: both probes use the shared escaper ===============================================
    Write-Host '[6] source: the WOW6432Node probe uses the same ConvertTo-PSSingleQuoted escaping' -ForegroundColor Cyan
    $src = Get-Content -LiteralPath (Join-Path $repo 'Private\Get-Win32ToolkitRequirementRule.ps1') -Raw
    $escaped = [regex]::Matches($src, "Test-Path -LiteralPath '\`$\(ConvertTo-PSSingleQuoted \`$\w+\)'")
    if ($escaped.Count -ge 2) { Ok "$($escaped.Count) tattoo probes, each built with ConvertTo-PSSingleQuoted" } else { Bad "escaped tattoo probes in source: $($escaped.Count)" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All RequirementRuleWow tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail RequirementRuleWow test(s) FAILED." -ForegroundColor Red; exit 1 }
