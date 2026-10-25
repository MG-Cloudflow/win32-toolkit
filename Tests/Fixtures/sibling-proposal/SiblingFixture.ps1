<#
    Test fixture builders for the sibling-capture proposal suites (installer-identity PR 3b, commit A1):
    SiblingProposal.unit, PriorInstall.unit, PriorCarryForward.unit, PackageReady.unit. Dot-sourced by those suites
    after the module's Private helpers (it needs ConvertTo-Win32ToolkitSiblingCaptureRecord). Not a suite.

      New-TestSiblingRecord     one capture record in the FROZEN shape (spec 2.14.7), built through the real re-typer;
      Write-TestSiblingRecord   writes it as Documentation\SiblingCapture\<CaptureId>.json (CaptureId = the SHA-256
                                prefix of the bytes, exactly as the capture writes it) and returns the id;
      New-TestSiblingProject    a minimal project (SupportFiles\AppConfig.json; a deploy script only with -Script).

    Defaults describe the maintainer's goal: the nullsoft Notepad++ sibling of a WiX Notepad++ package (key
    'Notepad++', %ProgramFiles%\Notepad++, uninstall.exe, notepad++.exe, a clean probe, verified noise control, the
    same signer as the package).
#>

$script:TestSiblingSerial = 0
$script:TestSiblingSigner = 'CN=Notepad++, O=Notepad++, C=FR'

function New-TestSiblingAcl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builder: returns data, changes nothing')]
    param([string]$Folder, [string]$Exe, [string]$Owner = 'S-1-5-32-544', [object[]]$ExtraFolderRules = @(), [string]$ExeOwner = 'S-1-5-32-544')
    $base = @(
        [ordered]@{ Sid = 'S-1-5-18'; Rights = 2032127; Inheritance = 3; Propagation = 0; Type = 'Allow' }
        [ordered]@{ Sid = 'S-1-5-32-544'; Rights = 2032127; Inheritance = 3; Propagation = 0; Type = 'Allow' }
        [ordered]@{ Sid = 'S-1-5-32-545'; Rights = 1179817; Inheritance = 3; Propagation = 0; Type = 'Allow' }
        [ordered]@{ Sid = 'S-1-3-0'; Rights = 268435456; Inheritance = 3; Propagation = 2; Type = 'Allow' }
        [ordered]@{ Sid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Rights = 2032127; Inheritance = 3; Propagation = 0; Type = 'Allow' }
    )
    $exeRules = @(
        [ordered]@{ Sid = 'S-1-5-18'; Rights = 2032127; Inheritance = 0; Propagation = 0; Type = 'Allow' }
        [ordered]@{ Sid = 'S-1-5-32-544'; Rights = 2032127; Inheritance = 0; Propagation = 0; Type = 'Allow' }
        [ordered]@{ Sid = 'S-1-5-32-545'; Rights = 1179817; Inheritance = 0; Propagation = 0; Type = 'Allow' }
    )
    @(
        [ordered]@{ Path = $Folder; Owner = $Owner; Rules = @($base + $ExtraFolderRules) }
        [ordered]@{ Path = $Exe; Owner = $ExeOwner; Rules = $exeRules }
    )
}

