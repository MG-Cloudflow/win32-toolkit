<#
    Installer-identity PR 3 (spec 2.4, 2.14.7, L35, SV5): the two host readers every later consumer goes through.

      [1] Get-Win32ToolkitSiblingCaptureRecord + ConvertTo-Win32ToolkitSiblingCaptureRecord: a record written in the frozen
          shape (ConvertTo-Json -Depth 12 -Compress -EscapeHandling EscapeNonAscii, UTF-8 without BOM, named by the first
          16 hex of its SHA-256) comes back typed, field order frozen, unknown fields dropped, CaptureId added; one byte
          changed -> ignored; a wrong type in a field (string for an int, an object for a list, an unknown enum value, a
          bad hash pattern) -> ignored; larger than 8 MB -> ignored; a name that is not '<16 hex>.json' -> ignored;
          -CaptureId filters; missing folder -> nothing; strings re-neutralised (control characters) and capped.
      [2] Get-Win32ToolkitPriorInstallDecision: missing or unreadable file -> empty set; unknown kinds / codes / malformed
          records ignored; one Waiver / Acknowledgement per Kind + Code + Target (the last wins); Approvals kept in order
          with Latest on the last one per Target; a Demoted date read.

    Fixtures under %TEMP%, removed at the end. Run:  pwsh -File Tests\CaptureRecordReader.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Get-Win32ToolkitSiblingCaptureRecord', 'ConvertTo-Win32ToolkitSiblingCaptureRecord', 'Get-Win32ToolkitPriorInstallDecision', 'ConvertTo-Win32ToolkitSafeText') {
    . (Join-Path $repo "Private\$f.ps1")
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32rec_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proj = Join-Path $root 'proj'
$recDir = Join-Path $proj 'Documentation\SiblingCapture'
$null = New-Item -ItemType Directory -Path $recDir -Force
$utf8 = [Text.UTF8Encoding]::new($false)

