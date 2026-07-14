function Invoke-Win32ToolkitHyperVRun {
    <#
    .SYNOPSIS
        Runs a test/capture against the Hyper-V backend: reset -> copy in -> run phases -> copy out.
    .DESCRIPTION
        The Hyper-V counterpart of launching a .wsb. It reverts the VM to its warm checkpoint, opens a
        PowerShell Direct session, copies the project to C:\PSADT (and an optional baseline to
        C:\PSADTOld), runs each phase synchronously with the guest's Windows PowerShell 5.1, copies the
        requested outputs back UNDER the host project (so the existing host-side waiters/consumers work
        unchanged), and always closes the session + reverts the VM. Returns $true on completion.

        This is the 'HyperV' branch of the test-backend seam; the flows call it instead of building a
        .wsb. See knowledge-base/designs/hyperv-backend-plan.md.
    .PARAMETER ProjectPath
        The PSADT project under test (host path). Copied to C:\PSADT in the guest.
    .PARAMETER Phase
        Ordered phases to run, each an object with: Label, Command (a 5.1-safe guest command string),
        and optional IgnoreExit ([bool], default $false).
    .PARAMETER Output
        Project-relative globs to copy back from the guest after the phases (default the capture JSON +
        Sandbox\Logs).
    .PARAMETER BaselineProjectPath
        Update baseline-project mode: a second project copied read-only-in-effect to C:\PSADTOld.
    .PARAMETER VMName / Credential / CheckpointName
        Resolved from config / the stored guest credential when omitted.
    .OUTPUTS
        [bool] — $true if the run completed (individual phase failures are warned, not fatal, matching
        the Sandbox fire-and-forget semantics; callers judge results from the copied-back outputs).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$ProjectPath,
        [Parameter(Mandatory)] [object[]]$Phase,
        [string[]]$Output = @('Documentation\InstallationChanges_*.json', 'Documentation\Targeted_Documentation_Log_*.txt', 'Sandbox\Logs\*'),
        [string]$BaselineProjectPath,
        [string]$VMName,
        [pscredential]$Credential,
        [string]$CheckpointName = 'clean-base'
    )

    if (-not $VMName)     { $VMName = Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden' }
    if (-not $CheckpointName) { $CheckpointName = Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base' }
    if (-not $Credential) { $Credential = Get-Win32ToolkitGuestCredential }
    if (-not $Credential) {
        throw "No Hyper-V guest credential is configured. Run New-Win32ToolkitTestVM first (it stores the credential), or pass -Credential."
    }

    $session = $null
    try {
        # Interactive phases need a logged-in desktop, so ask the session to ensure/recover one.
        $needsDesktop = @($Phase | Where-Object { $_.Interactive }).Count -gt 0

        Write-Host "Reverting '$VMName' to '$CheckpointName' and connecting over PowerShell Direct..." -ForegroundColor Cyan
        $session = New-Win32ToolkitHyperVSession -VMName $VMName -Credential $Credential -CheckpointName $CheckpointName -EnsureDesktop:$needsDesktop

        Write-Host "Copying project into the guest (C:\PSADT)..." -ForegroundColor Cyan
        Copy-Win32ToolkitProjectToGuest -Session $session -ProjectPath $ProjectPath -GuestPath 'C:\PSADT'
        if ($BaselineProjectPath) {
            # -ReadOnly reproduces the Sandbox <ReadOnly>true</ReadOnly> mount, so the baseline's own PSADT
            # run can't write into C:\PSADTOld on Hyper-V while the same run fails under Sandbox.
            Write-Host 'Copying the update baseline into the guest (C:\PSADTOld, read-only)...' -ForegroundColor Cyan
            Copy-Win32ToolkitProjectToGuest -Session $session -ProjectPath $BaselineProjectPath -GuestPath 'C:\PSADTOld' -ReadOnly
        }

        # If any phase is interactive, open the VM console so the operator can watch the PSADT GUI.
        if ($needsDesktop) {
            Write-Host 'Opening the VM console (vmconnect) for interactive GUI testing...' -ForegroundColor Cyan
            Start-Process -FilePath 'vmconnect.exe' -ArgumentList 'localhost', $VMName -ErrorAction SilentlyContinue
        }

        foreach ($ph in $Phase) {
            if ($ph.Pause) {
                Read-Host "  $($ph.Label) — press Enter to continue"
                continue
            }
            # Every phase runs as SYSTEM (the Intune context). For an interactive phase PSADT's own deploy
            # mode renders its GUI in the logged-on user's session (a real desktop is ensured above).
            $exit = Invoke-Win32ToolkitGuestPhase -Session $session -Command $ph.Command -Label $ph.Label
            if (-not $ph.IgnoreExit -and $exit -ne 0) {
                Write-Warning "Guest phase '$($ph.Label)' exited with code $exit."
            }
        }

        Write-Host "Copying results back to the project..." -ForegroundColor Cyan
        $guestGlobs = $Output | ForEach-Object { Join-Path 'C:\PSADT' $_ }
        Copy-Win32ToolkitResultsFromGuest -Session $session -GuestPath $guestGlobs -Destination $ProjectPath -GuestRoot 'C:\PSADT'

        return $true
    }
    catch {
        Write-Warning "Hyper-V run failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        Remove-Win32ToolkitHyperVSession -Session $session -VMName $VMName -CheckpointName $CheckpointName -Revert
    }
}
