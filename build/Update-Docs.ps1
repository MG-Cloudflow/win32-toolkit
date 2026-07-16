<#
    Regenerates docs/reference/ (one markdown page per exported command) from the module's
    comment-based help via platyPS.

    SINGLE SOURCE OF TRUTH: command facts live in the comment-based help only — this script projects
    them into docs/reference/, and CI fails a PR whose regenerated reference differs from the committed
    one (see .github/workflows/docs.yml). Never hand-edit docs/reference/*.md.

    Pinned to classic platyPS 0.14.x — verified against this module. (The newer
    Microsoft.PowerShell.PlatyPS 1.x generator uses a different schema; upgrade deliberately, not by
    accident.)

    NOTE: importing the module must stay PROMPT-FREE (BasePath prompting happens at command run time,
    not import) — if an import-time prompt ever appears, this script and the CI job will hang.

    Run:  pwsh -File build\Update-Docs.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent $PSScriptRoot
$outDir  = Join-Path $repo 'docs\reference'

# platyPS classic, pinned major.minor.
$platy = Get-Module -ListAvailable -Name platyPS | Where-Object { $_.Version -lt [version]'1.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $platy) {
    Write-Host 'Installing platyPS 0.14.2 (CurrentUser)...' -ForegroundColor Yellow
    Install-Module platyPS -RequiredVersion 0.14.2 -Scope CurrentUser -Force
    $platy = Get-Module -ListAvailable -Name platyPS | Where-Object { $_.Version -lt [version]'1.0' } | Sort-Object Version -Descending | Select-Object -First 1
}
Import-Module $platy -Force

Import-Module (Join-Path $repo 'win32-toolkit.psd1') -Force

if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# -NoMetadata: no YAML front matter — the pages must render cleanly on plain GitHub AND in MkDocs.
$null = New-MarkdownHelp -Module 'win32-toolkit' -OutputFolder $outDir -NoMetadata -Force

# Index page linking every command, grouped the way the README's command table groups them.
$groups = [ordered]@{
    'Start here'         = @('Show-Win32Toolkit', 'Invoke-Win32Toolkit', 'New-Win32ToolkitManualApp', 'Complete-Win32ToolkitManualApp', 'Test-Win32ToolkitProject')
    'Pipeline steps'     = @('Export-Win32ToolkitIntuneWin', 'Publish-Win32ToolkitIntuneApp', 'Export-Win32ToolkitDocumentation', 'Set-Win32ToolkitAppDependency', 'Sync-Win32ToolkitAppDependency')
    'Test-VM management' = @('New-Win32ToolkitTestVM', 'Set-Win32ToolkitTestVMResource', 'Reset-Win32ToolkitTestVM', 'Remove-Win32ToolkitTestVM')
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Command reference')
[void]$sb.AppendLine()
[void]$sb.AppendLine('> Generated from the module''s built-in help by [`build/Update-Docs.ps1`](../../build/Update-Docs.ps1) — do not edit these pages by hand. The same content is available offline via `Get-Help <command> -Full`.')
[void]$sb.AppendLine()
foreach ($g in $groups.Keys) {
    [void]$sb.AppendLine("## $g")
    [void]$sb.AppendLine()
    foreach ($cmd in $groups[$g]) {
        $syn = (Get-Help $cmd).Synopsis.Trim()
        [void]$sb.AppendLine("- [$cmd]($cmd.md) — $syn")
    }
    [void]$sb.AppendLine()
}
[System.IO.File]::WriteAllText((Join-Path $outDir 'README.md'), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

$count = @(Get-ChildItem -LiteralPath $outDir -Filter '*.md').Count
Write-Host "✓ docs/reference regenerated: $count page(s)." -ForegroundColor Green
