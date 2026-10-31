function Test-Win32ToolkitSiblingCapturePreflight {
    <#
    .SYNOPSIS
        Says whether a project's other installer technologies can be captured now, before anything is downloaded or run.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.1, SV24, SV28). One check list, used by the CLI scenario
        (Test-Win32ToolkitProject -Scenario SiblingCapture throws the Code) and by Finalize (a refusal becomes one
        Problems sentence; the pipeline goes on):

          Check                                                          Code when it fails
          the deploy script is Supported, has this catalog's remove-     W32T.PriorInstallSlotsMissing
          prior pair and no dialog before prior-check
          a winget project (manual apps have no winget siblings)         W32T.SiblingCaptureUnsupported
          OwnIdentity recorded (the install capture ran)                 W32T.SiblingCaptureUnsupported
          the package architecture is x64 or x86 (not arm64)             W32T.SiblingCaptureUnsupported
          -Assisted: the Hyper-V test VM is ready and the console can  W32T.SiblingCaptureUnsupported
          answer a prompt (D62)

        The backend (SV28): -Backend, else the Hyper-V test VM when it is ready, else Windows Sandbox. A Hyper-V capture
        whose VM is not ready runs in Windows Sandbox instead, with one note said before the first download: there the
        sibling installs as a user and every proposal is Block-only (Run.Backend Sandbox). Never throws (a W32T.* error
        from a helper is re-thrown); every reason and note is a sentence for the operator.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Backend
        HyperV or Sandbox (default: Hyper-V when the test VM is ready, else Windows Sandbox).
    .PARAMETER Assisted
        An assisted capture: the operator installs the sibling in the VM window (Hyper-V only, a console that can
        prompt; its proposals are Block-only, D62).
    .OUTPUTS
        [pscustomobject] Ok, Code, Reasons[], Notes[], Backend, WingetId, Architecture.
    .EXAMPLE
        $pre = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $p
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowEmptyString()]
        [ValidateSet('', 'HyperV', 'Sandbox')]
        [string]$Backend = '',

        [switch]$Assisted
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $state = @{ Code = '' }
    $fail = { param([string]$Code, [string]$Reason) if (-not $state.Code) { $state.Code = $Code }; $reasons.Add($Reason) }
    $resolved = ''
    $wingetId = ''
    $arch = ''
    try {
        $shape = Get-Win32ToolkitDeployScriptShape -Path (Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1')
        $revision = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision)
        if ([string]$shape.Support -ne 'Supported' -or [int]$shape.RemovePriorRevision -ne $revision -or -not $shape.PriorCheckFirst) {
            & $fail 'W32T.PriorInstallSlotsMissing' 'its deploy script has no place for prior-install rules (created before this win32-toolkit version, or a dialog runs before prior-check): re-create the project first'
        }
        $src = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath
        $wingetId = [string]$src.WingetId
        if (-not $wingetId) { & $fail 'W32T.SiblingCaptureUnsupported' 'it is a manual app: manual apps have no winget siblings' }
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $own = if ($cfg.PSObject.Properties['OwnIdentity']) { $cfg.OwnIdentity } else { $null }
        if (-not $own -or (-not [string]$own.ProductCode -and @(@($own.ArpKeys) | Where-Object { $_ }).Count -eq 0)) {
            & $fail 'W32T.SiblingCaptureUnsupported' "the package's own identity is not recorded: run the install capture first (Finalize)"
        }
        $arch = ([string]$src.Architecture).ToLowerInvariant()
        if (-not $arch -and $cfg.PSObject.Properties['App']) { $arch = ([string]$cfg.App.Arch).ToLowerInvariant() }
        if ($arch -notin @('x64', 'x86')) { & $fail 'W32T.SiblingCaptureUnsupported' "the package architecture is '$arch': an ARM64 sibling cannot be installed on the x64 test VM" }
        # SV28: the Hyper-V test VM when it is ready (only it gives removable rules), else Windows Sandbox (Block-only).
        $resolved = if ($Backend) { $Backend } else { 'HyperV' }
        if ($resolved -eq 'HyperV') {
            $notReady = @(Test-Win32ToolkitHyperVReady)
            if ($notReady.Count -gt 0) {
                if ($Assisted) { & $fail 'W32T.SiblingCaptureUnsupported' ("an assisted capture runs on the Hyper-V test VM, which is not ready (" + ($notReady -join '; ') + ')') }
                else {
                    $resolved = 'Sandbox'
                    $notes.Add("Hyper-V is not ready (" + ($notReady -join '; ') + '): this capture runs in Windows Sandbox as a user and can only give Block-only proposals.')
                }
            }
        }
        elseif ($Assisted) { & $fail 'W32T.SiblingCaptureUnsupported' 'an assisted capture runs on the Hyper-V test VM only (not in Windows Sandbox)' }
        else { $notes.Add('This capture runs in Windows Sandbox as a user and can only give Block-only proposals (the Hyper-V test VM gives removable ones).') }
        # A service, a CI job or redirected input, and also a console started with -NonInteractive (live row ASSISTED: a
        # 'pwsh -NonInteractive -File' host passed, two VM runs were spent and each failed at the operator's prompt).
        if ($Assisted -and ((Test-Win32ToolkitHostNonInteractive) -or (Test-Win32ToolkitNonInteractiveSwitch))) { & $fail 'W32T.SiblingCaptureUnsupported' 'an assisted capture needs a console that can answer a prompt (this one cannot)' }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $fail 'W32T.SiblingCaptureUnsupported' ("the project could not be checked (" + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200) + ')')
    }
    [pscustomobject]@{
        Ok           = $reasons.Count -eq 0
        Code         = [string]$state.Code
        Reasons      = [string[]]$reasons.ToArray()
        Notes        = [string[]]$notes.ToArray()
        Backend      = $resolved
        WingetId     = $wingetId
        Architecture = $arch
    }
}
