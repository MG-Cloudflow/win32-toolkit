function Get-Win32ToolkitTestMode {
    <#
    .SYNOPSIS
        Resolves the effective test mode ('Interactive' | 'Unattended') for a test backend.
    .DESCRIPTION
        One resolver for both backends so their precedence can't drift:
          1. An explicit -Unattended switch always wins.
          2. -TestMode, the run's own choice (Test-Win32ToolkitProject -TestMode, the TUI's Hyper-V run mode):
             Unattended returns Unattended; Interactive skips the config value.
          3. The per-backend config value (HyperVTestMode / SandboxTestMode) — 'Unattended' opts in. Read only
             when -TestMode is not given.
          4. A NON-INTERACTIVE host forces Unattended with a loud warning, also over -TestMode Interactive:
             Interactive mode blocks on Read-Host pauses (which THROW under pwsh -NonInteractive and hang forever
             on redirected stdin) and shows GUIs/countdowns no operator will ever see. For an explicit -TestMode
             Interactive, a console started with pwsh -NonInteractive (Test-Win32ToolkitNonInteractiveSwitch)
             counts as such a host too (a run without -TestMode keeps its mode there). The warning is loud
             because this changes WHAT is tested (Sandbox: PSADT runs -DeployMode Silent; Hyper-V: the install,
             uninstall and update run as the Intune-parity phase; either way no human verification window)
             — and the mode is recorded in the test outcome, so the change is visible in the docs.
          5. Otherwise: Interactive (the human-in-the-loop default, unchanged).
    .PARAMETER Backend
        'Sandbox' or 'HyperV' — selects which config value applies.
    .PARAMETER Unattended
        The caller's explicit switch (highest precedence).
    .PARAMETER TestMode
        This run's own choice, 'Interactive' or 'Unattended' (Test-Win32ToolkitProject -TestMode, the TUI's Hyper-V
        run mode): above the config value, below -Unattended; a non-interactive host still forces Unattended.
        Omit it to use -Unattended or the config value.
    .OUTPUTS
        [string] 'Interactive' or 'Unattended'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend,

        [switch]$Unattended,

        # This run's own choice (Test-Win32ToolkitProject -TestMode, the TUI's Hyper-V run mode): above the config
        # value, below -Unattended; a non-interactive host still forces Unattended (TUI audit G3).
        [ValidateSet('Interactive', 'Unattended')]
        [string]$TestMode
    )

    if ($Unattended -or $TestMode -eq 'Unattended') { return 'Unattended' }

    $configName = if ($Backend -eq 'HyperV') { 'HyperVTestMode' } else { 'SandboxTestMode' }
    if ($TestMode -ne 'Interactive' -and (Get-Win32ToolkitConfigValue -Name $configName -Default 'Interactive') -eq 'Unattended') {
        return 'Unattended'
    }

    # Interactive requested (or defaulted) — but only honor it when a human can actually interact.
    if ((Test-Win32ToolkitHostNonInteractive) -or ($TestMode -eq 'Interactive' -and (Test-Win32ToolkitNonInteractiveSwitch))) {
        # What Unattended means differs per backend: Sandbox runs PSADT silently, Hyper-V runs the
        # Intune-parity phases (Sandbox\Invoke-PsadtPackage.ps1 -IntuneParity, built by Test-Win32ToolkitProject).
        $whatRuns = if ($Backend -eq 'HyperV') {
            'the install, uninstall and update run as the Intune-parity phase (the published command line from a 32-bit parent, as SYSTEM)'
        }
        else { 'PSADT runs -DeployMode Silent' }
        Write-Warning "The host session is non-interactive — running the $Backend test UNATTENDED instead of Interactive. This changes what is tested: $whatRuns, with no operator verification window. Pass -Unattended (or set $configName=Unattended) to make this explicit."
        return 'Unattended'
    }

    return 'Interactive'
}
