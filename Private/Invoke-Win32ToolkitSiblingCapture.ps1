function Invoke-Win32ToolkitSiblingCapture {
    <#
    .SYNOPSIS
        Captures the other installer technologies of an app, one isolated run per capture (Hyper-V test VM or Windows
        Sandbox).
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.4 - 2.14.8; SV4, SV17, SV20, SV28, L18 - L22, L30, L31, L35, D62). For every
        capture of the plan (Get-Win32ToolkitSiblingCapturePlan; RemovableNow types, and ReportOnly ones the plan was asked
        to include):

          1. download exactly that installer type at that version for the siblings' architecture
             (Download-OldVersionInstaller -ExactType) into Sandbox\Siblings\<CaptureKey>; not offered -> CaptureFailed
             'not offered';
          2. a work folder Sandbox\SiblingRuns\<CaptureKey>-<yyyyMMddHHmmss>: in\SiblingCapture.ps1 (UTF-8 with BOM),
             in\SiblingCapture.data.json (BOM-less: the capture's values; the script holds none), in\installer\<leaf> and an
             empty quarantine\. Nothing else of the project enters the guest (no dependencies);
          3. the tripwire baseline of the project (L18), then the run:
             - Hyper-V: in\ runs with five constant phases (snapshot before, install - or, -Assisted, a pause in which the
               operator installs it in the VM window (D62) -, snapshot after - each StopRunOnFailure -, the removability
               probe, log collection - Always -); its output is copied back into quarantine\ only, through the
               allow-list and the 64 MB / 160 MB caps;
             - Windows Sandbox (L30): a .wsb maps in\ read-only at C:\PSADT and quarantine\ read-write at C:\W32TOut (the
               project is never mapped); the LogonCommand runs the script's All phase in the -Command "& { ... }" form,
               which shuts the sandbox down at the end; the host waits up to 50 minutes for SiblingDone_<key>.json (5
               minutes for a sandbox that never shows up), makes sure its sandbox is closed (as the Update test: its own
               sandbox for 10 minutes, then any for 1 minute; still open -> W32T.GuestTamper, L18), then applies the same
               allow-list and caps to the folder (a refused file is deleted). The sibling installs as the sandbox's
               user: every Sandbox record is Block-only;
          4. the tripwire check once the guest can no longer write (W32T.GuestTamper stops the whole capture), then the
             quarantine read (ConvertFrom-Win32ToolkitSiblingCaptureOutput) and the record written as
             Documentation\SiblingCapture\<CaptureId>.json (CaptureId = the first 16 hex of the SHA-256 of its bytes); the
             quarantine is deleted after a successful read, the work files are kept.
        Bisection (spec 2.14.8 rule 3): when the records show a drift (two identities of one technology with uncaptured
        versions between them) in the architecture this run captures, up to -MaxExtra more captures (role Extra) are
        taken, each at the middle offering version of the first such gap, before the proposals are final.
        Then the index Documentation\SiblingCapture.json (SchemaVersion 1.1, informational) lists every hash-verified
        record, this run's failures, the ReportOnly / NotCapturable types and the remaining gaps. A capture never writes
        PriorInstalls.
    .PARAMETER ProjectPath
        The PSADT project folder (its pre-flight passed: Test-Win32ToolkitSiblingCapturePreflight).
    .PARAMETER Plan
        The plan (Get-Win32ToolkitSiblingCapturePlan).
    .PARAMETER Backend
        HyperV (default) or Sandbox (the pre-flight's Backend).
    .PARAMETER Assisted
        Hyper-V only: the operator installs the sibling in the VM window instead of the scripted install (Block-only).
    .PARAMETER MaxExtra
        The most Extra captures the bisection of a drift may add (0-10, default 4).
    .OUTPUTS
        $true when at least one record was written, $false when every capture failed or nothing could be planned because
        the winget manifests could not be read (the plan's PackageProbe is not Ok, or a type is ProbeFailed: one warning
        says why and what would help - capture again later or after GitHub's time, check winget, or nothing for a
        manifest that cannot be used - with a command that keeps this run's scope; no index is written), $null when
        there was nothing to capture. A W32T.* error (W32T.GuestTamper, a lease timeout) is thrown.
    .EXAMPLE
        Invoke-Win32ToolkitSiblingCapture -ProjectPath $p -Plan (Get-Win32ToolkitSiblingCapturePlan -ProjectPath $p) -Backend HyperV
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [object]$Plan,

        [ValidateSet('HyperV', 'Sandbox')]
        [string]$Backend = 'HyperV',

        [switch]$Assisted,

        [ValidateRange(0, 10)]
        [int]$MaxExtra = 4
    )

    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $docDir = Join-Path $ProjectPath 'Documentation'
    $recDir = Join-Path $docDir 'SiblingCapture'
    $script = Get-Win32ToolkitSiblingCaptureScript
    $scriptBytes = [byte[]]([Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($script))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $scriptSha = -join ($sha.ComputeHash($scriptBytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
    $toolkitVersion = & $safe (Get-Win32ToolkitVersion) 32
    $pkg = $Plan.Package
    $sibArch = if ($Plan.PSObject.Properties['Architecture'] -and [string]$Plan.Architecture) { [string]$Plan.Architecture } else { [string]$pkg.Architecture }
    $mode = if ($Assisted -and $Backend -eq 'HyperV') { 'Assisted' } else { 'Unattended' }
    $where = if ($Backend -eq 'Sandbox') { 'in Windows Sandbox' } else { 'on the Hyper-V test VM' }
    $runs = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()

    $todo = @(@($Plan.Types) | Where-Object { @($_.Captures).Count -gt 0 -and $_.Class -in @('RemovableNow', 'ReportOnly') })
    # ---- the plan, before the first run (SV23, measured by H-S20 on 2026-10-25: about 2.5 minutes per Hyper-V capture run; 3-5 announced) ----
    Write-Host ''
    Write-Host "Sibling capture plan for $(& $safe $pkg.WingetId 128) $(& $safe $pkg.Version 64) ($(& $safe $pkg.Architecture 8), packaged as $(& $safe $pkg.InstallerType 32))$(if ($sibArch -ne [string]$pkg.Architecture) { "; $sibArch siblings" }):" -ForegroundColor Cyan
    foreach ($t in @($Plan.Types)) {
        $caps = (@($t.Captures) | ForEach-Object { "$($_.Version) ($($_.Role))" }) -join ', '
        $why = if ($t.Reason) { " - $($t.Reason)" } else { '' }
        Write-Host ("  {0,-9} {1,-14} {2}{3}" -f $t.Type, $t.Class, $(if ($caps) { $caps } else { '-' }), $why)
    }
    foreach ($pf in @($Plan.ProbeFailures)) { Write-Host "  (not checked: $(& $safe $pf 200))" -ForegroundColor DarkGray }
    $count = @($todo | ForEach-Object { @($_.Captures) }).Count
    # Live rows RAISE, INNO: a winget manifest that could not be read (GitHub answered HTTP 429) is not "nothing to
    # capture": the capture fails, says why, and what would help (the plan's PackageProbe.Cause / Types[].ProbeCause).
    $pp = if ($Plan.PSObject.Properties['PackageProbe']) { $Plan.PackageProbe } else { $null }
    $req = if ($Plan.PSObject.Properties['Request']) { $Plan.Request } else { $null }
    $unchecked = @(@($Plan.Types) | Where-Object { $_.PSObject.Properties['ProbeFailed'] -and $_.ProbeFailed })
    $uncheckedWhy = (@($unchecked | ForEach-Object { "$([string]$_.Type): $(& $safe $_.Reason 200)" }) -join '; ')
    $causeOf = { param($O, [string]$Name) if ($O -and $O.PSObject.Properties[$Name] -and [string]$O.$Name) { [string]$O.$Name } else { 'Transient' } }
    # GitHub's time (a RateLimited probe of the plan), rounded up to the minute: "until 10:01" for 10:01:40 would be too early.
    $retryAt = if ($Plan.PSObject.Properties['RetryAfterUtc']) { [string]$Plan.RetryAfterUtc } else { '' }
    $d = [datetime]::MinValue
    $when = if ($retryAt -and [datetime]::TryParse($retryAt, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) {
        $atMinute = [datetime]::new($d.Ticks - ($d.Ticks % [timespan]::TicksPerMinute), [DateTimeKind]::Utc)
        if ($atMinute -lt $d) { $atMinute = $atMinute.AddMinutes(1) }
        "GitHub limits requests from this computer until $($atMinute.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)) UTC; capture again after that"
    }
    else { 'Capture again later' }
    # The command that captures again keeps the scope of this run (its siblings' architecture, -IncludeReportOnly, the
    # versions asked for, -Assisted); the values are echoed, never run. PowerShell's own escaper doubles every quote a
    # single-quoted string ends at (' and U+2018-U+201B: a project name can hold them); a version keeps the probe's 128.
    $quote = { param($V, [int]$Max = 128) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent((& $safe $V $Max)) + "'" }
    $scope = ''
    if ($sibArch -ne [string]$pkg.Architecture) { $scope += " -SiblingArchitecture $sibArch" }
    if (($req -and $req.IncludeReportOnly) -or @($unchecked | Where-Object { [string]$_.Class -eq 'ReportOnly' }).Count -gt 0) { $scope += ' -IncludeReportOnly' }
    if ($req -and @($req.SiblingVersion).Count -gt 0) { $scope += ' -SiblingVersion ' + ((@($req.SiblingVersion) | ForEach-Object { & $quote $_ }) -join ',') }
    elseif ($req -and [int]$req.Coverage -gt 0) { $scope += " -SiblingCaptureCoverage $([int]$req.Coverage)" }
    elseif ($req -and [int]$req.VersionsBack -gt 0) { $scope += " -SiblingCaptureVersionsBack $([int]$req.VersionsBack)" }
    if ($mode -eq 'Assisted') { $scope += ' -Assisted' }
    $typesArg = {
        param([string[]]$Types)
        $t2 = @($Types | Where-Object { $_ })
        if ($t2.Count -gt 0 -and @($t2 | Where-Object { $_ -notin @('nullsoft', 'inno', 'exe', 'burn', 'msi', 'wix', 'msix') }).Count -eq 0) { " -SiblingInstallerType $($t2 -join ',')" } else { '' }
    }
    $again = "Test-Win32ToolkitProject -ProjectPath $(& $quote $ProjectPath 1024) -Scenario SiblingCapture$scope"
    # What would help: a Transient failure (RateLimited / Network / Timeout) passes, so capturing again (later, or after
    # GitHub's time) helps whenever any cause is not Permanent; a failed winget version list is this computer's winget;
    # only when every cause is Permanent (NotFound / Parse / TooLarge / InvalidId) does capturing again change nothing.
    $advice = {
        param([string[]]$Causes, [string]$Command, [switch]$Package)
        $retryable = @($Causes | Where-Object { $_ -ne 'Permanent' })
        if ($retryable.Count -eq 0) {
            if ($Package) { "Capturing again will not change this: check the project's winget id and version" }
            else { "Capturing again will not change this: winget-pkgs has no usable manifest for these versions$(if ($req -and @($req.SiblingVersion).Count -gt 0) { ' (check the versions named with -SiblingVersion)' })" }
        }
        elseif ($retryable -contains 'WingetList') { "Check winget on this computer (winget show --id $(& $safe $pkg.WingetId 128) --versions), then capture again: $Command" }
        else { "${when}: $Command" }
    }
    # Mixed: the types that capturing again cannot help are named after the advice for the others.
    $permanentTypes = @($unchecked | Where-Object { (& $causeOf $_ 'ProbeCause') -eq 'Permanent' } | ForEach-Object { [string]$_.Type })
    $permanentNote = if ($permanentTypes.Count -gt 0 -and $permanentTypes.Count -lt $unchecked.Count) { " ($($permanentTypes -join ', '): capturing again will not change that.)" } else { '' }
    if ($count -eq 0) {
        $retryTypes = if ($req) { & $typesArg @($req.SiblingInstallerType) } else { '' }
        if ($pp -and [string]$pp.Status -ne 'Ok') {
            Write-Warning "Nothing was captured: the winget manifest of $(& $safe $pkg.WingetId 128) $(& $safe $pkg.Version 64) could not be read ($(& $safe $pp.Reason 32)), so the other installer technologies of this app are not known. $(& $advice @(& $causeOf $pp 'Cause') "$again$retryTypes" -Package)."
            return $false
        }
        if ($unchecked.Count -gt 0) {
            Write-Warning "Nothing was captured: no technology could be checked ($uncheckedWhy). $(& $advice @($unchecked | ForEach-Object { & $causeOf $_ 'ProbeCause' }) "$again$retryTypes").$permanentNote"
            return $false
        }
        Write-Host 'Nothing to capture: no other installer technology of this app can be captured.' -ForegroundColor Yellow
        return $null
    }
    if ($unchecked.Count -gt 0) {
        # The command names only the types capturing again can help.
        $retryable = @($unchecked | Where-Object { (& $causeOf $_ 'ProbeCause') -ne 'Permanent' } | ForEach-Object { [string]$_.Type })
        Write-Warning "Not captured: $uncheckedWhy. $(& $advice @($unchecked | ForEach-Object { & $causeOf $_ 'ProbeCause' }) "$again$(& $typesArg $retryable)").$permanentNote"
    }
    # Live row GOAL-CAPTURE: '(plus up to 4 ...)' after a minutes figure read as 4 minutes; it is a number of capture runs.
    Write-Host "$count capture run(s) $where, about $(3 * $count)-$(5 * $count) minutes$(if ($MaxExtra -gt 0) { "; up to $MaxExtra more capture run(s), about $(3 * $MaxExtra)-$(5 * $MaxExtra) minutes, if a technology changed its identity between versions" })." -ForegroundColor Cyan
    if ($Backend -eq 'Sandbox') { Write-Host 'Windows Sandbox: the sibling installs as a user; every proposal from these captures is Block-only.' -ForegroundColor Yellow }
    if ($mode -eq 'Assisted') { Write-Host 'Assisted: you install each sibling yourself in the VM window when asked; these proposals are Block-only (an assisted capture is never removable).' -ForegroundColor Yellow }

    $keyOf = {
        param([string]$Type, [string]$Version)
        $k = "$Type-$Version"
        if ($sibArch -eq 'x86') { $k += '-x86' }
        $k = ($k.ToLowerInvariant() -replace '[^a-z0-9._+-]', '_')
        if ($k.Length -gt 80) { $k = $k.Substring(0, 80) }
        $k
    }
    # The Sandbox output folder gets the allow-list and caps of the Hyper-V copy-back: a refused entry is deleted.
    $filterQuarantine = {
        param([string]$Folder, [string]$Key)
        $k = [regex]::Escape($Key)
        $fileRx = '^(Sibling(Pre|Install|Capture|Probe|Done)_' + $k + '\.json|SiblingCopy_' + $k + '_(uninstaller|main)\.exe)$'
        $total = 0L
        $drop = {
            param($Item, [string]$Why)
            Write-Warning "Sibling capture ${Key}: '$(& $safe $Item.Name 80)' from the sandbox was refused ($Why) and deleted."
            if ($Item.PSIsContainer) { [System.IO.Directory]::Delete($Item.FullName, -not [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) }
            else { [System.IO.File]::Delete($Item.FullName) }
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $Folder -Force)) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { & $drop $item 'a link'; continue }
            if ($item.PSIsContainer) {
                if ($item.Name -cne 'Logs') { & $drop $item 'not an expected folder'; continue }
                foreach ($log in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
                    if ($log.PSIsContainer -or ($log.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $log.Name -cnotmatch '^[A-Za-z0-9_.-]{1,64}\.log$') { & $drop $log 'not an expected log file'; continue }
                    if ($log.Length -gt 64MB -or $total + $log.Length -gt 160MB) { & $drop $log 'too large'; continue }
                    $total += $log.Length
                }
                continue
            }
            if ($item.Name -cnotmatch $fileRx) { & $drop $item 'not an expected file'; continue }
            if ($item.Length -gt 64MB -or $total + $item.Length -gt 160MB) { & $drop $item 'too large'; continue }
            $total += $item.Length
        }
    }

    # ---- one capture ----
    $runOne = {
        param($t, $c)
        $key = [string]$c.CaptureKey
        $row = [ordered]@{ CaptureKey = $key; Type = [string]$t.Type; Version = [string]$c.Version; Role = [string]$c.Role; Status = 'CaptureFailed'; CaptureId = ''; Reason = '' }
        Write-Host "`nSibling capture $key ($($t.Type) $(& $safe $c.Version 64), $($c.Role))" -ForegroundColor Cyan
        try {
            # 1. the exact installer type
            $dlArgs = @{ AppId = [string]$pkg.WingetId; Version = [string]$c.Version; ProjectPath = $ProjectPath; DestinationDir = (Join-Path $ProjectPath "Sandbox\Siblings\$key")
                Architecture = $sibArch; InstallerType = [string]$t.Type; ExactType = $true }
            if ($c.Scope -in @('machine', 'user')) { $dlArgs['Scope'] = [string]$c.Scope }
            $dl = $null
            try { $dl = Download-OldVersionInstaller @dlArgs }
            catch {
                if ($_.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable') { $row.Reason = 'not offered'; $failed.Add($row); $runs.Add($row); Write-Warning "Sibling capture ${key}: winget offers no $($t.Type) installer at this version (not captured)."; return }
                throw
            }
            $leaf = [string]$dl.InstallerName
            $installerSha = (Get-FileHash -LiteralPath $dl.InstallerPath -Algorithm SHA256).Hash.ToUpperInvariant()
            $manifestText = (@($dl.ManifestPath) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) }) -join "`n---`n"
            $m = ConvertFrom-Win32ToolkitWingetManifest -Text $manifestText
            $inst = $null
            if ($m) {
                $inst = @($m.Installers | Where-Object { ($_.InstallerType -eq $t.Type -or $_.NestedInstallerType -eq $t.Type -or ($t.Type -in @('msi', 'wix') -and $_.InstallerType -in @('msi', 'wix'))) -and ($_.Architecture -in @($sibArch, 'neutral', '')) }) | Select-Object -First 1
            }
            $codes = @(); $afe = @()
            if ($inst) {
                if ($inst.ProductCode) { $codes += [string]$inst.ProductCode }
                $afe = @($inst.AppsAndFeaturesEntries | ForEach-Object { [ordered]@{ DisplayName = $_.DisplayName; Publisher = $_.Publisher; DisplayVersion = $_.DisplayVersion; ProductCode = $_.ProductCode; UpgradeCode = $_.UpgradeCode; InstallerType = $_.InstallerType } })
            }
            $manifest = [ordered]@{ ProductCodes = [string[]]$codes; Afe = [object[]]$afe; PackageName = $(if ($m) { [string]$m.PackageName } else { '' }); Publisher = $(if ($m) { [string]$m.Publisher } else { '' })
                DefaultInstallLocation = $(if ($inst) { [string]$inst.DefaultInstallLocation } else { '' }) }
            $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
            # The package's publisher (App.Vendor), the attribution's input on the host too: a Microsoft entry is ranked in
            # the guest exactly when the host ranks it (SV16).
            $pkgPublisher = if ($cfg.PSObject.Properties['App'] -and $cfg.App -and $cfg.App.PSObject.Properties['Vendor']) { [string]$cfg.App.Vendor } else { '' }
            $ownKeys = @(); $ownCodes = @()
            if ($cfg.PSObject.Properties['OwnIdentity'] -and $cfg.OwnIdentity) {
                $ownKeys = @(@($cfg.OwnIdentity.ArpKeys) | Where-Object { $_ } | ForEach-Object { [ordered]@{ Key = [string]$_.Key; View = [string]$_.View } })
                $ownCodes = @(@([string]$cfg.OwnIdentity.ProductCode, [string]$cfg.OwnIdentity.UpgradeCode) | Where-Object { $_ })
            }

            # 2. the isolated work folder
            $runFolder = Join-Path $ProjectPath ("Sandbox\SiblingRuns\$key-" + (Get-Date).ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture))
            $inDir = Join-Path $runFolder 'in'
            $quarantine = Join-Path $runFolder 'quarantine'
            foreach ($d in @((Join-Path $inDir 'installer'), $quarantine)) { $null = New-Item -ItemType Directory -Path $d -Force }
            [IO.File]::WriteAllBytes((Join-Path $inDir 'SiblingCapture.ps1'), [byte[]]$scriptBytes)
            Copy-Item -LiteralPath $dl.InstallerPath -Destination (Join-Path $inDir "installer\$leaf") -Force
            $expected = if ($t.Type -in @('nullsoft', 'inno')) { [string]$t.Type } else { 'exe' }
            $outDir = if ($Backend -eq 'Sandbox') { 'C:\W32TOut' } else { 'C:\PSADT\Out' }
            $data = [ordered]@{
                SchemaVersion = '1.0'; CaptureKey = $key; InstallerType = [string]$t.Type; ExpectedKind = $expected; Version = [string]$c.Version; Architecture = $sibArch
                InstallerFile = $leaf; InstallerArgs = [string]$dl.SilentArgs; OutDir = $outDir; Manifest = $manifest
                Own = [ordered]@{ ArpKeys = [object[]]$ownKeys; ProductCodes = [string[]]$ownCodes }; PackagePublisher = $pkgPublisher; Mode = $mode
            }
            [IO.File]::WriteAllText((Join-Path $inDir 'SiblingCapture.data.json'), (ConvertTo-Json -InputObject $data -Depth 8), [Text.UTF8Encoding]::new($false))

            # 3. the run, between the tripwire baseline and its check (L18)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $notRead = ''
            $outFolder = Join-Path $quarantine 'Out'
            if ($Backend -eq 'Sandbox') {
                $outFolder = $quarantine
                if (-not (Wait-Win32ToolkitSandboxFree -TimeoutSeconds 90)) { throw 'another Windows Sandbox is running (Windows allows one): close it and capture again' }
                $wsb = Join-Path $runFolder 'SiblingCapture.wsb'
                $mounts = @(@{ HostPath = $inDir; GuestPath = 'C:\PSADT'; ReadOnly = $true }, @{ HostPath = $quarantine; GuestPath = 'C:\W32TOut'; ReadOnly = $false })
                $logon = "powershell.exe -ExecutionPolicy Bypass -Command &quot;&amp; { &amp; 'C:\PSADT\SiblingCapture.ps1' -Phase All }&quot;"
                [IO.File]::WriteAllText($wsb, (New-Win32ToolkitSandboxConfig -Mount $mounts -LogonCommandXml $logon), [Text.UTF8Encoding]::new($false))
                $trip = Get-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath
                if (-not (Start-Win32ToolkitSandbox -ConfigPath $wsb)) { $notRead = 'Windows Sandbox did not start' }
                else {
                    $done = Join-Path $quarantine "SiblingDone_$key.json"
                    $deadline = (Get-Date).AddMinutes(50)
                    $seen = $false
                    $polls = 0
                    while (-not (Test-Path -LiteralPath $done) -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Seconds 10
                        $polls++
                        if (Test-Win32ToolkitSandboxRunning) { $seen = $true }
                        elseif ($seen) { break }
                        # A sandbox that never showed up in 5 minutes - no sandbox process and nothing written by its guest
                        # (the script creates its Logs folder first) - is not coming: no 50-minute wait for it.
                        elseif ($polls -ge 30 -and @(Get-ChildItem -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue).Count -eq 0) { $notRead = 'Windows Sandbox did not start within 5 minutes'; break }
                    }
                    # L18: the guest output is trusted only once this capture's own sandbox is closed (it maps the quarantine
                    # read-write, inside the project), whatever happened above. Not confirmed closed -> W32T.GuestTamper.
                    $closed = Wait-Win32ToolkitSandboxFree -TimeoutSeconds 600 -OwnRun
                    if (-not $closed) { $closed = Wait-Win32ToolkitSandboxFree -TimeoutSeconds 60 }
                    if (-not $closed) { Assert-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath -Scenario 'SiblingCapture' -Reason "this capture's Windows Sandbox could not be confirmed closed" }
                    if (-not $notRead -and -not (Test-Path -LiteralPath $done)) { $notRead = 'the sandbox ended (or 50 minutes passed) before the capture finished' }
                }
                Assert-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath -Before $trip -Scenario 'SiblingCapture'
                if (-not $notRead) { & $filterQuarantine $quarantine $key }
            }
            else {
                $k = [regex]::Escape($key)
                $allow = '^Out/(Sibling(Pre|Install|Capture|Probe|Done)_' + $k + '\.json|SiblingCopy_' + $k + '_(uninstaller|main)\.exe|Logs/[A-Za-z0-9_.-]{1,64}\.log)$'
                $installPhase = if ($mode -eq 'Assisted') { @{ Label = 'Sibling: install it yourself in the VM window (Assisted)'; Pause = $true; Interactive = $true; StopRunOnFailure = $true } }
                else { @{ Label = 'Sibling: install'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase Install; exit `$LASTEXITCODE"; StopRunOnFailure = $true } }
                $phases = @(
                    @{ Label = 'Sibling: snapshot before'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase PreSibling; exit `$LASTEXITCODE"; StopRunOnFailure = $true }
                    $installPhase
                    @{ Label = 'Sibling: snapshot after'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase PostSibling; exit `$LASTEXITCODE"; StopRunOnFailure = $true }
                    @{ Label = 'Sibling: removability probe'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase Probe; exit `$LASTEXITCODE" }
                    @{ Label = 'CollectLogs'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase CollectLogs"; IgnoreExit = $true; Always = $true }
                )
                # Assisted (D62): the operator has to know which file to start in the VM window (in\ is the guest's C:\PSADT).
                if ($mode -eq 'Assisted') { Write-Host "Assisted: when the run pauses, start C:\PSADT\installer\$(& $safe $leaf 128) (the $($t.Type) installer of version $(& $safe $c.Version 64)) in the VM window, finish its setup, then press Enter here." -ForegroundColor Yellow }
                $trip = Get-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath
                $ok = Invoke-Win32ToolkitHyperVRun -ProjectPath $inDir -Phase $phases -Output @('Out\*') -ResultDestination $quarantine -ResultAllowedEntry $allow -ResultMaxEntryBytes 64MB -ResultMaxTotalBytes 160MB
                Assert-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath -Before $trip -Scenario 'SiblingCapture'
                if (-not $ok) { Write-Warning "Sibling capture ${key}: the Hyper-V run did not complete." }
            }
            if ($notRead) { $row.Reason = $notRead; $failed.Add($row); $runs.Add($row); Write-Warning "Sibling capture ${key}: no record ($notRead)."; return }

            # 4. the record
            $sibling = [ordered]@{
                InstallerType = [string]$t.Type; EffectiveType = [string]$t.EffectiveType; Version = [string]$c.Version; Role = [string]$c.Role; ReleaseDate = [string]$c.ReleaseDate
                Scope = $(if ($dl.Scope -in @('machine', 'user')) { [string]$dl.Scope } else { '' }); Locale = [string]$dl.Locale; Architecture = $sibArch
                InstallerFile = $leaf; InstallerSha256 = $installerSha; SilentArgs = [string]$dl.SilentArgs; SilentArgsSource = [string]$dl.SilentArgsSource; Manifest = $manifest
            }
            $facts = @{
                CaptureKey    = $key
                Package       = [ordered]@{ WingetId = [string]$pkg.WingetId; Version = [string]$pkg.Version; Architecture = [string]$pkg.Architecture; InstallerType = [string]$pkg.InstallerType; Family = [string]$pkg.Family }
                Sibling       = $sibling
                Run           = @{ Backend = $Backend; Mode = $mode; Seconds = [int]$watch.Elapsed.TotalSeconds; ToolkitVersion = $toolkitVersion; GuestScriptSha256 = $scriptSha; DependenciesSkipped = $true }
                InstallerPath = [string]$dl.InstallerPath
            }
            $read = ConvertFrom-Win32ToolkitSiblingCaptureOutput -RunFolder $runFolder -Context $facts -OutputFolder $outFolder
            if (-not $read.Record) { $row.Reason = [string]$read.Failure; $failed.Add($row); $runs.Add($row); Write-Warning "Sibling capture ${key}: no record ($($row.Reason))."; return }
            $json = ConvertTo-Json -InputObject $read.Record -Depth 12 -Compress -EscapeHandling EscapeNonAscii
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $sha2 = [System.Security.Cryptography.SHA256]::Create()
            try { $id = (-join ($sha2.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16) } finally { $sha2.Dispose() }
            $null = New-Item -ItemType Directory -Path $recDir -Force
            [IO.File]::WriteAllBytes((Join-Path $recDir "$id.json"), $bytes)
            Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction SilentlyContinue
            $row.Status = 'Recorded'; $row.CaptureId = $id
            $runs.Add($row)
            $primary = [string]$read.Record.Observation.ProvisionalPrimary
            Write-Host "  recorded $id$(if ($primary) { " (primary: $(& $safe $primary 128); probe: $($read.Record.Probe.Result))" } else { ' (no primary entry)' })" -ForegroundColor Green
            # Live row GOAL-CAPTURE: an Unverified noise control made every proposal of the identity Block-only with no word on why.
            # RAISE / ASSISTED: the cause could not be read after the VM was restored: the detail stays in the index row too.
            if ([string]$read.Record.Observation.NoiseControl -ne 'Verified') {
                $row['NoiseDetail'] = [string]$read.NoiseDetail
                # Live rows DEMOTE, INNO, ASSISTED: the cause comes from the guest's detail (it blamed Windows Update for a check
                # before the install that had failed while nothing was installed).
                $cause = if ($read.PSObject.Properties['NoiseCause'] -and $read.NoiseCause) { [string]$read.NoiseCause } else { 'an update service or task was not held still during the capture' }
                Write-Warning "Sibling capture ${key}: the guest noise control was not verified ($(if ($read.NoiseDetail) { $read.NoiseDetail } else { 'no states reported' })): $cause, so the proposals of this identity are Block-only."
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $row.Reason = & $safe $_.Exception.Message 200
            $failed.Add($row); $runs.Add($row)
            Write-Warning "Sibling capture ${key} failed: $($row.Reason)"
        }
    }

    foreach ($t in $todo) { foreach ($c in @($t.Captures)) { & $runOne $t $c } }

    # ---- bisection of a drift (spec 2.14.8 rule 3): the middle uncaptured offering version of the first gap ----
    $extra = 0
    $gaps = @()
    while ($true) {
        $gaps = @()
        try { $gaps = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath).Gaps) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Sibling capture: the drift could not be checked ($($_.Exception.Message))."
        }
        if ($extra -ge $MaxExtra -or $gaps.Count -eq 0) { break }
        $records = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath)
        $next = $null
        foreach ($g in $gaps) {
            # Only a drift of the architecture this run captures: its offering versions say nothing about another one
            # (an x86 capture never narrows the gap of the x64 rules).
            if ([string]$g.Architecture -and [string]$g.Architecture -ne $sibArch) { continue }
            $t = @($todo | Where-Object { [string]$_.Type -eq [string]$g.Type }) | Select-Object -First 1
            if (-not $t -or -not $t.PSObject.Properties['Offering']) { continue }
            $from = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$g.From); $to = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$g.To)
            if ($null -eq $from -or $null -eq $to) { continue }
            $done = @($records | Where-Object { [string]$_.Sibling.InstallerType -eq [string]$t.Type -and [string]$_.Sibling.Architecture -eq $sibArch } | ForEach-Object { [string]$_.Sibling.Version })
            $done += @($runs | Where-Object { $_.Type -eq [string]$t.Type } | ForEach-Object { [string]$_.Version })
            $between = @(@($t.Offering) | Where-Object { $v = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_.Version); $null -ne $v -and $v -gt $from -and $v -lt $to -and $done -notcontains [string]$_.Version } |
                    Sort-Object -Property { ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_.Version) })
            if ($between.Count -gt 0) { $next = @{ Type = $t; Gap = $g; Offering = $between[[int][Math]::Floor(($between.Count - 1) / 2)] }; break }
        }
        if (-not $next) { break }
        $o = $next.Offering
        Write-Host "The $(& $safe $next.Type.Type 16) sibling changed its identity between $(& $safe $next.Gap.From 64) and $(& $safe $next.Gap.To 64): one more capture ($(& $safe $o.Version 64)) to narrow it down." -ForegroundColor Cyan
        & $runOne $next.Type ([pscustomobject]@{ Version = [string]$o.Version; Role = 'Extra'; ReleaseDate = [string]$o.ReleaseDate; Scope = [string]$o.Scope; CaptureKey = (& $keyOf ([string]$next.Type.Type) ([string]$o.Version)) })
        $extra++
    }

    # ---- the index (informational; every reader re-derives from the hash-verified records) ----
    $records = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath)
    $index = [ordered]@{
        SchemaVersion = '1.1'
        UpdatedUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        Package       = [ordered]@{ WingetId = [string]$pkg.WingetId; Version = [string]$pkg.Version; Architecture = [string]$pkg.Architecture; InstallerType = [string]$pkg.InstallerType }
        Backend       = $Backend
        Records       = @($records | ForEach-Object { [ordered]@{ CaptureId = $_.CaptureId; CaptureKey = $_.CaptureKey; Type = $_.Sibling.InstallerType; Version = $_.Sibling.Version; Role = $_.Sibling.Role; Primary = $_.Observation.ProvisionalPrimary; Probe = $_.Probe.Result; Backend = $_.Run.Backend; Mode = $_.Run.Mode } })
        LastRun       = @($runs.ToArray())
        Failed        = @($failed.ToArray())
        ReportOnly    = @(@($Plan.Types) | Where-Object { $_.Class -eq 'ReportOnly' } | ForEach-Object { [ordered]@{ Type = $_.Type; Reason = $_.Reason } })
        NotCapturable = @(@($Plan.Types) | Where-Object { $_.Class -eq 'NotCapturable' } | ForEach-Object { [ordered]@{ Type = $_.Type; Reason = $_.Reason } })
        Gaps          = @($gaps | ForEach-Object { [ordered]@{ Type = [string]$_.Type; From = [string]$_.From; To = [string]$_.To } })
        ProbeFailures = @($Plan.ProbeFailures)
    }
    $null = New-Item -ItemType Directory -Path $docDir -Force
    [IO.File]::WriteAllText((Join-Path $docDir 'SiblingCapture.json'), (ConvertTo-Json -InputObject $index -Depth 8), [Text.UTF8Encoding]::new($false))
    $recorded = @($runs | Where-Object { $_.Status -eq 'Recorded' }).Count
    Write-Host "`nSibling capture: $recorded recorded, $($failed.Count) failed (Documentation\SiblingCapture.json)." -ForegroundColor $(if ($failed.Count) { 'Yellow' } else { 'Green' })
    return ($recorded -gt 0)
}
