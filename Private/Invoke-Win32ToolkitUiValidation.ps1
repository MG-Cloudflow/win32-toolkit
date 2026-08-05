function Invoke-Win32ToolkitUiValidation {
    <#
    .SYNOPSIS
        Drives and validates a project's PSADT dialogs in a Hyper-V VM, unattended. HOST-ONLY, elevated.
    .DESCRIPTION
        The Hyper-V counterpart of a hands-on "watch the PSADT GUI" run, made standalone. It reverts the
        VM to its warm checkpoint, copies the project in, then runs a generated UI driver
        (see New-Win32ToolkitUiDriverScript) IN THE INTERACTIVE USER SESSION (via the scheduled-task-as-
        user primitive — SYSTEM/session-0 cannot show a GUI). The driver launches the deploy, clicks
        through each dialog with UI Automation, screenshots every dialog, and writes a structured
        state-log. The results are copied back and validated against the org template with
        Compare-Win32ToolkitUiToTemplate. The VM is always reverted afterwards.

        Nothing here requires an operator: no vmconnect window is opened and no phase pauses. The captured
        PNGs are the eyes — a human, or Claude reading them, judges the GAP (visual) checks; the
        structural/content checks are decided from the state-log automatically.

        Host tooling, so PowerShell 7 syntax is fine here. The GENERATED driver is 5.1-safe (it runs on
        the device under Windows PowerShell 5.1).
    .PARAMETER ProjectPath
        The PSADT project to validate (host path). Copied to C:\PSADT in the guest.
    .PARAMETER Template
        The org template object the project was branded from (Get-OrgTemplate output), used for the
        expectation checks.
    .PARAMETER DeploymentType
        'Install' (default) or 'Uninstall'.
    .PARAMETER Actions
        Intended click per Welcome dialog: 'Install' (default) or 'Defer'. A 'Defer' ends the deploy.
    .PARAMETER CaptureHostConsole
        Also capture the VM console framebuffer from the host on a cadence (best-effort fallback view;
        requires elevation and Hyper-V WMI access). Off by default — the guest screenshots are primary.
    .PARAMETER VMName / Credential / CheckpointName
        Resolved from config / the stored guest credential when omitted.
    .PARAMETER PerDialogTimeoutSec / OverallTimeoutSec
        Guest driver waits: per-dialog advance timeout (default 180) and overall run cap (default 900).
    .PARAMETER TimeoutMinutes
        Host wait for the whole driver task (default 20).
    .OUTPUTS
        [PSCustomObject] with .Completed, .DriverExit, .Report (Compare output), .ShotDir, .StateLogPath.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$ProjectPath,
        [Parameter(Mandatory)] $Template,
        [ValidateSet('Install', 'Uninstall')] [string]$DeploymentType = 'Install',
        [ValidateSet('Install', 'Defer')] [string[]]$Actions = @('Install'),
        [switch]$CaptureHostConsole,
        [string]$VMName,
        [pscredential]$Credential,
        [string]$CheckpointName = 'clean-base',
        [ValidateRange(30, 3600)] [int]$PerDialogTimeoutSec = 180,
        [ValidateRange(60, 7200)] [int]$OverallTimeoutSec = 900,
        [ValidateRange(1, 240)] [int]$TimeoutMinutes = 20
    )

    if (-not $VMName) { $VMName = Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden' }
    if (-not $CheckpointName) { $CheckpointName = Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base' }
    if (-not $Credential) { $Credential = Get-Win32ToolkitGuestCredential }
    if (-not $Credential) {
        throw "No Hyper-V guest credential is configured. Run New-Win32ToolkitTestVM first (it stores the credential), or pass -Credential."
    }

    # Emit the 5.1-safe guest driver into the project's Sandbox\ scratch folder so the project copy-in
    # carries it to C:\PSADT\Sandbox\DrivePsadtUi.ps1. Gate its 5.1-safety before it ever reaches a device.
    $driverPath = New-Win32ToolkitUiDriverScript -ProjectPath $ProjectPath
    if (Get-Command Test-Win32ToolkitPS51Syntax -ErrorAction SilentlyContinue) {
        $syntaxErrors = @(Test-Win32ToolkitPS51Syntax -Path $driverPath)
        if ($syntaxErrors.Count) {
            throw "Generated UI driver failed the Windows PowerShell 5.1 syntax gate: $($syntaxErrors -join ' | ')"
        }
    }

    $guestShotDir = 'C:\PSADT\Sandbox\Shots'
    $guestStateLog = 'C:\PSADT\Sandbox\Logs\uidriver-state.log'
    $runAsUser = ($Credential.UserName -split '\\')[-1]

    $session = $null
    $shotJob = $null
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $canThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)

    # Host-side console PNGs into the project's Sandbox\HostShots (best-effort, only when asked).
    $hostShotDir = Join-Path $ProjectPath 'Sandbox\HostShots'

    try {
        Write-Verbose "Reverting '$VMName' to '$CheckpointName' and connecting over PowerShell Direct (ensuring a desktop)..."
        $session = New-Win32ToolkitHyperVSession -VMName $VMName -Credential $Credential -CheckpointName $CheckpointName -EnsureDesktop

        Write-Verbose "Copying project into the guest (C:\PSADT)..."
        Copy-Win32ToolkitProjectToGuest -Session $session -ProjectPath $ProjectPath -GuestPath 'C:\PSADT'

        # Build the driver invocation. Trusted literals only — single-quoted paths, no untrusted splicing.
        $actionArg = ($Actions -join ',')
        $cmd = "& '$driverPath'".Replace($ProjectPath, 'C:\PSADT') +
        " -DeploymentType $DeploymentType -Actions $actionArg -DeployRoot 'C:\PSADT'" +
        " -ShotDir '$guestShotDir' -StateLog '$guestStateLog'" +
        " -PerDialogTimeoutSec $PerDialogTimeoutSec -OverallTimeoutSec $OverallTimeoutSec"

        # Optional host cadence: capture the VM console framebuffer every few seconds while the driver runs.
        # A ThreadJob runs in a bare runspace with the module NOT loaded, so ship BOTH function bodies (the
        # capture function AND the RGB565 converter it now delegates to) and rebuild them inside the job.
        if ($CaptureHostConsole -and $canThreadJob) {
            if (-not (Test-Path $hostShotDir)) { New-Item -ItemType Directory -Path $hostShotDir -Force | Out-Null }
            $capSrc = (Get-Command Get-Win32ToolkitVMScreenshot).ScriptBlock.ToString()
            $convSrc = (Get-Command ConvertFrom-Win32ToolkitRgb565Image).ScriptBlock.ToString()
            $shotJob = Start-ThreadJob -ScriptBlock {
                param($fnSrc, $convFnSrc, $vm, $dir, $overallSec)
                . ([scriptblock]::Create("function ConvertFrom-Win32ToolkitRgb565Image { $convFnSrc }"))
                . ([scriptblock]::Create("function Get-Win32ToolkitVMScreenshot { $fnSrc }"))
                $stop = (Get-Date).AddSeconds($overallSec + 60)
                $i = 0
                while ((Get-Date) -lt $stop) {
                    $i++
                    $p = Join-Path $dir ('host_{0:000}.png' -f $i)
                    try { Get-Win32ToolkitVMScreenshot -VMName $vm -Path $p -ErrorAction Stop | Out-Null } catch { }
                    Start-Sleep -Seconds 3
                }
            } -ArgumentList $capSrc, $convSrc, $VMName, $hostShotDir, $OverallTimeoutSec
        }
        elseif ($CaptureHostConsole) {
            Write-Warning 'CaptureHostConsole requested but Start-ThreadJob is unavailable; skipping the host cadence.'
        }

        Write-Verbose "Running the UI driver in the interactive session as '$runAsUser'..."
        $driverExit = Invoke-Win32ToolkitGuestScheduledTask -Session $session -Command $cmd -RunAs $runAsUser -Label 'psadt-ui-driver' -TimeoutMinutes $TimeoutMinutes

        # Stop the host cadence before copy-out.
        if ($shotJob) {
            Stop-Job -Job $shotJob -ErrorAction SilentlyContinue
            Remove-Job -Job $shotJob -Force -ErrorAction SilentlyContinue
            $shotJob = $null
        }

        Write-Verbose 'Copying screenshots and the state-log back to the project...'
        Copy-Win32ToolkitResultsFromGuest -Session $session `
            -GuestPath @('C:\PSADT\Sandbox\Shots\*', 'C:\PSADT\Sandbox\Logs\*') `
            -Destination $ProjectPath -GuestRoot 'C:\PSADT'

        $localStateLog = Join-Path $ProjectPath 'Sandbox\Logs\uidriver-state.log'
        $localShotDir = Join-Path $ProjectPath 'Sandbox\Shots'

        $report = $null
        if (Test-Path -LiteralPath $localStateLog) {
            $report = Compare-Win32ToolkitUiToTemplate -StateLogPath $localStateLog -Template $Template -DeploymentType $DeploymentType
        }
        else {
            Write-Warning "No state-log was copied back from the guest ($localStateLog missing) — the driver may not have run. Check the VM's interactive logon / auto-logon."
        }

        return [PSCustomObject]@{
            Completed     = ($driverExit -eq 0)
            DriverExit    = $driverExit
            Report        = $report
            ShotDir       = $localShotDir
            HostShotDir   = ($(if ($CaptureHostConsole) { $hostShotDir } else { $null }))
            StateLogPath  = $localStateLog
            DeployType    = $DeploymentType
        }
    }
    catch {
        Write-Warning "UI validation run failed: $($_.Exception.Message)"
        return [PSCustomObject]@{ Completed = $false; DriverExit = $null; Report = $null; ShotDir = $null; HostShotDir = $null; StateLogPath = $null; DeployType = $DeploymentType }
    }
    finally {
        if ($shotJob) {
            Stop-Job -Job $shotJob -ErrorAction SilentlyContinue
            Remove-Job -Job $shotJob -Force -ErrorAction SilentlyContinue
        }
        Remove-Win32ToolkitHyperVSession -Session $session -VMName $VMName -CheckpointName $CheckpointName -Revert
        # Interactive run: never presume the VM stayed clean.
        $script:HyperVCleanMarker = $null
        $ProgressPreference = $prevProgress
    }
}