function New-TestSiblingRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builder: returns data, changes nothing')]
    param(
        [string]$Type = 'nullsoft', [string]$EffectiveType = '', [string]$Version = '8.9.8', [string]$Observed = '', [string]$Role = 'Newest',
        [string]$ReleaseDate = '', [string]$Key = 'Notepad++', [string]$View = 'Native', [AllowEmptyString()][string]$DisplayName = 'Notepad++ (64-bit x64)',
        [string]$Publisher = 'Notepad++ Team', [string]$Dir = 'Notepad++', [AllowEmptyString()][string]$Main = 'notepad++.exe', [string]$Uninstaller = 'uninstall.exe',
        [AllowEmptyString()][string]$Root = $null, [switch]$NoNsis, [switch]$InnoMarkers, [string]$ProbeResult = 'Clean', [string]$Noise = 'Verified',
        [string]$Backend = 'HyperV', [string]$Mode = 'Unattended', [AllowEmptyString()][string]$UninstallerSignerStatus = 'Valid',
        [AllowEmptyString()][string]$InstallerSigner = $script:TestSiblingSigner, [AllowEmptyString()][string]$MainSigner = $script:TestSiblingSigner,
        [object[]]$Acl = $null, [object[]]$ExtraCandidates = @(), [string[]]$ProductCodes = @('Notepad++'), [object[]]$Afe = @(),
        [string]$PackageName = 'Notepad++', [string]$ManifestPublisher = 'Notepad++ Team', [string]$DefaultInstallLocation = '%ProgramFiles%\Notepad++',
        [bool]$Unsafe = $false, [string]$Quiet = '', [string]$Locale = '', [bool]$RootConfigRemoved = $false, [AllowEmptyString()][string]$ProvisionalPrimary = $null,
        [object[]]$Hkcu = @(), [string]$Arch = 'x64', [switch]$NoPrimaryCandidate, [AllowEmptyString()][string]$InstallLocation = $null, [bool]$Canonical = $true, [switch]$ForceNsis,
        [AllowEmptyString()][string]$InstallDirToken = $null
    )
    $script:TestSiblingSerial++
    if (-not $Observed) { $Observed = $Version }
    $pf = if ($View -eq 'Wow6432') { 'C:\Program Files (x86)' } else { 'C:\Program Files' }
    $tok = if ($View -eq 'Wow6432') { '%ProgramFiles(x86)%' } else { '%ProgramFiles%' }
    $folder = "$pf\$Dir"
    $uPath = "$folder\$Uninstaller"
    if ($null -eq $Root -or ($PSBoundParameters.ContainsKey('Root') -eq $false)) { $Root = "$pf\$(($Dir -split '\\')[0])" }
    if ($null -eq $Acl) { $Acl = New-TestSiblingAcl -Folder $folder -Exe $uPath }
    if (-not $PSBoundParameters.ContainsKey('ProvisionalPrimary')) { $ProvisionalPrimary = $Key }
    if (-not $PSBoundParameters.ContainsKey('InstallLocation')) { $InstallLocation = $folder }
    $files = @($Uninstaller) + @(if ($Main) { $Main }) + @('langs.xml')
    $cands = @()
    if (-not $NoPrimaryCandidate) {
        $cands += [ordered]@{
            Key = $Key; View = $View; DisplayName = $DisplayName; DisplayVersion = $Observed; Publisher = $Publisher; WindowsInstaller = $false; SystemComponent = $false
            InstallLocation = $InstallLocation; DisplayIconLeaf = $(if ($Main) { $Main } else { '' }); UninstallerPath = $(if ($Canonical) { $uPath } else { '' }); UninstallerCanonical = $Canonical
            UninstallerLeaf = $Uninstaller; InstallDir = $(if ($PSBoundParameters.ContainsKey('InstallDirToken')) { $InstallDirToken } else { "$tok\$Dir" }); MainExe = $Main; Files = $files; InstallLocationFiles = @(); InnoAppPath = [bool]$InnoMarkers; UnsDat = [bool]$InnoMarkers
            QuietUninstallArgs = $Quiet; Acl = @($Acl); UnsafeText = $Unsafe
        }
    }
    $cands += @($ExtraCandidates)
    $sig = { param([string]$Subject, [string]$Status = 'Valid') if ($Subject) { [ordered]@{ Status = $Status; Subject = $Subject } } else { [ordered]@{ Status = 'NotSigned'; Subject = '' } } }
    $rec = [ordered]@{
        SchemaVersion = '1.0'
        CaptureKey    = ("$Type-$Version-$Role-$($script:TestSiblingSerial)").ToLowerInvariant() -replace '[^a-z0-9_.+-]', '-'
        Package       = [ordered]@{ WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = $Arch; InstallerType = 'wix'; Family = 'msi' }
        Sibling       = [ordered]@{
            InstallerType = $Type; EffectiveType = $(if ($EffectiveType) { $EffectiveType } else { $Type }); Version = $Version; Role = $Role; ReleaseDate = $ReleaseDate; Scope = 'machine'; Locale = $Locale
            Architecture = $(if ($View -eq 'Wow6432') { 'x86' } else { $Arch }); InstallerFile = "setup.$Version.exe"; InstallerSha256 = ('{0:X64}' -f $script:TestSiblingSerial).PadLeft(64, 'A').Substring(0, 64)
            SilentArgs = '/S'; SilentArgsSource = 'catalog'
            Manifest = [ordered]@{ ProductCodes = @($ProductCodes); Afe = @($Afe); PackageName = $PackageName; Publisher = $ManifestPublisher; DefaultInstallLocation = $DefaultInstallLocation }
        }
        Run           = [ordered]@{ Backend = $Backend; Mode = $Mode; Account = 'SYSTEM'; Is64 = $true; OsBuild = '26100'; StartedUtc = ''; Seconds = $script:TestSiblingSerial; ToolkitVersion = '1.2.0'; GuestScriptSha256 = ('B' * 64); DependenciesSkipped = $true }
        Install       = [ordered]@{ ExitCode = 0; TimedOut = $false; Completed = $true; RebootRequested = $false; Lingering = @(); Seconds = 30 }
        Observation   = [ordered]@{
            Candidates = @($cands); Services = @(); Shortcuts = @("C:\ProgramData\Microsoft\Windows\Start Menu\Programs\$Key.lnk"); Tasks = @(); Appx = @(); HkcuArp = @($Hkcu)
            NewRoots = @(if ($Root) { $Root }); NoiseControl = $Noise; PfroCount = 0; ProvisionalPrimary = $ProvisionalPrimary
        }
        Probe         = [ordered]@{ Result = $ProbeResult; ProbedKey = $(if ($ProbeResult -ne 'NotProbed') { $Key } else { '' }); ProbedView = $(if ($ProbeResult -ne 'NotProbed') { $View } else { '' }); ExitCode = 0; Seconds = 12; LingeringProcess = @(); PfroUnderRoot = $false; RootConfigRemoved = $RootConfigRemoved; VendorConfigRemoved = @() }
        HostChecks    = [ordered]@{
            UninstallerSigner = (& $sig $(if ($UninstallerSignerStatus) { $script:TestSiblingSigner } else { '' }) $UninstallerSignerStatus); MainSigner = (& $sig $MainSigner)
            InstallerSigner = (& $sig $InstallerSigner); NsisMagic = ($ForceNsis -or (-not $NoNsis -and $Type -in @('nullsoft', 'exe'))); InnoMarkers = [bool]$InnoMarkers
        }
    }
    $typed = ConvertTo-Win32ToolkitSiblingCaptureRecord -InputObject $rec
    if ($null -eq $typed) { throw 'fixture record does not have the frozen shape' }
    $typed
}

