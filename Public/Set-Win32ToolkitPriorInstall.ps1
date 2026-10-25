function Set-Win32ToolkitPriorInstall {
    <#
    .SYNOPSIS
        Lists or sets the prior-install rules of a project: another installer technology of the app that the package
        refuses (Block), removes before it installs (Enforce) or only reports (Report).
    .DESCRIPTION
        A device can already have the app from ANOTHER installer technology (for example the vendor's NSIS setup of
        Notepad++ while the package installs the WiX MSI). Installing next to it leaves two registrations over one
        folder. A prior-install rule names that other install EXACTLY - its uninstall key in HKLM, the registry view,
        the publisher, the display name (or a {v} template) and a version window - and says what the package does when
        it finds it:

          Block    the install FAILS on such a device (exit code 69101) until the rule is Enforce;
          Enforce  the package runs that install's own uninstaller (NSIS '/S _?=<its folder>', Inno Setup
                   '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART') after the close-apps dialog and before it installs;
          Report   the device gets a marker (LastSeen) and the install goes on; nothing is removed.

        A device whose install is NEWER than the window fails with 69102; an exact key that is not the declared install
        (another publisher, name or version) is left as it is and the install goes on; a declared install in another
        folder than InstallDir fails with 69105. The rules are DATA in SupportFiles\AppConfig.json (PriorInstalls): the
        deploy script reads them when it runs. After a change, re-package (Export-Win32ToolkitIntuneWin) and publish the
        new .intunewin - a project created by this win32-toolkit version needs no re-creation. A project created before
        it has no remove-prior blocks: re-create it first (copy hand-written Install code out); this command refuses to
        write rules into it.

        An Enforce rule removes another vendor's install as SYSTEM, so Export refuses it until a Hyper-V Unattended
        Update test proved it (Test-Win32ToolkitProject -Scenario Update -Backend HyperV -TestMode Unattended), or an
        operator rule carries a PROOF waiver. Every rule needs the package's own identity, recorded by the install
        capture, and its process names are merged into ProcessesToClose so the close-apps dialog closes the app first.

        Parameter sets:
          List (default)  the rules, their source and lineage, their proof state, the decisions and what each does on a
                          device. Writes nothing.
          Manual          one rule typed by the operator (Source Operator).
          FromUpdateTest  a rule from the last failed Update test's candidates (Documentation\PriorInstallCandidates.json,
                          Source UpdateTest): the High candidate, or -CandidateKey.
          SetMode         change the mode of existing rules (Block -> Enforce after the proof; Enforce -> Block in an
                          incident).
          Remove          remove rules (the merged process names stay).
          Waive / Acknowledge / Revoke   host-side decisions (Documentation\PriorInstallDecisions.json; never shipped).

        Every write shows the resulting rule and its device consequence first and asks for confirmation (ConfirmImpact
        High; pass -Confirm:$false in scripts). -Mode has no default.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Mode
        Block, Enforce or Report (no default).
    .PARAMETER Key
        Manual: the exact uninstall key name under HKLM\SOFTWARE[\WOW6432Node]\Microsoft\Windows\CurrentVersion\Uninstall.
    .PARAMETER View
        Manual: Native (the 64-bit view) or Wow6432 (the 32-bit view).
    .PARAMETER Publisher
        Manual: the exact Publisher value of that key.
    .PARAMETER DisplayName
        Manual: the exact DisplayName value (or use -DisplayNameTemplate; an empty name needs a DISPLAYNAME waiver).
    .PARAMETER DisplayNameTemplate
        Manual: the DisplayName with the version replaced by exactly one {v} (for example 'Wireshark {v} x64').
    .PARAMETER VersionMin
        The lowest DisplayVersion the rule applies to (four parts, padded). FromUpdateTest: defaults to the version the
        test observed. A lower one is never removed (it is left as it is).
    .PARAMETER VersionMax
        The highest DisplayVersion the rule applies to; a newer install fails with 69102. For a package of the same
        technology family (an EXE package) it must be lower than the package version. FromUpdateTest: defaults to the
        observed version (same family) or the package version (another family).
    .PARAMETER UninstallerType
        Manual, Enforce: nullsoft or inno (selects the constant uninstall switches).
    .PARAMETER UninstallerFileName
        Manual, Enforce: the uninstaller's file name (for example uninstall.exe).
    .PARAMETER InstallDir
        Manual, Enforce: the install folder as %ProgramFiles%\<folder> or %ProgramFiles(x86)%\<folder>.
    .PARAMETER MainExe
        Manual, Enforce: the app's main program file in InstallDir (its absence makes the registration a leftover).
    .PARAMETER ProcessName
        The app's process names (no .exe; merged into ProcessesToClose).
    .PARAMETER UninstallerSigner
        Manual: the exact signer subject the uninstaller must have (Get-AuthenticodeSignature Valid).
    .PARAMETER Id
        The rule id (^[a-z0-9-]{1,40}$). Manual / FromUpdateTest: one id (default: derived, for example nsis-x64).
        SetMode: the rules to change.
    .PARAMETER FromUpdateTest
        Declare the rule from the last failed Update test's candidates.
    .PARAMETER CandidateKey
        FromUpdateTest: the uninstall key of the candidate to use when it is not the single High candidate.
    .PARAMETER Remove
        The ids of the rules to remove.
    .PARAMETER Waive
        PROOF (ship an Enforce rule without a proof), VERSIONMIN (no or a lower VersionMin than proven) or DISPLAYNAME
        (no display name) for -Target, with -Reason. Never for a rule from a sibling capture.
    .PARAMETER Acknowledge
        ID-PRIOR-DROPPED (a rule of the previous version is gone on purpose), DATA-LOSS (the prior's uninstaller deleted
        user data in the proof run) or SIGNER-MISMATCH, for -Target, with -Reason.
    .PARAMETER Revoke
        Remove the Waive or Acknowledge decision of that code for -Target.
    .PARAMETER Target
        The rule id a decision is about (it may be declared before the rule exists).
    .PARAMETER Reason
        Why (1-512 characters; kept on the host, never shipped).
    .OUTPUTS
        PSCustomObject[] - one per rule: Id, Mode, Kind, Key, View, Window, Source, Lineage, Proof, Decisions, Consequence.
    .EXAMPLE
        Set-Win32ToolkitPriorInstall -ProjectPath 'C:\Win32Apps\Projects\Contoso\Notepad++_x64_8.9.8.1'
    .EXAMPLE
        # Declare the vendor NSIS install the last Update test left behind, Block first
        Set-Win32ToolkitPriorInstall -ProjectPath $p -FromUpdateTest -Mode Block
    .EXAMPLE
        # After the Hyper-V proof run: remove it before installing
        Set-Win32ToolkitPriorInstall -ProjectPath $p -Id nsis-x64 -Mode Enforce
    .EXAMPLE
        Set-Win32ToolkitPriorInstall -ProjectPath $p -Mode Block -Key 'Notepad++' -View Native -Publisher 'Notepad++ Team' `
            -DisplayName 'Notepad++ (64-bit x64)' -VersionMin 8.7.9 -VersionMax 8.9.8.1
    .EXAMPLE
        Set-Win32ToolkitPriorInstall -ProjectPath $p -Acknowledge DATA-LOSS -Target nsis-x64 -Reason 'user settings live in %APPDATA%'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'List')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [Parameter(Mandatory, ParameterSetName = 'FromUpdateTest')]
        [Parameter(Mandatory, ParameterSetName = 'SetMode')]
        [ValidateSet('Block', 'Enforce', 'Report')]
        [string]$Mode,

        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [string]$Key,

        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [ValidateSet('Native', 'Wow6432')]
        [string]$View,

        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [string]$Publisher,

        [Parameter(ParameterSetName = 'Manual')]
        [AllowEmptyString()]
        [string]$DisplayName,

        [Parameter(ParameterSetName = 'Manual')]
        [string]$DisplayNameTemplate,

        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [Parameter(ParameterSetName = 'FromUpdateTest')]
        [AllowEmptyString()]
        [string]$VersionMin,

        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [Parameter(ParameterSetName = 'FromUpdateTest')]
        [string]$VersionMax,

        [Parameter(ParameterSetName = 'Manual')]
        [ValidateSet('nullsoft', 'inno')]
        [string]$UninstallerType,

        [Parameter(ParameterSetName = 'Manual')]
        [string]$UninstallerFileName,

        [Parameter(ParameterSetName = 'Manual')]
        [string]$InstallDir,

        [Parameter(ParameterSetName = 'Manual')]
        [string]$MainExe,

        [Parameter(ParameterSetName = 'Manual')]
        [Parameter(ParameterSetName = 'FromUpdateTest')]
        [string[]]$ProcessName,

        [Parameter(ParameterSetName = 'Manual')]
        [string]$UninstallerSigner,

        [Parameter(ParameterSetName = 'Manual')]
        [Parameter(ParameterSetName = 'FromUpdateTest')]
        [Parameter(Mandatory, ParameterSetName = 'SetMode')]
        [string[]]$Id,

        [Parameter(Mandatory, ParameterSetName = 'FromUpdateTest')]
        [switch]$FromUpdateTest,

        [Parameter(ParameterSetName = 'FromUpdateTest')]
        [string]$CandidateKey,

        [Parameter(Mandatory, ParameterSetName = 'Remove')]
        [string[]]$Remove,

        [Parameter(Mandatory, ParameterSetName = 'Waive')]
        [ValidateSet('PROOF', 'VERSIONMIN', 'DISPLAYNAME')]
        [string]$Waive,

        [Parameter(Mandatory, ParameterSetName = 'Acknowledge')]
        [ValidateSet('ID-PRIOR-DROPPED', 'DATA-LOSS', 'SIGNER-MISMATCH')]
        [string]$Acknowledge,

        [Parameter(Mandatory, ParameterSetName = 'Revoke')]
        [ValidateSet('PROOF', 'VERSIONMIN', 'DISPLAYNAME', 'ID-PRIOR-DROPPED', 'DATA-LOSS', 'SIGNER-MISMATCH')]
        [string]$Revoke,

        [Parameter(Mandatory, ParameterSetName = 'Waive')]
        [Parameter(Mandatory, ParameterSetName = 'Acknowledge')]
        [Parameter(Mandatory, ParameterSetName = 'Revoke')]
        [string]$Target,

        [Parameter(Mandatory, ParameterSetName = 'Waive')]
        [Parameter(Mandatory, ParameterSetName = 'Acknowledge')]
        [string]$Reason
    )

    $set = $PSCmdlet.ParameterSetName
    Write-Verbose "Set-Win32ToolkitPriorInstall: parameter set $set"
    $newError = {
        param([string]$Fqid, [string]$Message, [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidData)
        [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message), $Fqid, $Category, $ProjectPath)
    }
    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)

    try { $ProjectPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ProjectPath) }
    catch { Write-Verbose "ProjectPath not resolved ($($_.Exception.Message)); used as given." }
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1') -PathType Leaf)) {
        throw (& $newError 'W32T.PriorInstallInvalid' "Not a PSADT project (no Invoke-AppDeployToolkit.ps1): $ProjectPath")
    }
    $cfgFile = Join-Path $ProjectPath 'SupportFiles\AppConfig.json'
    $cfg = $null
    try { $cfg = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        throw (& $newError 'W32T.PriorInstallInvalid' "SupportFiles\AppConfig.json of $ProjectPath cannot be read ($(& $safe $_.Exception.Message 200)).")
    }
    if ($null -eq $cfg) { throw (& $newError 'W32T.PriorInstallInvalid' "SupportFiles\AppConfig.json of $ProjectPath is empty.") }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ })) { $entries.Add($e) }
    $decisions = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath)
    $records = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath)
    $appVersion = [string](& $prop (& $prop $cfg 'App') 'Version')
    $ownFamily = [string](& $prop (& $prop $cfg 'Installer') 'Type') -eq 'exe'

    # Lineage (SV5): Source SiblingCapture, a CaptureId, or an Approval record for the id make a rule a captured one.
    $lineageOf = {
        param($E)
        $eid = [string](& $prop $E 'Id')
        if ([string](& $prop $E 'Source') -ceq 'SiblingCapture' -or [string](& $prop $E 'CaptureId') -or @($decisions | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -ceq $eid }).Count -gt 0) { return 'Capture' }
        if ([string](& $prop $E 'Source') -ceq 'UpdateTest') { return 'UpdateTest' }
        return 'Operator'
    }
    $windowOf = {
        param($E)
        $lo = [string](& $prop $E 'VersionMin'); $hi = [string](& $prop $E 'VersionMax')
        if ($lo) { "$(& $safe $lo 64) <= version <= $(& $safe $hi 64)" } else { "version <= $(& $safe $hi 64)" }
    }
    $consequenceOf = {
        param($E)
        $root = if ([string](& $prop $E 'View') -eq 'Wow6432') { 'HKLM\SOFTWARE\WOW6432Node\...\Uninstall' } else { 'HKLM\SOFTWARE\...\Uninstall' }
        $keyText = & $safe (& $prop $E 'Key')
        switch -CaseSensitive ([string](& $prop $E 'Mode')) {
            'Enforce' {
                $leaf = & $safe (& $prop $E 'UninstallerFileName') 64
                $switches = if ([string](& $prop $E 'UninstallerType') -eq 'inno') { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } else { '/S _?=<folder>' }
                "On devices with $root\$keyText (publisher $(& $safe (& $prop $E 'Publisher')), $(& $windowOf $E)) the package runs $leaf $switches in $(& $safe (& $prop $E 'InstallDir') 260) before it installs. A newer one fails the install (69102); an older or different one is left as it is; one in another folder fails the install (69105)."
            }
            'Block' { "Devices with $root\$keyText ($(& $windowOf $E)) FAIL this install (69101) until the rule is Enforce." }
            'Report' { "Devices with $root\$keyText get a marker (LastSeen) and the install goes on; nothing is removed." }
            default { 'This rule is invalid: every device refuses the install (69105).' }
        }
    }
    $listObjects = {
        $states = @()
        try { $states = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Proof state not read: $($_.Exception.Message)"
        }
        $nowEntries = @(@(& $prop (& $prop (Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath) 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ })
        $nowDecisions = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath)
        foreach ($e in $nowEntries) {
            $eid = [string](& $prop $e 'Id')
            $st = @($states | Where-Object { $_.Id -ceq $eid }) | Select-Object -First 1
            $o = [pscustomobject][ordered]@{
                Id          = & $safe $eid 40
                Mode        = & $safe (& $prop $e 'Mode') 16
                Kind        = & $safe (& $prop $e 'Kind') 32
                Key         = & $safe (& $prop $e 'Key')
                View        = & $safe (& $prop $e 'View') 16
                Window      = & $windowOf $e
                Source      = & $safe (& $prop $e 'Source') 32
                Lineage     = & $lineageOf $e
                Proof       = if ($st) { [string]$st.State } else { '' }
                Decisions   = (@($nowDecisions | Where-Object { $_.Target -ceq $eid } | ForEach-Object { "$($_.Kind) $($_.Code)$(if ($_.Demoted) { ' (demoted)' })" }) -join ', ')
                Consequence = & $consequenceOf $e
            }
            $o.PSObject.Members.Add([System.Management.Automation.PSMemberSet]::new('PSStandardMembers', [System.Management.Automation.PSMemberInfo[]]@(
                        [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Id', 'Mode', 'Key', 'Proof')))))
            $o
        }
    }

    if ($set -eq 'List') {
        # A project created before PR 3 has no remove-prior blocks: it lists nothing and cannot take a rule until it is
        # re-created (D12). Said once here, as the write sets say it (live row LIVE-PREP: the List printed nothing).
        if ($entries.Count -eq 0) {
            $noRulesSaid = $false
            try {
                $listShape = Get-Win32ToolkitDeployScriptShape -Path (Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1')
                if ([int]$listShape.RemovePriorRevision -lt 1) { Write-Host 'No prior-install rules. This project was created before this win32-toolkit version (its deploy script has no remove-prior blocks): re-create it to declare one (Invoke-Win32Toolkit -Force or New-Win32ToolkitManualApp).' -ForegroundColor Yellow; $noRulesSaid = $true }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Deploy script shape not read: $($_.Exception.Message)"
            }
            # A current project with no rule (live rows RC2-BUILD, OP-BLOCK: the List printed nothing, also with the Update
            # test's candidate waiting): one line, and the candidates of the last failed Update test with the declare command.
            if (-not $noRulesSaid) {
                Write-Host 'No prior-install rules in this project.' -ForegroundColor Gray
                try {
                    $candFile = Join-Path $ProjectPath 'Documentation\PriorInstallCandidates.json'
                    if ((Test-Path -LiteralPath $candFile -PathType Leaf) -and (Get-Item -LiteralPath $candFile).Length -le 1MB) {
                        $listCands = @(@(& $prop (Get-Content -LiteralPath $candFile -Raw -Encoding UTF8 | ConvertFrom-Json) 'Candidates') | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and (& $prop $_ 'WindowsInstaller') -ne $true })
                        $listHigh = @($listCands | Where-Object { [string](& $prop $_ 'Confidence') -eq 'High' })
                        foreach ($lc in $listCands) {
                            $lcKey = & $safe (& $prop $lc 'Key')
                            $lcPick = if ($listHigh.Count -eq 1 -and [object]::ReferenceEquals($listHigh[0], $lc)) { '' } else { " -CandidateKey '$($lcKey -replace "'", "''")'" }
                            Write-Host "The last Update test left the prior-install candidate $(& $safe (& $prop $lc 'ProposedId') 40) ($(& $safe (& $prop $lc 'Confidence') 8)) - $lcKey [$(& $safe (& $prop $lc 'View') 16)] $(& $safe (& $prop $lc 'ObservedVersion') 64), publisher $(& $safe (& $prop $lc 'Publisher')). Declare it (Block first): Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromUpdateTest -Mode Block$lcPick" -ForegroundColor Yellow
                        }
                    }
                }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    Write-Verbose "Prior-install candidates not read: $($_.Exception.Message)"
                }
            }
        }
        return @(& $listObjects)
    }

    if (Test-Path -LiteralPath (Join-Path $ProjectPath 'Documentation\NotConfigured.json')) {
        throw (& $newError 'W32T.PriorInstallRefused' "This manual app is not completed yet (Documentation\NotConfigured.json): run Complete-Win32ToolkitManualApp first." ([System.Management.Automation.ErrorCategory]::InvalidOperation))
    }

    # ---- decisions (host-side records) ----
    if ($set -in 'Waive', 'Acknowledge', 'Revoke') {
        if ($Target -cnotmatch '^[a-z0-9-]{1,40}$') { throw (& $newError 'W32T.PriorInstallInvalid' "-Target must be a rule id (^[a-z0-9-]{1,40}$), not '$(& $safe $Target 60)'.") }
        $code = switch ($set) { 'Waive' { $Waive } 'Acknowledge' { $Acknowledge } default { $Revoke } }
        $kind = if ($code -in 'PROOF', 'VERSIONMIN', 'DISPLAYNAME') { 'Waiver' } else { 'Acknowledgement' }
        if ($set -ne 'Revoke') {
            if ($Reason.Length -lt 1 -or $Reason.Length -gt 512 -or (& $safe $Reason 512) -cne $Reason.Trim()) { throw (& $newError 'W32T.PriorInstallInvalid' '-Reason must be 1-512 characters without control characters.') }
            $tgt = @($entries | Where-Object { [string](& $prop $_ 'Id') -ceq $Target }) | Select-Object -First 1
            $isCapture = ($tgt -and (& $lineageOf $tgt) -eq 'Capture') -or @($decisions | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -ceq $Target }).Count -gt 0
            if ($kind -eq 'Waiver' -and $isCapture) {
                throw (& $newError 'W32T.PriorInstallRefused' "Rule '$Target' comes from a sibling capture: a $code waiver is never allowed for it (its proof, version window and name come from the capture; re-capture or prove it instead)." ([System.Management.Automation.ErrorCategory]::PermissionDenied))
            }
        }
        $rec = @{ Kind = $kind; Code = $code; Target = $Target; Reason = $(if ($set -eq 'Revoke') { '' } else { $Reason.Trim() }); On = $today }
        $action = if ($set -eq 'Revoke') { "Revoke the $code $($kind.ToLowerInvariant()) of '$Target'" } else { "Record a $code $($kind.ToLowerInvariant()) for '$Target'" }
        if ($PSCmdlet.ShouldProcess($Target, $action)) {
            $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath -Record $rec -Remove:($set -eq 'Revoke') -Confirm:$false
            Write-Host "$action (Documentation\PriorInstallDecisions.json; kept on this computer, never shipped)." -ForegroundColor Green
        }
        return @(& $listObjects)
    }

    # ---- remove ----
    if ($set -eq 'Remove') {
        $gone = @($entries | Where-Object { @($Remove) -ccontains [string](& $prop $_ 'Id') })
        $knownIds = [string[]]@($entries | ForEach-Object { [string](& $prop $_ 'Id') })
        foreach ($r in @($Remove | Where-Object { $_ -and $knownIds -cnotcontains $_ })) { Write-Warning "No prior-install rule '$(& $safe $r 40)' in this project." }
        if ($gone.Count -gt 0 -and $PSCmdlet.ShouldProcess((($gone | ForEach-Object { [string](& $prop $_ 'Id') }) -join ', '), 'Remove the prior-install rule(s)')) {
            $keep = @($entries | Where-Object { @($Remove) -cnotcontains [string](& $prop $_ 'Id') })
            $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = @($keep) }) -Force
            $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg -Confirm:$false
            $kept = @(@(& $prop $cfg 'ProcessesToClose') | Where-Object { $_ })
            Write-Host "Removed $($gone.Count) prior-install rule(s). The process names stay in ProcessesToClose ($(& $safe ($kept -join ', ') 200)): a name with no running process is harmless." -ForegroundColor Green
            Write-Host 'Re-package (Export-Win32ToolkitIntuneWin) and publish the new .intunewin for devices to get the change.' -ForegroundColor Cyan
        }
        return @(& $listObjects)
    }

    # ---- add / change: the project must have this catalog's remove-prior pair (D12, L3, L38, L39) ----
    $shape = Get-Win32ToolkitDeployScriptShape -Path (Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1')
    $catalogRevision = Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision
    if ($shape.RemovePriorRevision -lt 1 -or $shape.RemovePriorRevision -ne $catalogRevision -or -not $shape.PriorCheckFirst) {
        $why = if ($shape.RemovePriorRevision -lt 1) { 'its deploy script has no remove-prior blocks (it was created before this win32-toolkit version)' }
        elseif ($shape.RemovePriorRevision -ne $catalogRevision) { "its remove-prior blocks are catalog revision $($shape.RemovePriorRevision), this version writes revision $catalogRevision" }
        else { 'a dialog of the deploy script runs before its prior-check block (no org template dialogs, or a hand-written welcome in Pre-Install)' }
        throw (& $newError 'W32T.PriorInstallSlotsMissing' "No prior-install rule can be written into $ProjectPath`: $why. Re-create the project with this win32-toolkit version (Invoke-Win32Toolkit -Force or New-Win32ToolkitManualApp; copy hand-written Install code out first: re-creating deletes the folder). Nothing was written." ([System.Management.Automation.ErrorCategory]::InvalidOperation))
    }
    # A known own identity first (L28): no rule may ever name the package's own uninstall entry.
    $own = & $prop $cfg 'OwnIdentity'
    $uninstall = & $prop $cfg 'Uninstall'
    $ownKnown = ($own -and ([string](& $prop $own 'ProductCode') -or [string](& $prop $own 'UpgradeCode') -or @(& $prop $own 'ArpKeys' | Where-Object { $_ }).Count -gt 0)) -or
        @(& $prop $uninstall 'PrimaryKeys' | Where-Object { $_ }).Count -gt 0 -or @(& $prop $uninstall 'ProductCodes' | Where-Object { $_ }).Count -gt 0
    if (-not $ownKnown) {
        throw (& $newError 'W32T.PriorInstallRefused' "This project's own uninstall identity is not known yet: run the install capture first (Invoke-Win32Toolkit / Complete-Win32ToolkitManualApp). Nothing was written." ([System.Management.Automation.ErrorCategory]::InvalidOperation))
    }
    if ($set -in 'Manual', 'FromUpdateTest' -and $PSBoundParameters.ContainsKey('Id') -and @($Id).Count -ne 1) {
        throw (& $newError 'W32T.PriorInstallInvalid' '-Id takes exactly one rule id when a rule is added.')
    }

    $newIdFor = {
        param([string]$Stem)
        $cand = $Stem; $n = 1
        while (@($entries | Where-Object { [string](& $prop $_ 'Id') -ceq $cand }).Count -gt 0) { $n++; $cand = "$Stem-$n" }
        $cand
    }
    $changed = [System.Collections.Generic.List[object]]::new()
    switch ($set) {
        'Manual' {
            if ($PSBoundParameters.ContainsKey('DisplayName') -and $DisplayName -and $DisplayNameTemplate) { throw (& $newError 'W32T.PriorInstallInvalid' 'Give -DisplayName or -DisplayNameTemplate, not both.') }
            $arch = if ($View -eq 'Wow6432') { 'x86' } else { 'x64' }
            $stem = switch ($UninstallerType) { 'nullsoft' { "nsis-$arch" } 'inno' { "inno-$arch" } default { "exe-$arch" } }
            $eid = if ($PSBoundParameters.ContainsKey('Id')) { [string]@($Id)[0] } else { & $newIdFor $stem }
            if (-not $DisplayName -and -not $DisplayNameTemplate -and @($decisions | Where-Object { $_.Kind -eq 'Waiver' -and $_.Code -eq 'DISPLAYNAME' -and $_.Target -ceq $eid }).Count -eq 0) {
                throw (& $newError 'W32T.PriorInstallInvalid' "Give -DisplayName or -DisplayNameTemplate (or record a DISPLAYNAME waiver for '$eid' first).")
            }
            $changed.Add([pscustomobject][ordered]@{
                    Id = $eid; Kind = 'ArpKey'; Mode = $Mode; Key = $Key; View = $View; Publisher = $Publisher; DisplayName = $(if ($DisplayNameTemplate) { '' } else { [string]$DisplayName })
                    DisplayNameTemplate = [string]$DisplayNameTemplate; VersionMin = [string]$VersionMin; VersionMax = $VersionMax; UninstallerType = [string]$UninstallerType
                    UninstallerFileName = [string]$UninstallerFileName; UninstallerSigner = [string]$UninstallerSigner; InstallDir = [string]$InstallDir; MainExe = [string]$MainExe
                    ProcessNames = [string[]]@($ProcessName | Where-Object { $_ }); Source = 'Operator'; Track = 'Current'; AddedOn = $today
                })
        }
        'FromUpdateTest' {
            $candFile = Join-Path $ProjectPath 'Documentation\PriorInstallCandidates.json'
            $doc = $null
            try { if ((Get-Item -LiteralPath $candFile -ErrorAction Stop).Length -le 1MB) { $doc = Get-Content -LiteralPath $candFile -Raw -Encoding UTF8 | ConvertFrom-Json } }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $doc = $null
            }
            $cands = @(@(& $prop $doc 'Candidates') | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })
            if ($cands.Count -eq 0) { throw (& $newError 'W32T.PriorInstallInvalid' 'No prior-install candidates: run an Update test whose old version is another installer technology first (Test-Win32ToolkitProject -Scenario Update -BaselineInstallerType <type>); a failed OldArpGone writes Documentation\PriorInstallCandidates.json.') }
            $listing = ($cands | ForEach-Object { "$(& $safe (& $prop $_ 'Key')) [$(& $safe (& $prop $_ 'View') 16)] $(& $safe (& $prop $_ 'Confidence') 8)" }) -join '; '
            $pick = if ($CandidateKey) { @($cands | Where-Object { [string]::Equals([string](& $prop $_ 'Key'), $CandidateKey, [StringComparison]::OrdinalIgnoreCase) }) }
            else { @($cands | Where-Object { [string](& $prop $_ 'Confidence') -eq 'High' }) }
            if ($pick.Count -ne 1) { throw (& $newError 'W32T.PriorInstallInvalid' "Choose the candidate with -CandidateKey (one is needed; candidates: $listing).") }
            $c = $pick[0]
            if ((& $prop $c 'WindowsInstaller') -eq $true) { throw (& $newError 'W32T.PriorInstallInvalid' "The candidate $(& $safe (& $prop $c 'Key')) is registered by Windows Installer: it is not a prior install of this kind (an MSI prior comes with a later version). Nothing was written.") }
            # Live row RC2-BLOCK: a key a rule already names was refused under a made-up id ('nsis-x64-2: another entry names
            # the same uninstall key'). Name the rule (a write under that rule's own -Id replaces it).
            $namedBy = @($entries | Where-Object { [string](& $prop $_ 'View') -ceq [string](& $prop $c 'View') -and [string]::Equals([string](& $prop $_ 'Key'), [string](& $prop $c 'Key'), [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
            # A captured rule is refused below with its own reason (lineage, SV5).
            if ($namedBy -and (& $lineageOf $namedBy) -ne 'Capture' -and -not ($PSBoundParameters.ContainsKey('Id') -and [string]@($Id)[0] -ceq [string](& $prop $namedBy 'Id'))) {
                $nid = & $safe (& $prop $namedBy 'Id') 40
                throw (& $newError 'W32T.PriorInstallInvalid' ("The candidate $(& $safe (& $prop $c 'Key')) [$(& $safe (& $prop $c 'View') 16)] is already the $(& $safe (& $prop $namedBy 'Mode') 16) rule '$nid': change its mode (Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -Id $nid -Mode <mode>), " +
                        "or replace it from this candidate (Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromUpdateTest -Id $nid -Mode $(& $safe (& $prop $namedBy 'Mode') 16); add -VersionMin / -VersionMax to keep its window). Nothing was written."))
            }
            $observed = & $safe (& $prop $c 'ObservedVersion') 64
            $eid = if ($PSBoundParameters.ContainsKey('Id')) { [string]@($Id)[0] } else { & $newIdFor ([string](& $prop $c 'ProposedId') -replace '-\d+$', '') }
            $max = if ($PSBoundParameters.ContainsKey('VersionMax')) { $VersionMax } elseif ($ownFamily) { $observed } else { $appVersion }
            $changed.Add([pscustomobject][ordered]@{
                    Id = $eid; Kind = 'ArpKey'; Mode = $Mode; Key = [string](& $prop $c 'Key'); View = [string](& $prop $c 'View'); Publisher = & $safe (& $prop $c 'Publisher')
                    DisplayName = & $safe (& $prop $c 'DisplayName'); DisplayNameTemplate = & $safe (& $prop $c 'DisplayNameTemplate')
                    VersionMin = $(if ($PSBoundParameters.ContainsKey('VersionMin')) { $VersionMin } else { $observed }); VersionMax = $max
                    UninstallerType = [string](& $prop $c 'UninstallerType'); UninstallerFileName = [string](& $prop $c 'UninstallerFileName'); UninstallerSigner = ''
                    InstallDir = [string](& $prop $c 'InstallDir'); MainExe = [string](& $prop $c 'MainExe')
                    ProcessNames = [string[]]@(if ($PSBoundParameters.ContainsKey('ProcessName')) { $ProcessName | Where-Object { $_ } } else { @(& $prop $c 'ProcessNames') | Where-Object { $_ } })
                    Source = 'UpdateTest'; Track = 'Current'; AddedOn = $today
                })
        }
        'SetMode' {
            foreach ($i in @($Id | Where-Object { $_ })) {
                $e = @($entries | Where-Object { [string](& $prop $_ 'Id') -ceq $i }) | Select-Object -First 1
                if (-not $e) { throw (& $newError 'W32T.PriorInstallInvalid' "No prior-install rule '$(& $safe $i 40)' in this project.") }
                if ($Mode -eq 'Enforce' -and (& $lineageOf $e) -eq 'Capture') {
                    throw (& $newError 'W32T.PriorInstallRefused' "Rule '$i' comes from a sibling capture: it becomes Enforce only through its proposal, one approval each: Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromSiblingCapture -Mode Enforce -ProposalId $i" ([System.Management.Automation.ErrorCategory]::PermissionDenied))
                }
                $copy = $e.PSObject.Copy()
                # A hand-edited rule may have no Mode property at all (the set is validated below); an existing one keeps
                # its place, so the file changes by the mode only.
                if ($copy.PSObject.Properties['Mode']) { $copy.Mode = $Mode } else { $copy | Add-Member -NotePropertyName Mode -NotePropertyValue $Mode }
                $changed.Add($copy)
            }
        }
    }

    # Lineage (SV5): an operator or Update-test write never replaces a captured rule, by id or by identity.
    if ($set -in 'Manual', 'FromUpdateTest') {
        $n = $changed[0]
        $tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $n
        foreach ($e in $entries) {
            if ((& $lineageOf $e) -ne 'Capture') { continue }
            if ([string](& $prop $e 'Id') -ceq $n.Id -or (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e) -ceq $tuple) {
                throw (& $newError 'W32T.PriorInstallRefused' "Rule '$(& $safe (& $prop $e 'Id') 40)' comes from a sibling capture and has this id or identity: change it through its proposal (Set-Win32ToolkitPriorInstall -FromSiblingCapture). Nothing was written." ([System.Management.Automation.ErrorCategory]::PermissionDenied))
            }
        }
    }
    if (@($changed | Where-Object { $_.Mode -eq 'Enforce' }).Count -gt 0 -and -not $own) {
        throw (& $newError 'W32T.PriorInstallRefused' "An Enforce rule needs this package's own identity (OwnIdentity, written by the install capture): run the install capture first. Nothing was written." ([System.Management.Automation.ErrorCategory]::InvalidOperation))
    }

    # The resulting set, validated as a whole (the spec 2.1 rules, decisions and capture records bound).
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $entries) { if (@($changed | Where-Object { $_.Id -ceq [string](& $prop $e 'Id') }).Count -eq 0) { $result.Add($e) } }
    foreach ($c in $changed) { $result.Add($c) }
    $ids = [string[]]@($result | ForEach-Object { [string](& $prop $_ 'Id') })
    $order = [int[]]@(0..([Math]::Max(0, $result.Count - 1)))
    if ($result.Count -gt 1) { [Array]::Sort($ids, $order, [System.StringComparer]::Ordinal) }
    $sorted = @(if ($result.Count -gt 0) { $order | ForEach-Object { $result[$_] } })
    $newCfg = $cfg.PSObject.Copy()
    $newCfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = $sorted }) -Force
    $check = Test-Win32ToolkitPriorInstallEntry -Config $newCfg -Decisions $decisions -Records $records
    if (-not $check.Valid) {
        throw (& $newError 'W32T.PriorInstallInvalid' ("The prior-install rules would be invalid; nothing was written:`n  - " + (($check.Problems | ForEach-Object { & $safe $_ 400 }) -join "`n  - ")))
    }

    # Preview and the device consequence, then one confirmation per changed rule.
    $written = 0
    foreach ($c in $changed) {
        Write-Host ''
        Write-Host "Prior-install rule $($c.Id) ($($c.Mode), source $($c.Source)):" -ForegroundColor Cyan
        foreach ($f in 'Key', 'View', 'Publisher', 'DisplayName', 'DisplayNameTemplate', 'VersionMin', 'VersionMax', 'UninstallerType', 'UninstallerFileName', 'InstallDir', 'MainExe', 'UninstallerSigner') {
            $v = [string](& $prop $c $f)
            if ($v) { Write-Host ('  {0,-20}: {1}' -f $f, (& $safe $v 260)) }
        }
        if (@($c.ProcessNames).Count) { Write-Host ('  {0,-20}: {1}' -f 'ProcessNames', (& $safe (@($c.ProcessNames) -join ', ') 260)) }
        Write-Host "  Device consequence  : $(& $consequenceOf $c)" -ForegroundColor Yellow
    }
    $what = "Write $($changed.Count) prior-install rule(s) ($(@($changed | ForEach-Object { "$($_.Id) $($_.Mode)" }) -join ', '))"
    if (-not $PSCmdlet.ShouldProcess((@($changed | ForEach-Object { $_.Id }) -join ', '), $what)) { return @(& $listObjects) }

    $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = $sorted }) -Force
    $addedNames = @(Add-Win32ToolkitPriorInstallProcessName -Config $cfg)
    $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg -Confirm:$false
    $written = $changed.Count
    foreach ($c in $changed) { Write-Host "Prior-install rule written: $($c.Id) ($($c.Mode)) $(& $safe $c.Key) [$($c.View)]" -ForegroundColor Green }
    if ($addedNames.Count) {
        # Live rows OP-BLOCK, RC2-BLOCK, ASSISTED: a Block rule removes nothing (it refuses before the dialog).
        $closeWhy = if (@($changed | Where-Object { $_.Mode -eq 'Enforce' }).Count -gt 0) { 'the close-apps dialog closes the app before the removal' }
        elseif (@($changed | Where-Object { $_.Mode -eq 'Block' }).Count -gt 0) { 'the close-apps dialog closes the app before an Enforce rule removes that install (a Block rule refuses before the dialog and removes nothing)' }
        else { 'the close-apps dialog closes the app before the install' }
        Write-Host "ProcessesToClose gains $($addedNames -join ', '): $closeWhy." -ForegroundColor Green
    }
    Write-Host 'The rules are data in SupportFiles\AppConfig.json; the deploy script reads them when it runs. Re-package (Export-Win32ToolkitIntuneWin) and publish the new .intunewin - no project re-creation is needed for a project created by this version.' -ForegroundColor Cyan
    if (@($changed | Where-Object { $_.Mode -eq 'Enforce' }).Count -gt 0 -and $written -gt 0) {
        $groups = @(Get-Win32ToolkitPriorProofGroup -ProjectPath $ProjectPath)
        $groupArg = if ($groups.Count -gt 1) { ' -ProofEntryId ' + ((@($groups | Where-Object { @($_.EntryIds | Where-Object { @($changed.Id) -ccontains $_ }).Count -gt 0 }) | Select-Object -First 1).EntryIds -join ',') } else { '' }
        # Only for a rule that is not proven yet (live rows OP-EXPORT and RC2-PROOF: a switch back to Enforce whose earlier
        # proof still binds was told to prove it again). A proof state that cannot be read asks for the proof.
        $enforcedIds = [string[]]@($changed | Where-Object { $_.Mode -eq 'Enforce' } | ForEach-Object { [string]$_.Id })
        $provenIds = [string[]]@()
        try { $provenIds = [string[]]@(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath | Where-Object { $enforcedIds -ccontains [string]$_.Id -and $_.State -eq 'Proven' } | ForEach-Object { [string]$_.Id }) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Proof state not read: $($_.Exception.Message)"
        }
        if ($provenIds.Count -eq $enforcedIds.Count) { Write-Host "Proven: $($provenIds -join ', ') (a Hyper-V Unattended Update test already proved this package with these rules)." -ForegroundColor Green }
        else { Write-Host "Prove it: Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario Update -Backend HyperV -TestMode Unattended$groupArg" -ForegroundColor Yellow }
    }
    return @(& $listObjects)
}
