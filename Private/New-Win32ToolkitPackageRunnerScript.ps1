function New-Win32ToolkitPackageRunnerScript {
    <#
    .SYNOPSIS
        Writes the guest package runner (Sandbox\Invoke-PsadtPackage.ps1) and its Intune command-line data
        file (Sandbox\IntuneCommandLine.json) into a project.
    .DESCRIPTION
        Every test flow (Windows Sandbox and the Hyper-V VM) runs a PSADT package through this runner instead
        of dot-calling Invoke-AppDeployToolkit.ps1 inside its own PowerShell process:

          - ONE PACKAGE = ONE PROCESS. PSADT 4.2 refuses a second copy of its module in a process (even at the
            same version, from another folder), and 4.1 and 4.2 cannot share one. Chaining a baseline, a
            dependency and the app in one LogonCommand therefore produced false FAILs (60008).
          - Direct mode (default) starts a 64-bit Windows PowerShell child with -File (Sysnative from a 32-bit
            parent), so watched runs still show PSADT's UI.
          - -IntuneParity runs EXACTLY the published Intune command line (read from IntuneCommandLine.json,
            written here from Get-Win32ToolkitIntuneCommandLine) through SysWOW64\cmd.exe - a 32-bit parent,
            like the Intune Management Extension - from the package folder ('parent=x86-cmd'; 'parent=native-cmd'
            when the guest has no SysWOW64\cmd.exe: then no 32-bit parent ran and the run is not IME parity).
          - The exact PSADT exit code becomes the runner's exit code and is appended to
            Sandbox\Logs\PsadtExitCodes.log ('[<UTC time>Z] <label> <type> parent=<p> exit=<n> result=<r>',
            e.g. '[2026-10-21 02:06:04Z] app Install parent=x86-cmd exit=0 result=Success'), which the host
            prints after each run and the watched countdown reads for its verdict. Times are UTC with a 'Z'
            (invariant culture) so guest lines and the host's run marker read in order whatever the guest's
            time zone.

        The runner is VALUE-FREE (no project, app or template value is in it), Windows PowerShell 5.1-safe
        and written UTF-8 with BOM; the data file is BOM-less UTF-8. Both live under Sandbox\, which never
        ships in the .intunewin.
    .PARAMETER ProjectPath
        The PSADT project folder (the guest sees it as C:\PSADT).
    .OUTPUTS
        [string] the runner path (also under -WhatIf).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $sandboxPath = Join-Path $ProjectPath 'Sandbox'
    $runnerPath  = Join-Path $sandboxPath 'Invoke-PsadtPackage.ps1'
    $dataPath    = Join-Path $sandboxPath 'IntuneCommandLine.json'

    # The guest runner (spec section 5.6). Single-quoted here-string: every $ is the guest's own.
    $runner = @'
# win32-toolkit guest package runner - generated, do not edit (regenerated before every test run).
# Value-free and Windows PowerShell 5.1-safe. The Intune command line is DATA (IntuneCommandLine.json).
param(
    [string]$Path = 'C:\PSADT\Invoke-AppDeployToolkit.ps1',
    [ValidateSet('Install', 'Uninstall', 'Repair')][string]$DeploymentType = 'Install',
    [ValidateSet('', 'Auto', 'Interactive', 'NonInteractive', 'Silent')][string]$DeployMode = '',
    [switch]$IntuneParity,
    [string]$Label = 'app',
    [ValidateRange(1, 240)][int]$TimeoutMinutes = 25
)
# One PSADT package = one process (PSADT 4.2 refuses a 2nd module copy per process; 4.1/4.2 cannot mix).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $Path
$logDir = Join-Path $PSScriptRoot 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'PsadtExitCodes.log'
if ($IntuneParity) {
    # Exactly the published command line (data, written by the host), from a 32-bit parent like the IME.
    # The contract (Get-Win32ToolkitIntuneCommandLine) has Install and Uninstall only: Repair, a missing file or a
    # missing key must FAIL, never run an empty 'cmd /c' that exits 0 and is logged as Success.
    $cmdLine = ''
    try {
        $cl = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'IntuneCommandLine.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($DeploymentType -ne 'Repair' -and $cl.PSObject.Properties[$DeploymentType]) { $cmdLine = [string]$cl.$DeploymentType }
    } catch { $cmdLine = '' }
    if ([string]::IsNullOrWhiteSpace($cmdLine)) {
        ('[{0}] {1} {2} parent=none exit=87 result=Failed (no Intune command line for {2})' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'), $Label, $DeploymentType) |
            Add-Content -LiteralPath $logFile -Encoding UTF8
        exit 87
    }
    $exe = Join-Path $env:WinDir 'SysWOW64\cmd.exe'
    $parent = 'x86-cmd'
    if (-not (Test-Path -LiteralPath $exe)) {
        # No 32-bit cmd.exe (no SysWOW64): the OS's own cmd.exe is the parent, so this run is NOT IME parity.
        # 'native-cmd', not 'x64-cmd': on a 32-bit OS System32\cmd.exe is itself 32-bit.
        $exe = Join-Path $env:WinDir 'System32\cmd.exe'
        $parent = 'native-cmd'
    }
    $argList = @('/d', '/c', $cmdLine)
    # The IME resolves the bare 'Invoke-AppDeployToolkit.exe' in the content folder (CreateProcess searches the
    # current directory). Make sure an inherited NoDefaultCurrentDirectoryInExePath cannot change that.
    $env:NoDefaultCurrentDirectoryInExePath = $null
} else {
    $sys = 'System32'
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { $sys = 'Sysnative' }
    $exe = Join-Path $env:WinDir ($sys + '\WindowsPowerShell\v1.0\powershell.exe')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Path + '"'), '-DeploymentType', $DeploymentType)
    if ($DeployMode) { $argList += @('-DeployMode', $DeployMode) }
    $parent = 'x64-direct'
}
$p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $root -PassThru
$null = $p.Handle   # 5.1: cache the handle so ExitCode is available after WaitForExit
if ($p.WaitForExit($TimeoutMinutes * 60000)) { $rc = $p.ExitCode }
else { & (Join-Path $env:WinDir 'System32\taskkill.exe') /PID $p.Id /T /F | Out-Null; $rc = 1460 }
$class = 'Failed'
if ($rc -eq 0 -or $rc -eq 1707) { $class = 'Success' } elseif ($rc -eq 3010) { $class = 'SoftReboot' }
elseif ($rc -eq 1641) { $class = 'HardReboot' } elseif ($rc -eq 1618) { $class = 'Retry' } elseif ($rc -eq 1460) { $class = 'Timeout' }
('[{0}] {1} {2} parent={3} exit={4} result={5}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'), $Label, $DeploymentType, $parent, $rc, $class) |
    Add-Content -LiteralPath $logFile -Encoding UTF8
exit $rc
'@

    # The command lines Publish sends to Intune (single source: Get-Win32ToolkitIntuneCommandLine), as DATA.
    $json = ConvertTo-Json -InputObject (Get-Win32ToolkitIntuneCommandLine)

    if ($PSCmdlet.ShouldProcess($runnerPath, 'Write guest runner file')) {
        if (-not (Test-Path -LiteralPath $sandboxPath)) { New-Item -ItemType Directory -Path $sandboxPath -Force | Out-Null }
        # UTF-8 WITH BOM: the guest runs it under Windows PowerShell 5.1, which reads a BOM-less file as ANSI.
        [System.IO.File]::WriteAllText($runnerPath, $runner, (New-Object System.Text.UTF8Encoding($true)))
    }
    if ($PSCmdlet.ShouldProcess($dataPath, 'Write guest runner file')) {
        if (-not (Test-Path -LiteralPath $sandboxPath)) { New-Item -ItemType Directory -Path $sandboxPath -Force | Out-Null }
        # Guest data JSON is BOM-less UTF-8 (spec C-3); the runner reads it with -Encoding UTF8.
        [System.IO.File]::WriteAllText($dataPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    return $runnerPath
}
