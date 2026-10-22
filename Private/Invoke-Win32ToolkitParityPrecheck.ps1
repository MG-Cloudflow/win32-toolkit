function Invoke-Win32ToolkitParityPrecheck {
    <#
    .SYNOPSIS
        Decides, before an unattended Hyper-V Intune-parity test starts, whether it would only wait on a PSADT 4.1 dialog.
    .DESCRIPTION
        Installer-identity PR 2, spec 2.5(c) (A1 hv r1.2, L10-L12, L18, L19). Called by Test-Win32ToolkitProject
        for HyperV-unattended runs only (watched runs and Sandbox never call it). Never blocks on its own failure.

        1. Get-Win32ToolkitParityDialogRisk: not at risk -> Blocked $false; the VM is not touched.
        2. At risk: the VM, the guest credential and the run's base checkpoint come from the same settings
           the run uses (HyperVVMName, the stored guest credential, HyperVCheckpoint, default 'clean-base').
           No credential -> Blocked $false (the run then reports its usual error).
        3. One host line says the check runs (it takes minutes), then its own short PowerShell Direct session on
           that checkpoint (revert, query, revert):
           Get-Win32ToolkitGuestSignedInUser. The teardown revert runs only once the VM was found; it stamps
           the clean marker, so the run that follows skips its own open-revert. A VM, session or query
           problem prints one warning and the run starts as usual (fail-open).
        4. Blocked = the guest was checked and a user is signed in (the toolkit's VM always restores to a
           signed-in desktop). Then Message (one warning for the caller to print up front), Notes (the
           test record's Notes) and NotRun (the record's NotRun facts: Code PARITY-DIALOG-WAIT, Shape,
           ProcessesToClose, Welcome, SignedInSessions) are set.

        Risk is returned on every path: the caller derives the exit-code-1460 hint of the parity phases from
        Risk.AtRisk (L16): the PSADT 4.1 welcome text only for an at-risk project the check did not block.
    .PARAMETER ProjectPath
        The PSADT project under test.
    .PARAMETER Scenario
        InstallUninstall or Update (names the test in the message).
    .OUTPUTS
        [pscustomobject] Blocked [bool], Risk, Guest, Message [string], Notes [string], NotRun [hashtable or $null].
    .EXAMPLE
        $pre = Invoke-Win32ToolkitParityPrecheck -ProjectPath $proj -Scenario InstallUninstall
        if ($pre.Blocked) { Write-Warning $pre.Message }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string]$Scenario
    )

    $blocked = $false; $guest = $null; $message = ''; $notes = ''; $notRun = $null
    $risk = Get-Win32ToolkitParityDialogRisk -ProjectPath $ProjectPath
    if ($risk -and $risk.AtRisk) {
        # The run's effective base checkpoint (L18): the same expressions as Invoke-Win32ToolkitHyperVRun, so
        # both revert and query the same checkpoint and the clean marker stamped below matches the run.
        $vm   = Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden'
        $cp   = Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base'
        $cred = Get-Win32ToolkitGuestCredential
        if (-not $cred) {
            Write-Verbose 'Intune-parity pre-check skipped: no Hyper-V guest credential is configured.'
        }
        else {
            # One host line first: the two checkpoint restores and the PowerShell Direct wait take minutes with no other
            # output (live P5: 3 minutes of silence before the warning).
            Write-Host "Intune-parity pre-check: checking whether a user is signed in to the test VM '$vm' (restores checkpoint '$cp' before and after; this can take a few minutes)..." -ForegroundColor Cyan
            # No host progress bars from the checkpoint cmdlets (they tear the TUI, as in Invoke-Win32ToolkitHyperVRun);
            # a local variable: it ends with this function.
            $ProgressPreference = 'SilentlyContinue'
            $vmFound = $false; $session = $null
            try {
                $null = Get-VM -Name $vm -ErrorAction Stop
                $vmFound = $true
                $session = New-Win32ToolkitHyperVSession -VMName $vm -Credential $cred -CheckpointName $cp
                $guest = Get-Win32ToolkitGuestSignedInUser -Session $session
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $why = ConvertTo-Win32ToolkitSafeText -Text ([string]$_.Exception.Message) -MaxLength 256
                Write-Warning "Intune-parity pre-check could not reach the VM ($why); the run starts as usual."
                $guest = $null
            }
            finally {
                if ($vmFound) { Remove-Win32ToolkitHyperVSession -Session $session -VMName $vm -CheckpointName $cp -Revert }
            }

            if ($guest -and -not $guest.Checked) {
                Write-Warning "Intune-parity pre-check could not tell whether a user is signed in to the test VM '$vm' ($($guest.Reason)); the run starts as usual."
            }
            elseif ($guest -and $guest.SignedIn) {
                $blocked = $true
                $what = if ($Scenario -eq 'Update') { 'Update' } else { 'Install -> Uninstall' }
                $welcomeText = if ([string]$risk.Welcome -eq 'OrgUi') { "the org template's welcome dialog (OrgUi.Welcome: AllowDefer)" } else { 'a welcome dialog in the deploy script' }
                $project = Split-Path -Leaf $ProjectPath
                $message = ("Intune-parity pre-check: the unattended Hyper-V {0} test of '{1}' was NOT started. It is a PSADT 4.1 package with no processes to close, and {2} lets the user defer. " +
                    "PSADT 4.1 shows that dialog in Auto mode (the Intune command line has no deploy mode) whenever a user is signed in, and a user is signed in to the test VM '{3}' " +
                    "(the toolkit's VM always restores to a signed-in desktop): nobody would answer it, so the run would wait 25 minutes and then fail with exit code 1460. " +
                    'The result is recorded as Inconclusive (not run). To test this package: run the test watched and answer the dialog in the VM window ' +
                    '(a watched run needs all three: no -Unattended switch, the HyperVTestMode value under HKCU:\Software\CloudFlow\win32-toolkit set to Interactive or removed, and an interactive console), ' +
                    "or list the app's process in ProcessesToClose so that PSADT 4.1 asks only while the app is running (on devices too). Devices with a signed-in user show the same dialog.") -f
                    $what, $project, $welcomeText, $vm
                $notes = 'Not run (Intune-parity pre-check): a PSADT 4.1 package with no processes to close and a deferrable welcome dialog waits for an answer whenever a user is signed in, ' +
                    "and the test VM is always signed in. Run it watched, or list the app's process in ProcessesToClose."
                $notRun = @{
                    Code             = 'PARITY-DIALOG-WAIT'
                    Shape            = 'Psadt41'
                    ProcessesToClose = 0
                    Welcome          = [string]$risk.Welcome
                    SignedInSessions = [int]$guest.SessionCount
                }
            }
            elseif ($guest) {
                Write-Verbose "Intune-parity pre-check: nobody is signed in to the test VM '$vm'; the run starts as usual."
            }
        }
    }

    [pscustomobject]@{
        Blocked = [bool]$blocked
        Risk    = $risk
        Guest   = $guest
        Message = $message
        Notes   = $notes
        NotRun  = $notRun
    }
}
