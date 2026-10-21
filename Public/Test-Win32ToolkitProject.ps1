function Test-Win32ToolkitProject {
<#
.SYNOPSIS
    Tests a PSADT project in a disposable guest: Windows Sandbox or the Hyper-V test VM.
.DESCRIPTION
    Runs a chosen test scenario against a PSADT V4 project in the configured test backend:
    Windows Sandbox (default) or the local Hyper-V test VM (see New-Win32ToolkitTestVM). If no
    ProjectPath is supplied, an interactive menu lists all PSADT projects found under BasePath.

    Tests run WATCHED by default (a countdown/pause gives you a verification window) or
    UNATTENDED via -Unattended / the SandboxTestMode & HyperVTestMode config values (back-to-back,
    no operator needed: under Sandbox PSADT runs -DeployMode Silent and the guest shuts itself down
    afterwards so chained runs proceed; under Hyper-V the install, uninstall and update run as the
    Intune-parity phase). Watched runs use PSADT's Auto mode: on PSADT 4.2 the dialogs appear only
    when one of the app's listed processes is running (otherwise the run is silent); on 4.1.x Auto
    shows PSADT's dialogs. (The watched Hyper-V GUI phases force -DeployMode Interactive.)

    Process isolation: every PSADT package runs in its OWN Windows PowerShell process (PSADT 4.2
    refuses a second copy of its module in one process, and 4.1 and 4.2 cannot share one). Each
    declared 'project:' dependency is started by Sandbox\InstallDependencies.ps1, which stops at the
    first failing dependency and exits with its exit code. The app, an Update baseline project and the
    update run through the guest runner Sandbox\Invoke-PsadtPackage.ps1, which appends the exact exit
    code of each of its runs to Sandbox\Logs\PsadtExitCodes.log; those codes are printed after the run.

    Run logs: every run, and each run of -BaselineInstallerType Both, keeps its own copy of its logs (the
    assertion log, the Add/Remove Programs snapshots, its PsadtExitCodes.log lines and the PSADT and MSI
    logs) in a folder under Sandbox\Logs\Runs named after its start time, its scenario and, for an Update
    run, the old version's installer family, for example Sandbox\Logs\Runs\20261020-221500_Update_exe.
    Its Documentation\TestResults.json record names that folder (LogFolder). The files directly in
    Sandbox\Logs gather the logs of every run: each run overwrites the files it writes (and first clears
    its own scenario's assertion log), while files that only another run wrote stay there, for example
    UpdateAssertions.log after an InstallUninstall run, or the log of a dependency or an earlier version.
    A run's exact set of logs is its folder under Sandbox\Logs\Runs.

    The function is scenario-driven: new test types can be added as additional switch cases
    without changing the overall structure.
.PARAMETER ProjectPath
    Full path to the PSADT project folder (the folder that contains
    Invoke-AppDeployToolkit.ps1). If omitted, a numbered selection menu is shown.
.PARAMETER BasePath
    Root folder to scan for PSADT projects when ProjectPath is not provided. If omitted, the
    registry-saved value is used (see Invoke-Win32Toolkit).
.PARAMETER Scenario
    The test scenario to execute. If omitted, an interactive menu is shown.
    - InstallUninstall : Install → 2-minute countdown → Uninstall
    - Update           : Install an older baseline → assert the update-app requirement rule detects
                         it → 2-minute countdown → run the PSADT update → assert the requirement is
                         still met and the install tattoo holds the new version. Assertion results
                         stream back to the host (Sandbox\Logs\UpdateAssertions.log) and the command
                         reports a real PASS/FAIL verdict.
.PARAMETER VersionsBack
    Update scenario only. Automatically selects the version that is X positions older
    than the currently packaged version (e.g. 1 = the immediately previous release).
    Mutually exclusive intent with SpecificVersion; SpecificVersion takes priority.
    When neither is given, an interactive run shows a list of older versions to pick from; an unattended
    run (-Unattended, or the SandboxTestMode / HyperVTestMode config value) or a host that cannot prompt
    (a service, redirected input, or a console started with pwsh -NonInteractive) uses the previous
    version (as -VersionsBack 1) and says so in a warning.
.PARAMETER SpecificVersion
    Update scenario only. Installs this exact version as the baseline. Overrides
    VersionsBack if both are supplied.
.PARAMETER SkipRequirementCheck
    Update scenario only. Skip generating/running the update-app requirement script in the sandbox
    (its assertions report SKIP); the tattoo/detection assertion still runs. Use when the project
    has no usable requirement rule yet or you only want the plain install-over-old check.
.PARAMETER BaselineProjectPath
    Update scenario only. Install a PREVIOUS toolkit package (this folder) as the baseline instead of
    downloading the old vendor installer — exercises the tattoo-overwrite path (old tattoo → new
    tattoo) and works for manual (non-winget) projects. Mutually exclusive with -VersionsBack /
    -SpecificVersion. The baseline project is mapped READ-ONLY (its raw copy is never modified).
.PARAMETER BaselineProject
    Update scenario only. Same as -BaselineProjectPath but by FRIENDLY reference: '<Template>\<Name>'
    (or 'project:<Template>\<Name>'), resolved to <BasePath>\Projects\<Template>\<Name> — exactly how a
    'project:' dependency is referenced, so you don't type the full path. Mutually exclusive with
    -BaselineProjectPath / -VersionsBack / -SpecificVersion.
.PARAMETER BaselineInstallerType
    Update scenario, winget baseline only: the installer technology the old-version baseline must use.
    The baseline download always pins an installer type (never an unpinned retry) and never a locale.
    The resolved technology is printed as 'Baseline technology : ...' before the version is picked.
    - Auto (default): the other installer technology winget ships for this app, when there is one (read
      from Documentation\IdentityDelta.json, written on first use), so an MSI package is tested over the
      vendor EXE install that devices may already have; otherwise the packaged one.
      When the chosen version does not ship that technology, the run falls back to the packaged one with a
      warning and records UsedFallback (such a run cannot show a technology switch).
    - Both: one Update run per technology (the packaged one, then each other one winget ships) at the same
      version, each with its own verdict and TestResults.json record.
      Returns $false when a run failed, $null when a run had no verdict, else $true.
    - Packaged: the packaged installer technology only.
    - msi, wix, burn, nullsoft, inno, exe, msix: exactly that technology family, no fallback.
    A pinned scope (machine or user) is only a preference: when the version has no installer of that
    scope, winget's choice of scope is used and ScopeRelaxed is recorded.
    When the version has no installer of the required technology, the run records an Inconclusive result
    (Baseline.Unavailable) and returns $null.
    When an old install of ANOTHER technology is still registered after the update, an ID-TECH-SWITCH
    warning names it.
    Not valid with -BaselineProject / -BaselineProjectPath (that package has its own technology).
.PARAMETER Backend
    Which test backend to use for this run: 'Sandbox' (Windows Sandbox) or 'HyperV' (the local
    Hyper-V test VM over PowerShell Direct). Omit to use the configured default (the TestBackend
    config value — Sandbox unless HyperV is configured AND ready; an unready HyperV falls back to
    Sandbox with a warning).
.PARAMETER Unattended
    Run back-to-back on either backend with no countdown or pause; under Sandbox the guest shuts
    itself down afterwards so chained runs proceed unaided. The default is
    watched/interactive. Overrides the SandboxTestMode / HyperVTestMode config values; on a
    non-interactive host Unattended is auto-selected with a warning. Note the context difference:
    Sandbox-unattended runs the package -DeployMode Silent as the sandbox admin user, while
    HyperV-unattended runs an INTUNE-PARITY phase for install, uninstall and update: the exact
    published command line (Invoke-AppDeployToolkit.exe -DeploymentType Install|Uninstall, no
    -DeployMode) from a 32-bit cmd.exe parent, as SYSTEM, in the package folder - the way the Intune
    Management Extension launches it - with the exit code checked (0, 1707, 3010, 1641 = success).
    Their results are not equivalent evidence.
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario Update -VersionsBack 1 -SkipRequirementCheck
.EXAMPLE
    # Baseline with a previous toolkit package (tattoo-overwrite test), by full path
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.55.0' -Scenario Update -BaselineProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
.EXAMPLE
    # Same, by friendly reference (resolved under BasePath\Projects\)
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.55.0' -Scenario Update -BaselineProject 'Contoso\Git_x64_2.53.0'
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario InstallUninstall
.EXAMPLE
    # Unattended Intune-parity run (published command line, 32-bit parent, SYSTEM), no operator needed — ideal for automation
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario InstallUninstall -Backend HyperV -Unattended
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0' -Scenario Update -SpecificVersion '2.47.0'
.EXAMPLE
    Test-Win32ToolkitProject -BasePath 'D:\Packaging' -Scenario Update
.EXAMPLE
    # One Update run per installer technology winget ships (e.g. the vendor EXE and the MSI), each recorded separately
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1' -Scenario Update -VersionsBack 1 -BaselineInstallerType Both
.EXAMPLE
    # Pin the old version to the vendor EXE (NSIS) technology
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1' -Scenario Update -SpecificVersion '8.8.9' -BaselineInstallerType nullsoft
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProjectPath,

        [Parameter(Mandatory = $false)]
        [string]$BasePath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string]$Scenario,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1000)]
        [int]$VersionsBack,

        [Parameter(Mandatory = $false)]
        [string]$SpecificVersion,

        # Update scenario only: don't generate/run the update-app requirement script in the sandbox —
        # its assertions are reported as SKIP. The tattoo/detection assertion still runs.
        [Parameter(Mandatory = $false)]
        [switch]$SkipRequirementCheck,

        # Update scenario only: install a PREVIOUS toolkit package (this project folder) as the baseline
        # instead of downloading the old vendor installer — exercises the tattoo-overwrite path. Mutually
        # exclusive with -VersionsBack / -SpecificVersion, and works for manual (non-winget) projects.
        [Parameter(Mandatory = $false)]
        [string]$BaselineProjectPath,

        # Update scenario only: like -BaselineProjectPath but by FRIENDLY reference — '<Template>\<Name>'
        # (or 'project:<Template>\<Name>'), resolved to <BasePath>\Projects\<Template>\<Name>, the same way a
        # 'project:' dependency is referenced. Mutually exclusive with -BaselineProjectPath / -VersionsBack /
        # -SpecificVersion.
        [Parameter(Mandatory = $false)]
        [string]$BaselineProject,

        # Update scenario, winget baseline only: the installer technology of the old version. Auto (default) = the
        # other technology winget ships (falling back, pinned and loudly, to the packaged one), Both = one run per
        # technology, Packaged = the packaged one, or an installer type. Never an unpinned download.
        [Parameter(Mandatory = $false)]
        [ValidateSet('Auto', 'Both', 'Packaged', 'msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')]
        [string]$BaselineInstallerType = 'Auto',

        # Which test backend to run against. Omit to use the configured/resolved default (Sandbox unless
        # HyperV is configured AND ready). 'HyperV' runs the scenario in the local Hyper-V VM over
        # PowerShell Direct; 'Sandbox' uses Windows Sandbox.
        [Parameter(Mandatory = $false)]
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend,

        # Run back-to-back on EITHER backend (no countdown/pause, and under Sandbox the guest shuts itself
        # down afterwards so chained runs proceed) — ideal for automation. The default
        # is WATCHED: a human verification window (PSADT Auto mode in Sandbox, forced Interactive in the
        # Hyper-V GUI phases). Overrides the HyperVTestMode / SandboxTestMode config defaults; a
        # non-interactive host auto-selects Unattended with a warning (see Get-Win32ToolkitTestMode).
        # NOTE: Sandbox-unattended runs -DeployMode Silent as the WDAG admin user, while HyperV-unattended
        # runs the Intune-parity phases (published command line, 32-bit parent, SYSTEM) — not equivalent
        # evidence.
        [Parameter(Mandatory = $false)]
        [switch]$Unattended
    )

    try {
        # Prompt for scenario if not explicitly supplied
        if (-not $PSBoundParameters.ContainsKey('Scenario')) {
            $Scenario = Show-ScenarioSelection
        }

        # Resolve the project to test
        if (-not $ProjectPath) {
            $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath
            Write-Verbose 'Scanning for PSADT projects...'
            $projects = Get-PSADTProjects -BasePath $BasePath

            if ($projects.Count -eq 0) {
                throw "No PSADT projects found in: $BasePath. Ensure project folders contain Invoke-AppDeployToolkit.ps1."
            }

            $selectedProject = Show-ProjectSelection -Projects $projects
            $ProjectPath     = $selectedProject.Path
        }

        if (-not (Test-Path $ProjectPath)) {
            throw "Project path not found: $ProjectPath"
        }

        $projectName = Split-Path -Leaf $ProjectPath
        Write-Host "`nSelected project : $projectName"  -ForegroundColor Green
        Write-Host "Project path     : $ProjectPath"   -ForegroundColor Gray
        Write-Host "Scenario         : $Scenario"      -ForegroundColor Cyan

        # The baseline / version parameters only mean anything for the Update scenario. Rather than silently
        # ignore them under InstallUninstall (so the user thinks they configured an update-from-baseline test
        # but got a plain install/uninstall), reject the mismatch up front.
        if ($Scenario -ne 'Update') {
            $updateOnly = @('BaselineProject', 'BaselineProjectPath', 'VersionsBack', 'SpecificVersion', 'BaselineInstallerType') |
                Where-Object { $PSBoundParameters.ContainsKey($_) }
            if ($updateOnly) {
                throw "$(@($updateOnly | ForEach-Object { "-$_" }) -join ', ') apply only to -Scenario Update (got '$Scenario')."
            }
        }

        # -BaselineProject: resolve a friendly '<Template>\<Name>' (or 'project:<Template>\<Name>') reference
        # to a packaged project under BasePath, then feed the SAME -BaselineProjectPath machinery below — so
        # you can name a local package the way a 'project:' dependency does, instead of typing the full path.
        # A baseline PROJECT is installed by its own package, so its technology is fixed: only the winget baseline
        # takes an installer-technology choice (installer-identity PR 1).
        $baselineTechError = '-BaselineInstallerType applies to a winget baseline; the baseline project has its own technology.'
        if ($Scenario -eq 'Update' -and $BaselineProject) {
            if ($PSBoundParameters.ContainsKey('BaselineInstallerType') -and $BaselineInstallerType -ne 'Auto') {
                throw $baselineTechError
            }
            if ($BaselineProjectPath) {
                throw '-BaselineProject and -BaselineProjectPath are mutually exclusive — both name the baseline package; use one.'
            }
            if ($VersionsBack -or $SpecificVersion) {
                throw '-BaselineProject is mutually exclusive with -VersionsBack / -SpecificVersion (the baseline IS the referenced project).'
            }
            $ref = ConvertTo-Win32ToolkitDependencyRef -Reference $BaselineProject
            if ($ref.Source -ne 'project') {
                throw "-BaselineProject must reference a packaged project as '<Template>\<Name>' (or 'project:<Template>\<Name>'), not '$BaselineProject'."
            }
            # A full path contains backslashes too, so it parses as a 'project' ref and would then be joined
            # ONTO the Projects root ('...\Projects\C:\...') into a garbage path. Reject a rooted or traversal
            # ref and point the user at the right parameter.
            if ([System.IO.Path]::IsPathRooted($ref.Ref) -or $ref.Ref -match '\.\.[\\/]') {
                throw "-BaselineProject takes a '<Template>\<Name>' reference under Projects\, not a full path — use -BaselineProjectPath for an absolute path."
            }
            # Resolve BasePath WITHOUT prompting (a direct -ProjectPath caller leaves $BasePath empty; the
            # registry value fills it). If nothing is configured, fail clearly instead of hanging on Read-Host.
            $resolvedBase = Get-Win32ToolkitBasePath -BasePath $BasePath -NonInteractive
            if ([string]::IsNullOrWhiteSpace($resolvedBase)) {
                throw '-BaselineProject needs a configured BasePath to resolve against, but none is set. Pass -BaselineProjectPath (a full path), or run the toolkit once to set the base folder.'
            }
            $projectsRoot        = (Get-Win32ToolkitPaths -BasePath $resolvedBase).Projects
            $BaselineProjectPath = Join-Path $projectsRoot $ref.Ref
            if (-not (Test-Path -LiteralPath $BaselineProjectPath)) {
                throw "Baseline project '$($ref.Ref)' not found under Projects\ — package that (older) version first, then re-run. (Looked in: $BaselineProjectPath)"
            }
            Write-Host "Baseline (ref)   : $($ref.Ref)" -ForegroundColor Gray
        }

        # -BaselineProjectPath validation runs FIRST (before the sandbox pre-flight) so parameter
        # errors are deterministic regardless of whether a sandbox is open. (-BaselineProject resolves into
        # $BaselineProjectPath above, so it flows through exactly the same checks.)
        $baselineApp = $null
        if ($Scenario -eq 'Update' -and $BaselineProjectPath) {
            if ($PSBoundParameters.ContainsKey('BaselineInstallerType') -and $BaselineInstallerType -ne 'Auto') {
                throw $baselineTechError
            }
            if ($VersionsBack -or $SpecificVersion) {
                throw '-BaselineProjectPath is mutually exclusive with -VersionsBack / -SpecificVersion (the baseline IS the supplied project).'
            }
            if (-not (Test-Path -LiteralPath $BaselineProjectPath)) {
                throw "Baseline project not found: $BaselineProjectPath"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $BaselineProjectPath 'Invoke-AppDeployToolkit.ps1'))) {
                throw "Not a PSADT project (no Invoke-AppDeployToolkit.ps1): $BaselineProjectPath"
            }
            if ((Resolve-Path -LiteralPath $BaselineProjectPath).Path -eq (Resolve-Path -LiteralPath $ProjectPath).Path) {
                throw '-BaselineProjectPath must be a DIFFERENT project than the one under test.'
            }
            $baseCfg     = Get-Win32ToolkitAppConfig -ProjectPath $BaselineProjectPath
            $baselineApp = if ($baseCfg.PSObject.Properties.Name -contains 'App') { $baseCfg.App } else { $null }
            if (-not ($baselineApp -and $baselineApp.Version)) {
                throw "Baseline project has no App.Version in SupportFiles\AppConfig.json (it predates AppConfig — regenerate it): $BaselineProjectPath"
            }
        }

        # Resolve the effective test backend (Sandbox by default; HyperV is opt-in and falls back to
        # Sandbox with a warning if the VM / guest credential aren't ready).
        $resolvedBackend = if ($Backend) { Get-Win32ToolkitTestBackend -Backend $Backend } else { Get-Win32ToolkitTestBackend }
        Write-Host "Backend          : $resolvedBackend" -ForegroundColor Cyan

        # Windows Sandbox allows a single running instance. Instead of throwing the moment one exists —
        # which silently killed chained runs (the capture sandbox is still auto-closing when the
        # InstallUninstall test starts; the IU sandbox is still open when the chained Update test starts,
        # and the non-terminating error let packaging proceed AS IF the test had run) — wait up to 90 s
        # for it to exit, then fail with the same guidance. HyperV skips this guard.
        if ($resolvedBackend -eq 'Sandbox') {
            if (-not (Wait-Win32ToolkitSandboxFree -TimeoutSeconds 90)) {
                throw 'Another Windows Sandbox is still running after waiting 90 s (only one instance is allowed). Close it — e.g. a previous test sandbox left open for verification — and re-run the test.'
            }
        }

        # One PSADT package = one process: every package (baseline project, the app) runs through the guest
        # runner Sandbox\Invoke-PsadtPackage.ps1 instead of being dot-called inside the LogonCommand / phase
        # process — PSADT 4.2 refuses a second copy of its module in a process (60008), and 4.1/4.2 cannot
        # share one. Written BEFORE any scenario builds a command. The runner appends each run's exact exit
        # code to Sandbox\Logs\PsadtExitCodes.log. It is cleared once per OUTER call: the legs of an Update
        # '-BaselineInstallerType Both' run (inner calls) append to it, each after its own start marker
        # (Initialize-Win32ToolkitTestRunLog), so the printed codes and the watched countdown's verdict belong
        # to the current run, and every leg's lines stay (test campaign F2).
        $null = New-Win32ToolkitPackageRunnerScript -ProjectPath $ProjectPath
        $exitCodeLog = Join-Path $ProjectPath 'Sandbox\Logs\PsadtExitCodes.log'
        if ($null -eq $script:W32TUpdateLegContext -and (Test-Path -LiteralPath $exitCodeLog)) {
            Remove-Item -LiteralPath $exitCodeLog -Force -ErrorAction SilentlyContinue
        }
        # PSADT / Intune success codes (0, 1707 success; 3010 soft, 1641 hard reboot) for the runner phases.
        $psadtSuccessCodes = @(0, 1707, 3010, 1641)
        # Prints the runner's exit-code lines of the current run (after its start marker) when the log came back.
        $showExitCodes = {
            param($Run)
            if (Test-Path -LiteralPath $exitCodeLog) {
                $codeLines = @(Get-Content -LiteralPath $exitCodeLog -ErrorAction SilentlyContinue | Where-Object { $_ })
                $at = if ($Run -and $Run.Marker) { [array]::LastIndexOf([string[]]$codeLines, [string]$Run.Marker) } else { -1 }
                if ($at -ge 0) { $codeLines = @($codeLines | Select-Object -Skip ($at + 1)) }
                $codeLines = @($codeLines | Where-Object { $_ -notmatch '^\[[^\]]*\]\s+-- test run ' })
                if ($codeLines.Count -gt 0) {
                    Write-Host 'PSADT exit codes (Sandbox\Logs\PsadtExitCodes.log):' -ForegroundColor Cyan
                    foreach ($codeLine in $codeLines) {
                        $codeColor = if ($codeLine -match 'result=(Success|SoftReboot|HardReboot)\b') { 'Green' } else { 'Red' }
                        Write-Host "  $codeLine" -ForegroundColor $codeColor
                    }
                }
            }
        }
        # Keeps the run's logs in its own folder, Sandbox\Logs\Runs\<run>\ (test campaign F2): the next run (the
        # next leg of a Both run) overwrites the top-level Sandbox\Logs files it writes, and files only an earlier
        # run wrote stay there, so only the run folder is exactly this run's. Under Sandbox the guest
        # collects the PSADT/MSI logs AFTER the last assertion, so wait for its collector first (-WaitSeconds).
        # Returns the folder relative to the project for the TestResults.json record ('' when none).
        $saveRunLog = {
            param($Run, [int]$WaitSeconds)
            if (-not $Run) { return '' }
            if ($WaitSeconds -gt 0 -and -not (Wait-Win32ToolkitCollectedLog -ProjectPath $ProjectPath -TimeoutSeconds $WaitSeconds)) {
                Write-Warning "The Sandbox log collector did not finish within $WaitSeconds s: this run's log folder may miss its PSADT/MSI logs (see Sandbox\Logs)."
            }
            $rel = Save-Win32ToolkitTestRunLog -Run $Run
            if ($rel) { Write-Host "Run logs         : $(Join-Path $ProjectPath $rel)" -ForegroundColor Gray }
            [string]$rel
        }

        # Stage declared dependencies (winget installers / packaged projects) into Sandbox\Dependencies\ so
        # the guest installs them BEFORE the app — the same order Intune uses on a real device. Returns 0
        # (and generates nothing) when the project declares none, so behaviour is unchanged for those.
        # The phase command ends in 'exit $LASTEXITCODE' so the dependency script's exact code (not the
        # -Command 0/1 collapse) reaches the Hyper-V provider.
        $depCount   = Initialize-Win32ToolkitDependencyStaging -ProjectPath $ProjectPath
        $depCommand = '& ''C:\PSADT\Sandbox\InstallDependencies.ps1''; exit $LASTEXITCODE'
        if ($depCount -gt 0) {
            Write-Host "Dependencies     : $depCount (installed in the guest before the app)" -ForegroundColor Cyan
        }

        switch ($Scenario) {

            'InstallUninstall' {
                # Mode-neutral: the watched countdown / Hyper-V pause (or their absence) is announced once the
                # mode is resolved below — never by a second Get-Win32ToolkitTestMode call (its non-interactive
                # warning would print twice).
                Write-Host "`nScenario: Install → Uninstall" -ForegroundColor Cyan

                # Assertion script: after install it must be DETECTED (Intune's own detection signal — the
                # install tattoo); after uninstall it must be GONE. Value-free, reads AppConfig in the guest.
                $null = New-InstallAssertionScript -ProjectPath $ProjectPath
                $assertCmd = "& 'C:\PSADT\Sandbox\InstallAssertions.ps1'"
                # Clear a previous run's log so the verdict reflects THIS run only.
                $installAssertLog = Join-Path $ProjectPath 'Sandbox\Logs\InstallAssertions.log'
                if (Test-Path -LiteralPath $installAssertLog) { Remove-Item -LiteralPath $installAssertLog -Force -ErrorAction SilentlyContinue }

                if ($resolvedBackend -eq 'HyperV') {
                    # Log collector runs inside the guest (copies PSADT/MSI logs to Sandbox\Logs).
                    $null = New-LogCollectorScript -ProjectPath $ProjectPath

                    # Interactive (default) shows the PSADT GUI in the VM console for hands-on testing;
                    # -Unattended (or HyperVTestMode=Unattended, or a non-interactive host) runs the
                    # Intune-parity phases back-to-back (published command line from a 32-bit cmd.exe
                    # parent, as SYSTEM, no -DeployMode). One resolver for both backends (Get-Win32ToolkitTestMode).
                    $interactive = (Get-Win32ToolkitTestMode -Backend HyperV -Unattended:$Unattended) -eq 'Interactive'

                    # Dependencies go in FIRST (silently), exactly as Intune installs them on a device.
                    $phases = @()
                    if ($depCount -gt 0) { $phases += @{ Label = 'Install dependencies'; Command = $depCommand; DepPhase = $true } }

                    # Every package run goes through the guest runner (own process) and ends in
                    # 'exit $LASTEXITCODE' (single-quoted: literal for the guest), so the provider sees the
                    # EXACT PSADT exit code and judges it against SuccessExitCodes.
                    if ($interactive) {
                        # GUI phases force -DeployMode Interactive so the operator always sees PSADT's dialogs.
                        $phases += @(
                            @{ Label = 'Install (GUI)';                   Command = '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -DeploymentType Install -DeployMode Interactive -Label app; exit $LASTEXITCODE'; Interactive = $true; SuccessExitCodes = $psadtSuccessCodes }
                            @{ Label = 'Assert: installed';               Command = "$assertCmd -Phase PostInstall"; IgnoreExit = $true }
                            @{ Label = 'Test the app in the VM window';   Pause = $true }
                            @{ Label = 'Uninstall (GUI)';                 Command = '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -DeploymentType Uninstall -DeployMode Interactive -Label app; exit $LASTEXITCODE'; Interactive = $true; SuccessExitCodes = $psadtSuccessCodes }
                            @{ Label = 'Assert: uninstalled';             Command = "$assertCmd -Phase PostUninstall"; IgnoreExit = $true }
                            @{ Label = 'CollectLogs';                     Command = "& 'C:\PSADT\Sandbox\CollectLogs.ps1'"; IgnoreExit = $true }
                        )
                        Write-Host 'Running an INTERACTIVE Install → test → Uninstall in the Hyper-V VM (watch the vmconnect window)...' -ForegroundColor Cyan
                    }
                    else {
                        # INTUNE PARITY: the exact published command line (Get-Win32ToolkitIntuneCommandLine,
                        # via Sandbox\IntuneCommandLine.json) from a 32-bit cmd.exe parent, as SYSTEM, in the
                        # package folder, with no -DeployMode — the way the IME launches it. Replaces the old
                        # 64-bit '.ps1 -DeployMode Silent' runs (spec Q7).
                        $phases += @(
                            @{ Label = 'Install (Intune parity)';   Command = '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Install -Label app; exit $LASTEXITCODE'; SuccessExitCodes = $psadtSuccessCodes }
                            @{ Label = 'Assert: installed';         Command = "$assertCmd -Phase PostInstall"; IgnoreExit = $true }
                            @{ Label = 'Uninstall (Intune parity)'; Command = '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Uninstall -Label app; exit $LASTEXITCODE'; SuccessExitCodes = $psadtSuccessCodes }
                            @{ Label = 'Assert: uninstalled';       Command = "$assertCmd -Phase PostUninstall"; IgnoreExit = $true }
                            @{ Label = 'CollectLogs';               Command = "& 'C:\PSADT\Sandbox\CollectLogs.ps1'"; IgnoreExit = $true }
                        )
                        Write-Host 'Running an UNATTENDED Install → Uninstall in the Hyper-V VM with the Intune command line (32-bit parent, SYSTEM)...' -ForegroundColor Cyan
                    }
                    $runLog = Initialize-Win32ToolkitTestRunLog -ProjectPath $ProjectPath -Scenario 'InstallUninstall'
                    $ran = Invoke-Win32ToolkitHyperVRun -ProjectPath $ProjectPath -Phase $phases -Output @('Sandbox\Logs\*')
                    if ($ran) {
                        Write-Host "✓ Hyper-V install/uninstall completed. Logs: $(Join-Path $ProjectPath 'Sandbox\Logs')" -ForegroundColor Green
                    } else {
                        Write-Warning 'Hyper-V install/uninstall run did not complete cleanly — see the warnings above.'
                    }
                    & $showExitCodes $runLog
                    # Read the install/uninstall assertions the guest wrote (only if the log came back — no 30-min
                    # hang if the run died before writing it), report a verdict, and record it for the docs.
                    $iuVerdict = $null
                    if ($ran -and (Test-Path -LiteralPath $installAssertLog)) {
                        $iuVerdict = Wait-Win32ToolkitUpdateAssertion -ProjectPath $ProjectPath -Backend HyperV -TimeoutMinutes 1 -LogFileName 'InstallAssertions.log' -Label 'INSTALL/UNINSTALL TEST'
                    }
                    # The logs came back with the copy-out: nothing to wait for.
                    $runFolder = & $saveRunLog $runLog 0
                    Write-Win32ToolkitTestOutcome -ProjectPath $ProjectPath -Scenario 'InstallUninstall' -Backend 'HyperV' `
                        -Mode $(if ($interactive) { 'Interactive' } else { 'Unattended' }) -Verdict $iuVerdict -LogFileName 'InstallAssertions.log' -LogFolder $runFolder
                    return $iuVerdict
                }

                # Watched (default) vs unattended: watched keeps the human verification window (countdown
                # GUI, PSADT's interactive UI, -NoExit for inspection); unattended drops all three, runs
                # PSADT -DeployMode Silent, and SHUTS THE GUEST DOWN afterwards so a chained test's
                # single-instance guard clears on its own. NOTE the mode divergence: Sandbox-unattended
                # runs as the WDAG interactive admin user, HyperV-unattended as SYSTEM/session-0 — their
                # verdicts are not equivalent evidence (the recorded Mode/Backend make this visible).
                $sbInteractive = (Get-Win32ToolkitTestMode -Backend Sandbox -Unattended:$Unattended) -eq 'Interactive'

                if ($sbInteractive) {
                    # Create the countdown helper script inside Sandbox\ (watched mode only)
                    Write-Verbose 'Creating countdown script...'
                    $countdownPath = New-CountdownScript -ProjectPath $ProjectPath
                    Write-Host "✓ Countdown script : $countdownPath" -ForegroundColor Green
                }

                # Log collector — copies PSADT/MSI logs back to the project after the run
                $logCollectorPath = New-LogCollectorScript -ProjectPath $ProjectPath
                Write-Host "✓ Log collector    : $logCollectorPath" -ForegroundColor Green

                # Build sandbox configuration
                $sandboxFolder     = Join-Path $ProjectPath 'Sandbox'
                $sandboxConfigFile = Join-Path $sandboxFolder 'FinalDemo.wsb'

                # Dependencies install FIRST (static, XML-safe path — no untrusted value is spliced here;
                # the untrusted installer args live in Sandbox\Dependencies\dependencies.json as DATA).
                # The app's install and uninstall each run in their OWN process via the guest runner (a
                # 'project:' dependency would otherwise already have loaded PSADT into this process).
                $depPrefixXml = if ($depCount -gt 0) { 'C:\PSADT\Sandbox\InstallDependencies.ps1; ' } else { '' }
                if ($sbInteractive) {
                    # Watched: PSADT's Auto mode (no -DeployMode), as before.
                    $logonCommandXml = "powershell.exe -NoExit -ExecutionPolicy Bypass -Command &quot;&amp; { try { ${depPrefixXml}C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Install -Label app; C:\PSADT\Sandbox\InstallAssertions.ps1 -Phase PostInstall; C:\PSADT\Sandbox\Countdown.ps1; C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Uninstall -Label app; C:\PSADT\Sandbox\InstallAssertions.ps1 -Phase PostUninstall } finally { C:\PSADT\Sandbox\CollectLogs.ps1 } }&quot;"
                }
                else {
                    # No -NoExit, no countdown, Silent deploys; 5 s before Stop-Computer lets the VSMB
                    # mapped-folder write-back flush the collected logs.
                    $logonCommandXml = "powershell.exe -ExecutionPolicy Bypass -Command &quot;&amp; { try { ${depPrefixXml}C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Install -DeployMode Silent -Label app; C:\PSADT\Sandbox\InstallAssertions.ps1 -Phase PostInstall; C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1 -DeploymentType Uninstall -DeployMode Silent -Label app; C:\PSADT\Sandbox\InstallAssertions.ps1 -Phase PostUninstall } finally { C:\PSADT\Sandbox\CollectLogs.ps1; Start-Sleep -Seconds 5; Stop-Computer -Force } }&quot;"
                }
                $sandboxConfigContent = New-Win32ToolkitSandboxConfig `
                    -Mount @{ HostPath = $ProjectPath; GuestPath = 'C:\PSADT'; ReadOnly = $false } `
                    -LogonCommandXml $logonCommandXml
                Set-Content -Path $sandboxConfigFile -Value $sandboxConfigContent -Encoding UTF8
                Write-Host "✓ Sandbox config   : $sandboxConfigFile" -ForegroundColor Green

                # Launch Windows Sandbox
                Write-Host ''
                Write-Host 'Launching Windows Sandbox for Final Demo...' -ForegroundColor Cyan
                Write-Host '=============================================' -ForegroundColor Cyan
                Write-Host 'The sandbox will:'                            -ForegroundColor White
                if ($sbInteractive) {
                Write-Host '  1. Install the application'                 -ForegroundColor Green
                Write-Host '  2. Show a 2-minute countdown for testing'   -ForegroundColor Yellow
                Write-Host '  3. Uninstall the application'               -ForegroundColor Red
                Write-Host '  4. Copy PSADT/MSI logs to project\Sandbox\Logs' -ForegroundColor Cyan
                Write-Host '  5. Keep the sandbox open for verification'  -ForegroundColor Cyan
                } else {
                Write-Host '  1. SILENTLY install the application'        -ForegroundColor Green
                Write-Host '  2. Uninstall it back-to-back (no countdown)' -ForegroundColor Red
                Write-Host '  3. Copy PSADT/MSI logs to project\Sandbox\Logs' -ForegroundColor Cyan
                Write-Host '  4. Shut the sandbox down automatically'     -ForegroundColor Cyan
                }
                Write-Host '=============================================' -ForegroundColor Cyan

                $runLog = Initialize-Win32ToolkitTestRunLog -ProjectPath $ProjectPath -Scenario 'InstallUninstall'
                $launched = (Invoke-Win32ToolkitTestRun -Backend Sandbox -SandboxConfigPath $sandboxConfigFile).Launched
                if ($launched) {
                    Write-Host "`n✓ Final demo sandbox launched successfully!" -ForegroundColor Green
                    Write-Host 'Monitor the sandbox for the complete install/uninstall cycle.' -ForegroundColor White
                } else {
                    Write-Warning "The sandbox did NOT auto-launch — start it manually by double-clicking: $sandboxConfigFile"
                }
                # Wait for the in-sandbox install/uninstall assertions (only if it launched), print a verdict,
                # and record it for the docs. Bounded to 10 min (install + the 2-min countdown + uninstall, plus
                # slow-first-boot margin): if the operator closes the sandbox before the PostUninstall assertion,
                # the run can never complete, so we must not block the host on the 30-min Update default.
                $iuVerdict = if ($launched) {
                    Wait-Win32ToolkitUpdateAssertion -ProjectPath $ProjectPath -Backend Sandbox -TimeoutMinutes 10 -LogFileName 'InstallAssertions.log' -Label 'INSTALL/UNINSTALL TEST'
                } else { $null }
                & $showExitCodes $runLog
                $runFolder = & $saveRunLog $runLog $(if ($launched) { 60 } else { 0 })
                Write-Win32ToolkitTestOutcome -ProjectPath $ProjectPath -Scenario 'InstallUninstall' -Backend 'Sandbox' `
                    -Mode $(if ($sbInteractive) { 'Interactive' } else { 'Unattended' }) -Verdict $iuVerdict -LogFileName 'InstallAssertions.log' -LogFolder $runFolder
                return $iuVerdict
            }

            'Update' {
                $useBaselineProject = [bool]$BaselineProjectPath
                # Mode-neutral (the countdown / pause is announced with the steps once the mode is known), and
                # printed once: the legs of a '-BaselineInstallerType Both' run print their own leg banner.
                if ($null -eq $script:W32TUpdateLegContext) {
                    Write-Host "`nScenario: Install Old Version → Run PSADT Update" -ForegroundColor Cyan
                }

                # Baseline technology (installer-identity PR 1): the canonical -BaselineInstallerType value, and the
                # leg context a '-BaselineInstallerType Both' run sets for each of its inner runs (L13).
                $baselineMode = @('Auto', 'Both', 'Packaged', 'msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix') |
                    Where-Object { $_ -eq $BaselineInstallerType } | Select-Object -First 1
                $legContext = $script:W32TUpdateLegContext
                # What this run's old version was (Documentation\TestResults.json 'Baseline').
                $baselineInfo = $null
                # A failed Update test whose surviving old install is ANOTHER technology: say so (ID-TECH-SWITCH, V42).
                $warnTechSwitch = {
                    try {
                        foreach ($s in @(Get-Win32ToolkitTechnologySwitch -ProjectPath $ProjectPath)) { Write-Warning $s.Message }
                    }
                    catch {
                        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                        Write-Verbose "Technology-switch check skipped: $($_.Exception.Message)"
                    }
                }

                if ($useBaselineProject) {
                    # ── Baseline = a previous TOOLKIT package (no winget) ──────────────────
                    $targetVersion = $baselineApp.Version
                    Write-Host "Baseline project : $BaselineProjectPath" -ForegroundColor Gray
                    Write-Host "Baseline version : $targetVersion (from its AppConfig)" -ForegroundColor Yellow
                    $baselineSource = Get-Win32ToolkitProjectSource -ProjectPath $BaselineProjectPath
                    $baselineInfo = @{
                        Version                = [string]$targetVersion
                        Mode                   = $baselineMode
                        Origin                 = 'Project'
                        RequestedInstallerType = ''
                        InstallerType          = [string]$baselineSource.InstallerType
                        Family                 = [string]$baselineSource.Family
                        UsedFallback           = $false
                        FallbackReason         = ''
                        RequestedScope         = ''
                        Scope                  = [string]$baselineSource.Scope
                        ScopeRelaxed           = $false
                        Unavailable            = $false
                        Locale                 = [string]$baselineSource.Locale
                        Source                 = 'project'
                        ProjectName            = Split-Path -Leaf $BaselineProjectPath
                    }

                    # Warn if the baseline is a different app (the tattoo-overwrite test would be meaningless).
                    $cfgU = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
                    $appU = if ($cfgU.PSObject.Properties.Name -contains 'App') { $cfgU.App } else { $null }
                    $idU  = "$($appU.ScriptAuthor)|$($appU.Vendor)|$(if ($appU.DisplayName) { $appU.DisplayName } else { $appU.Name })"
                    $idB  = "$($baselineApp.ScriptAuthor)|$($baselineApp.Vendor)|$(if ($baselineApp.DisplayName) { $baselineApp.DisplayName } else { $baselineApp.Name })"
                    if ($idU -ne $idB) {
                        Write-Warning "The baseline project's tattoo identity ($idB) differs from the project under test ($idU) — the tattoo-overwrite assertions may FAIL because it is a different app."
                    }
                    # The baseline is mapped ReadOnly; a LogPath that is relative or points inside the
                    # baseline project folder would make its install fail — warn (best-effort; PSADT
                    # variable paths like $envWinDir\... are left alone). The config always stores a HOST
                    # path, so match the risky host shapes — NOT the C:\PSADTOld sandbox mount.
                    $baseConfigPsd1 = Join-Path $BaselineProjectPath 'Config\config.psd1'
                    if (Test-Path -LiteralPath $baseConfigPsd1) {
                        if ((Get-Content -LiteralPath $baseConfigPsd1 -Raw) -match "(?m)LogPath\s*=\s*'([^']*)'") {
                            $lp = $matches[1]
                            $isVar = $lp -match '^\s*[\$%]'
                            if ($lp -and -not $isVar -and ((-not [System.IO.Path]::IsPathRooted($lp)) -or ($lp -like "$BaselineProjectPath*"))) {
                                Write-Warning "The baseline project's LogPath ('$lp') is relative or inside the project folder, which is mapped READ-ONLY — its install may fail. Use a template with an absolute default LogPath (e.g. C:\Windows\Logs\Software)."
                            }
                        }
                    }
                }
                else {
                    # ── Step 1: Read package info from the project's Files YAML ──────────────
                    $filesPath = Join-Path $ProjectPath 'Files'
                    if (-not (Test-Path $filesPath)) {
                        throw "Files directory not found in: $filesPath`nEnsure this project was created with win32-toolkit."
                    }

                    $wingetId = Get-WingetIdFromProject -FilesPath $filesPath
                    if (-not $wingetId) {
                        throw "No winget PackageIdentifier found in: $filesPath`nThe Update scenario needs a winget-based project (it downloads the older baseline from winget). For a manual project, pass -BaselineProjectPath, or use -Scenario InstallUninstall."
                    }

                    $yamlInfo       = Get-YAMLInstallerInfo -FilesPath $filesPath
                    $currentVersion = if ($yamlInfo) { $yamlInfo.PackageVersion } else { $null }
                    $architecture   = if ($yamlInfo) { $yamlInfo.Architecture }   else { $null }

                    Write-Host "Package ID       : $wingetId"       -ForegroundColor Gray
                    Write-Host "Packaged version : $currentVersion" -ForegroundColor Gray

                    # ── Baseline technology (installer-identity PR 1) ─────────────────────────────
                    # Resolved BEFORE the version is picked, so the operator knows which technology the old version
                    # must ship (Dv5). Every leg pins an installer type (never an unpinned download, never a locale);
                    # Auto prefers the other technology winget ships for this app (V22, D5).
                    $legs = @(Resolve-Win32ToolkitBaselineFamily -ProjectPath $ProjectPath -Mode $baselineMode)
                    if ($legs.Count -eq 0) {
                        throw 'No Update baseline technology could be resolved for this project.'
                    }
                    foreach ($leg in $legs) {
                        # Inside a Both leg the inner run resolves its pin value ('requested with
                        # -BaselineInstallerType'): show the label the outer list gave this leg instead (H6-F2).
                        $legLabel = if ($legContext -and $legContext.Label) { [string]$legContext.Label } else { $leg.Label }
                        Write-Host "Baseline technology : $legLabel" -ForegroundColor Cyan
                        if ($leg.Note) { Write-Host "  $($leg.Note)" -ForegroundColor DarkGray }
                    }
                    if ($legContext) {
                        Write-Host "Update test leg  : $($legContext.Index) of $($legContext.Count) (-BaselineInstallerType Both)" -ForegroundColor Gray
                    }

                    # ── Step 2-3: Pick the target baseline version ────────────────────────────
                    if ($SpecificVersion) {
                        # Explicit baseline: usable even when winget lists no (or no older) versions —
                        # the older-version lookup is advisory only here.
                        $targetVersion = $SpecificVersion
                        # Inside a Both leg the outer call already picked (or warned about) this version: no second
                        # advisory winget query per leg (test campaign 2026-10-21, H6-F3).
                        if (-not $legContext) {
                            try {
                                $known = @(Get-WingetVersions -AppId $wingetId -CurrentVersion $currentVersion)
                                if ($known -notcontains $SpecificVersion) {
                                    Write-Warning "'$SpecificVersion' was not found in the filtered older-version list but will be used as requested."
                                }
                            }
                            catch { Write-Verbose "Older-version lookup skipped: $($_.Exception.Message)" }
                        }

                    } else {
                        # @() guard: a single older version must stay an array, or indexing below would
                        # slice characters out of the version STRING.
                        $olderVersions = @(Get-WingetVersions -AppId $wingetId -CurrentVersion $currentVersion)

                        # A run nobody can answer never reaches the version picker (test campaign F5): under
                        # -NonInteractive its Read-Host threw, the test had no verdict and packaging went on
                        # UNTESTED. An unattended run (-Unattended, SandboxTestMode / HyperVTestMode) or a host
                        # that cannot prompt (a service or redirected input, or a console started with
                        # -NonInteractive) uses the previous version, as -VersionsBack 1, and says so. A prompt
                        # the host still refuses (NonInteractive mode under a host not recognised here) does the same.
                        $versionsBackToUse = $VersionsBack
                        $noPromptWarning = 'No baseline version was given (-VersionsBack or -SpecificVersion) and this run cannot ask for one (an unattended run or a non-interactive host): the Update test uses the previous version (-VersionsBack 1). Pass -VersionsBack or -SpecificVersion to test from another version.'
                        if ($versionsBackToUse -le 0) {
                            $cannotAsk = [bool]$Unattended -or (Test-Win32ToolkitHostNonInteractive) -or (Test-Win32ToolkitNonInteractiveSwitch) -or
                                ((Get-Win32ToolkitTestMode -Backend $resolvedBackend -WarningAction SilentlyContinue) -eq 'Unattended')
                            if ($cannotAsk) {
                                Write-Warning $noPromptWarning
                                $versionsBackToUse = 1
                            }
                            else {
                                try {
                                    $targetVersion = Show-VersionSelection -Versions $olderVersions
                                }
                                catch {
                                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                    if ($_.FullyQualifiedErrorId -notlike '*,Microsoft.PowerShell.Commands.ReadHostCommand') { throw }
                                    Write-Verbose "The version picker could not prompt: $($_.Exception.Message)"
                                    Write-Warning $noPromptWarning
                                    $versionsBackToUse = 1
                                }
                            }
                        }

                        if ($versionsBackToUse -gt 0) {
                            if ($versionsBackToUse -gt $olderVersions.Count) {
                                throw "Requested $versionsBackToUse version(s) back but only $($olderVersions.Count) older version(s) are available for '$wingetId'."
                            }
                            $targetVersion = $olderVersions[$versionsBackToUse - 1]
                        }
                    }

                    Write-Host "Target version   : $targetVersion" -ForegroundColor Yellow

                    # ── Both (L13, D5): one Update run per technology at this version, each recorded ──
                    # The legs re-invoke this command with -SpecificVersion and a single-technology
                    # -BaselineInstallerType; the leg's Mode/Origin reach the inner run through a script-scoped
                    # context (no hidden parameter), cleared in finally.
                    if ($baselineMode -eq 'Both' -and $null -eq $script:W32TUpdateLegContext) {
                        Write-Host ''
                        Write-Host "Both technologies: $($legs.Count) Update run(s) of v$targetVersion, one per installer technology, each recorded separately:" -ForegroundColor Cyan
                        for ($i = 1; $i -le $legs.Count; $i++) { Write-Host ('  {0}. {1}' -f $i, $legs[$i - 1].Label) -ForegroundColor Cyan }
                        $sandboxWatched = $resolvedBackend -eq 'Sandbox' -and
                            (Get-Win32ToolkitTestMode -Backend Sandbox -Unattended:$Unattended) -eq 'Interactive'
                        $legVerdicts = [System.Collections.Generic.List[object]]::new()
                        for ($i = 1; $i -le $legs.Count; $i++) {
                            $leg = $legs[$i - 1]
                            $legVerdict = $null
                            $legRan = $true
                            if ($i -gt 1 -and $sandboxWatched) {
                                # Watched Sandbox runs stay open for verification; only one Sandbox may run.
                                Write-Host "Close the Windows Sandbox of the previous leg to start the $($leg.Family) leg" -ForegroundColor Yellow
                                if (-not (Wait-Win32ToolkitSandboxFree -TimeoutSeconds 600)) {
                                    Write-Warning "The Windows Sandbox of the previous leg is still open after 10 minutes: the $($leg.Family) leg did not run (no verdict)."
                                    $legRan = $false
                                }
                            }
                            if ($legRan) {
                                $innerArgs = @{}
                                foreach ($k in $PSBoundParameters.Keys) { $innerArgs[$k] = $PSBoundParameters[$k] }
                                [void]$innerArgs.Remove('VersionsBack')
                                $innerArgs['ProjectPath']           = $ProjectPath
                                $innerArgs['Scenario']              = 'Update'
                                $innerArgs['SpecificVersion']       = $targetVersion
                                $innerArgs['BaselineInstallerType'] = if ($leg.Origin -eq 'Packaged') { 'Packaged' } else { $leg.InstallerType }
                                Write-Host "`n=== Update test leg $i of $($legs.Count): $($leg.Label) ===" -ForegroundColor Cyan
                                try {
                                    $script:W32TUpdateLegContext = @{ Mode = 'Both'; Origin = $leg.Origin; Label = $leg.Label; Index = $i; Count = $legs.Count }
                                    $legVerdict = @(Test-Win32ToolkitProject @innerArgs) | Select-Object -Last 1
                                }
                                catch {
                                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                    Write-Warning "The $($leg.Family) leg of the Update test did not finish (no verdict): $($_.Exception.Message)"
                                    $legVerdict = $null
                                }
                                finally {
                                    $script:W32TUpdateLegContext = $null
                                }
                            }
                            $legVerdicts.Add($legVerdict)
                        }

                        Write-Host "`nUpdate test, one run per installer technology:" -ForegroundColor Cyan
                        for ($i = 1; $i -le $legs.Count; $i++) {
                            $lv = $legVerdicts[$i - 1]
                            $text, $color = if ($lv -eq $true) { 'PASSED', 'Green' } elseif ($lv -eq $false) { 'FAILED', 'Red' } else { 'NO VERDICT', 'Yellow' }
                            Write-Host ('  {0}. {1}: {2}' -f $i, $legs[$i - 1].Label, $text) -ForegroundColor $color
                        }
                        # Combined verdict: a failed leg fails the test; otherwise a leg without a verdict leaves it open.
                        if (@($legVerdicts | Where-Object { $_ -eq $false }).Count -gt 0) { return $false }
                        if (@($legVerdicts | Where-Object { $null -eq $_ }).Count -gt 0) { return $null }
                        return $true
                    }

                    # ── Step 4: Download the old-version installer, pinned to the leg's technology ──
                    # K5/K6: only 'no installer of that technology at this version' is handled here; every other
                    # error keeps the outer catch. Auto's sibling leg falls back, pinned and loudly, to the packaged
                    # technology (L2); otherwise the run has no verdict and says so in TestResults.json (L21).
                    $leg            = $legs[0]
                    $legMode        = if ($legContext) { 'Both' } else { $baselineMode }
                    $legOrigin      = if ($legContext -and $legContext.Origin) { [string]$legContext.Origin } else { [string]$leg.Origin }
                    $usedFallback   = $false
                    $fallbackReason = ''
                    $unavailable    = $null
                    $oldInstaller   = $null
                    $dl = @{
                        AppId         = $wingetId
                        Version       = $targetVersion
                        ProjectPath   = $ProjectPath
                        Architecture  = $architecture
                        InstallerType = [string]$leg.InstallerType
                        FamilyPin     = $true
                    }
                    if ($leg.Scope) { $dl['Scope'] = [string]$leg.Scope }
                    if (-not $leg.InstallerType) {
                        $unavailable = "No Update baseline can be downloaded: the packaged installer technology of this project cannot be pinned. $($leg.Note)".Trim()
                    }
                    else {
                        try {
                            $oldInstaller = Download-OldVersionInstaller @dl
                        }
                        catch {
                            if ($_.FullyQualifiedErrorId -ne 'W32T.InstallerVariantUnavailable') { throw }
                            if ($leg.FallbackInstallerType) {
                                $fbRow = Get-Win32ToolkitInstallerFamily -Type $leg.FallbackInstallerType
                                $legFamilyLabel = switch ([string]$leg.Family) { 'msi' { 'MSI' } 'exe' { 'vendor EXE' } 'msix' { 'MSIX package' } default { [string]$leg.Family } }
                                Write-Warning (("v{0} has no {1} installer for {2}; this Update test falls back to the packaged technology ({3}) and cannot show a technology switch. " +
                                    'Export keeps warning until a {1} baseline passes: pick a version that ships it (-SpecificVersion) or run -BaselineInstallerType {4}.') -f
                                    $targetVersion, $legFamilyLabel, $(if ($architecture) { $architecture } else { 'any architecture' }), $fbRow.Label, $leg.InstallerType)
                                $usedFallback   = $true
                                $fallbackReason = 'SiblingFamilyNotOfferedAtBaselineVersion'
                                $dl['InstallerType'] = [string]$leg.FallbackInstallerType
                                if ($leg.FallbackScope) { $dl['Scope'] = [string]$leg.FallbackScope } else { [void]$dl.Remove('Scope') }
                                try {
                                    $oldInstaller = Download-OldVersionInstaller @dl
                                }
                                catch {
                                    if ($_.FullyQualifiedErrorId -ne 'W32T.InstallerVariantUnavailable') { throw }
                                    $unavailable = $_.Exception.Message
                                }
                            }
                            else {
                                $unavailable = $_.Exception.Message
                            }
                        }
                    }

                    if ($null -ne $unavailable) {
                        # L21: no verdict. Recorded directly (never Write-Win32ToolkitTestOutcome, which would read a
                        # stale assertions log) and marked Unavailable, so it is listed but never judged.
                        Write-Warning $unavailable
                        $baselineInfo = @{
                            Version                = [string]$targetVersion
                            Mode                   = $legMode
                            Origin                 = $legOrigin
                            RequestedInstallerType = [string]$leg.InstallerType
                            InstallerType          = ''
                            Family                 = [string]$leg.Family
                            UsedFallback           = $usedFallback
                            FallbackReason         = $fallbackReason
                            RequestedScope         = [string]$leg.Scope
                            Scope                  = ''
                            ScopeRelaxed           = $false
                            Unavailable            = $true
                            Locale                 = ''
                            Source                 = 'winget'
                            ProjectName            = ''
                        }
                        try {
                            $null = Add-Win32ToolkitTestResult -ProjectPath $ProjectPath -Scenario 'Update' -Backend $resolvedBackend `
                                -Mode (Get-Win32ToolkitTestMode -Backend $resolvedBackend -Unattended:$Unattended) -Verdict 'Inconclusive' `
                                -Assertions @() -Notes "Baseline unavailable: $unavailable" -Baseline $baselineInfo
                        }
                        catch {
                            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                            Write-Warning "Could not record the test result to Documentation\TestResults.json: $($_.Exception.Message)"
                        }
                        Write-Host 'Update test: NO VERDICT (the baseline technology is not available at this version).' -ForegroundColor Yellow
                        return $null
                    }

                    $baselineType = if ($oldInstaller.ManifestInstallerType) { [string]$oldInstaller.ManifestInstallerType } else { [string]$dl['InstallerType'] }
                    $baselineInfo = @{
                        Version                = [string]$targetVersion
                        Mode                   = $legMode
                        Origin                 = $legOrigin
                        RequestedInstallerType = [string]$dl['InstallerType']
                        InstallerType          = $baselineType
                        Family                 = [string]$oldInstaller.Family
                        UsedFallback           = [bool]($usedFallback -or $oldInstaller.UsedFallback)
                        FallbackReason         = $fallbackReason
                        RequestedScope         = if ($dl.ContainsKey('Scope')) { [string]$dl['Scope'] } else { '' }
                        Scope                  = [string]$oldInstaller.Scope
                        ScopeRelaxed           = [bool]$oldInstaller.ScopeRelaxed
                        Unavailable            = $false
                        Locale                 = [string]$oldInstaller.Locale
                        Source                 = 'winget'
                        ProjectName            = ''
                    }
                    $usedNotes = @()
                    if ($baselineInfo.ScopeRelaxed) { $usedNotes += 'scope relaxed' }
                    if ($baselineInfo.UsedFallback) { $usedNotes += 'packaged-technology fallback' }
                    Write-Host ("Baseline used    : {0} ({1}){2}" -f $baselineInfo.InstallerType, $baselineInfo.Family,
                        $(if ($usedNotes) { ', ' + ($usedNotes -join ', ') } else { '' })) -ForegroundColor Gray
                }

                # ── Step 5: Ensure Countdown.ps1 exists (Sandbox WATCHED mode only) ──────
                # The in-guest WinForms countdown is a Windows Sandbox artifact. On Hyper-V the HOST
                # pauses instead (a Pause phase); an UNATTENDED Sandbox run drops the countdown entirely.
                $sbInteractive = $true
                if ($resolvedBackend -eq 'Sandbox') {
                    $sbInteractive = (Get-Win32ToolkitTestMode -Backend Sandbox -Unattended:$Unattended) -eq 'Interactive'
                    if ($sbInteractive) {
                        Write-Verbose 'Creating countdown script...'
                        $countdownPath = New-CountdownScript -ProjectPath $ProjectPath
                        Write-Host "✓ Countdown script : $countdownPath" -ForegroundColor Green
                    }
                }

                # Log collector — copies PSADT/MSI logs back to the project after the run
                $logCollectorPath = New-LogCollectorScript -ProjectPath $ProjectPath
                Write-Host "✓ Log collector    : $logCollectorPath" -ForegroundColor Green

                # ── Step 5b: Requirement script + in-sandbox assertions ──────────────────
                # Generate the update app's requirement script now (Get-Win32ToolkitRequirementRule
                # writes SupportFiles\UpdateRequirement.ps1 as a side effect) so the sandbox can prove
                # it detects a REAL old install: PreUpdate = requirement met on the old baseline,
                # PostUpdate = still met + tattoo holds the NEW version (the Intune detection rule).
                # With -SkipRequirementCheck the requirement assertions are SKIPped (tattoo still runs).
                if (-not $SkipRequirementCheck) {
                    $reqRule = Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath
                    if (-not $reqRule) {
                        Write-Warning 'No update requirement rule could be built for this project — the requirement assertions will be SKIPPED in the sandbox.'
                        # Remove a stale UpdateRequirement.ps1 from an earlier packaging so the sandbox
                        # doesn't assert against a rule that will not ship.
                        $staleReq = Join-Path $ProjectPath 'SupportFiles\UpdateRequirement.ps1'
                        if (Test-Path -LiteralPath $staleReq) {
                            Remove-Item -LiteralPath $staleReq -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                else {
                    Write-Warning 'Requirement check disabled (-SkipRequirementCheck).'
                }
                $assertionPath = New-UpdateAssertionScript -ProjectPath $ProjectPath `
                    -SkipRequirement:$SkipRequirementCheck -OldVersion $targetVersion `
                    -ExpectBaselineTattoo:$useBaselineProject
                Write-Host "✓ Assertion script : $assertionPath" -ForegroundColor Green

                # Fresh run: clear the assertions log and the ARP snapshot state from any previous run.
                $logsDir = Join-Path $ProjectPath 'Sandbox\Logs'
                foreach ($f in 'UpdateAssertions.log', 'PreBaselineArp.json', 'PreUpdateArpBaseline.json') {
                    $fp = Join-Path $logsDir $f
                    if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue }
                }

                # Baseline install command — BACKEND-NEUTRAL: the guest paths (C:\PSADT, C:\PSADTOld) are
                # identical under Sandbox mapped folders and the Hyper-V copy-in, so the same command
                # string drives both. Vendor baseline: exe/msi via Start-Process, msix/appx via
                # Add-AppxPackage (untrusted values escaped + argv-safe). Toolkit-package baseline: run its
                # Invoke-AppDeployToolkit.ps1 from C:\PSADTOld through the guest runner, so the baseline's
                # PSADT loads in its OWN process (the update then loads the new package's PSADT in another
                # one) — fixed guest paths, no untrusted splice.
                $installCmd = if ($useBaselineProject) {
                    "& 'C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1' -Path 'C:\PSADTOld\Invoke-AppDeployToolkit.ps1' -DeployMode Silent -Label baseline"
                } else {
                    Get-Win32ToolkitBaselineInstallCommand `
                        -InstallerSandboxPath "C:\PSADT\Sandbox\OldVersion\$($oldInstaller.InstallerName)" `
                        -InstallerType $oldInstaller.InstallerType `
                        -SilentArgs    $oldInstaller.SilentArgs
                }

                # ── Step 6 (Hyper-V): run the update sequence in the VM over PowerShell Direct ────
                # Exactly the Sandbox LogonCommand sequence, expressed as provider phases. The in-guest
                # WinForms Countdown becomes a HOST pause (dropped under -Unattended / HyperVTestMode).
                # The baseline project is copied to C:\PSADTOld by the provider (-BaselineProjectPath).
                if ($resolvedBackend -eq 'HyperV') {
                    $interactive = (Get-Win32ToolkitTestMode -Backend HyperV -Unattended:$Unattended) -eq 'Interactive'

                    # Dependencies FIRST — and before the PreBaseline snapshot, so the dependency's own
                    # Add/Remove-Programs entry is part of the baseline rather than looking like something
                    # the app under test installed (which would confuse the OldArpGone assertion).
                    $phases = @()
                    if ($depCount -gt 0) { $phases += @{ Label = 'Install dependencies'; Command = $depCommand; DepPhase = $true } }

                    # A toolkit-package baseline goes through the runner: end the phase with its exact exit
                    # code (single-quoted 'exit $LASTEXITCODE', literal for the guest). A vendor baseline
                    # command is unchanged.
                    $baselinePhase = @{ Label = "Install baseline v$targetVersion"; Command = $installCmd }
                    if ($useBaselineProject) {
                        $baselinePhase['Command']          = $installCmd + '; exit $LASTEXITCODE'
                        $baselinePhase['SuccessExitCodes'] = $psadtSuccessCodes
                    }
                    $phases += @(
                        @{ Label = 'Assert: PreBaseline';              Command = "& 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreBaseline" }
                        $baselinePhase
                        @{ Label = 'Assert: PreUpdate';                Command = "& 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreUpdate" }
                    )
                    # Every Hyper-V phase runs as SYSTEM in session 0. With a user logged on, PSADT's Auto
                    # mode still resolves normally there (session 0 alone does not force Silent), so the
                    # mode is forced explicitly ONLY for the interactive GUI phase (so the operator always
                    # sees the dialogs). Interactive=$true is also what makes the provider ensure a desktop
                    # and open vmconnect — without it the operator would be told to watch a VM window that
                    # never opens. The unattended update is an INTUNE-PARITY run: the published command
                    # line from a 32-bit parent with no -DeployMode, exactly as the IME launches it.
                    if ($interactive) {
                        $phases += @{ Label = 'Verify the OLD install in the VM window'; Pause = $true; Interactive = $true }
                        $phases += @{ Label = 'Update (PSADT GUI)'; Command = '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -DeploymentType Install -DeployMode Interactive -Label update; exit $LASTEXITCODE'; Interactive = $true; SuccessExitCodes = $psadtSuccessCodes }
                    }
                    else {
                        $phases += @{ Label = 'Update (Intune parity)'; Command = '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Install -Label update; exit $LASTEXITCODE'; SuccessExitCodes = $psadtSuccessCodes }
                    }
                    $phases += @(
                        @{ Label = 'Assert: PostUpdate'; Command = "& 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PostUpdate" }
                        @{ Label = 'CollectLogs';        Command = "& 'C:\PSADT\Sandbox\CollectLogs.ps1'"; IgnoreExit = $true }
                    )

                    $hvArgs = @{ ProjectPath = $ProjectPath; Phase = $phases; Output = @('Sandbox\Logs\*') }
                    if ($useBaselineProject) { $hvArgs['BaselineProjectPath'] = $BaselineProjectPath }

                    if ($interactive) { Write-Host "`nRunning an INTERACTIVE Update test in the Hyper-V VM (verify the old install in the vmconnect window, then press Enter)..." -ForegroundColor Cyan }
                    else { Write-Host "`nRunning an UNATTENDED Update test in the Hyper-V VM with the Intune command line (32-bit parent, SYSTEM)..." -ForegroundColor Cyan }
                    $runLog = Initialize-Win32ToolkitTestRunLog -ProjectPath $ProjectPath -Scenario 'Update' -Family ([string]$baselineInfo.Family)
                    if (-not (Invoke-Win32ToolkitHyperVRun @hvArgs)) {
                        Write-Warning 'The Hyper-V update run did not complete cleanly — see the warnings above.'
                    }
                    & $showExitCodes $runLog
                    # The logs came back with the copy-out: nothing to wait for.
                    $runFolder = & $saveRunLog $runLog 0

                    # The Hyper-V run is SYNCHRONOUS: UpdateAssertions.log already came back with
                    # Sandbox\Logs, so the waiter's first poll succeeds. If the copy-out silently failed
                    # there is nothing to wait FOR — bail instead of blocking the host for the 30-min default.
                    $assertLog = Join-Path $ProjectPath 'Sandbox\Logs\UpdateAssertions.log'
                    if (-not (Test-Path -LiteralPath $assertLog)) {
                        Write-Warning "No UpdateAssertions.log came back from the VM — the assertions never ran, or the copy-out failed. Check $ProjectPath\Sandbox\Logs and the phase warnings above."
                        Write-Win32ToolkitTestOutcome -ProjectPath $ProjectPath -Scenario 'Update' -Backend 'HyperV' -Mode $(if ($interactive) { 'Interactive' } else { 'Unattended' }) -Verdict $null -Notes 'Assertions log did not return from the VM.' -Baseline $baselineInfo -LogFolder $runFolder
                        return $null
                    }
                    $updVerdict = Wait-Win32ToolkitUpdateAssertion -ProjectPath $ProjectPath -Backend HyperV -TimeoutMinutes 1 -PollSeconds 1
                    Write-Win32ToolkitTestOutcome -ProjectPath $ProjectPath -Scenario 'Update' -Backend 'HyperV' -Mode $(if ($interactive) { 'Interactive' } else { 'Unattended' }) -Verdict $updVerdict -Baseline $baselineInfo -LogFolder $runFolder
                    if ($updVerdict -eq $false) { & $warnTechSwitch }
                    return $updVerdict
                }

                # ── Step 6 (Sandbox): build the .wsb config ───────────────────────────────
                $sandboxFolder     = Join-Path $ProjectPath 'Sandbox'
                $sandboxConfigFile = Join-Path $sandboxFolder 'UpdateDemo.wsb'
                $installCmdXml     = ConvertTo-XmlEncoded $installCmd

                # Mapped folders: project (RW) + optional read-only baseline (never mutate the raw
                # Projects\ copy). Order preserved: project first, then baseline (C:\PSADTOld).
                $mounts = @(@{ HostPath = $ProjectPath; GuestPath = 'C:\PSADT'; ReadOnly = $false })
                if ($useBaselineProject) {
                    $mounts += @{ HostPath = $BaselineProjectPath; GuestPath = 'C:\PSADTOld'; ReadOnly = $true }
                }

                # $installCmdXml is already XML-encoded (ConvertTo-XmlEncoded above); the rest of the
                # LogonCommand is static, XML-safe text. The builder XML-encodes the host paths.
                # Dependencies install FIRST — before the PreBaseline snapshot, so the dependency's own ARP
                # entry belongs to the baseline instead of looking like something the app under test added.
                # The update itself runs through the guest runner in its OWN process (a baseline project
                # or a 'project:' dependency would otherwise already have loaded PSADT into this one).
                $depPrefixXml = if ($depCount -gt 0) { "&amp; 'C:\PSADT\Sandbox\InstallDependencies.ps1'; " } else { '' }
                if ($sbInteractive) {
                    $logonCommandXml = "powershell.exe -NoExit -ExecutionPolicy Bypass -Command &quot;&amp; { try { ${depPrefixXml}&amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreBaseline; $installCmdXml; &amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreUpdate; &amp; 'C:\PSADT\Sandbox\Countdown.ps1'; &amp; 'C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1' -DeploymentType Install -Label update; &amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PostUpdate } finally { &amp; 'C:\PSADT\Sandbox\CollectLogs.ps1' } }&quot;"
                }
                else {
                    # Unattended: no -NoExit, no countdown, the PSADT update runs Silent, and the guest
                    # shuts down after log collection (5 s VSMB flush) so a chained run's guard clears.
                    $logonCommandXml = "powershell.exe -ExecutionPolicy Bypass -Command &quot;&amp; { try { ${depPrefixXml}&amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreBaseline; $installCmdXml; &amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreUpdate; &amp; 'C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1' -DeploymentType Install -DeployMode Silent -Label update; &amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PostUpdate } finally { &amp; 'C:\PSADT\Sandbox\CollectLogs.ps1'; Start-Sleep -Seconds 5; Stop-Computer -Force } }&quot;"
                }
                $sandboxConfigContent = New-Win32ToolkitSandboxConfig -Mount $mounts -LogonCommandXml $logonCommandXml
                Set-Content -Path $sandboxConfigFile -Value $sandboxConfigContent -Encoding UTF8
                Write-Host "✓ Sandbox config   : $sandboxConfigFile" -ForegroundColor Green

                # ── Step 7: Launch Windows Sandbox ────────────────────────────────────────
                Write-Host ''
                Write-Host 'Launching Windows Sandbox for the Update test...'           -ForegroundColor Cyan
                Write-Host '================================================'          -ForegroundColor Cyan
                Write-Host 'The sandbox will:'                                          -ForegroundColor White
                Write-Host '  0. Snapshot existing Add/Remove Programs entries (baseline)' -ForegroundColor DarkGray
                if ($useBaselineProject) {
                Write-Host "  1. Install the PREVIOUS toolkit package v$targetVersion (writes its tattoo)" -ForegroundColor Green
                } else {
                Write-Host "  1. Silently install v$targetVersion (old vendor baseline)" -ForegroundColor Green
                }
                if ($useBaselineProject) {
                Write-Host '  2. ASSERT: baseline tattoo = old version; requirement detects the old install' -ForegroundColor Cyan
                } elseif ($SkipRequirementCheck) {
                Write-Host '  2. (requirement-rule check skipped by request)'          -ForegroundColor DarkYellow
                } else {
                Write-Host '  2. ASSERT: update requirement rule detects the old install' -ForegroundColor Cyan
                }
                if ($sbInteractive) {
                Write-Host '  3. Show a 2-minute countdown — verify the old install'   -ForegroundColor Yellow
                Write-Host '  4. Run the PSADT package to perform the update'          -ForegroundColor Cyan
                } else {
                Write-Host '  3. (unattended: no countdown; the sandbox shuts down when done)' -ForegroundColor DarkYellow
                Write-Host '  4. SILENTLY run the PSADT package to perform the update' -ForegroundColor Cyan
                }
                Write-Host '  5. ASSERT: requirement still met; tattoo = new version; old ARP entry gone' -ForegroundColor Cyan
                Write-Host '  6. Copy PSADT/MSI logs to project\Sandbox\Logs'          -ForegroundColor Cyan
                if ($sbInteractive) {
                Write-Host '  7. Keep the sandbox open for final verification'         -ForegroundColor White
                } else {
                Write-Host '  7. Shut the sandbox down automatically'                  -ForegroundColor White
                }
                Write-Host '================================================'          -ForegroundColor Cyan

                $runLog = Initialize-Win32ToolkitTestRunLog -ProjectPath $ProjectPath -Scenario 'Update' -Family ([string]$baselineInfo.Family)
                $launched = (Invoke-Win32ToolkitTestRun -Backend Sandbox -SandboxConfigPath $sandboxConfigFile).Launched
                if ($launched) {
                    Write-Host "`n✓ Update test sandbox launched." -ForegroundColor Green
                } else {
                    Write-Warning "The sandbox did NOT auto-launch — start it manually by double-clicking: $sandboxConfigFile"
                }

                # ── Step 8: Wait for the in-sandbox assertions and report pass/fail ──────
                # The verdict is RETURNED ($true pass / $false fail / $null inconclusive) so callers
                # (finalize pipeline, TUI, automation) can gate on a failed update test.
                $updVerdict = Wait-Win32ToolkitUpdateAssertion -ProjectPath $ProjectPath
                & $showExitCodes $runLog
                $runFolder = & $saveRunLog $runLog $(if ($launched) { 60 } else { 0 })
                Write-Win32ToolkitTestOutcome -ProjectPath $ProjectPath -Scenario 'Update' -Backend 'Sandbox' `
                    -Mode $(if ($sbInteractive) { 'Interactive' } else { 'Unattended' }) -Verdict $updVerdict -Baseline $baselineInfo -LogFolder $runFolder
                if ($updVerdict -eq $false) { & $warnTechSwitch }
                return $updVerdict
            }
        }
    }
    catch {
        Write-Error "Test-Win32ToolkitProject failed: $($_.Exception.Message)"
    }
}