function Write-TestSiblingRecord {
    param([string]$ProjectPath, $Record)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Record -Depth 12 -Compress -EscapeHandling EscapeNonAscii))
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $id = (-join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16) } finally { $hasher.Dispose() }
    $dir = Join-Path $ProjectPath 'Documentation\SiblingCapture'
    $null = New-Item -ItemType Directory -Path $dir -Force
    [IO.File]::WriteAllBytes((Join-Path $dir "$id.json"), $bytes)
    $id
}

function New-TestSiblingProject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builder: writes only under the suite''s temp folder')]
    param([string]$Path, [string]$InstallerType = 'msi', [string]$Version = '8.9.9', [string]$WingetId = 'Notepad++.Notepad++', [switch]$NoOwn, [string[]]$OwnArpKeys = @(),
        [string]$Vendor = 'Notepad++ Team')
    $pc = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
    foreach ($d in 'SupportFiles', 'Documentation', 'Files') { $null = New-Item -ItemType Directory -Path (Join-Path $Path $d) -Force }
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Vendor = $Vendor; Name = 'Notepad++'; DisplayName = 'Notepad++'; Version = $Version; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        Installer = [ordered]@{ Type = $InstallerType; FileName = 'npp.msi'; SilentArgs = '' }; ProcessesToClose = @()
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = $WingetId; Architecture = 'x64'; ProductCode = $(if ($InstallerType -eq 'msi') { $pc } else { '' }) } }
    if (-not $NoOwn) {
        $arp = @([ordered]@{ Key = $pc; View = 'Native' }) + @($OwnArpKeys | ForEach-Object { [ordered]@{ Key = $_; View = 'Native' } })
        $cfg['OwnIdentity'] = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $pc; UpgradeCode = ''; ArpKeys = $arp; CapturedOn = '2026-10-25' }
    }
    [IO.File]::WriteAllText((Join-Path $Path 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $Path
}
