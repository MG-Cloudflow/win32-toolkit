<#
    Installer-identity PR 3b (spec 2.14.1, 2.14.5, 2.14.7, 2.16; SV4, SV5, SV11, C-14, L18, L31, L35): the sibling capture
    on the host - the quarantine reader, the records, the run loop, the pre-flight and the CLI scenario. The VM, winget
    and the downloads are shadowed; the reader, the record re-typer and reader, and the tripwire are real.

      [1] ConvertFrom-Win32ToolkitSiblingCaptureOutput: a good quarantine -> a record in the frozen shape (host checks:
          the NSIS marker read from the copied uninstaller, the copies deleted); hostile JSON (CR/LF/NUL, ESC, bidi and
          isolate controls, U+2028/2029, CMTrace delimiters, a comment-close sequence) -> kept but flagged UnsafeText and neutralised; '..'
          paths and a non-Program-Files InstallDir dropped; an 8 MB+ file, a failed or timed-out install, a missing file
          -> no record, with the reason.
      [2] Invoke-Win32ToolkitSiblingCapture: the record is written as Documentation\SiblingCapture\<CaptureId>.json with
          CaptureId = the SHA-256 prefix of its bytes, it round-trips through Get-Win32ToolkitSiblingCaptureRecord, a
          tampered record is ignored; a type not offered -> CaptureFailed 'not offered', the rest go on; the index lists
          records and failures; $true / $false / $null; a plan whose winget manifests could not be read (the package's,
          HTTP 429; or every version of a type) -> $false with one warning saying when to capture again, never "Nothing to
          capture" (live rows RAISE, INNO); the work folder holds the BOM script, the BOM-less data file (with
          the package's publisher and the installer's switches) and the installer, the quarantine goes after a successful
          read; a guest that changes the project -> W32T.GuestTamper.
      [3] Test-Win32ToolkitSiblingCapturePreflight never throws: an unsupported shape, a manual app, no OwnIdentity, an
          ARM64 package -> Ok false, the reason and the code (the Windows Sandbox fallback of a Hyper-V VM that is not ready:
          SiblingCaptureExtras.unit [2]).
      [4] Test-Win32ToolkitProject -Scenario SiblingCapture: a refused pre-flight throws its code and runs nothing; the
          result of the capture is returned; sibling parameters outside the scenario, and Update parameters in it, are
          refused.

    Run:  pwsh -File Tests\SiblingCapture.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32sc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$key = 'nullsoft-8.9.8'
function New-NsisBytes { $b = [byte[]]::new(2048); $sig = [byte[]](0xEF, 0xBE, 0xAD, 0xDE) + [Text.Encoding]::ASCII.GetBytes('NullsoftInst'); [Array]::Copy($sig, 0, $b, 516, $sig.Length); $b }
function Cand([hashtable]$O = @{}) {
    $c = [ordered]@{ Key = 'Notepad++'; View = 'Native'; DisplayName = 'Notepad++ (64-bit x64)'; DisplayVersion = '8.9.8'; Publisher = 'Notepad++ Team'; WindowsInstaller = $false; SystemComponent = $false
        InstallLocation = 'C:\Program Files\Notepad++'; DisplayIconLeaf = 'notepad++.exe'; UninstallerPath = 'C:\Program Files\Notepad++\uninstall.exe'; UninstallerCanonical = $true; UninstallerLeaf = 'uninstall.exe'
        InstallDir = '%ProgramFiles%\Notepad++'; MainExe = 'notepad++.exe'; Files = @('notepad++.exe', 'uninstall.exe', 'config.xml'); InstallLocationFiles = @(); InnoAppPath = $false; UnsDat = $false; QuietUninstallArgs = ''
        Acl = @([ordered]@{ Path = 'C:\Program Files\Notepad++'; Owner = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Rules = @([ordered]@{ Sid = 'S-1-5-18'; Rights = 2032127; Inheritance = 3; Propagation = 0; Type = 'Allow' }) }); UnsafeText = $false }
    foreach ($k in $O.Keys) { $c[$k] = $O[$k] }
    $c
}
function Write-Quarantine([string]$Run, [hashtable]$O = @{}, [string]$K = $key) {
    $out = Join-Path $Run 'quarantine\Out'
    $null = New-Item -ItemType Directory -Path $out -Force
    $files = @{
        "SiblingPre_$K.json"     = [ordered]@{ SchemaVersion = '1.0'; StartedUtc = '2026-10-25T10:00:00Z'; Account = 'NT AUTHORITY\SYSTEM'; Is64 = $true; OsBuild = '10.0.26100.1'; NoiseVerified = $true }
        "SiblingInstall_$K.json" = [ordered]@{ InstallFailed = $false; ExitCode = 0; TimedOut = $false; Completed = $true; RebootRequested = $false; Lingering = @(); Seconds = 40 }
        "SiblingCapture_$K.json" = [ordered]@{ SchemaVersion = '1.0'; Candidates = @((Cand)); Services = @(); Shortcuts = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Notepad++.lnk'); Tasks = @(); Appx = @(); HkcuArp = @()
            NewRoots = @('C:\Program Files\Notepad++'); NoiseControl = 'Verified'; PfroCount = 0; ProvisionalPrimary = 'Notepad++'; ProvisionalView = 'Native' }
        "SiblingProbe_$K.json"   = [ordered]@{ Result = 'Clean'; ProbedKey = 'Notepad++'; ProbedView = 'Native'; ExitCode = 0; Seconds = 12; LingeringProcess = @('Au_'); PfroUnderRoot = $false; RootConfigRemoved = $true; VendorConfigRemoved = @('config.xml') }
        "SiblingDone_$K.json"    = [ordered]@{ SchemaVersion = '1.0' }
    }
    foreach ($k in $O.Keys) { $files[$k] = $O[$k] }
    foreach ($n in $files.Keys) { if ($null -ne $files[$n]) { [IO.File]::WriteAllText((Join-Path $out $n), ($files[$n] | ConvertTo-Json -Depth 10), $utf8) } }
    [IO.File]::WriteAllBytes((Join-Path $out "SiblingCopy_${K}_uninstaller.exe"), (New-NsisBytes))
    $out
}
$facts = @{
    CaptureKey = $key
    Package = [ordered]@{ WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = 'x64'; InstallerType = 'wix'; Family = 'msi' }
    Sibling = [ordered]@{ InstallerType = 'nullsoft'; EffectiveType = 'nullsoft'; Version = '8.9.8'; Role = 'Floor'; ReleaseDate = '2026-09-01'; Scope = 'machine'; Locale = ''; Architecture = 'x64'
        InstallerFile = 'npp.8.9.8.Installer.x64.exe'; InstallerSha256 = ('A' * 64); SilentArgs = '/S'; SilentArgsSource = 'catalog'
        Manifest = [ordered]@{ ProductCodes = @('Notepad++'); Afe = @(); PackageName = 'Notepad++'; Publisher = 'Notepad++ Team'; DefaultInstallLocation = '%ProgramFiles%\Notepad++' } }
    Run = @{ Backend = 'HyperV'; Mode = 'Unattended'; Seconds = 300; ToolkitVersion = '1.4.0'; GuestScriptSha256 = ('B' * 64); DependenciesSkipped = $true }
    InstallerPath = ''
}
function Read-Run([string]$Run) { ConvertFrom-Win32ToolkitSiblingCaptureOutput -RunFolder $Run -Context $facts }

