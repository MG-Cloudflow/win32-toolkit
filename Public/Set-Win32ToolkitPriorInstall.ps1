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
          FromSiblingCapture
                          rules from the proposals of a sibling capture (Test-Win32ToolkitProject -Scenario SiblingCapture;
                          Source SiblingCapture), re-derived from the hash-verified capture records every time. Without
                          -ProposalId (Block or Report only): every High-confidence proposal without flags whose identity
                          is not a rule yet - the others are listed, never written, and an existing rule is never changed.
                          With -ProposalId: those proposals, one confirmation each; Enforce needs -ProposalId, an
                          Enforce-eligible proposal and records one approval per proposal (kept on the host). The window
                          is never typed: VersionMin is the oldest capture's observed version, VersionMax the newest one
                          of the same identity.
          SetMode         change the mode of existing rules (Block -> Enforce after the proof; Enforce -> Block in an
                          incident). A rule from a sibling capture becomes Enforce only through -FromSiblingCapture.
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
    .PARAMETER FromSiblingCapture
        Declare rules from the proposals of the project's sibling capture (Documentation\SiblingCapture\*.json).
    .PARAMETER ProposalId
        FromSiblingCapture: the proposals to apply (for example nsis-x64; the List and the capture name them). Required
        with -Mode Enforce: one confirmation and one approval per proposal.
    .PARAMETER Remove
        The ids of the rules to remove.
    .PARAMETER Waive
        PROOF (ship an Enforce rule without a proof), VERSIONMIN (no or a lower VersionMin than proven) or DISPLAYNAME
        (no display name) for -Target, with -Reason. Never for a rule from a sibling capture.
    .PARAMETER Acknowledge
        ID-PRIOR-DROPPED (a rule of the previous version is gone on purpose), DATA-LOSS (the prior's uninstaller deleted
        user data in the proof run, or - for a rule from a sibling capture - the capture's removability probe saw it delete
        configuration files in its install folder) or SIGNER-MISMATCH, for -Target, with -Reason.
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
        # After a sibling capture: Block every High, flag-free proposal; then approve one for removal
        Set-Win32ToolkitPriorInstall -ProjectPath $p -FromSiblingCapture -Mode Block
        Set-Win32ToolkitPriorInstall -ProjectPath $p -FromSiblingCapture -Mode Enforce -ProposalId nsis-x64
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
        [Parameter(Mandatory, ParameterSetName = 'FromSiblingCapture')]
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

        [Parameter(Mandatory, ParameterSetName = 'FromSiblingCapture')]
        [switch]$FromSiblingCapture,

        [Parameter(ParameterSetName = 'FromSiblingCapture')]
        [string[]]$ProposalId,

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
    # The current proposals, re-derived from the hash-verified capture records (spec 2.14.8): only when there are records.
    $sibling = $null
    if ($records.Count -gt 0) { $sibling = ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath -ProposalId ([string[]]@($ProposalId | Where-Object { $_ })) }
    $proposalHashes = [string[]]@(if ($sibling) { @($sibling.Proposals) | ForEach-Object { $_.ProposalHash } })

    # Lineage (SV5): Source SiblingCapture, a CaptureId, an Approval record for the id, or the identity (Tuple) of a
    # current proposal make a rule a captured one.
    $lineageOf = {
        param($E)
        $eid = [string](& $prop $E 'Id')
        if ([string](& $prop $E 'Source') -ceq 'SiblingCapture' -or [string](& $prop $E 'CaptureId') -or @($decisions | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -ceq $eid }).Count -gt 0) { return 'Capture' }
        if ($proposalHashes.Count -gt 0 -and $proposalHashes -ccontains (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $E)) { return 'Capture' }
        if ([string](& $prop $E 'Source') -ceq 'UpdateTest') { return 'UpdateTest' }
        return 'Operator'
    }
    $windowOf = {
        param($E)
        $lo = [string](& $prop $E 'VersionMin'); $hi = [string](& $prop $E 'VersionMax')
        if ($lo) { "$(& $safe $lo 64) <= version <= $(& $safe $hi 64)" } else { "version <= $(& $safe $hi 64)" }
    }
    $consequenceOf = {
        param($E, $Proposal = $null)
        $root = if ([string](& $prop $E 'View') -eq 'Wow6432') { 'HKLM\SOFTWARE\WOW6432Node\...\Uninstall' } else { 'HKLM\SOFTWARE\...\Uninstall' }
        $keyText = & $safe (& $prop $E 'Key')
        switch -CaseSensitive ([string](& $prop $E 'Mode')) {
            'Enforce' {
                $leaf = & $safe (& $prop $E 'UninstallerFileName') 64
                $switches = if ([string](& $prop $E 'UninstallerType') -eq 'inno') { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } else { '/S _?=<folder>' }
                "On devices with $root\$keyText (publisher $(& $safe (& $prop $E 'Publisher')), $(& $windowOf $E)) the package runs $leaf $switches in $(& $safe (& $prop $E 'InstallDir') 260) before it installs. A newer one fails the install (69102); an older or different one is left as it is; one in another folder fails the install (69105)."
            }
            'Block' {
                # The identity condition and what is left alone, as for Enforce (live row OP-UNPROVEN: "Devices with <key>
                # (<window>) FAIL" read as if any install under that key failed; the device leaves another publisher or name, or
                # an older version, as it is and installs).
                $who = "On devices with $root\$keyText (publisher $(& $safe (& $prop $E 'Publisher')), $(& $windowOf $E))"
                $rest = 'A newer one fails the install too (69102); an older or different one is left as it is and the install goes on.'
                # An identity a Windows Sandbox or assisted capture saw stays Block-only (live rows SB-CAPTURE and ASSISTED).
                if ($Proposal -and (@($Proposal.Flags) -contains 'Sandbox' -or @($Proposal.Flags) -contains 'Assisted')) { "$who this install FAILS (69101); this identity stays Block-only (a Windows Sandbox or assisted capture saw it). $rest" }
                else { "$who this install FAILS (69101) until the rule is Enforce. $rest" }
            }
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
                Consequence = & $consequenceOf $e $(if ($sibling) { $eTuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e; @(@($sibling.Proposals) | Where-Object { $_.ProposalHash -ceq $eTuple }) | Select-Object -First 1 })
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
        if ($sibling -and @($sibling.Proposals).Count -gt 0) {
            Write-Host 'Sibling-capture proposals (apply with -FromSiblingCapture -Mode <mode> -ProposalId <id>):' -ForegroundColor Cyan
            foreach ($p in @($sibling.Proposals)) {
                $applied = @($entries | Where-Object { (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $_) -ceq $p.ProposalHash }) | Select-Object -First 1
                $state = if ($applied) { "rule '$(& $safe (& $prop $applied 'Id') 40)' ($(& $safe (& $prop $applied 'Mode') 16))" } else { 'not applied' }
                $enforce = if ($p.EnforceEligible) { 'Enforce-eligible' } else { 'Block only' }
                $flagText = if (@($p.Flags).Count) { "; flags $(@($p.Flags) -join ', ')" } else { '' }
                # Live row GOAL-APPROVE: the probe's data loss showed only at Export. GOAL-EXPORT: once the rule's DATA-LOSS
                # acknowledgement is recorded, the line says so instead of asking for it again.
                # Only for an identity that can become Enforce (live row ASSISTED: a Block-only identity removes nothing).
                if ($p.DataLoss -and $p.EnforceEligible) {
                    $dlAck = $applied -and @($decisions | Where-Object { $_.Kind -eq 'Acknowledgement' -and $_.Code -eq 'DATA-LOSS' -and $_.Target -ceq [string](& $prop $applied 'Id') }).Count -gt 0
                    $flagText += if ($dlAck) { '; data loss (its uninstaller deletes configuration in its folder; acknowledged)' } else { '; data loss (its uninstaller deletes configuration in its folder: Enforce needs -Acknowledge DATA-LOSS)' }
                }
                Write-Host ("  {0,-12} {1} [{2}] {3} {4} <= version <= {5}; {6}, {7}, {8}; {9}{10}" -f $p.ProposalId, (& $safe $p.Key), $p.View, $p.SiblingType, $p.VersionMin, $p.VersionMax, $p.Confidence, $p.Track, $enforce, $state, $flagText)
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

    # ---- add / change: Enforce from a capture names its proposals (SV2) ----
    if ($set -eq 'FromSiblingCapture' -and $Mode -eq 'Enforce' -and @($ProposalId | Where-Object { $_ }).Count -eq 0) {
        throw (& $newError 'W32T.PriorInstallRefused' "A rule from a sibling capture becomes Enforce only by name, one approval per proposal: Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromSiblingCapture -Mode Enforce -ProposalId <id> (the List names the proposals). Nothing was written." ([System.Management.Automation.ErrorCategory]::PermissionDenied))
    }
    # ---- the project must have this catalog's remove-prior pair (D12, L3, L38, L39) ----
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

    $changed = [System.Collections.Generic.List[object]]::new()
    $newIdFor = {
        param([string]$Stem)
        $cand = $Stem; $n = 1
        while (@(@($entries) + @($changed) | Where-Object { [string](& $prop $_ 'Id') -ceq $cand }).Count -gt 0) { $n++; $cand = "$Stem-$n" }
        $cand
    }
    $proposalFor = @{}
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
        'FromSiblingCapture' {
            $props = @(if ($sibling) { @($sibling.Proposals) })
            if ($props.Count -eq 0) {
                throw (& $newError 'W32T.PriorInstallInvalid' "This project has no sibling-capture proposal: capture the other installer technologies first (Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario SiblingCapture). Nothing was written.")
            }
            $tupleOf = @{}
            foreach ($e in $entries) { $tupleOf[[string](& $prop $e 'Id')] = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e }
            $existingFor = { param($P) @($entries | Where-Object { $tupleOf[[string](& $prop $_ 'Id')] -ceq $P.ProposalHash }) | Select-Object -First 1 }
            $pick = [System.Collections.Generic.List[object]]::new()
            $wanted = @($ProposalId | Where-Object { $_ } | Select-Object -Unique)
            if ($wanted.Count -gt 0) {
                $known = [string[]]@($props | ForEach-Object { $_.ProposalId })
                $unknown = @($wanted | Where-Object { $known -cnotcontains $_ })
                if ($unknown.Count) { throw (& $newError 'W32T.PriorInstallInvalid' "No sibling-capture proposal $((@($unknown) | ForEach-Object { "'$(& $safe $_ 40)'" }) -join ', ') (proposals: $($known -join ', ')). Nothing was written.") }
                foreach ($w in $wanted) { $pick.Add((@($props | Where-Object { $_.ProposalId -ceq $w }))[0]) }
                if ($Mode -eq 'Enforce') {
                    $refused = @($pick | Where-Object { -not $_.EnforceEligible })
                    if ($refused.Count) {
                        $lines = @($refused | ForEach-Object { "$($_.ProposalId): $((@($_.IneligibleReasons) | ForEach-Object { & $safe $_ 200 }) -join '; ')" })
                        # A reason comes from a flag of a capture record of that identity, and a proposal carries the flags of all of
                        # its records: a later capture does not take it back (live rows SB-CAPTURE, GOAL-APPROVE), so no "capture again".
                        $tail = 'Apply it as Block (-FromSiblingCapture -Mode Block -ProposalId <id>): these reasons come from capture records of that identity and stay with it (a later capture does not take them back).'
                        throw (& $newError 'W32T.PriorInstallRefused' ("Not eligible for Enforce; nothing was written:`n  - " + ($lines -join "`n  - ") + "`n" + $tail) ([System.Management.Automation.ErrorCategory]::PermissionDenied))
                    }
                }
            }
            else {
                # The bulk form (spec 2.12 rule 7, B27): High, flag-free, and an identity that is not a rule yet.
                foreach ($p in $props) {
                    $ex = & $existingFor $p
                    $why = if ($ex) { "already a rule ('$(& $safe (& $prop $ex 'Id') 40)', $(& $safe (& $prop $ex 'Mode') 16)): changed only by -ProposalId" }
                    elseif ($p.Confidence -ne 'High') { 'Medium confidence: name it with -ProposalId' }
                    elseif (-not $p.FlagFree) { "flags: $(@($p.Flags) -join ', ')" }
                    else { '' }
                    if ($why) { Write-Host "  not applied: $($p.ProposalId) $(& $safe $p.Key) [$($p.View)] - $why" -ForegroundColor DarkGray }
                    else { $pick.Add($p) }
                }
                if ($pick.Count -eq 0) {
                    Write-Host 'No sibling-capture proposal to apply in bulk (each one is listed above with the reason).' -ForegroundColor Yellow
                    return @(& $listObjects)
                }
            }
            foreach ($p in $pick) {
                $ex = & $existingFor $p
                $below = if ($p.SameFamily) { $appVersion } else { '' }
                if ($ex) {
                    $c = $ex.PSObject.Copy()
                    $floorId = if ([string](& $prop $ex 'CaptureId')) { [string]$ex.CaptureId } else { $p.FloorCaptureId }
                    $w = Get-Win32ToolkitPriorInstallWindow -Captures $sibling.Captures -Tuple $p.ProposalHash -FloorCaptureId $floorId -Below $below
                    if (-not $w.Found) { $w = Get-Win32ToolkitPriorInstallWindow -Captures $sibling.Captures -Tuple $p.ProposalHash -FloorCaptureId $p.FloorCaptureId -Below $below }
                    foreach ($kv in @{ Mode = $Mode; Source = 'SiblingCapture'; CaptureId = $w.FloorCaptureId; Track = $p.Track; VersionMin = $w.VersionMin; VersionMax = $w.VersionMax }.GetEnumerator()) {
                        $c | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force
                    }
                }
                else {
                    $eid = & $newIdFor $p.ProposalId
                    $c = [pscustomobject][ordered]@{
                        Id = $eid; Kind = 'ArpKey'; Mode = $Mode; Key = $p.Key; View = $p.View; Publisher = $p.Publisher; DisplayName = $p.DisplayName
                        DisplayNameTemplate = $p.DisplayNameTemplate; VersionMin = $p.VersionMin; VersionMax = $p.VersionMax; UninstallerType = $p.UninstallerType
                        UninstallerFileName = $p.UninstallerFileName; UninstallerSigner = $p.UninstallerSigner; InstallDir = $p.InstallDir; MainExe = $p.MainExe
                        ProcessNames = [string[]]@($p.ProcessNames); Source = 'SiblingCapture'; CaptureId = $p.FloorCaptureId; Track = $p.Track; AddedOn = $today
                    }
                }
                $proposalFor[[string]$c.Id] = $p
                $changed.Add($c)
            }
        }
        'SetMode' {
            foreach ($i in @($Id | Where-Object { $_ })) {
                $e = @($entries | Where-Object { [string](& $prop $_ 'Id') -ceq $i }) | Select-Object -First 1
                if (-not $e) { throw (& $newError 'W32T.PriorInstallInvalid' "No prior-install rule '$(& $safe $i 40)' in this project.") }
                if ($Mode -eq 'Enforce' -and (& $lineageOf $e) -eq 'Capture') {
                    # The command names the current proposal of the rule's identity (proposal ids follow the records; a
                    # rule id need not be one), else the rule id.
                    $tupleNow = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e
                    $cur = @(if ($sibling) { @($sibling.Proposals) | Where-Object { $_.ProposalHash -ceq $tupleNow } }) | Select-Object -First 1
                    $propId = if ($cur) { [string]$cur.ProposalId } else { $i }
                    throw (& $newError 'W32T.PriorInstallRefused' "Rule '$(& $safe $i 40)' comes from a sibling capture: it becomes Enforce only through its proposal, one approval each: Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromSiblingCapture -Mode Enforce -ProposalId $propId" ([System.Management.Automation.ErrorCategory]::PermissionDenied))
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
        $same = @(if ($sibling) { @($sibling.Proposals) | Where-Object { $_.ProposalHash -ceq $tuple } }) | Select-Object -First 1
        if ($same) {
            throw (& $newError 'W32T.PriorInstallRefused' "This identity is the sibling-capture proposal '$($same.ProposalId)': a captured identity is declared only from its capture (Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromSiblingCapture -Mode <mode> -ProposalId $($same.ProposalId)). Nothing was written." ([System.Management.Automation.ErrorCategory]::PermissionDenied))
        }
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
    $resultOf = {
        param($Changes)
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($e in $entries) { if (@($Changes | Where-Object { $_.Id -ceq [string](& $prop $e 'Id') }).Count -eq 0) { $result.Add($e) } }
        foreach ($c in $Changes) { $result.Add($c) }
        $ids = [string[]]@($result | ForEach-Object { [string](& $prop $_ 'Id') })
        $order = [int[]]@(0..([Math]::Max(0, $result.Count - 1)))
        if ($result.Count -gt 1) { [Array]::Sort($ids, $order, [System.StringComparer]::Ordinal) }
        $sortedSet = @(if ($result.Count -gt 0) { $order | ForEach-Object { $result[$_] } })
        $newCfg = $cfg.PSObject.Copy()
        $newCfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = $sortedSet }) -Force
        $check = Test-Win32ToolkitPriorInstallEntry -Config $newCfg -Decisions $decisions -Records $records
        if (-not $check.Valid) {
            throw (& $newError 'W32T.PriorInstallInvalid' ("The prior-install rules would be invalid; nothing was written:`n  - " + (($check.Problems | ForEach-Object { & $safe $_ 400 }) -join "`n  - ")))
        }
        , $sortedSet
    }
    $sorted = & $resultOf $changed

    # Preview and the device consequence, then the confirmation: one per proposal for a capture (SV2), else one.
    $previewOf = {
        param($c)
        Write-Host ''
        Write-Host "Prior-install rule $($c.Id) ($($c.Mode), source $($c.Source)):" -ForegroundColor Cyan
        foreach ($f in 'Key', 'View', 'Publisher', 'DisplayName', 'DisplayNameTemplate', 'VersionMin', 'VersionMax', 'UninstallerType', 'UninstallerFileName', 'InstallDir', 'MainExe', 'UninstallerSigner') {
            $v = [string](& $prop $c $f)
            if ($v) { Write-Host ('  {0,-20}: {1}' -f $f, (& $safe $v 260)) }
        }
        if (@($c.ProcessNames).Count) { Write-Host ('  {0,-20}: {1}' -f 'ProcessNames', (& $safe (@($c.ProcessNames) -join ', ') 260)) }
        if ($proposalFor.ContainsKey([string]$c.Id)) {
            $pp = $proposalFor[[string]$c.Id]
            $flagText = if (@($pp.Flags).Count) { "; flags $(@($pp.Flags) -join ', ')" } else { '' }
            Write-Host ('  {0,-20}: {1}' -f 'Proposal', "$($pp.ProposalId) ($($pp.Confidence) confidence, $($pp.Track); captures $(@($pp.CaptureIds) -join ', ')$flagText)")
            # Live row GOAL-APPROVE: the data loss the removability probe saw is said before the approval, not first at Export -
            # for an identity that can become Enforce (live row ASSISTED: a Block-only identity never removes anything).
            if ($pp.DataLoss -and $pp.EnforceEligible) { Write-Host ('  {0,-20}: {1}' -f 'Data loss', 'the removability probe saw its uninstaller delete configuration in its install folder (RootConfigRemoved): Export of an Enforce rule needs -Acknowledge DATA-LOSS') -ForegroundColor Yellow }
        }
        $ppFor = if ($proposalFor.ContainsKey([string]$c.Id)) { $proposalFor[[string]$c.Id] } else { $null }
        Write-Host "  Device consequence  : $(& $consequenceOf $c $ppFor)" -ForegroundColor Yellow
    }
    $written = 0
    if ($set -eq 'FromSiblingCapture') {
        $accepted = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $changed) {
            & $previewOf $c
            if ($PSCmdlet.ShouldProcess([string]$c.Id, "Write the prior-install rule $($c.Id) ($($c.Mode)) from the sibling-capture proposal $($proposalFor[[string]$c.Id].ProposalId)")) { $accepted.Add($c) }
        }
        if ($accepted.Count -eq 0) { return @(& $listObjects) }
        if ($accepted.Count -ne $changed.Count) { $sorted = & $resultOf $accepted }
        $changed = $accepted
        # One approval per Enforce proposal (SV2), kept on the host; written before the rule it approves.
        foreach ($c in @($changed | Where-Object { $_.Mode -eq 'Enforce' })) {
            $pp = $proposalFor[[string]$c.Id]
            $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath -Record @{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = [string]$c.Id; Reason = ''; On = $today
                ProposalId = [string]$pp.ProposalId; ProposalHash = [string]$pp.ProposalHash; CaptureIds = @($pp.CaptureIds); Demoted = '' } -Confirm:$false
            Write-Host "Approval recorded: $($c.Id) = proposal $($pp.ProposalId) (Documentation\PriorInstallDecisions.json; kept on this computer, never shipped)." -ForegroundColor Green
        }
    }
    else {
        foreach ($c in $changed) { & $previewOf $c }
        $what = "Write $($changed.Count) prior-install rule(s) ($(@($changed | ForEach-Object { "$($_.Id) $($_.Mode)" }) -join ', '))"
        if (-not $PSCmdlet.ShouldProcess((@($changed | ForEach-Object { $_.Id }) -join ', '), $what)) { return @(& $listObjects) }
    }

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
        # Live row GOAL-APPROVE: what else Export needs that is known now (the proposal's data loss or signer mismatch) is said
        # here, not first when Export refuses.
        foreach ($c in @($changed | Where-Object { $_.Mode -eq 'Enforce' -and $proposalFor.ContainsKey([string]$_.Id) })) {
            $pp = $proposalFor[[string]$c.Id]
            $acked = { param([string]$Code) @($decisions | Where-Object { $_.Kind -eq 'Acknowledgement' -and $_.Code -eq $Code -and $_.Target -ceq [string]$c.Id }).Count -gt 0 }
            if ($pp.DataLoss -and -not (& $acked 'DATA-LOSS')) {
                Write-Host "Export also needs the data-loss acknowledgement (its uninstaller deletes configuration in its folder): Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -Acknowledge DATA-LOSS -Target $($c.Id) -Reason '<why>'" -ForegroundColor Yellow
            }
            if (@($pp.Flags) -contains 'SignerMismatch' -and -not (& $acked 'SIGNER-MISMATCH')) {
                Write-Host "Export also needs the signer acknowledgement (its uninstaller's signer differs from this package's): Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -Acknowledge SIGNER-MISMATCH -Target $($c.Id) -Reason '<why>'" -ForegroundColor Yellow
            }
        }
    }
    return @(& $listObjects)
}
