function Invoke-Win32ToolkitSiblingCapture {
    <#
    .SYNOPSIS
        Captures the other installer technologies of an app in the Hyper-V test VM, one isolated run per capture.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.4 - 2.14.7; SV4, SV17, SV20, L18 - L22, L31, L35). For every capture of the
        plan (Get-Win32ToolkitSiblingCapturePlan; RemovableNow types, and ReportOnly ones the plan was asked to include):

          1. download exactly that installer type at that version (Download-OldVersionInstaller -ExactType) into
             Sandbox\Siblings\<CaptureKey>; not offered -> CaptureFailed 'not offered';
          2. a work folder Sandbox\SiblingRuns\<CaptureKey>-<yyyyMMddHHmmss>: in\SiblingCapture.ps1 (UTF-8 with BOM),
             in\SiblingCapture.data.json (BOM-less: the capture's values; the script holds none), in\installer\<leaf> and an
             empty quarantine\. Nothing else of the project enters the guest (no dependencies);
          3. the tripwire baseline of the project (L18), then the Hyper-V run of in\ with five constant phases
             (snapshot before, install, snapshot after - each StopRunOnFailure -, the removability probe, log collection
             - Always -), its output copied back into quarantine\ only, through the allow-list and the 64 MB / 160 MB caps;
          4. the tripwire check once the run returned (W32T.GuestTamper stops the whole capture), then the quarantine read
             (ConvertFrom-Win32ToolkitSiblingCaptureOutput) and the record written as
             Documentation\SiblingCapture\<CaptureId>.json (CaptureId = the first 16 hex of the SHA-256 of its bytes);
             the quarantine is deleted after a successful read, the work files are kept.
        Then the index Documentation\SiblingCapture.json (SchemaVersion 1.1, informational) lists every hash-verified record,
        this run's failures and the ReportOnly / NotCapturable types. A capture never writes PriorInstalls.
    .PARAMETER ProjectPath
        The PSADT project folder (its pre-flight passed: Test-Win32ToolkitSiblingCapturePreflight).
    .PARAMETER Plan
        The plan (Get-Win32ToolkitSiblingCapturePlan).
    .PARAMETER Backend
        HyperV (this version captures on Hyper-V only).
    .OUTPUTS
        $true when at least one record was written, $false when every capture failed, $null when there was nothing to
        capture. A W32T.* error (W32T.GuestTamper, a lease timeout) is thrown.
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

        [ValidateSet('HyperV')]
        [string]$Backend = 'HyperV'
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
    $runs = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()

    $todo = @(@($Plan.Types) | Where-Object { @($_.Captures).Count -gt 0 -and $_.Class -in @('RemovableNow', 'ReportOnly') })
    # ---- the plan, before the first run (SV23, measured by H-S20 on 2026-10-25: about 2.5 minutes per Hyper-V capture run; 3-5 announced) ----
    Write-Host ''
    Write-Host "Sibling capture plan for $(& $safe $pkg.WingetId 128) $(& $safe $pkg.Version 64) ($(& $safe $pkg.Architecture 8), packaged as $(& $safe $pkg.InstallerType 32)):" -ForegroundColor Cyan
    foreach ($t in @($Plan.Types)) {
        $caps = (@($t.Captures) | ForEach-Object { "$($_.Version) ($($_.Role))" }) -join ', '
        $why = if ($t.Reason) { " - $($t.Reason)" } else { '' }
        Write-Host ("  {0,-9} {1,-14} {2}{3}" -f $t.Type, $t.Class, $(if ($caps) { $caps } else { '-' }), $why)
    }
    foreach ($pf in @($Plan.ProbeFailures)) { Write-Host "  (not checked: $(& $safe $pf 200))" -ForegroundColor DarkGray }
    $count = @($todo | ForEach-Object { @($_.Captures) }).Count
    if ($count -eq 0) {
        Write-Host 'Nothing to capture: no other installer technology of this app can be captured.' -ForegroundColor Yellow
        return $null
    }
    Write-Host "$count capture run(s) on the Hyper-V test VM, about $(3 * $count)-$(5 * $count) minutes." -ForegroundColor Cyan

    foreach ($t in $todo) {
        foreach ($c in @($t.Captures)) {
            $key = [string]$c.CaptureKey
            $row = [ordered]@{ CaptureKey = $key; Type = [string]$t.Type; Version = [string]$c.Version; Role = [string]$c.Role; Status = 'CaptureFailed'; CaptureId = ''; Reason = '' }
            Write-Host "`nSibling capture $key ($($t.Type) $(& $safe $c.Version 64), $($c.Role))" -ForegroundColor Cyan
            try {
                # 1. the exact installer type
                $dlArgs = @{ AppId = [string]$pkg.WingetId; Version = [string]$c.Version; ProjectPath = $ProjectPath; DestinationDir = (Join-Path $ProjectPath "Sandbox\Siblings\$key")
                    Architecture = [string]$pkg.Architecture; InstallerType = [string]$t.Type; ExactType = $true }
                if ($c.Scope -in @('machine', 'user')) { $dlArgs['Scope'] = [string]$c.Scope }
                $dl = $null
                try { $dl = Download-OldVersionInstaller @dlArgs }
                catch {
                    if ($_.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable') { $row.Reason = 'not offered'; $failed.Add($row); $runs.Add($row); Write-Warning "Sibling capture ${key}: winget offers no $($t.Type) installer at this version (not captured)."; continue }
                    throw
                }
                $leaf = [string]$dl.InstallerName
                $installerSha = (Get-FileHash -LiteralPath $dl.InstallerPath -Algorithm SHA256).Hash.ToUpperInvariant()
                $manifestText = (@($dl.ManifestPath) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) }) -join "`n---`n"
                $m = ConvertFrom-Win32ToolkitWingetManifest -Text $manifestText
                $inst = $null
                if ($m) {
                    $inst = @($m.Installers | Where-Object { ($_.InstallerType -eq $t.Type -or $_.NestedInstallerType -eq $t.Type -or ($t.Type -in @('msi', 'wix') -and $_.InstallerType -in @('msi', 'wix'))) -and ($_.Architecture -in @([string]$pkg.Architecture, 'neutral', '')) }) | Select-Object -First 1
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
                $data = [ordered]@{
                    SchemaVersion = '1.0'; CaptureKey = $key; InstallerType = [string]$t.Type; ExpectedKind = $expected; Version = [string]$c.Version; Architecture = [string]$pkg.Architecture
                    InstallerFile = $leaf; InstallerArgs = [string]$dl.SilentArgs; OutDir = 'C:\PSADT\Out'; Manifest = $manifest
                    Own = [ordered]@{ ArpKeys = [object[]]$ownKeys; ProductCodes = [string[]]$ownCodes }; PackagePublisher = $pkgPublisher; Mode = 'Unattended'
                }
                [IO.File]::WriteAllText((Join-Path $inDir 'SiblingCapture.data.json'), (ConvertTo-Json -InputObject $data -Depth 8), [Text.UTF8Encoding]::new($false))

                # 3. the run, between the tripwire baseline and its check (L18)
                $trip = Get-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath
                $k = [regex]::Escape($key)
                $allow = '^Out/(Sibling(Pre|Install|Capture|Probe|Done)_' + $k + '\.json|SiblingCopy_' + $k + '_(uninstaller|main)\.exe|Logs/[A-Za-z0-9_.-]{1,64}\.log)$'
                $phases = @(
                    @{ Label = 'Sibling: snapshot before'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase PreSibling; exit `$LASTEXITCODE"; StopRunOnFailure = $true }
                    @{ Label = 'Sibling: install'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase Install; exit `$LASTEXITCODE"; StopRunOnFailure = $true }
                    @{ Label = 'Sibling: snapshot after'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase PostSibling; exit `$LASTEXITCODE"; StopRunOnFailure = $true }
                    @{ Label = 'Sibling: removability probe'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase Probe; exit `$LASTEXITCODE" }
                    @{ Label = 'CollectLogs'; Command = "& 'C:\PSADT\SiblingCapture.ps1' -Phase CollectLogs"; IgnoreExit = $true; Always = $true }
                )
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $ok = Invoke-Win32ToolkitHyperVRun -ProjectPath $inDir -Phase $phases -Output @('Out\*') -ResultDestination $quarantine -ResultAllowedEntry $allow -ResultMaxEntryBytes 64MB -ResultMaxTotalBytes 160MB
                Assert-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath -Before $trip -Scenario 'SiblingCapture'
                if (-not $ok) { Write-Warning "Sibling capture ${key}: the Hyper-V run did not complete." }

                # 4. the record
                $sibling = [ordered]@{
                    InstallerType = [string]$t.Type; EffectiveType = [string]$t.EffectiveType; Version = [string]$c.Version; Role = [string]$c.Role; ReleaseDate = [string]$c.ReleaseDate
                    Scope = $(if ($dl.Scope -in @('machine', 'user')) { [string]$dl.Scope } else { '' }); Locale = [string]$dl.Locale; Architecture = [string]$pkg.Architecture
                    InstallerFile = $leaf; InstallerSha256 = $installerSha; SilentArgs = [string]$dl.SilentArgs; SilentArgsSource = [string]$dl.SilentArgsSource; Manifest = $manifest
                }
                $facts = @{
                    CaptureKey    = $key
                    Package       = [ordered]@{ WingetId = [string]$pkg.WingetId; Version = [string]$pkg.Version; Architecture = [string]$pkg.Architecture; InstallerType = [string]$pkg.InstallerType; Family = [string]$pkg.Family }
                    Sibling       = $sibling
                    Run           = @{ Backend = $Backend; Mode = 'Unattended'; Seconds = [int]$watch.Elapsed.TotalSeconds; ToolkitVersion = $toolkitVersion; GuestScriptSha256 = $scriptSha; DependenciesSkipped = $true }
                    InstallerPath = [string]$dl.InstallerPath
                }
                $read = ConvertFrom-Win32ToolkitSiblingCaptureOutput -RunFolder $runFolder -Context $facts
                if (-not $read.Record) { $row.Reason = [string]$read.Failure; $failed.Add($row); $runs.Add($row); Write-Warning "Sibling capture ${key}: no record ($($row.Reason))."; continue }
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
                if ([string]$read.Record.Observation.NoiseControl -ne 'Verified') {
                    Write-Warning "Sibling capture ${key}: the guest noise control was not verified ($(if ($read.NoiseDetail) { $read.NoiseDetail } else { 'no states reported' }); Windows Update installed something, or an updater ran during the capture): the proposals of this identity are Block-only."
                }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $row.Reason = & $safe $_.Exception.Message 200
                $failed.Add($row); $runs.Add($row)
                Write-Warning "Sibling capture ${key} failed: $($row.Reason)"
            }
        }
    }

    # ---- the index (informational; every reader re-derives from the hash-verified records) ----
    $records = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath)
    $index = [ordered]@{
        SchemaVersion = '1.1'
        UpdatedUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        Package       = [ordered]@{ WingetId = [string]$pkg.WingetId; Version = [string]$pkg.Version; Architecture = [string]$pkg.Architecture; InstallerType = [string]$pkg.InstallerType }
        Backend       = $Backend
        Records       = @($records | ForEach-Object { [ordered]@{ CaptureId = $_.CaptureId; CaptureKey = $_.CaptureKey; Type = $_.Sibling.InstallerType; Version = $_.Sibling.Version; Role = $_.Sibling.Role; Primary = $_.Observation.ProvisionalPrimary; Probe = $_.Probe.Result } })
        LastRun       = @($runs.ToArray())
        Failed        = @($failed.ToArray())
        ReportOnly    = @(@($Plan.Types) | Where-Object { $_.Class -eq 'ReportOnly' } | ForEach-Object { [ordered]@{ Type = $_.Type; Reason = $_.Reason } })
        NotCapturable = @(@($Plan.Types) | Where-Object { $_.Class -eq 'NotCapturable' } | ForEach-Object { [ordered]@{ Type = $_.Type; Reason = $_.Reason } })
        Gaps          = @()
        ProbeFailures = @($Plan.ProbeFailures)
    }
    $null = New-Item -ItemType Directory -Path $docDir -Force
    [IO.File]::WriteAllText((Join-Path $docDir 'SiblingCapture.json'), (ConvertTo-Json -InputObject $index -Depth 8), [Text.UTF8Encoding]::new($false))
    $recorded = @($runs | Where-Object { $_.Status -eq 'Recorded' }).Count
    Write-Host "`nSibling capture: $recorded recorded, $($failed.Count) failed (Documentation\SiblingCapture.json)." -ForegroundColor $(if ($failed.Count) { 'Yellow' } else { 'Green' })
    return ($recorded -gt 0)
}
