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
          the Hyper-V test VM is ready (this version captures on         W32T.SiblingCaptureUnsupported
          Hyper-V only)

        The backend is -Backend, else the configured test backend. Never throws (a W32T.* error from a helper is
        re-thrown); every reason is a sentence for the operator.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Backend
        HyperV or Sandbox (default: the configured test backend).
    .OUTPUTS
        [pscustomobject] Ok, Code, Reasons[], Backend, WingetId, Architecture.
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
        [string]$Backend = ''
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
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
        $resolved = if ($Backend) { $Backend } else { [string](Get-Win32ToolkitConfigValue -Name 'TestBackend' -Default 'Sandbox') }
        if ($resolved -eq 'HyperV') {
            $notReady = @(Test-Win32ToolkitHyperVReady)
            if ($notReady.Count -gt 0) { & $fail 'W32T.SiblingCaptureUnsupported' ("Hyper-V is not ready (" + ($notReady -join '; ') + '): this win32-toolkit version captures the other installer technologies on the Hyper-V test VM only') }
        }
        else {
            & $fail 'W32T.SiblingCaptureUnsupported' 'the test backend is Windows Sandbox: this win32-toolkit version captures the other installer technologies on the Hyper-V test VM only (pass -Backend HyperV, or set up the test VM with New-Win32ToolkitTestVM)'
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $fail 'W32T.SiblingCaptureUnsupported' ("the project could not be checked (" + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200) + ')')
    }
    [pscustomobject]@{
        Ok           = $reasons.Count -eq 0
        Code         = [string]$state.Code
        Reasons      = [string[]]$reasons.ToArray()
        Backend      = $resolved
        WingetId     = $wingetId
        Architecture = $arch
    }
}
