function Get-Win32ToolkitPriorInstallCandidate {
    <#
    .SYNOPSIS
        Turns the old installs an Update test left behind into prior-install candidates
        (Documentation\PriorInstallCandidates.json).
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.10 host step 3, V15, C-14). When OldArpGone-PostUpdate fails, the guest writes
        Sandbox\Logs\PriorCandidates.json: one object per surviving old uninstall entry (key leaf, view, names, version,
        WindowsInstaller, InstallLocation, the uninstaller's leaf and folder, the DisplayIcon leaf, the Inno Setup
        marker, up to 20 .exe leaves of the uninstaller folder). That file is UNTRUSTED (guest output): it is read only
        when at most 1 MB, parsed in a try, and every field is copied into a typed candidate - strings through
        ConvertTo-Win32ToolkitSafeText, the key, leaves and folder re-checked, unknown fields dropped.

        A survivor that is this package's OWN uninstall entry (OwnIdentity.ProductCode / ArpKeys, Uninstall.ProductCodes /
        PrimaryKeys of SupportFiles\AppConfig.json) is no candidate: it is named on one host line as this package's own
        product (live row OP-OWN: after a 69106 refusal the same-version baseline MSI 'survived' and replaced the NSIS
        candidate in the file). With no other survivor the file is not written.

        Candidate (the frozen schema of PriorInstallCandidates.json, the only input of
        Set-Win32ToolkitPriorInstall -FromUpdateTest, which re-validates every field):
          ProposedId          '<nsis|inno|msi|exe>-<x64|x86>' (-2, -3 on a collision; msi for a Windows Installer entry)
          Confidence          High only when the key equals the baseline manifest's ProductCode AND the publisher equals
                              a publisher of the baseline manifest; else Low
          Key, View, Publisher, DisplayName / DisplayNameTemplate (the observed version replaced by one {v} when the
          name contains it), ObservedVersion, WindowsInstaller
          UninstallerType     inno (Inno Setup marker and a key ending _is1), else the baseline type when nullsoft or
                              inno, else ''
          UninstallerFileName the uninstaller leaf; InstallDir its folder tokenised to %ProgramFiles% /
                              %ProgramFiles(x86)% ('' otherwise); MainExe the DisplayIcon leaf when it is one of the
                              folder's .exe files, else the only other .exe; ProcessNames MainExe without .exe
        The file is written BOM-less; one host line per candidate and the next step are printed: the declare command
        (Block first); for a key a rule already names whose publisher or window differs, its replacement from the candidate
        that keeps the rule's mode and widens its window to the observed version (a captured rule: capture again); for a
        project whose remove-prior blocks are not this catalog's, re-create it and run the test again first. Fail-open: an
        unreadable or hostile file writes nothing and returns @() with one warning (a W32T.* error is re-thrown).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Baseline
        The Update run's baseline facts (Version, InstallerType, Family).
    .PARAMETER Architecture
        The baseline architecture (x64 / x86).
    .PARAMETER ManifestProductCode
        The baseline manifest's ProductCode ('' when unknown).
    .PARAMETER ManifestPath
        The folder holding the baseline's downloaded winget manifests (Sandbox\OldVersion).
    .OUTPUTS
        [pscustomobject[]] the candidates written.
    .EXAMPLE
        Get-Win32ToolkitPriorInstallCandidate -ProjectPath $p -Baseline $baselineInfo -Architecture x64 -ManifestProductCode 'Notepad++' -ManifestPath $old
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [hashtable]$Baseline = @{},

        [AllowEmptyString()]
        [string]$Architecture = '',

        [AllowEmptyString()]
        [string]$ManifestProductCode = '',

        [AllowEmptyString()]
        [string]$ManifestPath = ''
    )

    $guestFile = Join-Path $ProjectPath 'Sandbox\Logs\PriorCandidates.json'
    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $leafRule = '^[A-Za-z0-9 ._+-]{1,64}\.exe$'
    $keyRule = '^[^\\/*?\[\]\p{Cc}\p{Cf}]{1,255}$'
    try {
        if (-not (Test-Path -LiteralPath $guestFile -PathType Leaf)) { return @() }
        if ((Get-Item -LiteralPath $guestFile).Length -gt 1MB) { throw 'the guest file is larger than 1 MB' }
        $raw = @(Get-Content -LiteralPath $guestFile -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })

        # The baseline manifest's publishers (root and Apps and Features entries) for the High confidence rule.
        $publishers = [System.Collections.Generic.List[string]]::new()
        if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath -PathType Container)) {
            foreach ($y in @(Get-ChildItem -LiteralPath $ManifestPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Select-Object -First 8)) {
                if ($y.Length -gt 1MB) { continue }
                foreach ($m in [regex]::Matches((Get-Content -LiteralPath $y.FullName -Raw -Encoding UTF8), '(?m)^\s*(?:-\s+)?Publisher:\s*(.+?)\s*$')) {
                    $v = & $safe ($m.Groups[1].Value.Trim().Trim('"', "'"))
                    if ($v -and -not $publishers.Contains($v)) { $publishers.Add($v) }
                }
            }
        }
        $baseType = ([string]$Baseline['InstallerType']).ToLowerInvariant()
        $arch = if (([string]$Architecture).ToLowerInvariant() -eq 'x86') { 'x86' } else { 'x64' }
        $usedIds = [System.Collections.Generic.List[string]]::new()
        $candidates = [System.Collections.Generic.List[object]]::new()
        # The project's rules (for the next-step lines) and its own uninstall identity (never a candidate).
        $entries = @()
        $ownKeys = [System.Collections.Generic.List[string]]::new()
        try {
            $cfgNow = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
            $pi = & $prop $cfgNow 'PriorInstalls'
            $entries = @(@(& $prop $pi 'Entries') | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })
            $ownId = & $prop $cfgNow 'OwnIdentity'
            $unin = & $prop $cfgNow 'Uninstall'
            foreach ($k in @([string](& $prop $ownId 'ProductCode')) + @(@(& $prop $ownId 'ArpKeys') | ForEach-Object { [string](& $prop $_ 'Key') }) +
                @(@(& $prop $unin 'ProductCodes') | ForEach-Object { [string]$_ }) + @(@(& $prop $unin 'PrimaryKeys') | ForEach-Object { [string](& $prop $_ 'Name') })) {
                if ($k) { $ownKeys.Add($k) }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "The project's prior-install rules and own identity were not read for the candidates: $($_.Exception.Message)"
        }
        $ownSeen = [System.Collections.Generic.List[string]]::new()
        foreach ($c in $raw) {
            $key = [string](& $prop $c 'Key')
            $view = [string](& $prop $c 'View')
            if ($key -notmatch $keyRule -or $key -match '[\r\n]' -or $key -in '.', '..' -or @('Native', 'Wow6432') -cnotcontains $view) { Write-Verbose 'A guest candidate with an invalid key or view was dropped.'; continue }
            if (@($ownKeys | Where-Object { [string]::Equals($_, $key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                $ownSeen.Add(('{0} [{1}] {2}' -f (& $safe $key), $view, (& $safe (& $prop $c 'DisplayVersion') 64)))
                continue
            }
            $publisher = & $safe (& $prop $c 'Publisher')
            $display = & $safe (& $prop $c 'DisplayName')
            $observed = & $safe (& $prop $c 'DisplayVersion') 64
            $windowsInstaller = (& $prop $c 'WindowsInstaller') -eq $true
            $leaf = [string](& $prop $c 'UninstallerLeaf')
            if ($leaf -notmatch $leafRule) { $leaf = '' }
            $folder = [string](& $prop $c 'UninstallerFolder')
            $installDir = ''
            if ($folder -match '^[A-Za-z]:\\[^/:*?"<>|~\p{Cc}\p{Cf}]+$' -and $folder -notmatch '\\[. ]*(\\|$)|[. ](\\|$)') {
                $rest = $null
                if ($folder.StartsWith('C:\Program Files (x86)\', [StringComparison]::OrdinalIgnoreCase)) { $rest = '%ProgramFiles(x86)%\' + $folder.Substring(23) }
                elseif ($folder.StartsWith('C:\Program Files\', [StringComparison]::OrdinalIgnoreCase)) { $rest = '%ProgramFiles%\' + $folder.Substring(17) }
                if ($rest -and $rest -cmatch '^%ProgramFiles(\(x86\))?%(\\[A-Za-z0-9 ._+()-]{1,64}){1,4}$') { $installDir = $rest }
            }
            $exes = @(@(& $prop $c 'Exes') | Where-Object { $_ -is [string] -and $_ -match $leafRule } | Select-Object -First 20)
            $iconLeaf = [string](& $prop $c 'DisplayIconLeaf')
            $mainExe = ''
            if ($iconLeaf -match $leafRule -and @($exes | Where-Object { [string]::Equals($_, $iconLeaf, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { $mainExe = $iconLeaf }
            else {
                $others = @($exes | Where-Object { -not [string]::Equals($_, $leaf, [StringComparison]::OrdinalIgnoreCase) })
                if ($others.Count -eq 1) { $mainExe = [string]$others[0] }
            }
            if ($mainExe -and [string]::Equals($mainExe, $leaf, [StringComparison]::OrdinalIgnoreCase)) { $mainExe = '' }
            $uType = if ((& $prop $c 'InnoAppPath') -eq $true -and $key -like '*_is1') { 'inno' } elseif ($baseType -in 'nullsoft', 'inno') { $baseType } else { '' }
            $template = ''
            if ($observed -and $display -and $display.Contains($observed)) {
                $i = $display.IndexOf($observed, [StringComparison]::Ordinal)
                $template = $display.Substring(0, $i) + '{v}' + $display.Substring($i + $observed.Length)
                if (($template.Length - $template.Replace('{v}', '').Length) -ne 3) { $template = '' }
            }
            # A Windows Installer entry is 'msi' (live row SB-REGRESSION: it was 'exe-x64').
            $stem = if ($windowsInstaller) { 'msi' } else { switch ($uType) { 'nullsoft' { 'nsis' } 'inno' { 'inno' } default { 'exe' } } }
            $proposed = "$stem-$arch"
            $n = 1
            while ($usedIds.Contains($proposed)) { $n++; $proposed = "$stem-$arch-$n" }
            $usedIds.Add($proposed)
            $high = $ManifestProductCode -and [string]::Equals($key, $ManifestProductCode, [StringComparison]::OrdinalIgnoreCase) -and
                @($publishers | Where-Object { [string]::Equals($_, $publisher, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            $candidates.Add([pscustomobject][ordered]@{
                    ProposedId          = $proposed
                    Confidence          = if ($high) { 'High' } else { 'Low' }
                    Key                 = $key
                    View                = $view
                    Publisher           = $publisher
                    DisplayName         = if ($template) { '' } else { $display }
                    DisplayNameTemplate = $template
                    ObservedVersion     = $observed
                    WindowsInstaller    = $windowsInstaller
                    UninstallerType     = $uType
                    UninstallerFileName = $leaf
                    InstallDir          = $installDir
                    MainExe             = $mainExe
                    ProcessNames        = [string[]]@(if ($mainExe) { [IO.Path]::GetFileNameWithoutExtension($mainExe) })
                })
        }
        foreach ($o in $ownSeen) { Write-Host "Old install left after the update: $o - this package's own product (its own uninstall entry), not a prior install" -ForegroundColor DarkGray }
        if ($candidates.Count -eq 0) { return @() }
        $doc = [ordered]@{
            SchemaVersion = '1.0'
            Baseline      = [ordered]@{
                Version             = & $safe $Baseline['Version'] 64
                InstallerType       = & $safe $Baseline['InstallerType'] 32
                Family              = & $safe $Baseline['Family'] 32
                Architecture        = $arch
                ManifestProductCode = & $safe $ManifestProductCode
                ManifestPublisher   = if ($publishers.Count) { $publishers[0] } else { '' }
            }
            Candidates    = @($candidates.ToArray())
        }
        $docDir = Join-Path $ProjectPath 'Documentation'
        if (-not (Test-Path -LiteralPath $docDir)) { $null = New-Item -ItemType Directory -Path $docDir -Force }
        [System.IO.File]::WriteAllText((Join-Path $docDir 'PriorInstallCandidates.json'), (ConvertTo-Json -InputObject $doc -Depth 6), [System.Text.UTF8Encoding]::new($false))
        # The next step per candidate (installer-identity PR 3 live checks: OP-BLOCK, OP-REPORT, OP-UNPROVEN, OP-NEWER, KILL-*,
        # APP-RUNNING, MSIBUSY, RC2-*, DEMOTE, GOAL-PROOF, SB-REGRESSION). A key a rule already names is not declared again
        # (-FromUpdateTest refuses the duplicate): the line names that rule and what differs from the observed install.
        # A Windows Installer key is not a prior install of this kind (-FromUpdateTest refuses it). The declare command
        # names the candidate with -CandidateKey unless it is the file's single High candidate.
        $declarable = [System.Collections.Generic.List[object]]::new()
        # A project whose remove-prior blocks are not this catalog's cannot take a rule (live row OP-CONTROL: the printed command
        # was refused with W32T.PriorInstallSlotsMissing, and re-creating the project drops this file). Fail-open: no deploy
        # script, or one that cannot be read, gives the commands as before.
        $slotWhy = ''
        try {
            $deployScript = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
            if (Test-Path -LiteralPath $deployScript -PathType Leaf) {
                $shape = Get-Win32ToolkitDeployScriptShape -Path $deployScript
                $catalogRevision = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision)
                if ([int]$shape.RemovePriorRevision -lt 1) { $slotWhy = 'its deploy script has no remove-prior blocks (it was created before this win32-toolkit version)' }
                elseif ([int]$shape.RemovePriorRevision -ne $catalogRevision) { $slotWhy = "its remove-prior blocks are catalog revision $([int]$shape.RemovePriorRevision), this version writes revision $catalogRevision" }
                elseif (-not $shape.PriorCheckFirst) { $slotWhy = 'a dialog of its deploy script runs before the prior-check block' }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "The deploy script's remove-prior blocks were not read for the next step: $($_.Exception.Message)"
        }
        $recreate = 'Re-create it with this win32-toolkit version (Invoke-Win32Toolkit -Force or New-Win32ToolkitManualApp; copy hand-written Install code out first), run this Update test again (re-creating drops the candidates)'
        foreach ($cd in $candidates) {
            $line = "Prior install candidate: {0} ({1}) - {2} [{3}] {4}, publisher {5}" -f $cd.ProposedId, $cd.Confidence, $cd.Key, $cd.View, $cd.ObservedVersion, $cd.Publisher
            $rule = @($entries | Where-Object { [string](& $prop $_ 'View') -ceq $cd.View -and [string]::Equals([string](& $prop $_ 'Key'), $cd.Key, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
            if ($rule) {
                $rid = & $safe (& $prop $rule 'Id') 40
                $diff = [System.Collections.Generic.List[string]]::new()
                $rulePub = & $safe (& $prop $rule 'Publisher')
                if ($cd.Publisher -and -not [string]::Equals($rulePub, $cd.Publisher, [StringComparison]::OrdinalIgnoreCase)) { $diff.Add("its publisher '$rulePub' is not the observed '$($cd.Publisher)'") }
                $obsV = ConvertTo-Win32ToolkitPriorVersion -Text $cd.ObservedVersion
                $maxV = ConvertTo-Win32ToolkitPriorVersion -Text ([string](& $prop $rule 'VersionMax'))
                $minV = ConvertTo-Win32ToolkitPriorVersion -Text ([string](& $prop $rule 'VersionMin'))
                if ($obsV -and $maxV -and $obsV -gt $maxV) { $diff.Add("the observed version $($cd.ObservedVersion) is above its VersionMax $(& $safe (& $prop $rule 'VersionMax') 64)") }
                elseif ($obsV -and $minV -and $obsV -lt $minV) { $diff.Add("the observed version $($cd.ObservedVersion) is below its VersionMin $(& $safe (& $prop $rule 'VersionMin') 64)") }
                # The replacement keeps the rule's mode and widens its window just enough to cover the observed version (live
                # rows OP-NEWER, OP-UNPROVEN: "-Remove, then declare it again" dropped the operator's Enforce mode and floor, and
                # named no declare command). A rule from a sibling capture changes only through its capture.
                $replace = ''
                if ($diff.Count) {
                    if ($slotWhy) { $replace = " (this project cannot take a rule change yet: $slotWhy. $recreate, then replace it)" }
                    elseif ([string](& $prop $rule 'Source') -ceq 'SiblingCapture' -or [string](& $prop $rule 'CaptureId')) {
                        $replace = " (a captured rule changes only through its capture: Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario SiblingCapture, then apply its proposal again)"
                    }
                    else {
                        $minText = [string](& $prop $rule 'VersionMin'); $maxText = [string](& $prop $rule 'VersionMax')
                        $newMin = if ($minText -and $obsV -and $minV -and $obsV -lt $minV) { $cd.ObservedVersion } else { & $safe $minText 64 }
                        $newMax = if ($obsV -and (-not $maxV -or $obsV -gt $maxV)) { $cd.ObservedVersion } else { & $safe $maxText 64 }
                        $pickArg = if (@($candidates | Where-Object { $_.Confidence -eq 'High' }).Count -eq 1 -and $cd.Confidence -eq 'High') { '' } else { " -CandidateKey '$($cd.Key -replace "'", "''")'" }
                        $replace = " (replace it from this candidate, keeping its mode: Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromUpdateTest -Id $rid -Mode $(& $safe (& $prop $rule 'Mode') 16) -VersionMin '$($newMin -replace "'", "''")' -VersionMax '$($newMax -replace "'", "''")'$pickArg)"
                    }
                }
                $why = if ($diff.Count) { ': ' + ($diff -join '; ') + $replace } else { '' }
                Write-Host "$line - already the $(& $safe (& $prop $rule 'Mode') 16) rule '$rid'$why" -ForegroundColor Yellow
            }
            elseif ($cd.WindowsInstaller) { Write-Host "$line - registered by Windows Installer: not a prior install of this kind, nothing to declare" -ForegroundColor DarkGray }
            else {
                Write-Host $line -ForegroundColor Yellow
                $declarable.Add($cd)
            }
        }
        $highAll = @($candidates | Where-Object { $_.Confidence -eq 'High' })
        foreach ($cd in $declarable) {
            $pickArg = if ($highAll.Count -eq 1 -and [object]::ReferenceEquals($highAll[0], $cd)) { '' } else { " -CandidateKey '$($cd.Key -replace "'", "''")'" }
            if ($slotWhy) {
                Write-Host "This project cannot take a prior-install rule yet: $slotWhy. $recreate, then declare it (Block first): Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromUpdateTest -Mode Block$pickArg" -ForegroundColor Yellow
            }
            else { Write-Host "Declare it (Block first): Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromUpdateTest -Mode Block$pickArg" -ForegroundColor Yellow }
        }
        return $candidates.ToArray()
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning ('The prior-install candidates of this Update test were not read (' + (& $safe $_.Exception.Message 200) + ').')
        return @()
    }
}