function New-Record([hashtable]$Over = @{}) {
    $r = [ordered]@{
        SchemaVersion = '1.0'; CaptureKey = 'nullsoft-8.9.8.1'
        Package = [ordered]@{ WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = 'x64'; InstallerType = 'wix'; Family = 'msi' }
        Sibling = [ordered]@{ InstallerType = 'nullsoft'; EffectiveType = 'nullsoft'; Version = '8.9.8.1'; Role = 'Newest'; ReleaseDate = '2026-09-30'; Scope = ''; Locale = ''; Architecture = 'x64'
            InstallerFile = 'npp.8.9.8.1.Installer.x64.exe'; InstallerSha256 = ('AB' * 32); SilentArgs = '/S'; SilentArgsSource = 'manifest-silent'
            Manifest = [ordered]@{ ProductCodes = @('Notepad++'); Afe = @([ordered]@{ DisplayName = 'Notepad++ (64-bit x64)'; Publisher = 'Notepad++ Team'; DisplayVersion = ''; ProductCode = ''; UpgradeCode = ''; InstallerType = '' }); PackageName = 'Notepad++'; Publisher = 'Notepad++ Team'; DefaultInstallLocation = '' } }
        Run = [ordered]@{ Backend = 'HyperV'; Mode = 'Unattended'; Account = 'NT AUTHORITY\SYSTEM'; Is64 = $true; OsBuild = '10.0.26100'; StartedUtc = '2026-10-25T10:11:12Z'; Seconds = 312; ToolkitVersion = '1.3.0'; GuestScriptSha256 = ('CD' * 32); DependenciesSkipped = $false }
        Install = [ordered]@{ ExitCode = 0; TimedOut = $false; Completed = $true; RebootRequested = $false; Lingering = @(); Seconds = 20 }
        Observation = [ordered]@{
            Candidates = @([ordered]@{ Key = 'Notepad++'; View = 'Native'; DisplayName = 'Notepad++ (64-bit x64)'; DisplayVersion = '8.9.8.1'; Publisher = 'Notepad++ Team'; WindowsInstaller = $false; SystemComponent = $false
                    InstallLocation = 'C:\Program Files\Notepad++'; DisplayIconLeaf = 'notepad++.exe'; UninstallerPath = 'C:\Program Files\Notepad++\uninstall.exe'; UninstallerCanonical = $true; UninstallerLeaf = 'uninstall.exe'
                    InstallDir = '%ProgramFiles%\Notepad++'; MainExe = 'notepad++.exe'; Files = @('notepad++.exe', 'uninstall.exe'); InstallLocationFiles = @(); InnoAppPath = $false; UnsDat = $false; QuietUninstallArgs = ''
                    Acl = @([ordered]@{ Path = 'C:\Program Files\Notepad++'; Owner = 'S-1-5-18'; Rules = @([ordered]@{ Sid = 'S-1-5-18'; Rights = 2032127; Inheritance = 3; Propagation = 0; Type = 'Allow' }) }); UnsafeText = $false })
            Services = @(); Shortcuts = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Notepad++.lnk'); Tasks = @(); Appx = @(); HkcuArp = @(); NewRoots = @('C:\Program Files\Notepad++'); NoiseControl = 'Verified'; PfroCount = 0; ProvisionalPrimary = 'Notepad++' }
        Probe = [ordered]@{ Result = 'Clean'; ProbedKey = 'Notepad++'; ProbedView = 'Native'; ExitCode = 0; Seconds = 9; LingeringProcess = @(); PfroUnderRoot = $false; RootConfigRemoved = $false; VendorConfigRemoved = @() }
        HostChecks = [ordered]@{ UninstallerSigner = [ordered]@{ Status = 'NotSigned'; Subject = '' }; MainSigner = [ordered]@{ Status = 'Valid'; Subject = 'CN=Notepad++' }; InstallerSigner = [ordered]@{ Status = 'Valid'; Subject = 'CN=Notepad++' }; NsisMagic = $true; InnoMarkers = $false }
    }
    foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
    $r
}
function Write-Record($Record, [string]$Json = $null) {
    if (-not $Json) { $Json = ConvertTo-Json -InputObject $Record -Depth 12 -Compress -EscapeHandling EscapeNonAscii }
    $bytes = $utf8.GetBytes($Json)
    $sha = [Security.Cryptography.SHA256]::Create()
    $id = (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
    [IO.File]::WriteAllBytes((Join-Path $recDir "$id.json"), $bytes)
    $id
}
function Clear-RecordFolder { Get-ChildItem -LiteralPath $recDir -File | Remove-Item -Force }

try {
    # == [1] capture records ==========================================================================
    Write-Host '[1] capture records: hash-verified, frozen shape' -ForegroundColor Cyan
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath (Join-Path $root 'none')).Count -eq 0) { Ok 'no Documentation\SiblingCapture folder -> nothing' } else { Bad 'missing folder' }
    $rec = New-Record
    $rec['Extra'] = 'dropped'
    $rec.Observation.Candidates[0]['Unknown'] = 'dropped too'
    $id = Write-Record $rec
    $got = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj)
    $g = $got[0]
    if ($got.Count -eq 1 -and $g -is [System.Collections.Specialized.OrderedDictionary] -and $g.CaptureId -ceq $id -and $g.Sibling.Version -ceq '8.9.8.1' -and $g.Observation.Candidates[0].Key -ceq 'Notepad++') { Ok "the record comes back typed with CaptureId $id" } else { Bad "read: $($got.Count) $($g | ConvertTo-Json -Depth 3 -Compress)" }
    $order = @($g.Keys) -join ','
    if ($order -ceq 'SchemaVersion,CaptureKey,Package,Sibling,Run,Install,Observation,Probe,HostChecks,CaptureId' -and -not $g.Contains('Extra') -and -not $g.Observation.Candidates[0].Contains('Unknown')) { Ok 'frozen field order; unknown fields dropped' } else { Bad "order: $order" }
    if ($g.Run.Seconds -is [int] -and $g.Run.Is64 -is [bool] -and $g.Observation.Candidates[0].Acl[0].Rules[0].Rights -eq 2032127 -and $g.Observation.Candidates[0].Files -is [string[]] -and $g.Install.Lingering.Count -eq 0) { Ok 'integers, booleans and lists typed (an empty list is never $null)' } else { Bad 'types' }
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj -CaptureId 'ffffffffffffffff').Count -eq 0 -and @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj -CaptureId $id).Count -eq 1) { Ok '-CaptureId filters' } else { Bad 'filter' }

    $file = Join-Path $recDir "$id.json"
    $bytes = [IO.File]::ReadAllBytes($file)
    $i = [Array]::IndexOf($bytes, [byte][char]'8')
    $bytes[$i] = [byte][char]'9'
    [IO.File]::WriteAllBytes($file, $bytes)
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj).Count -eq 0) { Ok 'one byte changed after it was written -> ignored (the name no longer matches the content)' } else { Bad 'tampered record returned' }
    Clear-RecordFolder

    foreach ($c in @(
            @{ L = 'a string where an integer belongs'; M = { param($r) $r.Run.Seconds = '312' } }
            @{ L = 'a string where a boolean belongs'; M = { param($r) $r.Install.Completed = 'true' } }
            @{ L = 'an object where a list belongs'; M = { param($r) $r.Observation.Candidates = [ordered]@{ Key = 'x' } } }
            @{ L = 'an unknown Role'; M = { param($r) $r.Sibling.Role = 'Latest' } }
            @{ L = 'an unknown Backend'; M = { param($r) $r.Run.Backend = 'Docker' } }
            @{ L = 'a lower-case installer hash'; M = { param($r) $r.Sibling.InstallerSha256 = ('ab' * 32) } }
            @{ L = 'a CaptureKey with a slash'; M = { param($r) $r.CaptureKey = 'nullsoft/8.9' } }
            @{ L = 'SchemaVersion 2.0'; M = { param($r) $r.SchemaVersion = '2.0' } }
            @{ L = 'an InstallDir outside the Program Files tokens'; M = { param($r) $r.Observation.Candidates[0].InstallDir = 'C:\Apps\Notepad++' } }
            @{ L = 'a number out of the int range'; M = { param($r) $r.Probe.ExitCode = 99999999999 } }
        )) {
        Clear-RecordFolder
        $r = New-Record
        & $c.M $r
        $null = Write-Record $r
        if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj).Count -eq 0) { Ok "$($c.L) -> ignored" } else { Bad "$($c.L) -> returned" }
    }
    Clear-RecordFolder
    $r = New-Record
    $r.Observation.Candidates[0].DisplayName = "Notepad++$([char]0x1B)[31m (x64)$([char]0x202E)"
    $r.Sibling.SilentArgs = 'x' * 600
    $null = Write-Record $r
    $g = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj)[0]
    if ($g.Observation.Candidates[0].DisplayName -ceq 'Notepad++?[31m (x64)?' -and $g.Sibling.SilentArgs.Length -eq 512 -and $g.Sibling.SilentArgs.EndsWith('...')) { Ok 'strings re-neutralised (ESC, U+202E -> ?) and capped (SilentArgs 512)' } else { Bad "strings: $($g.Observation.Candidates[0].DisplayName) / $($g.Sibling.SilentArgs.Length)" }
    Clear-RecordFolder
    $r = New-Record
    $r.Observation.Candidates = @(1..70 | ForEach-Object { $c = [ordered]@{}; foreach ($k in $rec.Observation.Candidates[0].Keys) { if ($k -ne 'Unknown') { $c[$k] = $rec.Observation.Candidates[0][$k] } }; $c.Key = "K$_"; $c })
    $null = Write-Record $r
    $g = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj)[0]
    if ($g.Observation.Candidates.Count -eq 64) { Ok '70 candidates -> capped at 64' } else { Bad "cap: $($g.Observation.Candidates.Count)" }
    Clear-RecordFolder
    $null = Write-Record (New-Record)
    Copy-Item -LiteralPath (Get-ChildItem $recDir -File)[0].FullName -Destination (Join-Path $recDir 'record.json')
    Copy-Item -LiteralPath (Get-ChildItem $recDir -File -Filter '????????????????.json')[0].FullName -Destination (Join-Path $recDir '0123456789ABCDEF.json')
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj).Count -eq 1) { Ok "only '<16 lower-case hex>.json' names are read (record.json, upper-case hex ignored)" } else { Bad 'names' }
    Clear-RecordFolder
    $big = '{"SchemaVersion":"1.0","Pad":"' + ('x' * (8MB + 10)) + '"}'
    $null = Write-Record $null $big
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj).Count -eq 0) { Ok 'a file larger than 8 MB -> ignored (not even parsed)' } else { Bad '8 MB' }
    Clear-RecordFolder
    $null = Write-Record $null '{ not json'
    $null = Write-Record $null '[1,2,3]'
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj -Verbose:$false).Count -eq 0) { Ok 'unparsable or non-object JSON -> ignored, no throw' } else { Bad 'bad json' }
    Clear-RecordFolder
    $null = Write-Record $null '{"SchemaVersion":"1.0","CaptureKey":"exe-1.0"}'
    if (@(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj).Count -eq 0) { Ok 'a record without its enumerations (Architecture, Backend, ...) -> ignored (never read as HyperV)' } else { Bad 'record without enumerations returned' }
    Clear-RecordFolder
    $r = New-Record
    $r.Remove('Probe'); $r.Observation.Remove('Tasks'); $r.Install.Remove('Lingering')
    $r.Probe = [ordered]@{ Result = 'NotProbed'; ProbedView = '' }
    $null = Write-Record $r
    $g = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $proj)[0]
    if ($g -and $g.Observation.Tasks.Count -eq 0 -and $g.Install.Lingering.Count -eq 0 -and $g.Probe.ExitCode -eq 0 -and $g.Probe.RootConfigRemoved -eq $false -and $g.Probe.ProbedKey -ceq '') { Ok 'missing lists, integers, booleans and free strings take their empty values' } else { Bad 'missing fields' }

    # == [2] decisions ================================================================================
    Write-Host '[2] Get-Win32ToolkitPriorInstallDecision: lenient reader' -ForegroundColor Cyan
    $dec = Join-Path $proj 'Documentation\PriorInstallDecisions.json'
    if (@(Get-Win32ToolkitPriorInstallDecision -ProjectPath $proj).Count -eq 0) { Ok 'missing file -> empty set' } else { Bad 'missing file' }
    [IO.File]::WriteAllText($dec, '{ broken', $utf8)
    if (@(Get-Win32ToolkitPriorInstallDecision -ProjectPath $proj).Count -eq 0) { Ok 'unreadable file -> empty set, no throw' } else { Bad 'unreadable file' }
    $records = @(
        [ordered]@{ Kind = 'Waiver'; Code = 'PROOF'; Target = 'nsis-x64'; Reason = 'first'; On = '2026-10-20' }
        [ordered]@{ Kind = 'Waiver'; Code = 'PROOF'; Target = 'nsis-x64'; Reason = 'second'; On = '2026-10-21' }
        [ordered]@{ Kind = 'Waiver'; Code = 'EVERYTHING'; Target = 'nsis-x64'; Reason = 'x'; On = '2026-10-21' }
        [ordered]@{ Kind = 'Override'; Code = 'PROOF'; Target = 'nsis-x64'; Reason = 'x'; On = '2026-10-21' }
        [ordered]@{ Kind = 'Waiver'; Code = 'PROOF'; Target = 'NSIS'; Reason = 'x'; On = '2026-10-21' }
        [ordered]@{ Kind = 'Waiver'; Code = 'VERSIONMIN'; Target = 'nsis-x64'; Reason = ''; On = '2026-10-21' }
        [ordered]@{ Kind = 'Acknowledgement'; Code = 'DATA-LOSS'; Target = 'nsis-x64'; Reason = "user data `e[31mlost"; On = '2026-10-22' }
        [ordered]@{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'nsis-x64'; ProposalId = 'nsis-x64'; ProposalHash = ('A' * 64); CaptureIds = @('3f9c0a7d51e2b846', 'BAD'); On = '2026-10-22'; Demoted = '' }
        [ordered]@{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'nsis-x64'; ProposalId = 'nsis-x64'; ProposalHash = ('B' * 64); CaptureIds = @(); On = '2026-10-23'; Demoted = '2026-10-24' }
        [ordered]@{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'inno-x64'; ProposalId = 'inno-x64'; ProposalHash = 'short'; On = '2026-10-23'; Demoted = '' }
        [ordered]@{ Kind = 'Waiver'; Code = 'DISPLAYNAME'; Target = 'later-entry'; Reason = 'declared before the entry'; On = '2026-10-23' }
    )
    [IO.File]::WriteAllText($dec, (ConvertTo-Json -InputObject ([ordered]@{ SchemaVersion = '1.0'; Records = $records }) -Depth 6), $utf8)
    $d = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $proj)
    $proof = @($d | Where-Object { $_.Kind -eq 'Waiver' -and $_.Code -eq 'PROOF' })
    if ($proof.Count -eq 1 -and $proof[0].Reason -ceq 'second') { Ok 'one Waiver per Kind + Code + Target: the last one wins' } else { Bad "waivers: $($proof.Count) $($proof.Reason -join ',')" }
    if (@($d | Where-Object { $_.Code -eq 'EVERYTHING' -or $_.Kind -eq 'Override' -or $_.Target -ceq 'NSIS' }).Count -eq 0) { Ok 'unknown codes, unknown kinds and malformed targets are ignored' } else { Bad 'unknown records kept' }
    if (@($d | Where-Object { $_.Code -eq 'VERSIONMIN' }).Count -eq 0) { Ok 'a Waiver without a Reason is ignored' } else { Bad 'reasonless waiver kept' }
    $ack = @($d | Where-Object { $_.Kind -eq 'Acknowledgement' })
    if ($ack.Count -eq 1 -and $ack[0].Reason -ceq 'user data ?[31mlost') { Ok 'Acknowledgement read; its Reason neutralised' } else { Bad "ack: $($ack.Reason)" }
    $ap = @($d | Where-Object { $_.Kind -eq 'Approval' })
    if ($ap.Count -eq 2 -and -not $ap[0].Latest -and $ap[1].Latest -and $ap[1].Demoted -ceq '2026-10-24' -and @($ap[0].CaptureIds) -join ',' -ceq '3f9c0a7d51e2b846') { Ok 'Approvals kept in order; Latest on the last per Target; Demoted read; bad capture ids dropped; a bad ProposalHash drops the record' } else { Bad "approvals: $($ap | ConvertTo-Json -Compress)" }
    if (@($d | Where-Object { $_.Target -eq 'later-entry' }).Count -eq 1) { Ok 'a record may name an entry that does not exist yet' } else { Bad 'later-entry waiver dropped' }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All CaptureRecordReader tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail CaptureRecordReader test(s) FAILED." -ForegroundColor Red; exit 1 }
