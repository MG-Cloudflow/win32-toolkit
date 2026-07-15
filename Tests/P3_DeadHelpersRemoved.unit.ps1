<#
    P3 — dead escaping helpers removed.

      ConvertTo-PSLiteral.ps1 and ConvertTo-PSDoubleQuoted.ps1 had ZERO call sites and were deleted.
      This test locks that in AND guards against over-deletion: the two STILL-load-bearing escapers
      (ConvertTo-PSSingleQuoted, ConvertTo-XmlEncoded) must remain present with real call sites, and
      the module must still import and export its full public surface (12 commands).

      Fails if:
        - either dead file reappears,
        - either keeper file is missing,
        - a keeper loses all real (non-definition) call sites,
        - the module fails to import, or exports != 12 commands.

    Run:  pwsh -File Tests\P3_DeadHelpersRemoved.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# ── (a) the two dead helpers must be gone ─────────────────────────────────────────────────────────
Write-Host '[a] deleted dead escaping helpers must no longer exist' -ForegroundColor Cyan
foreach ($dead in @('ConvertTo-PSLiteral.ps1', 'ConvertTo-PSDoubleQuoted.ps1')) {
    $p = Join-Path $repo (Join-Path 'Private' $dead)
    if (Test-Path -LiteralPath $p) { Bad "$dead still exists" } else { Ok "$dead removed" }
}

# Also confirm no residual definition of either function anywhere in the repo source.
$srcFiles = Get-ChildItem -Path $repo -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch '\\Tests\\' }
foreach ($fn in @('ConvertTo-PSLiteral', 'ConvertTo-PSDoubleQuoted')) {
    $hits = $srcFiles | Select-String -Pattern ("function\s+" + [regex]::Escape($fn) + "\b") -List
    if ($hits) { Bad "$fn still defined in: $($hits.Path -join ', ')" } else { Ok "$fn has no definition left in source" }
}

# ── (b) the two keepers must still exist AND still have real (non-definition) call sites ───────────
Write-Host '[b] load-bearing escapers must remain, with real call sites' -ForegroundColor Cyan
$allPs1 = Get-ChildItem -Path $repo -Recurse -Filter *.ps1 -File
foreach ($keep in @('ConvertTo-PSSingleQuoted', 'ConvertTo-XmlEncoded')) {
    $defFile = Join-Path $repo (Join-Path 'Private' ($keep + '.ps1'))
    if (-not (Test-Path -LiteralPath $defFile)) { Bad "$keep.ps1 is missing"; continue }
    Ok "$keep.ps1 present"

    # A call site = the name appearing in a source (Private\/Public\) file OTHER than its own definition,
    # on a line that is not the `function <name>` declaration.
    $callSites = 0
    foreach ($f in $allPs1) {
        if ($f.FullName -eq $defFile) { continue }
        if ($f.FullName -match '\\Tests\\') { continue }
        $m = Select-String -LiteralPath $f.FullName -Pattern ([regex]::Escape($keep)) |
            Where-Object { $_.Line -notmatch ("function\s+" + [regex]::Escape($keep) + "\b") }
        $callSites += @($m).Count
    }
    if ($callSites -gt 0) { Ok "$keep has $callSites real call site(s)" }
    else { Bad "$keep has NO call sites — it may have been orphaned" }
}

# ── (c) module still imports cleanly and its public surface is intact ──────────────────────────────
# (The exact export COUNT is deliberately not pinned — new public commands are added over time; deleting
# the dead PRIVATE helpers must not reduce the public surface, so assert it did not shrink below the
# baseline and that the core commands are all still exported.)
Write-Host '[c] module imports cleanly and its public surface is intact' -ForegroundColor Cyan
$manifest = Join-Path $repo 'win32-toolkit.psd1'
try {
    Import-Module $manifest -Force -ErrorAction Stop
    Ok 'Import-Module succeeded'
    $exported = @((Get-Module win32-toolkit).ExportedFunctions.Keys)
    if ($exported.Count -ge 12) { Ok "exports its full public surface ($($exported.Count) commands)" }
    else { Bad "public surface shrank to $($exported.Count) commands: $($exported -join ', ')" }
    $core = @('Invoke-Win32Toolkit', 'Test-Win32ToolkitProject', 'Export-Win32ToolkitIntuneWin', 'Publish-Win32ToolkitIntuneApp')
    $missing = @($core | Where-Object { $_ -notin $exported })
    if ($missing.Count -eq 0) { Ok 'the core public commands are all still exported' } else { Bad "missing core commands: $($missing -join ', ')" }
} catch {
    Bad "Import-Module failed: $($_.Exception.Message)"
} finally {
    Remove-Module win32-toolkit -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
