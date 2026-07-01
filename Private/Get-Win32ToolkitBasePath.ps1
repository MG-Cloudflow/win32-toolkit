function Get-Win32ToolkitBasePath {
    <#
    .SYNOPSIS
        Resolves the win32-toolkit base folder, persisting a first-run choice to the registry.
    .DESCRIPTION
        Resolution order:
          1. An explicit -BasePath (used as-is, NOT persisted).
          2. The value stored at HKCU:\Software\CloudFlow\win32-toolkit\BasePath.
          3. First run (or -Reconfigure): prompt for a folder (default C:\Win32Apps) and save it.

        The base folder holds all output tiers: Templates\, Projects\, Staging\, IntuneWin\.
        See knowledge-base/01-architecture.md.
    .PARAMETER BasePath
        Explicit override. When supplied, it wins and is not written to the registry.
    .PARAMETER Reconfigure
        Ignore any stored value and re-prompt, saving the new choice.
    .EXAMPLE
        $base = Get-Win32ToolkitBasePath
    .EXAMPLE
        $base = Get-Win32ToolkitBasePath -BasePath 'D:\Packaging'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$BasePath,
        [switch]$Reconfigure,
        [switch]$NonInteractive,
        [string]$Set
    )

    $regKey = 'HKCU:\Software\CloudFlow\win32-toolkit'

    # 0. Persist an explicit value (used by the TUI settings screen) — no prompt.
    if (-not [string]::IsNullOrWhiteSpace($Set)) {
        $val = $Set.Trim().TrimEnd('\')
        try {
            if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
            Set-ItemProperty -Path $regKey -Name 'BasePath' -Value $val
        }
        catch { Write-Warning "Could not save BasePath to the registry: $($_.Exception.Message)" }
        return $val
    }

    # 1. Explicit override always wins (not persisted).
    if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
        return $BasePath.Trim().TrimEnd('\')
    }

    # 2. Stored value.
    if (-not $Reconfigure) {
        try {
            $stored = (Get-ItemProperty -Path $regKey -Name 'BasePath' -ErrorAction Stop).BasePath
            if (-not [string]::IsNullOrWhiteSpace($stored)) { return $stored }
        }
        catch { }
    }

    # 3. Not configured. Non-interactive callers (e.g. the TUI health check) get $null.
    if ($NonInteractive) { return $null }

    # 4. First run / -Reconfigure: prompt and persist.
    $default = 'C:\Win32Apps'
    Write-Host ''
    Write-Host '=== win32-toolkit setup ===' -ForegroundColor Cyan
    Write-Host 'Choose the base folder for all output (Templates, Projects, Staging, IntuneWin).' -ForegroundColor Gray
    $entered = Read-Host "Base folder [$default]"
    if ([string]::IsNullOrWhiteSpace($entered)) { $entered = $default }
    $entered = $entered.Trim().TrimEnd('\')

    try {
        if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
        Set-ItemProperty -Path $regKey -Name 'BasePath' -Value $entered
        Write-Host "✓ Saved base folder to $regKey" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not save BasePath to the registry: $($_.Exception.Message)"
    }

    return $entered
}