try {
    # == [1] the quarantine reader ==========================================================================
    Write-Host '[1] ConvertFrom-Win32ToolkitSiblingCaptureOutput' -ForegroundColor Cyan
    $run = Join-Path $root 'run1'; $out = Write-Quarantine $run
    $r = Read-Run $run
    $rec = $r.Record
    if ($rec -and -not $r.Failure -and $rec.CaptureKey -eq $key -and $rec.Observation.Candidates.Count -eq 1 -and $rec.Observation.ProvisionalPrimary -eq 'Notepad++' -and $rec.Probe.Result -eq 'Clean' -and
        $rec.Run.StartedUtc -eq '2026-10-25T10:00:00Z' -and $rec.Run.Account -eq 'NT AUTHORITY\SYSTEM' -and $rec.Install.Completed -and $rec.Probe.RootConfigRemoved) { Ok 'a good quarantine -> the record (candidates, probe, run and install facts)' } else { Bad "good: $($r | ConvertTo-Json -Depth 4 -Compress)" }
    if ($rec.HostChecks.NsisMagic -and -not $rec.HostChecks.InnoMarkers -and -not (Test-Path -LiteralPath (Join-Path $out "SiblingCopy_${key}_uninstaller.exe"))) { Ok 'the NSIS marker read from the copied uninstaller (never run); the copy deleted (L31)' } else { Bad "host checks: $($rec.HostChecks | ConvertTo-Json -Compress)" }
    $typedAgain = ConvertTo-Win32ToolkitSiblingCaptureRecord -InputObject $rec
    if ($null -ne $typedAgain -and ($typedAgain | ConvertTo-Json -Depth 12 -Compress) -ceq ($rec | ConvertTo-Json -Depth 12 -Compress)) { Ok 'the record is in the frozen shape (the re-typer returns it unchanged)' } else { Bad 'not frozen shape' }

    # Live row GOAL-CAPTURE (2026-10-26): an Unverified record said nothing about which service or task was not controlled.
    # The guest's NoiseDetail reaches the operator (printable, capped), never the record.
    $runN = Join-Path $root 'run-noise'
    $null = Write-Quarantine $runN @{ "SiblingCapture_$key.json" = [ordered]@{ SchemaVersion = '1.0'; Candidates = @((Cand)); NewRoots = @('C:\Program Files\Notepad++'); NoiseControl = 'Unverified'
            NoiseDetail = @('wuauserv Running/Manual', "edgeupdate Stopped/Disabled$([char]0x1B)[31m"); PfroCount = 0; ProvisionalPrimary = 'Notepad++'; ProvisionalView = 'Native' } }
    $rn = Read-Run $runN
    if ($rn.Record -and $rn.Record.Observation.NoiseControl -eq 'Unverified' -and $rn.NoiseDetail -match '^wuauserv Running/Manual; edgeupdate Stopped/Disabled\?' -and -not $rn.Record.Observation.Contains('NoiseDetail')) { Ok 'NoiseDetail: the guest states for the operator (printable), not part of the record' } else { Bad "noise detail: '$($rn.NoiseDetail)' record keys $($rn.Record.Observation.Keys -join ',')" }
    $invSrc = [IO.File]::ReadAllText((Join-Path $repo 'Private\Invoke-Win32ToolkitSiblingCapture.ps1'))
    if ($invSrc -match "the guest noise control was not verified \(\`$\(if \(\`$read\.NoiseDetail\)") { Ok 'the capture warns with the noise states when a record is Unverified' } else { Bad 'no noise warning in Invoke-Win32ToolkitSiblingCapture' }
    # Live rows DEMOTE, INNO, ASSISTED: the warning said "Windows Update installed something, or an updater ran" for a check
    # before the install that failed while Windows Update installed nothing. The cause follows the guest's detail.
    $causeOf = {
        param([string[]]$Detail)
        $rd = Join-Path $root ('run-cause-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = Write-Quarantine $rd @{ "SiblingCapture_$key.json" = [ordered]@{ SchemaVersion = '1.0'; Candidates = @((Cand)); NewRoots = @('C:\Program Files\Notepad++'); NoiseControl = 'Unverified'
                NoiseDetail = $Detail; PfroCount = 0; ProvisionalPrimary = 'Notepad++'; ProvisionalView = 'Native' } }
        (Read-Run $rd).NoiseCause
    }
    $cases = @(
        @{ D = @('before the install: wuauserv Running/Manual', 'wuauserv Running/Manual'); W = 'the update services and tasks could not be held still before the install' }
        @{ D = @('wuauserv Running/Manual', 'Windows Update installed: 2026-10 Cumulative Update (KB5099999)'); W = 'Windows Update installed something during the capture' }
        @{ D = @('before the install: edgeupdate Running/Auto', 'Windows Update event log unreadable'); W = 'the update services and tasks could not be held still before the install; the Windows Update event log could not be read, so a restarted update service could not be excused' }
        @{ D = @('edgeupdate Running/Auto'); W = 'an update service or task was not held still during the capture' }
    )
    $bad = @($cases | Where-Object { (& $causeOf $_.D) -cne $_.W })
    if ($bad.Count -eq 0 -and $r.NoiseCause -eq '' -and $invSrc -match '\$read\.NoiseCause' -and $invSrc -notmatch 'Windows Update installed something, or an updater ran') { Ok 'NoiseCause follows the guest detail (before the install / Windows Update installed / log unreadable / not held still); a Verified record has none; the warning uses it' } else { Bad "noise cause: $(@($bad | ForEach-Object { "$($_.D -join ',') -> $(& $causeOf $_.D)" }) -join ' | ')" }
    # Live rows RAISE, ASSISTED: a guest before the fix wrote the list nested ([[...]]); the host joined it into ONE string
    # and cut it at 80 characters, so the cause (UsoSvc, the Windows Update event) never showed. Flattened; 160 per item.
    $runN2 = Join-Path $root 'run-noise-nested'
    $wuItem = 'Windows Update installed: 2026-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5099999)'
    $null = Write-Quarantine $runN2 @{ "SiblingCapture_$key.json" = [ordered]@{ SchemaVersion = '1.0'; Candidates = @((Cand)); NewRoots = @('C:\Program Files\Notepad++'); NoiseControl = 'Unverified'
            NoiseDetail = @(, @('edgeupdate Stopped/Disabled', 'edgeupdatem Stopped/Disabled', 'wuauserv Running/Manual', 'UsoSvc Running/Auto', $wuItem)); PfroCount = 0; ProvisionalPrimary = 'Notepad++'; ProvisionalView = 'Native' } }
    $rn2 = Read-Run $runN2
    if ($rn2.NoiseDetail -ceq "edgeupdate Stopped/Disabled; edgeupdatem Stopped/Disabled; wuauserv Running/Manual; UsoSvc Running/Auto; $wuItem") { Ok 'a nested NoiseDetail list is flattened: every state and the full Windows Update title (not one string cut at 80)' } else { Bad "nested detail: '$($rn2.NoiseDetail)'" }

    $nul = [char]0; $esc = [char]0x1B; $rlo = [char]0x202E; $iso = [char]0x2066; $ls = [char]0x2028
    $hostile = @(
        (Cand @{ Key = "Bad${nul}Key"; DisplayName = "Note${esc}[31mpad" }),
        (Cand @{ Key = 'Rlo'; Publisher = "Evil${rlo}Corp" }),
        (Cand @{ Key = 'Iso'; DisplayName = "x${iso}y${ls}z" }),
        (Cand @{ Key = 'Cm<![LOG[x]LOG]!>'; DisplayName = 'cm' }),
        (Cand @{ Key = 'Hash'; Publisher = 'p #> q' }),
        (Cand @{ Key = 'Crlf'; DisplayName = "a`r`nb" }),
        (Cand @{ Key = 'Trav'; UninstallerPath = 'C:\Program Files\X\..\..\Windows\evil.exe'; InstallDir = '%ProgramFiles%\..\Windows' }),
        (Cand @{ Key = 'Fine'; View = 'Native' }),
        (Cand @{ Key = 'BadView'; View = 'User' })
    )
    $run2 = Join-Path $root 'run2'
    $null = Write-Quarantine $run2 @{ "SiblingCapture_$key.json" = [ordered]@{ Candidates = $hostile; NewRoots = @('C:\Program Files\X', 'C:\Program Files\..\Windows', "C:\x${nul}y"); NoiseControl = 'Bogus'; ProvisionalPrimary = 'Fine' } }
    $h = (Read-Run $run2).Record
    $by = @{}; foreach ($c in $h.Observation.Candidates) { $by[$c.Key] = $c }
    $flagged = @($h.Observation.Candidates | Where-Object UnsafeText | ForEach-Object Key)
    $json = $h | ConvertTo-Json -Depth 12 -Compress
    $clean = -not ($json.ToCharArray() | Where-Object { [int]$_ -lt 32 -or [int]$_ -in 0x1B, 0x202E, 0x2066, 0x2028 })
    if ($flagged.Count -eq 6 -and -not $by['Fine'].UnsafeText -and $clean) { Ok 'CR/LF/NUL, ESC, bidi and isolate controls, U+2028, CMTrace delimiters and #> -> kept but flagged UnsafeText; no control character survives' } else { Bad "flags: $($flagged -join ' | ')" }
    if ($by['Trav'].UninstallerPath -eq '' -and -not $by['Trav'].UninstallerCanonical -and $by['Trav'].InstallDir -eq '' -and -not $by.ContainsKey('BadView') -and (@($h.Observation.NewRoots) -join ',') -eq 'C:\Program Files\X' -and $h.Observation.NoiseControl -eq 'Unverified') { Ok "'..' uninstaller path and InstallDir dropped; a view other than Native/Wow6432 dropped; non-canonical roots dropped; an unknown NoiseControl -> Unverified" } else { Bad "sanitising: $($by['Trav'] | ConvertTo-Json -Compress) roots $(@($h.Observation.NewRoots) -join ',')" }

    foreach ($c in @(
            @{ L = 'a failed install'; O = @{ "SiblingInstall_$key.json" = [ordered]@{ ExitCode = 1603; Completed = $false; TimedOut = $false } }; Rx = 'failed \(exit code 1603\)' }
            @{ L = 'a timed-out install'; O = @{ "SiblingInstall_$key.json" = [ordered]@{ ExitCode = -1; Completed = $false; TimedOut = $true } }; Rx = 'still running after 20 minutes' }
            @{ L = 'a missing capture file'; O = @{ "SiblingCapture_$key.json" = $null }; Rx = "SiblingCapture_$key\.json is missing" }
            @{ L = 'a failed snapshot'; O = @{ "SiblingCapture_$key.json" = [ordered]@{ PostSiblingFailed = $true } }; Rx = 'snapshot after the install failed' }
        )) {
        $rr = Join-Path $root ('f' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = Write-Quarantine $rr $c.O
        $x = Read-Run $rr
        if ($null -eq $x.Record -and $x.Failure -match $c.Rx) { Ok "$($c.L) -> no record ($($x.Failure))" } else { Bad "$($c.L): $($x | ConvertTo-Json -Depth 3 -Compress)" }
    }
    $rb = Join-Path $root 'big'; $ob = Write-Quarantine $rb
    $fs = [IO.File]::Open((Join-Path $ob "SiblingCapture_$key.json"), 'Append'); $fs.SetLength(9MB); $fs.Dispose()
    $x = Read-Run $rb
    if ($null -eq $x.Record -and $x.Failure -match 'larger than 8 MB') { Ok 'a file over 8 MB is not read -> no record' } else { Bad "big: $($x.Failure)" }

    # == [2] the run loop and the records ===================================================================
    Write-Host '[2] Invoke-Win32ToolkitSiblingCapture' -ForegroundColor Cyan
    $proj = Join-Path $root 'Projects\T\Notepad++_x64_8.9.8.1'
    foreach ($d in 'SupportFiles', 'Documentation', 'Files') { $null = New-Item -ItemType Directory -Path (Join-Path $proj $d) -Force }
    [IO.File]::WriteAllText((Join-Path $proj 'SupportFiles\AppConfig.json'), (@{ App = @{ Version = '8.9.8.1'; Vendor = 'Notepad++ Team' }; OwnIdentity = @{ ProductCode = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'; ArpKeys = @(@{ Key = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'; View = 'Native' }) } } | ConvertTo-Json -Depth 5), $utf8)
    [IO.File]::WriteAllText((Join-Path $proj 'Invoke-AppDeployToolkit.ps1'), '# script', $utf8)
    $script:dl = @(); $script:runs = @(); $script:offered = @('nullsoft-8.9.8', 'nullsoft-8.9.8-r'); $script:tamper = $false; $script:noiseQ = $null
    function Download-OldVersionInstaller {
        param($AppId, $Version, $ProjectPath, $DestinationDir, $Architecture, $InstallerType, [switch]$ExactType, $Scope)
        $null = $AppId, $ProjectPath, $Architecture
        $script:dl += [pscustomobject]@{ Version = $Version; Type = $InstallerType; Exact = [bool]$ExactType; Dest = $DestinationDir; Scope = $Scope }
        if ($script:offered -notcontains (Split-Path -Leaf $DestinationDir)) {
            throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('not offered'), 'W32T.InstallerVariantUnavailable', 'ObjectNotFound', $AppId)
        }
        $null = New-Item -ItemType Directory -Path $DestinationDir -Force
        [IO.File]::WriteAllBytes((Join-Path $DestinationDir 'npp.exe'), [byte[]](1..50))
        [IO.File]::WriteAllText((Join-Path $DestinationDir 'npp.installer.yaml'), "PackageIdentifier: Notepad++.Notepad++`nPackageVersion: $Version`nPublisher: Notepad++ Team`nPackageName: Notepad++`nInstallers:`n- Architecture: x64`n  InstallerType: nullsoft`n  ProductCode: Notepad++`n  InstallationMetadata:`n    DefaultInstallLocation: '%ProgramFiles%\Notepad++'", $utf8)
        [pscustomobject]@{ InstallerPath = (Join-Path $DestinationDir 'npp.exe'); InstallerName = 'npp.exe'; SilentArgs = '/S'; SilentArgsSource = 'catalog'; Scope = 'machine'; Locale = ''; ManifestPath = @((Join-Path $DestinationDir 'npp.installer.yaml')) }
    }
    function Invoke-Win32ToolkitHyperVRun {
        param($ProjectPath, $Phase, $Output, $ResultDestination, $ResultAllowedEntry, $ResultMaxEntryBytes, $ResultMaxTotalBytes)
        $script:runs += [pscustomobject]@{ In = $ProjectPath; Phases = @($Phase | ForEach-Object Label); Stop = @($Phase | Where-Object StopRunOnFailure | ForEach-Object Label); Dest = $ResultDestination; Allow = $ResultAllowedEntry; Max = $ResultMaxEntryBytes; Total = $ResultMaxTotalBytes; Output = $Output }
        $k = ([IO.File]::ReadAllText((Join-Path $ProjectPath 'SiblingCapture.data.json')) | ConvertFrom-Json).CaptureKey
        $null = Write-Quarantine (Split-Path -Parent $ResultDestination) $(if ($script:noiseQ) { & $script:noiseQ $k } else { @{} }) $k
        if ($script:tamper) { [IO.File]::AppendAllText((Join-Path $proj 'SupportFiles\AppConfig.json'), ' ') }
        $true
    }
    $plan = [pscustomobject]@{ Package = [pscustomobject]@{ WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = 'x64'; InstallerType = 'wix'; Family = 'msi' }; Backend = 'HyperV'; ProbeFailures = @(); EstimatedRuns = 3
        Types = @([pscustomobject]@{ Type = 'nullsoft'; EffectiveType = 'nullsoft'; Class = 'RemovableNow'; Reason = ''; Captures = @(
                    [pscustomobject]@{ Version = '8.9.8'; Role = 'Newest'; ReleaseDate = '2026-09-01'; Scope = 'machine'; CaptureKey = 'nullsoft-8.9.8' },
                    [pscustomobject]@{ Version = '8.9.8'; Role = 'Repeat'; ReleaseDate = '2026-09-01'; Scope = ''; CaptureKey = 'nullsoft-8.9.8-r' },
                    [pscustomobject]@{ Version = '8.8.9'; Role = 'Floor'; ReleaseDate = '2025-12-09'; Scope = ''; CaptureKey = 'nullsoft-8.8.9' }) }
            [pscustomobject]@{ Type = 'portable'; EffectiveType = 'portable'; Class = 'NotCapturable'; Reason = 'registers nothing'; Captures = @() }) }
    $res = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $plan -Backend HyperV 6>$null 3>$null
    $records = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj)
    $files = @(Get-ChildItem -LiteralPath (Join-Path $proj 'Documentation\SiblingCapture') -File)
    $ok = $true
    foreach ($fi in $files) {
        $sha = [Security.Cryptography.SHA256]::Create(); $hx = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($fi.FullName)) | ForEach-Object { $_.ToString('x2') }); $sha.Dispose()
        if ($fi.BaseName -cne $hx.Substring(0, 16)) { $ok = $false }
    }
    if ($res -eq $true -and $records.Count -eq 2 -and $files.Count -eq 2 -and $ok) { Ok 'two records written as <CaptureId>.json, CaptureId = the first 16 hex of the SHA-256 of the bytes; both read back by Get-Win32ToolkitSiblingCaptureRecord; $true' } else { Bad "records: res=$res records=$($records.Count) files=$($files.Count) hash=$ok" }
    if (@($script:dl | Where-Object { -not $_.Exact -or $_.Type -ne 'nullsoft' }).Count -eq 0 -and $script:dl[0].Scope -eq 'machine' -and -not $script:dl[1].Scope) { Ok 'every download asks -ExactType nullsoft; the scope only where the plan saw one' } else { Bad "downloads: $($script:dl | ConvertTo-Json -Compress)" }
    $r0 = $script:runs[0]
    if ($r0.In -like '*\Sandbox\SiblingRuns\nullsoft-8.9.8-*\in' -and $r0.Dest -like '*\quarantine' -and (@($r0.Output) -join ',') -eq 'Out\*' -and $r0.Max -eq 64MB -and $r0.Total -eq 160MB -and ($r0.Stop -join ',') -eq 'Sibling: snapshot before,Sibling: install,Sibling: snapshot after' -and "Out/SiblingPre_nullsoft-8.9.8.json" -match $r0.Allow -and "Out/evil.ps1" -notmatch $r0.Allow -and "Out/SiblingPre_nullsoft-8.9.8-r.json" -notmatch $r0.Allow) {
        Ok 'the run: in\ copied in, output into quarantine\ only (Out\*, the allow-list of this key, 64 MB / 160 MB); the first three phases StopRunOnFailure'
    } else { Bad "run: $($r0 | ConvertTo-Json -Compress)" }
    $runDir = Split-Path -Parent $r0.In
    $sb = [IO.File]::ReadAllBytes((Join-Path $r0.In 'SiblingCapture.ps1')); $db = [IO.File]::ReadAllBytes((Join-Path $r0.In 'SiblingCapture.data.json'))
    if ($sb[0] -eq 0xEF -and $sb[1] -eq 0xBB -and $db[0] -ne 0xEF -and (Test-Path -LiteralPath (Join-Path $r0.In 'installer\npp.exe')) -and -not (Test-Path -LiteralPath (Join-Path $runDir 'quarantine')) -and @(Get-ChildItem -LiteralPath $r0.In -Recurse -File).Count -eq 3) { Ok 'the work folder: the script with a BOM, the BOM-less data file and the installer only; the quarantine removed after the read' } else { Bad 'work folder' }
    # The guest ranks with the host's inputs (SV16): the package's publisher (App.Vendor) is in the data file.
    $d0 = [Text.Encoding]::UTF8.GetString($db) | ConvertFrom-Json
    if ($d0.PackagePublisher -ceq 'Notepad++ Team' -and $d0.InstallerArgs -ceq '/S') { Ok "the data file carries the package's publisher (App.Vendor, the host's attribution input) and the installer's switches" } else { Bad "data: PackagePublisher [$($d0.PackagePublisher)] InstallerArgs [$($d0.InstallerArgs)]" }
    $idx = Get-Content -LiteralPath (Join-Path $proj 'Documentation\SiblingCapture.json') -Raw | ConvertFrom-Json
    if ($idx.SchemaVersion -eq '1.1' -and @($idx.Records).Count -eq 2 -and @($idx.Failed).Count -eq 1 -and $idx.Failed[0].CaptureKey -eq 'nullsoft-8.8.9' -and $idx.Failed[0].Reason -eq 'not offered' -and @($idx.NotCapturable).Count -eq 1) { Ok "the index: 2 records, 1 failure ('not offered', the run went on), the NotCapturable type" } else { Bad "index: $($idx | ConvertTo-Json -Depth 4 -Compress)" }
    $one = $files[0].FullName; $bytes = [IO.File]::ReadAllBytes($one); $bytes[20] = [byte](($bytes[20] + 1) % 256); [IO.File]::WriteAllBytes($one, $bytes)
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj).Count -eq 1) { Ok 'a tampered record (its bytes no longer match its name) is ignored' } else { Bad 'tampered record read' }

    $script:offered = @()
    $res2Out = @(Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $plan -Backend HyperV 6>&1 3>$null)
    $res2 = @($res2Out | Where-Object { $_ -is [bool] }) | Select-Object -Last 1
    # Live row GOAL-CAPTURE: the announced cost follows the H-S20 measurement (about 2.5 minutes per Hyper-V capture run).
    if (@($res2Out | Where-Object { "$_" -match '^3 capture run\(s\) .*, about 9-15 minutes' }).Count -eq 1) { Ok 'the plan announces about 3-5 minutes per capture run (3 runs -> 9-15 minutes)' } else { Bad "estimate: $(@($res2Out | Where-Object { "$_" -match 'capture run' }) -join ' | ')" }
    # Live row GOAL-CAPTURE (round 2): '(plus up to 4 if ...)' right after the minutes read as 4 minutes; it is 4 capture runs.
    if (@($res2Out | Where-Object { "$_" -match '9-15 minutes; up to 4 more capture run\(s\), about 12-20 minutes, if a technology changed its identity between versions\.$' }).Count -eq 1) { Ok 'the extra bisection runs are named as capture runs with their own minutes (up to 4 more -> 12-20 minutes)' } else { Bad "extra estimate: $(@($res2Out | Where-Object { "$_" -match 'capture run' }) -join ' | ')" }
    $res3 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan ([pscustomobject]@{ Package = $plan.Package; Types = @($plan.Types[1]); ProbeFailures = @() }) -Backend HyperV 6>$null 3>$null
    if ($res2 -eq $false -and $null -eq $res3) { Ok 'every capture failed -> $false; nothing to capture -> $null' } else { Bad "results: $res2 / $res3" }

    # Live rows RAISE, INNO: a winget manifest that could not be read is not "nothing to capture": $false, one warning
    # with the reason and when to capture again, no "Nothing to capture" line, no download, the index left as it was.
    $idxPath = Join-Path $proj 'Documentation\SiblingCapture.json'
    $idxHash = (Get-FileHash -LiteralPath $idxPath).Hash
    $dlBefore = @($script:dl).Count
    $at = '2026-10-29T14:05:00.0000000Z'
    $limited = [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'RateLimited'; RetryAfterUtc = $at; Cause = 'Transient' }
        RetryAfterUtc = $at; Types = @(); ProbeFailures = @("the package version's winget manifest could not be read (RateLimited)"); EstimatedRuns = 0 }
    $o4 = @(Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $limited -Backend HyperV -WarningVariable w4 -WarningAction SilentlyContinue 6>&1)
    $r4 = @($o4 | Where-Object { $_ -is [bool] })
    $h4 = @($o4 | Where-Object { $_ -isnot [bool] } | ForEach-Object { "$_" })
    if ($r4.Count -eq 1 -and $r4[0] -eq $false -and @($w4).Count -eq 1 -and
        "$($w4[0])" -match "^Nothing was captured: the winget manifest of Notepad\+\+\.Notepad\+\+ 8\.9\.8\.1 could not be read \(RateLimited\), so the other installer technologies of this app are not known\. GitHub limits requests from this computer until 14:05 UTC; capture again after that: Test-Win32ToolkitProject -ProjectPath '.+' -Scenario SiblingCapture\.$" -and
        @($h4 | Where-Object { $_ -match 'Nothing to capture' }).Count -eq 0 -and @($script:dl).Count -eq $dlBefore -and (Get-FileHash -LiteralPath $idxPath).Hash -ceq $idxHash) {
        Ok 'the package manifest rate-limited -> $false; one warning: could not be read (RateLimited), until 14:05 UTC, the command; no "Nothing to capture", no download, the index unchanged'
    } else { Bad "limited: result [$($r4 -join ',')] warnings [$(@($w4) -join ' || ')] host [$($h4 -join ' || ')] downloads $(@($script:dl).Count - $dlBefore)" }
    $innoWhy = 'its versions could not be checked: 2 winget manifest(s) could not be read (Network)'
    $unchecked = [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = [pscustomobject]@{ Status = 'Ok'; Reason = ''; RetryAfterUtc = ''; Cause = '' }; RetryAfterUtc = ''
        Types = @([pscustomobject]@{ Type = 'inno'; EffectiveType = 'inno'; Class = 'RemovableNow'; Reason = $innoWhy; ProbeFailed = $true; ProbeCause = 'Transient'; Captures = @() })
        ProbeFailures = @('inno 2.9: the manifest could not be read (Network)', 'inno 2.8: the manifest could not be read (Network)'); EstimatedRuns = 0 }
    $r5 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $unchecked -Backend HyperV -WarningVariable w5 -WarningAction SilentlyContinue 6>$null
    if ($r5 -eq $false -and @($w5).Count -eq 1 -and "$($w5[0])" -match "^Nothing was captured: no technology could be checked \(inno: $([regex]::Escape($innoWhy))\)\. Capture again later: Test-Win32ToolkitProject -ProjectPath '.+' -Scenario SiblingCapture\.$" -and (Get-FileHash -LiteralPath $idxPath).Hash -ceq $idxHash) {
        Ok 'the only capturable type is ProbeFailed (Transient) -> $false; one warning with the type''s own reason, capture again later'
    } else { Bad "unchecked: $r5 [$(@($w5) -join ' || ')]" }
    # One type planned, one ProbeFailed: the planned one is captured, and one warning names the other with the command.
    $script:offered = @('nullsoft-8.9.8')
    $nsOne = [pscustomobject]@{ Type = 'nullsoft'; EffectiveType = 'nullsoft'; Class = 'RemovableNow'; Reason = ''; ProbeFailed = $false; ProbeCause = ''; Captures = @($plan.Types[0].Captures[0]) }
    $partial = [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = $unchecked.PackageProbe; RetryAfterUtc = '2026-10-29T09:30:00Z'
        Types = @($nsOne, $unchecked.Types[0])
        ProbeFailures = @('inno 2.9: the manifest could not be read (RateLimited); no further version was checked'); EstimatedRuns = 1 }
    $r6 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $partial -Backend HyperV -MaxExtra 0 -WarningVariable w6 -WarningAction SilentlyContinue 6>$null
    $w6t = @($w6 | ForEach-Object { "$_" } | Where-Object { $_ -match '^Not captured:' })
    if ($r6 -eq $true -and $w6t.Count -eq 1 -and $w6t[0] -match "^Not captured: inno: $([regex]::Escape($innoWhy))\. GitHub limits requests from this computer until 09:30 UTC; capture again after that: Test-Win32ToolkitProject -ProjectPath '.+' -Scenario SiblingCapture -SiblingInstallerType inno\.$") {
        Ok 'one type planned, one ProbeFailed -> the planned one is captured ($true); one warning names inno, the time and -SiblingInstallerType inno'
    } else { Bad "partial: $r6 [$(@($w6) -join ' || ')]" }
    # A ProbeFailed ReportOnly type: the command keeps -IncludeReportOnly (else that type is not captured again and the
    # retry reads "Nothing to capture"); a type outside the -SiblingInstallerType set (appx) is not named in it.
    foreach ($c in @(@{ T = 'appx'; Rx = ' -IncludeReportOnly\.$' }, @{ T = 'msi'; Rx = ' -IncludeReportOnly -SiblingInstallerType msi\.$' })) {
        $script:offered = @('nullsoft-8.9.8')
        $ro = [pscustomobject]@{ Type = $c.T; EffectiveType = $c.T; Class = 'ReportOnly'; Reason = 'its versions could not be checked: 1 winget manifest(s) could not be read (Network)'; ProbeFailed = $true; ProbeCause = 'Transient'; Captures = @() }
        $pRo = [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = $unchecked.PackageProbe; RetryAfterUtc = ''; Types = @($nsOne, $ro); ProbeFailures = @(); EstimatedRuns = 1
            Request = [pscustomobject]@{ SiblingInstallerType = [string[]]@(); SiblingVersion = [string[]]@(); VersionsBack = 0; Coverage = 0; IncludeReportOnly = $true } }
        $r7 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $pRo -Backend HyperV -MaxExtra 0 -WarningVariable w7 -WarningAction SilentlyContinue 6>$null
        $w7t = @($w7 | ForEach-Object { "$_" } | Where-Object { $_ -match '^Not captured:' })
        if ($r7 -eq $true -and $w7t.Count -eq 1 -and $w7t[0] -match "-Scenario SiblingCapture$($c.Rx)" -and ($c.T -ne 'appx' -or $w7t[0] -notmatch 'SiblingInstallerType')) { Ok "a ProbeFailed ReportOnly $($c.T) -> the command keeps -IncludeReportOnly$(if ($c.T -eq 'appx') { ' and names no -SiblingInstallerType (appx is not in its set)' } else { ' and names -SiblingInstallerType msi' })" } else { Bad "reportonly $($c.T): $r7 [$(@($w7) -join ' || ')]" }
    }
    # The command keeps the scope of the run (x86 siblings, the versions asked for, the types, -Assisted); GitHub's time
    # is rounded up to the minute (10:01:40 -> 10:02).
    $scoped = [pscustomobject]@{ Package = $plan.Package; Architecture = 'x86'; Backend = 'HyperV'; PackageProbe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'RateLimited'; RetryAfterUtc = '2026-10-29T10:01:40.0000000Z'; Cause = 'Transient' }
        RetryAfterUtc = '2026-10-29T10:01:40.0000000Z'; Types = @(); ProbeFailures = @(); EstimatedRuns = 0
        Request = [pscustomobject]@{ SiblingInstallerType = [string[]]@('nullsoft'); SiblingVersion = [string[]]@("1.9", "2.0'x"); VersionsBack = 0; Coverage = 0; IncludeReportOnly = $false } }
    $r8 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $scoped -Backend HyperV -Assisted -WarningVariable w8 -WarningAction SilentlyContinue 6>$null
    if ($r8 -eq $false -and @($w8).Count -eq 1 -and "$($w8[0])" -match "until 10:02 UTC; capture again after that: Test-Win32ToolkitProject -ProjectPath '.+' -Scenario SiblingCapture -SiblingArchitecture x86 -SiblingVersion '1\.9','2\.0''x' -Assisted -SiblingInstallerType nullsoft\.$") {
        Ok "the retry command keeps -SiblingArchitecture x86, -SiblingVersion (quoted), -Assisted and -SiblingInstallerType; 10:01:40 reads 'until 10:02 UTC'"
    } else { Bad "scope: $r8 [$(@($w8) -join ' || ')]" }
    # Causes that capturing again cannot fix: the package manifest is gone (Permanent) -> no "later", no command; the
    # winget version list failed (WingetList) -> check winget on this computer.
    $gone = [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'NotFound'; RetryAfterUtc = ''; Cause = 'Permanent' }
        RetryAfterUtc = ''; Types = @(); ProbeFailures = @(); EstimatedRuns = 0 }
    $r9 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $gone -Backend HyperV -WarningVariable w9 -WarningAction SilentlyContinue 6>$null
    $list = [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = $unchecked.PackageProbe; RetryAfterUtc = ''; ProbeFailures = @(); EstimatedRuns = 0
        Types = @([pscustomobject]@{ Type = 'nullsoft'; EffectiveType = 'nullsoft'; Class = 'RemovableNow'; Reason = 'its versions could not be checked: the winget versions could not be listed'; ProbeFailed = $true; ProbeCause = 'WingetList'; Captures = @() }) }
    $r10 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $list -Backend HyperV -WarningVariable w10 -WarningAction SilentlyContinue 6>$null
    if ($r9 -eq $false -and "$($w9[0])" -match "could not be read \(NotFound\), so the other installer technologies of this app are not known\. Capturing again will not change this: check the project's winget id and version\.$" -and "$($w9[0])" -notmatch 'later|Test-Win32ToolkitProject' -and
        $r10 -eq $false -and "$($w10[0])" -match "^Nothing was captured: no technology could be checked \(nullsoft: its versions could not be checked: the winget versions could not be listed\)\. Check winget on this computer \(winget show --id Notepad\+\+\.Notepad\+\+ --versions\), then capture again: Test-Win32ToolkitProject .+ -Scenario SiblingCapture\.$") {
        Ok 'the package manifest gone (Permanent) -> "Capturing again will not change this", no command; the version list failed (WingetList) -> check winget, then the command'
    } else { Bad "causes: $r9 [$(@($w9) -join ' || ')] / $r10 [$(@($w10) -join ' || ')]" }
    # Mixed causes (second review): capturing again helps whenever one cause is not Permanent - the retry advice and the
    # command, the Permanent types named after it; on the partial path the command names only the retryable types. Only
    # Permanent types (with -SiblingVersion) -> no command, the versions named.
    $tPerm = [pscustomobject]@{ Type = 'exe'; EffectiveType = 'exe'; Class = 'RemovableNow'; Reason = 'its versions could not be checked: 1 winget manifest(s) could not be read (Parse)'; ProbeFailed = $true; ProbeCause = 'Permanent'; Captures = @() }
    $tList = [pscustomobject]@{ Type = 'inno'; EffectiveType = 'inno'; Class = 'RemovableNow'; Reason = 'its versions could not be checked: the winget versions could not be listed'; ProbeFailed = $true; ProbeCause = 'WingetList'; Captures = @() }
    $mk = { param([object[]]$Types, [int]$Runs = 0, $Request = $null) [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = $unchecked.PackageProbe; RetryAfterUtc = ''; ProbeFailures = @(); EstimatedRuns = $Runs; Types = @($Types); Request = $Request } }
    $wm = $null; $rm1 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan (& $mk @($tPerm, $unchecked.Types[0])) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $mixT = "$($wm[0])"
    $wm = $null; $rm2 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan (& $mk @($tPerm, $tList)) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $mixL = "$($wm[0])"
    $script:offered = @('nullsoft-8.9.8')
    $wm = $null; $rm3 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan (& $mk @($nsOne, $tPerm, $unchecked.Types[0]) 1) -Backend HyperV -MaxExtra 0 -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $mixP = @($wm | ForEach-Object { "$_" } | Where-Object { $_ -match '^Not captured:' })
    $wm = $null; $rm4 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan (& $mk @($tPerm) 0 ([pscustomobject]@{ SiblingInstallerType = [string[]]@(); SiblingVersion = [string[]]@('2.7'); VersionsBack = 0; Coverage = 0; IncludeReportOnly = $false })) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $permOnly = "$($wm[0])"
    # Only Permanent types of the default walk (no -SiblingVersion asked): no command and no "-SiblingVersion" hint.
    $wm = $null; $rm5 = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan (& $mk @($tPerm) 0 ([pscustomobject]@{ SiblingInstallerType = [string[]]@('exe'); SiblingVersion = [string[]]@(); VersionsBack = 0; Coverage = 0; IncludeReportOnly = $false })) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $permWalk = "$($wm[0])"
    if ($rm5 -eq $false -and $permWalk -match 'Capturing again will not change this: winget-pkgs has no usable manifest for these versions\.$' -and $permWalk -notmatch 'SiblingVersion|Test-Win32ToolkitProject') { Ok 'Permanent only, default walk (no -SiblingVersion) -> no command and no -SiblingVersion hint' } else { Bad "permanent walk: $rm5 [$permWalk]" }
    if ($rm1 -eq $false -and $mixT -match 'Capture again later: Test-Win32ToolkitProject .+ -Scenario SiblingCapture\. \(exe: capturing again will not change that\.\)$' -and
        $rm2 -eq $false -and $mixL -match 'Check winget on this computer .+ then capture again: Test-Win32ToolkitProject .+ -Scenario SiblingCapture\. \(exe: capturing again will not change that\.\)$' -and
        $rm3 -eq $true -and $mixP.Count -eq 1 -and $mixP[0] -match '-Scenario SiblingCapture -SiblingInstallerType inno\. \(exe: capturing again will not change that\.\)$' -and
        $rm4 -eq $false -and $permOnly -match 'Capturing again will not change this: winget-pkgs has no usable manifest for these versions \(check the versions named with -SiblingVersion\)\.$' -and $permOnly -notmatch 'Test-Win32ToolkitProject') {
        Ok 'mixed causes: Permanent + Transient -> capture again later + the command, exe named as unchangeable; Permanent + WingetList -> check winget; partial -> -SiblingInstallerType inno only; Permanent only (-SiblingVersion) -> no command, the versions named'
    } else { Bad "mixed: [$mixT] [$mixL] [$($mixP -join ' || ')] [$permOnly]" }
    # The retry command keeps -IncludeReportOnly from the request on the package-probe path, -SiblingCaptureCoverage or
    # -SiblingCaptureVersionsBack; quoting survives a typographic apostrophe in the project path (U+2019 ends a PowerShell
    # single-quoted string too) and a long version is echoed whole.
    $rs = { param($Rq) [pscustomobject]@{ Package = $plan.Package; Architecture = 'x64'; Backend = 'HyperV'; PackageProbe = [pscustomobject]@{ Status = 'Unavailable'; Reason = 'Network'; RetryAfterUtc = ''; Cause = 'Transient' }; RetryAfterUtc = ''; Types = @(); ProbeFailures = @(); EstimatedRuns = 0; Request = $Rq } }
    $wm = $null; $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan (& $rs ([pscustomobject]@{ SiblingInstallerType = [string[]]@(); SiblingVersion = [string[]]@(); VersionsBack = 0; Coverage = 2; IncludeReportOnly = $true })) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $cov = "$($wm[0])"
    $wm = $null; $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan (& $rs ([pscustomobject]@{ SiblingInstallerType = [string[]]@(); SiblingVersion = [string[]]@(); VersionsBack = 3; Coverage = 0; IncludeReportOnly = $false })) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $back = "$($wm[0])"
    # A deep (OneDrive) BasePath: the path is longer than a version's 128 and is echoed whole (1024).
    $odd = "C:\Users\first.last\OneDrive - Contoso Ltd\Documents\Packaging\Win32Apps\Projects\Contoso-Standard-Template-2026\Bob$([char]0x2019)s;calc;#_Microsoft.VisualStudio.2022.BuildTools_x64_17.11.35327.3"
    if ($odd.Length -le 128) { Bad "precondition: the long path is $($odd.Length) characters" }
    $longV = '1.' + ('2' * 98)
    $wm = $null; $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $odd -Plan (& $rs ([pscustomobject]@{ SiblingInstallerType = [string[]]@(); SiblingVersion = [string[]]@($longV); VersionsBack = 0; Coverage = 0; IncludeReportOnly = $false })) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $cmd = ("$($wm[0])" -replace '^.*Capture again later: ', '') -replace '\.$', ''
    $tokens = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$tokens, [ref]$perr)
    $cmdAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    $pathArg = if ($cmdAst) { $i = [array]::IndexOf(@($cmdAst.CommandElements | ForEach-Object { if ($_ -is [System.Management.Automation.Language.CommandParameterAst]) { $_.ParameterName } else { '' } }), 'ProjectPath'); if ($i -ge 0) { $cmdAst.CommandElements[$i + 1].SafeGetValue() } }
    $verArg = if ($cmdAst) { $i = [array]::IndexOf(@($cmdAst.CommandElements | ForEach-Object { if ($_ -is [System.Management.Automation.Language.CommandParameterAst]) { $_.ParameterName } else { '' } }), 'SiblingVersion'); if ($i -ge 0) { $cmdAst.CommandElements[$i + 1].SafeGetValue() } }
    if ($cov -match '-Scenario SiblingCapture -IncludeReportOnly -SiblingCaptureCoverage 2\.$' -and $back -match '-Scenario SiblingCapture -SiblingCaptureVersionsBack 3\.$' -and
        @($perr).Count -eq 0 -and @($ast.EndBlock.Statements).Count -eq 1 -and $pathArg -ceq $odd -and $verArg -ceq $longV) {
        Ok "the command keeps -IncludeReportOnly (requested) with -SiblingCaptureCoverage 2, or -SiblingCaptureVersionsBack 3; a $($odd.Length)-character project path with U+2019 and ';' parses as ONE command with that exact path; a 100-character version is echoed whole"
    } else { Bad "scope/quoting: [$cov] [$back] [$cmd] errors $(@($perr).Count) statements $(@($ast.EndBlock.Statements).Count) path [$pathArg] version [$verArg]" }
    # The values are neutralised before they are quoted: an ESC sequence in a version and a bidi override in the path read
    # '?', and a version longer than the probe's 128 is cut.
    $wm = $null; $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath "C:\W32T\Projects\T\App$([char]0x202E)gpj_x64_1.0" -Plan (& $rs ([pscustomobject]@{ SiblingInstallerType = [string[]]@(); SiblingVersion = [string[]]@("2.0$([char]27)[2J", ('1.' + ('2' * 198))); VersionsBack = 0; Coverage = 0; IncludeReportOnly = $false })) -Backend HyperV -WarningVariable wm -WarningAction SilentlyContinue 6>$null
    $qw = "$($wm[0])"
    if ($qw -notmatch '[\x1b\u202e]' -and $qw -match "-ProjectPath 'C:\\W32T\\Projects\\T\\App\?gpj_x64_1\.0'" -and $qw -match "-SiblingVersion '2\.0\?\[2J','1\.2{123}\.\.\.'") {
        Ok 'the retry command neutralises before it quotes: ESC in a version and U+202E in the path read ?, a 200-character version is cut at 128'
    } else { Bad "quote safe-text: [$qw]" }

    # Live rows DEMOTE, INNO, ASSISTED: the warning of an Unverified capture names the cause the guest's detail gives.
    $script:offered = @('nullsoft-8.9.8')
    $script:noiseQ = { param($k) @{ "SiblingCapture_$k.json" = [ordered]@{ SchemaVersion = '1.0'; Candidates = @((Cand)); NewRoots = @('C:\Program Files\Notepad++'); NoiseControl = 'Unverified'
                NoiseDetail = @('before the install: wuauserv Running/Manual', 'wuauserv Running/Manual'); PfroCount = 0; ProvisionalPrimary = 'Notepad++'; ProvisionalView = 'Native' } } }
    $warnOut = @(Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $plan -Backend HyperV -MaxExtra 0 6>$null 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
    $script:noiseQ = $null
    if (@($warnOut | Where-Object { $_ -match 'the guest noise control was not verified \(before the install: wuauserv Running/Manual; wuauserv Running/Manual\): the update services and tasks could not be held still before the install, so the proposals of this identity are Block-only\.$' }).Count -eq 1 -and
        @($warnOut | Where-Object { $_ -match 'Windows Update installed something' }).Count -eq 0) { Ok 'an Unverified capture whose check before the install failed: the warning says so (not "Windows Update installed something")' } else { Bad "noise warning: $($warnOut -join ' | ')" }

    $script:offered = @('nullsoft-8.9.8'); $script:tamper = $true
    $before = @(Get-ChildItem -LiteralPath (Join-Path $proj 'Documentation\SiblingCapture') -File).Count
    $err = $null
    try { $null = Invoke-Win32ToolkitSiblingCapture -ProjectPath $proj -Plan $plan -Backend HyperV 6>$null 3>$null } catch { $err = $_ }
    $script:tamper = $false
    if ($err.FullyQualifiedErrorId -eq 'W32T.GuestTamper' -and @(Get-ChildItem -LiteralPath (Join-Path $proj 'Documentation\SiblingCapture') -File).Count -eq $before -and (Test-Path -LiteralPath (Join-Path $proj 'Documentation\GuestTamper.json'))) { Ok 'a run that changed a project file -> W32T.GuestTamper before any record is written (the marker written)' } else { Bad "tamper: $($err.FullyQualifiedErrorId)" }

    # == [3] the pre-flight =================================================================================
    Write-Host '[3] Test-Win32ToolkitSiblingCapturePreflight' -ForegroundColor Cyan
    $script:shape = [pscustomobject]@{ Support = 'Supported'; RemovePriorRevision = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision); PriorCheckFirst = $true }
    $script:src = [pscustomobject]@{ WingetId = 'Notepad++.Notepad++'; Architecture = 'x64' }
    $script:ready = @(); $script:backendCfg = 'HyperV'
    function Get-Win32ToolkitDeployScriptShape { param($Path, $Content, [switch]$IncludeLayout) $null = $Path, $Content, $IncludeLayout; $script:shape }
    function Get-Win32ToolkitProjectSource { param($ProjectPath, [switch]$Rebuild) $null = $ProjectPath, $Rebuild; $script:src }
    function Test-Win32ToolkitHyperVReady { param([switch]$Force) $null = $Force; @($script:ready) }
    function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($Name -eq 'TestBackend') { $script:backendCfg } else { $Default } }
    $p = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $proj
    if ($p.Ok -and $p.Backend -eq 'HyperV' -and $p.WingetId -eq 'Notepad++.Notepad++') { Ok 'a supported winget project with its own identity on a ready Hyper-V VM -> Ok' } else { Bad "ok: $($p | ConvertTo-Json -Compress)" }
    $cases = @(
        @{ L = 'an unsupported shape'; S = { $script:shape = [pscustomobject]@{ Support = 'Supported'; RemovePriorRevision = 0; PriorCheckFirst = $true } }; Code = 'W32T.PriorInstallSlotsMissing'; Rx = 'no place for prior-install rules' }
        @{ L = 'a manual app'; S = { $script:src = [pscustomobject]@{ WingetId = ''; Architecture = 'x64' } }; Code = 'W32T.SiblingCaptureUnsupported'; Rx = 'manual apps have no winget siblings' }
        @{ L = 'an ARM64 package'; S = { $script:src = [pscustomobject]@{ WingetId = 'A.B'; Architecture = 'arm64' } }; Code = 'W32T.SiblingCaptureUnsupported'; Rx = 'ARM64' }
    )
    foreach ($c in $cases) {
        $script:shape = [pscustomobject]@{ Support = 'Supported'; RemovePriorRevision = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision); PriorCheckFirst = $true }; $script:src = [pscustomobject]@{ WingetId = 'Notepad++.Notepad++'; Architecture = 'x64' }; $script:ready = @(); $script:backendCfg = 'HyperV'
        & $c.S
        $threw = $false
        try { $p = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $proj } catch { $threw = $true }
        if (-not $threw -and -not $p.Ok -and $p.Code -eq $c.Code -and ($p.Reasons -join ' ') -match $c.Rx) { Ok "$($c.L) -> Ok false, $($c.Code), no throw" } else { Bad "$($c.L): $($p | ConvertTo-Json -Compress) threw=$threw" }
    }
    $script:shape = [pscustomobject]@{ Support = 'Supported'; RemovePriorRevision = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision); PriorCheckFirst = $true }; $script:src = [pscustomobject]@{ WingetId = 'Notepad++.Notepad++'; Architecture = 'x64' }; $script:backendCfg = 'HyperV'
    $noOwn = Join-Path $root 'noown'; $null = New-Item -ItemType Directory -Path (Join-Path $noOwn 'SupportFiles') -Force
    [IO.File]::WriteAllText((Join-Path $noOwn 'SupportFiles\AppConfig.json'), '{"App":{"Version":"1.0"}}', $utf8)
    $p = Test-Win32ToolkitSiblingCapturePreflight -ProjectPath $noOwn
    if (-not $p.Ok -and ($p.Reasons -join ' ') -match 'run the install capture first') { Ok 'no OwnIdentity -> Ok false (run the install capture first)' } else { Bad "no own: $($p | ConvertTo-Json -Compress)" }

    # == [4] the CLI scenario ===============================================================================
    Write-Host '[4] Test-Win32ToolkitProject -Scenario SiblingCapture' -ForegroundColor Cyan
    $script:pre = [pscustomobject]@{ Ok = $false; Code = 'W32T.SiblingCaptureUnsupported'; Reasons = @('it is a manual app'); Backend = 'HyperV' }
    $script:capResult = $true; $script:capCalls = 0; $script:planArgs = $null
    function Test-Win32ToolkitSiblingCapturePreflight { param($ProjectPath, $Backend) $null = $ProjectPath, $Backend; $script:pre }
    function Get-Win32ToolkitSiblingCapturePlan { param($ProjectPath, $SiblingInstallerType, $SiblingVersion, $VersionsBack, [switch]$IncludeReportOnly) $script:planArgs = $PSBoundParameters; [pscustomobject]@{ Backend = ''; Types = @() } }
    function Invoke-Win32ToolkitSiblingCapture { param($ProjectPath, $Plan, $Backend) $null = $ProjectPath, $Plan, $Backend; $script:capCalls++; $script:capResult }
    $err = $null
    try { $null = Test-Win32ToolkitProject -ProjectPath $proj -Scenario SiblingCapture 6>$null 3>$null } catch { $err = $_ }
    if ($err.FullyQualifiedErrorId -eq 'W32T.SiblingCaptureUnsupported' -and "$($err.Exception.Message)" -match 'manual app' -and $script:capCalls -eq 0) { Ok 'a refused pre-flight throws its code; nothing runs' } else { Bad "refused: $($err.FullyQualifiedErrorId) calls $($script:capCalls)" }
    $script:pre = [pscustomobject]@{ Ok = $true; Code = ''; Reasons = @(); Backend = 'HyperV' }
    foreach ($want in @($true, $false, $null)) {
        $script:capResult = $want
        $got = Test-Win32ToolkitProject -ProjectPath $proj -Scenario SiblingCapture -SiblingInstallerType nullsoft -SiblingVersion '8.9.8' -SiblingCaptureVersionsBack 2 -IncludeReportOnly 6>$null 3>$null
        if ($got -eq $want -and $script:planArgs['SiblingInstallerType'] -eq 'nullsoft' -and $script:planArgs['VersionsBack'] -eq 2 -and $script:planArgs['IncludeReportOnly']) { Ok "the capture's result is returned ($(if ($null -eq $want) { '$null' } else { $want })); the sibling parameters reach the plan" } else { Bad "dispatch $want -> $got" }
    }
    $e1 = $null; try { $null = Test-Win32ToolkitProject -ProjectPath $proj -Scenario InstallUninstall -SiblingVersion '1' 6>$null 3>$null } catch { $e1 = $_ }
    $e2 = $null; try { $null = Test-Win32ToolkitProject -ProjectPath $proj -Scenario SiblingCapture -VersionsBack 1 6>$null 3>$null } catch { $e2 = $_ }
    if ("$($e1.Exception.Message)" -match '-SiblingVersion applies only to -Scenario SiblingCapture' -and "$($e2.Exception.Message)" -match '-VersionsBack applies only to -Scenario Update') { Ok 'sibling parameters outside the scenario, and Update parameters in it, are refused' } else { Bad "guards: $($e1.Exception.Message) / $($e2.Exception.Message)" }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingCapture tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingCapture test(s) FAILED." -ForegroundColor Red; exit 1 }
