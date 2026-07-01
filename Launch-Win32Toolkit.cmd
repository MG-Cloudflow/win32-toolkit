@echo off
REM ============================================================================
REM  win32-toolkit — double-click launcher for the interactive text UI.
REM  Opens PowerShell 7, imports the module next to this file, and starts the
REM  menu (Show-Win32Toolkit). No PowerShell knowledge required.
REM ============================================================================

where pwsh >nul 2>nul
if errorlevel 1 (
    echo.
    echo   PowerShell 7 ^(pwsh^) is required but was not found.
    echo   Install it from https://aka.ms/powershell and run this again.
    echo.
    pause
    exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Import-Module '%~dp0win32-toolkit.psd1' -Force; Show-Win32Toolkit } catch { Write-Host $_.Exception.Message -ForegroundColor Red; Read-Host 'Press Enter to close' }"
