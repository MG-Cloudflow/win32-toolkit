<#
    Installer-identity PR 3 (spec 2.6, L6-L11, D10-D16, D22, D26, D27): the remove-prior catalog texts
    'RemovePriorCheck' (slot Pre-Install:prior-check) and 'RemovePrior' (slot Pre-Install:remove-prior).

      [1] static checks: both texts parse (host); ASCII-only; 'New-TimeSpan -Minutes 30' once; one Start-ADTProcess with
          -WaitForChildProcesses, -Timeout and -PassThru; no KillChildProcessesWithParent, NoTerminateOnTimeout,
          Get-ADTApplication, Uninstall-ADTApplication or here-string; every assigned / foreach / parameter variable is
          $w32t*; RemovePriorCheck starts with the PriorPredicate text and then the PriorEvaluate text (byte identity);
          the revision marker once; the pair (revision 2, CatalogVersion) is PINNED (any text change must bump it, L38).
      [2] the texts run under Windows PowerShell 5.1 (Set-StrictMode -Version 1, $ErrorActionPreference 'Stop') with
          every PSADT command, the registry, the ACL and signature readers, Get-Process, Start-Sleep and the Windows
          Installer COM object shadowed (the COM fake is a C# class compiled in the child, driven through InvokeMember
          as on a device). $env:ProgramFiles / ${env:ProgramFiles(x86)} point at temp folders; the "installs" are
          files the test creates there. The registry shadows throw on any HKLM path they do not know, and after
          every case the suite asserts that HKLM:\SOFTWARE\<test author> does not exist on this (elevated) host.
          Cases: the Appendix A smoke (no entries, absent, removal, Block, newer, windows, D14 unproven + markers,
          template, Report, path/ACL/signer refusals, own key, VersionMax rules, field validation, kill switch,
          anti-ping-pong, restart, MSI busy, payload, running process, timeout/failure, 3010, survivors, Inno
          arguments) plus the Appendix B rows (custom folder, empty folder, missing uninstaller, the 4.2 FileInfo
          DefaultMsiFile, a relative DefaultMsiFile, WOW-only kill switch, kill switch set after prior-check, ACL
          allow-list and owner, OwnIdentity missing, the payload MSI's own codes (69106), OpenDatabase failure,
          duplicates, unwritable marker, already removed by an earlier uninstaller, Report never refuses).
      [3] the 32-bit Windows PowerShell (SysWOW64): a Report-only set is logged and the install goes on; a Block entry
          refuses 69105.

    Nothing is installed or executed; everything is written below %TEMP% and removed (junctions first).

    Run:  pwsh -File Tests\RemovePriorBlock.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitDeployScriptBlock.ps1')
$predicate = Get-Win32ToolkitDeployScriptBlock -Name PriorPredicate
$evaluate = Get-Win32ToolkitDeployScriptBlock -Name PriorEvaluate
$check = Get-Win32ToolkitDeployScriptBlock -Name RemovePriorCheck
$remove = Get-Win32ToolkitDeployScriptBlock -Name RemovePrior

# == [1] static checks =================================================================================
Write-Host '[1] the catalog texts: composition, constants, 5.1/C-12 rules, variable names, the pinned revision' -ForegroundColor Cyan
function Get-Count([string]$Text, [string]$Needle) { ([regex]::Matches($Text, [regex]::Escape($Needle))).Count }
if ($check.StartsWith($predicate + "`n" + $evaluate + "`n", [StringComparison]::Ordinal)) { Ok 'RemovePriorCheck = PriorPredicate + PriorEvaluate + the prior-check body (byte identity)' } else { Bad 'RemovePriorCheck does not start with the PriorPredicate and PriorEvaluate texts' }
$composed = $check + "`n" + $remove
foreach ($c in @(
        @{ T = $composed; N = '## remove-prior catalog revision 2 (win32-toolkit)'; W = 1 }
        @{ T = $composed; N = 'New-TimeSpan -Minutes 30'; W = 1 }
        @{ T = $composed; N = 'Start-ADTProcess'; W = 1 }
        @{ T = $composed; N = '-WaitForChildProcesses -Timeout $w32tPrLimit -PassThru'; W = 1 }
        @{ T = $composed; N = "'/S _?=' + `$w32tPrR.Dir"; W = 1 }
        @{ T = $composed; N = "$w32tPrArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'"; W = 1 }
        @{ T = $composed; N = 'KillChildProcessesWithParent'; W = 0 }
        @{ T = $composed; N = 'NoTerminateOnTimeout'; W = 0 }
        @{ T = $composed; N = 'Get-ADTApplication'; W = 0 }
        @{ T = $composed; N = 'Uninstall-ADTApplication'; W = 0 }
        @{ T = $composed; N = "@'"; W = 0 }
        @{ T = $composed; N = '@"'; W = 0 }
        @{ T = $composed; N = '$appConfig ='; W = 0 }
        @{ T = $composed; N = '## win32-toolkit:'; W = 0 }
        # InvokeMember passes its arguments as they are: a Join-Path result is a PSObject-wrapped string that reflection (and
        # COM) cannot bind, so the payload path is cast to a plain [string] (found by the relative-DefaultMsiFile case below).
        @{ T = $composed; N = '$w32tPrPayload = [string](Join-Path $adtSession.DirFiles $w32tPrPayload)'; W = 1 }
    )) {
    $n = Get-Count $c.T $c.N
    if ($n -eq $c.W) { Ok "'$($c.N)' occurs $($c.W) time(s)" } else { Bad "'$($c.N)' occurs $n time(s), want $($c.W)" }
}
if (@([Text.Encoding]::UTF8.GetBytes($composed) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'ASCII-only' } else { Bad 'non-ASCII characters in the texts' }
if ($composed -notmatch '(?i)firefox|mozilla|helper\.exe|notepad|7-zip|chrome|google|adobe|zoom') { Ok 'no app or vendor name in the texts (they ship in every package)' } else { Bad 'an app or vendor name in the texts' }
foreach ($pair in @(@('RemovePriorCheck', $check), @('RemovePrior', $remove), @('composed', $composed))) {
    $perr = $null; [void][Management.Automation.Language.Parser]::ParseInput($pair[1], [ref]$null, [ref]$perr)
    if (-not $perr) { Ok "$($pair[0]) parses (host)" } else { Bad "$($pair[0]) host parse: $($perr[0].Message)" }
}
$ast = [Management.Automation.Language.Parser]::ParseInput($composed, [ref]$null, [ref]$null)
$assigned = [Collections.Generic.List[string]]::new()
foreach ($n in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $left = $n.Left
    while ($left -is [Management.Automation.Language.IndexExpressionAst] -or $left -is [Management.Automation.Language.MemberExpressionAst]) { $left = if ($left -is [Management.Automation.Language.IndexExpressionAst]) { $left.Target } else { $left.Expression } }
    if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
    if ($left -is [Management.Automation.Language.VariableExpressionAst]) { $assigned.Add($left.VariablePath.UserPath) }
}
foreach ($n in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.ForEachStatementAst] }, $true)) { $assigned.Add($n.Variable.VariablePath.UserPath) }
foreach ($n in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.ParameterAst] }, $true)) { $assigned.Add($n.Name.VariablePath.UserPath) }
$badNames = @($assigned | Sort-Object -Unique | Where-Object { $_ -notlike 'w32t*' -and $_ -ne 'null' })
$reserved = @('w32tUi', 'w32tWelcome', 'w32tCountdown', 'w32tProgress', 'w32tInstallDone')
$clash = @($assigned | Sort-Object -Unique | Where-Object { $reserved -ccontains $_ })
if ($assigned.Count -gt 50 -and $badNames.Count -eq 0 -and $clash.Count -eq 0) { Ok "every assigned / foreach / parameter variable ($(@($assigned | Sort-Object -Unique).Count) names) is `$w32t* and none is an org-ui / loader name" } else { Bad "variables: not w32t*: $($badNames -join ', '); clashes: $($clash -join ', ')" }
$rev = Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision
$cv = Get-Win32ToolkitDeployScriptBlock -Name RemovePriorCatalogVersion
# PINNED (L38): the requirement and the guest assertions embed the CURRENT predicate while a project keeps the block it
# was created with (D12). A change of any of the four texts must bump the revision marker, and then this pair.
# Revision 2 (installer-identity PR 3 live checks, fixer round 1): the Windows Installer check that throws counts as busy
    # (MSIBUSY, PSADT 4.2.0-rc2), each log line names its step (prior-check or remove-prior, DEMOTE), 69110 names the app's own
    # updater (GUP) and 69111 in remove-prior says 'after prior-check' (KILL-WOW).
    if ($rev -is [int] -and $rev -eq 2 -and $cv -ceq '28573ba28432910a') { Ok "catalog revision 2 <-> CatalogVersion $cv (pinned)" } else { Bad "revision/CatalogVersion changed: $rev / $cv - bump the revision marker in the prior-check text and pin the new pair" }
$sha = [Security.Cryptography.SHA256]::Create()
$own = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($predicate + "`n" + $evaluate + "`n" + $check.Substring($predicate.Length + $evaluate.Length + 2) + "`n" + $remove)) | ForEach-Object { $_.ToString('x2') })
if ($own.Substring(0, 16) -ceq $cv) { Ok 'CatalogVersion = the first 16 hex of the SHA-256 of the four texts' } else { Bad "CatalogVersion: $cv vs $($own.Substring(0, 16))" }

# == [2] Windows PowerShell 5.1 runs ===================================================================
Write-Host '[2] the texts under Windows PowerShell 5.1 with shadowed PSADT, registry, ACL, signature and COM' -ForegroundColor Cyan
$ps51 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51)) {
    Write-Host '  SKIP: Windows PowerShell 5.1 not present for the runtime check' -ForegroundColor DarkYellow
    if ($fail -eq 0) { exit 3 }
    exit 1
}

$harness = @'
param([string]$CheckPath, [string]$RemovePath, [string]$Root, [string]$Author, [string]$Mode = 'full')
Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Ok($m) { Write-Output "PASS: $m" }
function Bad($m) { Write-Output "FAIL: $m"; $script:fail++ }

$checkText = [IO.File]::ReadAllText($CheckPath)
$removeText = [IO.File]::ReadAllText($RemovePath)
foreach ($t in @($checkText, $removeText, ($checkText + "`n" + $removeText))) {
    $e = $null; [void][Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e)
    if (@($e).Count -ne 0) { Bad "5.1 parse: $($e[0].Message)" }
}
Ok 'the texts parse under Windows PowerShell 5.1'
$checkSb = [scriptblock]::Create($checkText)
$removeSb = [scriptblock]::Create($removeText)

$PF = Join-Path $Root 'PF'; $PF86 = Join-Path $Root 'PF86'; $Other = Join-Path $Root 'Other'; $FilesDir = Join-Path $Root 'Files'
foreach ($d in $PF, $PF86, $Other, $FilesDir) { [void][IO.Directory]::CreateDirectory($d) }
$env:ProgramFiles = $PF
${env:ProgramFiles(x86)} = $PF86

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
public class W32tFakeRecord {
    private string v;
    public W32tFakeRecord(string v) { this.v = v; }
    [System.Runtime.CompilerServices.IndexerName("StringData")]
    public string this[int i] { get { return v; } }
}
public class W32tFakeView {
    private string prop;
    public W32tFakeView(string sql) { int a = sql.IndexOf("Property='"); prop = sql.Substring(a + 10).TrimEnd('\''); }
    public void Execute() { }
    public object Fetch() { string v; if (W32tFakeInstaller.DbProps.TryGetValue(prop, out v)) { return new W32tFakeRecord(v); } return null; }
}
public class W32tFakeDatabase { public object OpenView(string sql) { return new W32tFakeView(sql); } }
public class W32tFakeInstaller {
    public static Dictionary<string, int> States = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    public static Dictionary<string, string[]> Related = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
    public static Dictionary<string, string> Versions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    public static Dictionary<string, string> DbProps = new Dictionary<string, string>(StringComparer.Ordinal);
    public static bool DbFail;
    public static List<string> Opened = new List<string>();
    public int ProductState(string pc) { int s; return States.TryGetValue(pc, out s) ? s : -1; }
    public string[] RelatedProducts(string uc) { string[] r; return Related.TryGetValue(uc, out r) ? r : new string[0]; }
    public string ProductInfo(string pc, string prop) { string v; if (Versions.TryGetValue(pc, out v)) { return v; } throw new Exception("unknown product"); }
    public object OpenDatabase(string path, int mode) { Opened.Add(path); if (DbFail) { throw new Exception("cannot open"); } return new W32tFakeDatabase(); }
}
"@

$NativeArp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$WowArp = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$MarkRoot = "HKLM:\SOFTWARE\$Author\win32-toolkit"
$WowMarkRoot = "HKLM:\SOFTWARE\WOW6432Node\$Author\win32-toolkit"
$SessionMgr = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$script:known = @($NativeArp, $WowArp, $MarkRoot, $WowMarkRoot, $SessionMgr, "HKLM:\SOFTWARE\$Author", "HKLM:\SOFTWARE\WOW6432Node\$Author")
function Assert-Known([string]$P) {
    foreach ($k in $script:known) { if ($P -eq $k -or $P.StartsWith($k + '\', [StringComparison]::OrdinalIgnoreCase)) { return } }
    throw "the test registry does not know $P"
}

# ---- shadows ----
$script:reg = @{}; $script:markFail = @(); $script:log = @(); $script:started = @(); $script:exitCode = $null
$script:running = @(); $script:sig = @{}; $script:acl = @{}; $script:effects = @{}; $script:rebootCbs = $false; $script:rebootWu = $false
$script:msiBusy = $false; $script:sleeps = 0; $script:removedFiles = @(); $script:comCalls = 0
function Write-ADTLogEntry { param([string]$Message, [int]$Severity = 1) $script:log += "[$Severity] $Message" }
function Get-ADTPendingReboot { New-Object psobject -Property @{ IsCBServicingRebootPending = $script:rebootCbs; IsWindowsUpdateRebootPending = $script:rebootWu } }
function Test-ADTMutexAvailability { param([string]$MutexName) if ($MutexName -ne 'Global\_MSIExecute') { throw "mutex $MutexName" }; if ($script:msiThrows) { throw "The property 'FilePath' cannot be found on this object. Verify that the property exists." }; -not $script:msiBusy }
function Get-Process { [CmdletBinding()] param([string]$Name) if ($script:running -contains $Name) { New-Object psobject -Property @{ Name = $Name } } }
function Start-Sleep { param([int]$Seconds) $script:sleeps++ }
function Get-AuthenticodeSignature {
    [CmdletBinding()] param([string]$LiteralPath)
    $s = $script:sig[$LiteralPath]
    if ($s) { return (New-Object psobject -Property @{ Status = $s.Status; SignerCertificate = (New-Object psobject -Property @{ Subject = $s.Subject }) }) }
    New-Object psobject -Property @{ Status = 'NotSigned'; SignerCertificate = $null }
}
function New-FakeAcl([string]$Owner, [object[]]$Rules) {
    $o = Microsoft.PowerShell.Utility\New-Object psobject
    $o | Add-Member -MemberType NoteProperty -Name OwnerSid -Value $Owner
    $o | Add-Member -MemberType NoteProperty -Name RuleList -Value $Rules
    $o | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($t) Microsoft.PowerShell.Utility\New-Object System.Security.Principal.SecurityIdentifier $this.OwnerSid }
    $o | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { param($a, $b, $t) , $this.RuleList }
    $o
}
function Rule([string]$Sid, [string]$Rights, [string]$Type = 'Allow', [string]$Prop = 'None') {
    # .NET drops the propagation flags of a rule without inheritance flags: an InheritOnly rule needs them (as on a real folder).
    $inh = 'None'; if ($Prop -ne 'None') { $inh = 'ContainerInherit, ObjectInherit' }
    Microsoft.PowerShell.Utility\New-Object System.Security.AccessControl.FileSystemAccessRule ((Microsoft.PowerShell.Utility\New-Object System.Security.Principal.SecurityIdentifier $Sid), [Security.AccessControl.FileSystemRights]$Rights, [Security.AccessControl.InheritanceFlags]$inh, [Security.AccessControl.PropagationFlags]$Prop, [Security.AccessControl.AccessControlType]$Type)
}
$script:trusted = @((Rule 'S-1-5-18' 'FullControl'), (Rule 'S-1-5-32-544' 'FullControl'), (Rule 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' 'FullControl'), (Rule 'S-1-5-32-545' 'ReadAndExecute'), (Rule 'S-1-3-0' 'FullControl' 'Allow' 'InheritOnly'))
function Get-Acl {
    [CmdletBinding()] param([string]$LiteralPath)
    if ($script:acl.ContainsKey($LiteralPath)) { return $script:acl[$LiteralPath] }
    # A file carries no InheritOnly ACE (that one exists on folders only).
    if ([IO.File]::Exists($LiteralPath)) { return (New-FakeAcl 'S-1-5-32-544' @($script:trusted | Where-Object { $_.PropagationFlags -eq 'None' })) }
    New-FakeAcl 'S-1-5-32-544' $script:trusted
}
function Test-Path {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Path, [string]$PathType)
    $p = $LiteralPath; if (-not $p) { $p = $Path }
    if ($p -like 'HKLM:*') { Assert-Known $p; return $script:reg.ContainsKey($p.ToLowerInvariant()) }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Name)
    if ($LiteralPath -notlike 'HKLM:*') { throw "Get-ItemProperty on $LiteralPath" }
    Assert-Known $LiteralPath
    $k = $script:reg[$LiteralPath.ToLowerInvariant()]
    if ($null -eq $k) { throw "Cannot find path '$LiteralPath' because it does not exist." }
    if ($k.ContainsKey('__readfail')) { throw 'Requested registry access is not allowed.' }
    if ($Name -and -not $k.ContainsKey($Name)) { throw "Property $Name does not exist at path $LiteralPath." }
    $o = Microsoft.PowerShell.Utility\New-Object psobject
    foreach ($n in @($k.Keys)) { $o | Add-Member -MemberType NoteProperty -Name $n -Value $k[$n] }
    $o
}
function New-Item {
    [CmdletBinding()] param([string]$Path, [string]$ItemType, [switch]$Force, $Value)
    if ($Path -like 'HKLM:*') {
        Assert-Known $Path
        foreach ($m in $script:markFail) { if ($Path -like $m) { throw 'Requested registry access is not allowed.' } }
        if (-not $script:reg.ContainsKey($Path.ToLowerInvariant())) { $script:reg[$Path.ToLowerInvariant()] = @{} }
        return (Microsoft.PowerShell.Utility\New-Object psobject -Property @{ PSPath = $Path })
    }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function New-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Name, $Value, [string]$PropertyType, [switch]$Force)
    if ($LiteralPath -notlike 'HKLM:*') { throw "New-ItemProperty on $LiteralPath" }
    Assert-Known $LiteralPath
    foreach ($m in $script:markFail) { if ($LiteralPath -like $m) { throw 'Requested registry access is not allowed.' } }
    $k = $script:reg[$LiteralPath.ToLowerInvariant()]
    if ($null -eq $k) { throw "Cannot find path '$LiteralPath'" }
    $k[$Name] = $Value
    Microsoft.PowerShell.Utility\New-Object psobject
}
function Remove-Item {
    [CmdletBinding()] param([string]$LiteralPath, [switch]$Force, [switch]$Recurse)
    $script:removedFiles += $LiteralPath
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
function New-Object {
    param([Parameter(Position = 0)][string]$TypeName, [Parameter(Position = 1)][object[]]$ArgumentList, [string]$ComObject, [hashtable]$Property)
    if ($ComObject) {
        if ($ComObject -ne 'WindowsInstaller.Installer') { throw "unexpected COM object $ComObject" }
        $script:comCalls++
        return (Microsoft.PowerShell.Utility\New-Object W32tFakeInstaller)
    }
    Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}
function Start-ADTProcess {
    [CmdletBinding()] param([string]$FilePath, [string[]]$ArgumentList, [switch]$WaitForChildProcesses, [timespan]$Timeout, [switch]$PassThru)
    $script:started += New-Object psobject -Property @{ FilePath = $FilePath; Args = @($ArgumentList); Count = @($ArgumentList).Count; Wait = [bool]$WaitForChildProcesses
        Timeout = $Timeout; Bound = (@($PSBoundParameters.Keys | Sort-Object) -join ',') }
    $fx = $script:effects[$FilePath]
    if (-not $fx) { $fx = @{} }
    if ($fx.ContainsKey('Throw')) { throw $fx.Throw }
    foreach ($k in @($fx.Keys)) { if ($k -like 'Key*') { [void]$script:reg.Remove(([string]$fx[$k]).ToLowerInvariant()) } }
    foreach ($k in @($fx.Keys)) { if ($k -like 'File*') { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $fx[$k] -Force -ErrorAction SilentlyContinue } }
    if ($fx.ContainsKey('Pfro')) { $script:reg[$SessionMgr.ToLowerInvariant()]['PendingFileRenameOperations'] = @($script:reg[$SessionMgr.ToLowerInvariant()]['PendingFileRenameOperations']) + @($fx.Pfro) }
    $exit = 0; if ($fx.ContainsKey('Exit')) { $exit = $fx.Exit }
    New-Object psobject -Property @{ ExitCode = $exit }
}

$adtSession = Microsoft.PowerShell.Utility\New-Object psobject
$adtSession | Add-Member -MemberType NoteProperty -Name UseDefaultMsi -Value $true
$adtSession | Add-Member -MemberType NoteProperty -Name DefaultMsiFile -Value ''
$adtSession | Add-Member -MemberType NoteProperty -Name DirFiles -Value $FilesDir
$adtSession | Add-Member -MemberType ScriptMethod -Name SetExitCode -Value { param($c) $script:exitCode = $c }

$PC = '{AAAAAAAA-1111-2222-3333-444444444444}'; $UC = '{BBBBBBBB-1111-2222-3333-444444444444}'
$PayloadPC = '{CCCCCCCC-1111-2222-3333-444444444444}'; $PayloadUC = '{DDDDDDDD-1111-2222-3333-444444444444}'
$script:caseN = 0

# One prior install: files under $Base\$Folder and its uninstall key. Returns its paths.
function New-Prior {
    param([string]$Key = 'App', [string]$View = 'Native', [string]$Base = $PF, [string]$Folder = 'App', [string]$Version = '8.9.8', [string]$Publisher = 'Vendor Team',
        [string]$DisplayName = 'App (64-bit)', [string]$Uninstaller = 'uninstall.exe', [string]$Main = 'app.exe', [string]$UninstallString = '', [switch]$NoMain, [switch]$NoUninstaller, [switch]$Msi, [switch]$Inno)
    $dir = Join-Path $Base $Folder
    [void][IO.Directory]::CreateDirectory($dir)
    $exe = Join-Path $dir $Uninstaller; $mainPath = Join-Path $dir $Main
    if (-not $NoUninstaller) { [IO.File]::WriteAllText($exe, 'x') } elseif (Microsoft.PowerShell.Management\Test-Path -LiteralPath $exe) { [IO.File]::Delete($exe) }
    if (-not $NoMain) { [IO.File]::WriteAllText($mainPath, 'x') } elseif (Microsoft.PowerShell.Management\Test-Path -LiteralPath $mainPath) { [IO.File]::Delete($mainPath) }
    $root = $NativeArp; if ($View -eq 'Wow6432') { $root = $WowArp }
    $kp = "$root\$Key"
    $us = $UninstallString; if (-not $us) { $us = '"' + $exe + '"' }
    $vals = @{ DisplayName = $DisplayName; DisplayVersion = $Version; Publisher = $Publisher; UninstallString = $us }
    if ($Msi) { $vals['WindowsInstaller'] = 1 }
    $script:reg[$kp.ToLowerInvariant()] = $vals
    $fx = @{ Key1 = $kp; File1 = $mainPath }
    if ($Inno) { $fx['File2'] = $exe }
    $script:effects[$exe] = $fx
    New-Object psobject -Property @{ Dir = $dir; Exe = $exe; Main = $mainPath; KeyPath = $kp }
}
function Entry {
    param([string]$Id = 'app-x64', [string]$Mode = 'Enforce', [string]$Key = 'App', [string]$View = 'Native', [string]$Publisher = 'Vendor Team', [string]$DisplayName = 'App (64-bit)',
        [string]$Template = '', [string]$VersionMin = '8.0', [string]$VersionMax = '8.9.8.1', [string]$Type = 'nullsoft', [string]$Leaf = 'uninstall.exe', [string]$Signer = '',
        [string]$Dir = '%ProgramFiles%\App', [string]$Main = 'app.exe', [object[]]$Procs = @('app'))
    New-Object psobject -Property ([ordered]@{ Id = $Id; Kind = 'ArpKey'; Mode = $Mode; Key = $Key; View = $View; Publisher = $Publisher; DisplayName = $DisplayName
            DisplayNameTemplate = $Template; VersionMin = $VersionMin; VersionMax = $VersionMax; UninstallerType = $Type; UninstallerFileName = $Leaf; UninstallerSigner = $Signer
            InstallDir = $Dir; MainExe = $Main; ProcessNames = $Procs; Source = 'Operator'; AddedOn = '2026-10-25' })
}
function Cfg {
    param([object[]]$Entries, [string]$Type = 'msi', [string]$Version = '9.0', [string]$Author2 = $Author, [switch]$NoOwn, [string]$FileName = 'pkg.msi')
    $own = New-Object psobject -Property @{ ProductCode = $PC; UpgradeCode = $UC; ArpKeys = @((New-Object psobject -Property @{ Key = $PC; View = 'Native' })) }
    $c = New-Object psobject -Property ([ordered]@{
            App = (New-Object psobject -Property @{ Version = $Version; ScriptAuthor = $Author2; Name = 'Pkg'; Vendor = 'V' })
            Installer = (New-Object psobject -Property @{ Type = $Type; FileName = $FileName; SilentArgs = '' })
            PriorInstalls = (New-Object psobject -Property @{ SchemaVersion = '1.0'; Entries = @($Entries) })
            ProcessesToClose = @()
        })
    if (-not $NoOwn) { $c | Add-Member -MemberType NoteProperty -Name OwnIdentity -Value $own }
    $c
}
function Reset-World {
    foreach ($d in $PF, $PF86, $Other) {
        foreach ($sub in [IO.Directory]::GetDirectories($d)) {
            if ([IO.File]::GetAttributes($sub) -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($sub) } else { [IO.Directory]::Delete($sub, $true) }
        }
    }
    $script:reg = @{}; $script:reg[$SessionMgr.ToLowerInvariant()] = @{ PendingFileRenameOperations = @() }
    $script:markFail = @(); $script:running = @(); $script:sig = @{}; $script:acl = @{}; $script:effects = @{}
    $script:rebootCbs = $false; $script:rebootWu = $false; $script:msiBusy = $false; $script:msiThrows = $false
    [W32tFakeInstaller]::States.Clear(); [W32tFakeInstaller]::Related.Clear(); [W32tFakeInstaller]::Versions.Clear(); [W32tFakeInstaller]::DbProps.Clear(); [W32tFakeInstaller]::Opened.Clear()
    [W32tFakeInstaller]::DbFail = $false
    [W32tFakeInstaller]::DbProps['ProductCode'] = $PayloadPC; [W32tFakeInstaller]::DbProps['UpgradeCode'] = $PayloadUC
    [IO.File]::WriteAllText((Join-Path $FilesDir 'pkg.msi'), 'x'); [IO.File]::WriteAllText((Join-Path $FilesDir 'setup.exe'), 'x')
    $adtSession.UseDefaultMsi = $true; $adtSession.DefaultMsiFile = (Join-Path $FilesDir 'pkg.msi')
}
function Invoke-Case {
    param($Config, [scriptblock]$Between = $null)
    $script:caseN++
    $script:log = @(); $script:started = @(); $script:exitCode = $null; $script:sleeps = 0; $script:removedFiles = @(); $script:comCalls = 0
    $appConfig = $Config
    $res = 'ok'
    try { . $checkSb; if ($Between) { & $Between }; . $removeSb } catch { $res = 'threw: ' + $_.Exception.Message }
    if (Microsoft.PowerShell.Management\Test-Path -LiteralPath "HKLM:\SOFTWARE\$Author") { Bad "case $($script:caseN): the REAL HKLM:\SOFTWARE\$Author exists on this host" }
    New-Object psobject -Property @{ Res = $res; Code = $script:exitCode; Started = @($script:started); Log = ($script:log -join ' | ') }
}
function Mark([string]$View, [string]$Key, [string]$Name) { $k = $script:reg[("$MarkRoot\PriorInstalls\$View\$Key").ToLowerInvariant()]; if ($k -and $k.ContainsKey($Name)) { [string]$k[$Name] } else { '' } }
function Refused($r, [int]$Code) { $r.Res -like 'threw:*' -and $r.Code -eq $Code -and @($r.Started).Count -eq 0 }
function Show($r) { "res=$($r.Res) code=$($r.Code) started=$(@($r.Started).Count) log=$($r.Log)" }
# The first started process's argument / file, or '' when nothing started (live row HOST-SMOKE: a regression that started no
# uninstaller stopped the whole 5.1 run at 'Cannot index into a null array', hiding the later checks).
function StartArg($r) { $s = @($r.Started); if ($s.Count -lt 1 -or $null -eq $s[0]) { return '' }; $a = @($s[0].Args); if ($a.Count -lt 1) { return '' }; [string]$a[0] }
function StartFile($r) { $s = @($r.Started); if ($s.Count -lt 1 -or $null -eq $s[0]) { return '' }; [string]$s[0].FilePath }
function StartCount($r) { $s = @($r.Started); if ($s.Count -lt 1 -or $null -eq $s[0]) { return 0 }; [int]$s[0].Count }

try {
if ($Mode -eq 'x86') {
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry -Mode Report)))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and $r.Log -match 'a 32-bit process cannot read the native registry view; policy Report') { Ok '32-bit: a Report-only set is logged and the install goes on (D26)' } else { Bad "32-bit Report: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry -Mode Block)))
    if ((Refused $r 69105) -and $r.Log -match '32-bit process') { Ok '32-bit: a Block entry refuses 69105 (the native view cannot be read)' } else { Bad "32-bit Block: $(Show $r)" }
}
else {
    # ---- basics ----
    Reset-World
    $r = Invoke-Case (Cfg @())
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and -not $r.Log -and @($r.Started).Count -eq 0) { Ok 'no entries: nothing logged, nothing started, no exit code' } else { Bad "no entries: $(Show $r)" }
    $noPi = Cfg @(); $noPi.PSObject.Properties.Remove('PriorInstalls')
    $r = Invoke-Case $noPi
    if ($r.Res -eq 'ok' -and -not $r.Log) { Ok 'no PriorInstalls section (a project without rules): a no-op' } else { Bad "no section: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and $r.Log -match 'is not present' -and @($r.Started).Count -eq 0) { Ok 'absent prior: logged, nothing started' } else { Bad "absent: $(Show $r)" }

    # ---- Enforce removal (NSIS) ----
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry)))
    $s = @($r.Started)[0]
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and @($r.Started).Count -eq 1 -and $s.Count -eq 1 -and $s.Args[0] -ceq "/S _?=$($p.Dir)" -and $s.Wait -and $s.Timeout.TotalMinutes -eq 30 -and $s.Bound -ceq 'ArgumentList,FilePath,PassThru,Timeout,WaitForChildProcesses') { Ok "Enforce: the NSIS uninstaller runs with ONE argument string '/S _?=<folder>', -WaitForChildProcesses, 30 min, -PassThru" } else { Bad "removal: $(Show $r) args=$(@($s.Args) -join '|') bound=$($s.Bound)" }
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $p.Exe)) { Ok 'the leftover NSIS uninstaller is deleted' } else { Bad 'leftover uninstaller still there' }
    if ((Mark 'Native' 'App' 'Removed') -match '^\d{4}-\d{2}-\d{2}$' -and (Mark 'Native' 'App' 'Version') -ceq '8.9.8' -and (Mark 'Native' 'App' 'LastSeen') -match ' Planned 8\.9\.8$') { Ok 'markers: Removed (date), Version, and the Planned probe written before the removal' } else { Bad "markers: Removed=$(Mark 'Native' 'App' 'Removed') Version=$(Mark 'Native' 'App' 'Version') LastSeen=$(Mark 'Native' 'App' 'LastSeen')" }
    if ($r.Log -match 'proven: .* it is removed after the close-apps dialog' -and $r.Log -match 'removed .*8\.9\.8, uninstaller') { Ok 'the plan and the removal are logged' } else { Bad "log: $($r.Log)" }

    # ---- Inno arguments; Inno uninstaller left -> 69109 ----
    Reset-World
    $p = New-Prior -Key 'App_is1' -Uninstaller 'unins000.exe' -Inno
    $r = Invoke-Case (Cfg @((Entry -Key 'App_is1' -Type inno -Leaf 'unins000.exe')))
    if ($r.Res -eq 'ok' -and (StartArg $r) -ceq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -and (StartCount $r) -eq 1) { Ok "Inno: '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' (one string)" } else { Bad "inno: $(Show $r)" }
    Reset-World
    $p = New-Prior -Key 'App_is1' -Uninstaller 'unins000.exe'
    $r = Invoke-Case (Cfg @((Entry -Key 'App_is1' -Type inno -Leaf 'unins000.exe')))
    if ($r.Res -like 'threw*' -and $r.Code -eq 69109 -and $script:sleeps -ge 59) { Ok 'Inno: its uninstaller still there after the bounded wait -> 69109' } else { Bad "inno left: $(Show $r) sleeps=$($script:sleeps)" }

    # ---- Block, Enforce + Block, newer, windows ----
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry -Mode Block)))
    if ((Refused $r 69101) -and $r.Log -match 'policy is Block') { Ok 'Block: 69101, nothing started' } else { Bad "block: $(Show $r)" }
    if ($r.Log -match 'LastRefusal' -or ($script:reg[$MarkRoot.ToLowerInvariant()]['LastRefusal'] -match '^\d{4}-\d{2}-\d{2} 69101 9\.0$')) { Ok 'LastRefusal marker = <date> 69101 <package version>' } else { Bad 'LastRefusal marker missing' }
    $p2 = New-Prior -Key 'Other' -Folder 'Other' -Main 'other.exe'
    $r = Invoke-Case (Cfg @((Entry -Id 'a-enforce'), (Entry -Id 'b-block' -Mode Block -Key 'Other' -Dir '%ProgramFiles%\Other' -Main 'other.exe')))
    if (Refused $r 69101) { Ok 'Enforce A + Block B: 69101 and no uninstaller started for A' } else { Bad "A+B: $(Show $r)" }
    Reset-World
    $p = New-Prior -Version '9.1'
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 69102) -and $r.Log -match 'NEWER prior install') { Ok 'newer than VersionMax: 69102' } else { Bad "newer: $(Show $r)" }
    Reset-World
    $p = New-Prior -Version '8.9.8.1'
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok '8.9.8.1 = VersionMax: proven, removed' } else { Bad "at max: $(Show $r)" }
    Reset-World
    $p = New-Prior -Version '26.02'
    $r = Invoke-Case (Cfg @((Entry -VersionMin '26.2' -VersionMax '26.2')))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok "'26.02' equals the window '26.2' (padded numeric parts)" } else { Bad "26.02: $(Show $r)" }

    # ---- D14: unproven -> leave it, marker, continue ----
    foreach ($c in @(
            @{ L = 'a 10-digit version part'; P = @{ Version = '8.9.1234567890' }; Why = 'its version cannot be read' }
            @{ L = 'a fifth version part'; P = @{ Version = '8.9.8.1.5' }; Why = 'its version cannot be read' }
            @{ L = 'publisher drift'; P = @{ Publisher = 'Other Team' }; Why = 'its publisher differs' }
            @{ L = 'below the window'; P = @{ Version = '7.9' }; Why = 'its version is below the proven window' }
            @{ L = 'WindowsInstaller 1'; P = @{ Msi = $true }; Why = 'registered by Windows Installer' }
            @{ L = 'another display name (ARM64)'; P = @{ DisplayName = 'App (ARM64)' }; Why = 'its display name differs' }
        )) {
        Reset-World
        $pp = $c.P
        $p = New-Prior @pp
        $r = Invoke-Case (Cfg @((Entry)))
        $seen = Mark 'Native' 'App' 'LastSeen'
        if ($r.Res -eq 'ok' -and $null -eq $r.Code -and @($r.Started).Count -eq 0 -and $r.Log -match [regex]::Escape($c.Why) -and $r.Log -match 'code 69103; the install goes on' -and $seen -match '^\d{4}-\d{2}-\d{2} Unproven 69103 ' -and -not (Mark 'Native' 'App' 'Removed')) {
            Ok "D14 $($c.L): left as it is, severity-2 line naming 69103, LastSeen '$seen', no exit code"
        } else { Bad "D14 $($c.L): $(Show $r) LastSeen=$seen" }
    }

    # ---- display-name template ----
    Reset-World
    $p = New-Prior -DisplayName 'App 8.9.8 (64-bit)'
    $r = Invoke-Case (Cfg @((Entry -DisplayName '' -Template 'App {v} (64-bit)')))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok 'template match: the observed DisplayVersion substituted, proven' } else { Bad "template: $(Show $r)" }
    Reset-World
    $p = New-Prior -DisplayName 'App 8.9.7 (64-bit)'
    $r = Invoke-Case (Cfg @((Entry -DisplayName '' -Template 'App {v} (64-bit)')))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 0 -and $r.Log -match 'display name differs') { Ok 'template mismatch: unproven, the install goes on' } else { Bad "template mismatch: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry -DisplayName '' -Template 'App {v} {v}')))
    if (Refused $r 69105) { Ok 'a template with two {v}: 69105 (invalid data)' } else { Bad "two tokens: $(Show $r)" }

    # ---- Report (D26) ----
    Reset-World
    $p = New-Prior -Version '9.5'
    $r = Invoke-Case (Cfg @((Entry -Mode Report)))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and @($r.Started).Count -eq 0 -and $r.Log -match 'policy Report: nothing removed' -and (Mark 'Native' 'App' 'LastSeen') -match ' Report Newer 9\.5$') { Ok 'Report (newer prior): logged, LastSeen Report Newer, no refusal, nothing removed' } else { Bad "report: $(Show $r) seen=$(Mark 'Native' 'App' 'LastSeen')" }
    $r = Invoke-Case (Cfg @((Entry -Mode Report -Publisher '')))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and $r.Log -match 'failed validation: Publisher; policy Report') { Ok 'Report with invalid data: logged, the install goes on (never 69105, D26)' } else { Bad "report invalid: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry -Mode Report)) -Author2 'bad\author')
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and $r.Log -match 'Report markers are not written') { Ok 'Report-only set with an unusable ScriptAuthor: logged, no refusal' } else { Bad "report author: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry -Mode Block)) -Author2 'bad\author')
    if (Refused $r 69105) { Ok 'the same with a Block entry: 69105' } else { Bad "block author: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry -Mode Enforce)) -Author2 '')
    if (Refused $r 69105) { Ok 'no ScriptAuthor with an Enforce entry: 69105' } else { Bad "no author: $(Show $r)" }

    # ---- path, files, ACL, signer (L8, L9, S27, SV10) ----
    foreach ($c in @(
            @{ L = 'registered in another folder (custom install folder, both files there)'; U = 'OTHER' }
            @{ L = 'forward slashes'; U = 'SLASH' }
            @{ L = 'an alternate data stream'; U = 'ADS' }
            @{ L = 'an 8.3 short name'; U = 'SHORT' }
            @{ L = 'another uninstaller file name'; U = 'LEAF' }
            @{ L = 'a relative part'; U = 'DOTDOT' }
        )) {
        Reset-World
        $p = New-Prior
        $o = New-Prior -Base $Other -Key 'Ignore' -Folder 'App'
        $u = switch ($c.U) {
            'OTHER' { '"' + $o.Exe + '"' }
            'SLASH' { '"' + $p.Exe.Replace('\', '/') + '"' }
            'ADS' { '"' + $p.Exe + ':evil"' }
            'SHORT' { '"' + ($p.Exe -replace '\\PF\\', '\PF~1\') + '"' }
            'LEAF' { '"' + (Join-Path $p.Dir 'uninst.exe') + '"' }
            'DOTDOT' { '"' + (Join-Path $p.Dir '..\App\uninstall.exe') + '"' }
        }
        $script:reg[$p.KeyPath.ToLowerInvariant()]['UninstallString'] = $u
        $r = Invoke-Case (Cfg @((Entry)))
        if ((Refused $r 69105) -and (Microsoft.PowerShell.Management\Test-Path -LiteralPath $p.Exe)) { Ok "proven prior whose uninstaller is $($c.L): 69105, nothing removed (L9)" } else { Bad "$($c.L): $(Show $r)" }
    }
    # Live row HOST-SMOKE (B3): the case above keeps the declared folder populated, so a main-program check placed BEFORE the
    # path check would still reach it. Here the declared folder is absent and both files are in the registered custom
    # folder: 69105 (never "Unproven 69103", which would install next to the prior), and no LastSeen marker.
    Reset-World
    $o = New-Prior -Base $Other -Folder 'App'
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 69105) -and -not (Mark 'Native' 'App' 'LastSeen') -and -not (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $PF 'App')) -and (Microsoft.PowerShell.Management\Test-Path -LiteralPath $o.Exe)) {
        Ok 'the declared folder absent, both files in the registered custom folder: 69105, no LastSeen (the path check comes before any file check, B3)'
    } else { Bad "B3 order: $(Show $r) LastSeen=$(Mark 'Native' 'App' 'LastSeen')" }
    # Live row HOST-SMOKE: the unquoted case never had a space in its path on a profile without one; the folder has one now.
    Reset-World
    $p = New-Prior -Folder 'My App' -UninstallString ''
    $script:reg[$p.KeyPath.ToLowerInvariant()]['UninstallString'] = $p.Exe + ' /S'
    $r = Invoke-Case (Cfg @((Entry -Dir '%ProgramFiles%\My App')))
    if ($p.Exe.Contains(' ') -and $r.Res -eq 'ok' -and @($r.Started).Count -eq 1 -and (StartFile $r) -ceq $p.Exe -and (StartArg $r) -ceq "/S _?=$($p.Dir)") { Ok 'an unquoted registered path with spaces and arguments is accepted' } else { Bad "unquoted: $(Show $r)" }
    # Live row DEMOTE: a refusal in prior-check was logged as 'win32-toolkit remove-prior:', as if the removal had begun.
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry -Mode Block)))
    $rk = Invoke-Case (Cfg @((Entry))) -Between { $script:reg[$MarkRoot.ToLowerInvariant()] = @{ RemovePriorDisabled = 1 } }
    if ($r.Log -match 'win32-toolkit prior-check: \[app-x64\] a prior install is present' -and $r.Log -notmatch 'win32-toolkit remove-prior:' -and $rk.Log -match 'win32-toolkit remove-prior: removal was disabled') { Ok 'each log line names its step: a prior-check refusal "prior-check:", a remove-prior refusal "remove-prior:"' } else { Bad "step names: $($r.Log) || $($rk.Log)" }
    Reset-World
    $p = New-Prior -NoMain -NoUninstaller
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and @($r.Started).Count -eq 0 -and $r.Log -match 'program file or its uninstaller is missing' -and (Mark 'Native' 'App' 'LastSeen') -match 'Unproven 69103') { Ok 'key present, empty declared folder: Unproven, the install goes on (leftover registration, D14)' } else { Bad "empty folder: $(Show $r)" }
    Reset-World
    $p = New-Prior -NoUninstaller
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 0 -and $r.Log -match 'missing') { Ok 'uninstaller missing in the declared folder (main exe there): Unproven' } else { Bad "no uninstaller: $(Show $r)" }
    Reset-World
    $p = New-Prior -NoMain
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 0 -and $r.Log -match 'missing') { Ok 'main exe missing: Unproven, the install goes on' } else { Bad "no main: $(Show $r)" }
    Reset-World
    $p = New-Prior -Base $PF86
    $r = Invoke-Case (Cfg @((Entry -Dir '%ProgramFiles(x86)%\App')))
    if ($r.Res -eq 'ok' -and (StartArg $r) -ceq "/S _?=$($p.Dir)") { Ok '%ProgramFiles(x86)% resolves to the x86 Program Files folder' } else { Bad "x86 dir: $(Show $r)" }
    Reset-World
    $p = New-Prior -View 'Wow6432'
    $r = Invoke-Case (Cfg @((Entry -View 'Wow6432')))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1 -and (Mark 'Wow6432' 'App' 'Removed')) { Ok 'View Wow6432: the WOW6432Node key is read and removed; marker under PriorInstalls\Wow6432' } else { Bad "wow: $(Show $r)" }
    # junction
    Reset-World
    $real = Join-Path $Other 'RealApp'
    [void][IO.Directory]::CreateDirectory($real)
    $null = cmd /c mklink /J "$(Join-Path $PF 'App')" "$real" 2>&1
    if ([IO.File]::GetAttributes((Join-Path $PF 'App')) -band [IO.FileAttributes]::ReparsePoint) {
        [IO.File]::WriteAllText((Join-Path $real 'uninstall.exe'), 'x'); [IO.File]::WriteAllText((Join-Path $real 'app.exe'), 'x')
        $script:reg[("$NativeArp\App").ToLowerInvariant()] = @{ DisplayName = 'App (64-bit)'; DisplayVersion = '8.9.8'; Publisher = 'Vendor Team'; UninstallString = '"' + (Join-Path $PF 'App\uninstall.exe') + '"' }
        $r = Invoke-Case (Cfg @((Entry)))
        if ((Refused $r 69105) -and $r.Log -match 'link \(reparse point\)') { Ok 'the install folder is a junction: 69105, nothing removed' } else { Bad "junction: $(Show $r)" }
    } else { Bad 'could not create the junction for the test' }
    foreach ($c in @(
            @{ L = 'Domain Users Modify on the folder'; Folder = $true; Acl = { New-FakeAcl 'S-1-5-32-544' (@($script:trusted) + @(Rule 'S-1-5-21-1-2-3-513' 'Modify')) } }
            @{ L = 'Users Modify on the folder'; Folder = $true; Acl = { New-FakeAcl 'S-1-5-32-544' (@($script:trusted) + @(Rule 'S-1-5-32-545' 'Modify')) } }
            @{ L = 'a per-user owner of the folder'; Folder = $true; Acl = { New-FakeAcl 'S-1-5-21-1-2-3-1001' $script:trusted } }
            @{ L = 'a per-user WriteData ACE on the uninstaller'; Folder = $false; Acl = { New-FakeAcl 'S-1-5-18' (@($script:trusted) + @(Rule 'S-1-5-21-1-2-3-1001' 'WriteData')) } }
        )) {
        Reset-World
        $p = New-Prior
        $target = if ($c.Folder) { $p.Dir } else { $p.Exe }
        $script:acl[$target] = & $c.Acl
        $r = Invoke-Case (Cfg @((Entry)))
        if ((Refused $r 69105) -and $r.Log -match 'not safe') { Ok "$($c.L): 69105 (only SYSTEM, Administrators, TrustedInstaller may change it)" } else { Bad "$($c.L): $(Show $r)" }
    }
    foreach ($o in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')) {
        Reset-World
        $p = New-Prior
        $script:acl[$p.Dir] = New-FakeAcl $o $script:trusted
        $script:acl[$p.Exe] = New-FakeAcl $o @((Rule 'S-1-5-18' 'FullControl'), (Rule 'S-1-5-32-544' 'FullControl'), (Rule 'S-1-5-32-545' 'ReadAndExecute'))
        $r = Invoke-Case (Cfg @((Entry)))
        if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok "owner $o + an InheritOnly CREATOR OWNER ACE: allowed, removed" } else { Bad "owner ${o}: $(Show $r)" }
    }
    Reset-World
    $p = New-Prior
    $script:sig[$p.Exe] = @{ Status = 'Valid'; Subject = 'CN=Other' }
    $r = Invoke-Case (Cfg @((Entry -Signer 'CN=Vendor')))
    if ((Refused $r 69105) -and $r.Log -match 'not signed by the recorded signer') { Ok 'signer mismatch: 69105' } else { Bad "signer: $(Show $r)" }
    $script:sig[$p.Exe] = @{ Status = 'Valid'; Subject = 'CN=Vendor' }
    $r = Invoke-Case (Cfg @((Entry -Signer 'CN=Vendor')))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok 'signer match: removed' } else { Bad "signer ok: $(Show $r)" }

    # ---- own identity, VersionMax rules (S3, SV15, L28) ----
    Reset-World
    $p = New-Prior -Key $PC
    $r = Invoke-Case (Cfg @((Entry -Key $PC)))
    if ((Refused $r 69105) -and $r.Log -match "own uninstall key") { Ok "the package's own key: 69105" } else { Bad "own key: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry -VersionMax '9.0')) -Type 'exe' -FileName 'setup.exe')
    if (Refused $r 69105) { Ok 'EXE package, VersionMax = App.Version: 69105 (own family must be older)' } else { Bad "exe max: $(Show $r)" }
    $exeOwn = Cfg @((Entry -VersionMax '8.9.8.1')) -Type 'exe' -FileName 'setup.exe'
    $exeOwn.OwnIdentity.ProductCode = ''; $exeOwn.OwnIdentity.ArpKeys = @()
    $r = Invoke-Case $exeOwn
    if ((Refused $r 69105) -and $r.Log -match 'OwnIdentity') { Ok 'EXE package without any own key: 69105' } else { Bad "exe no own: $(Show $r)" }
    $adtSession.UseDefaultMsi = $false
    $r = Invoke-Case (Cfg @((Entry -VersionMax '8.9.8.1')) -Type 'exe' -FileName 'setup.exe')
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok 'EXE package with an older prior: removed (the payload is Files\setup.exe)' } else { Bad "exe older: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry -VersionMax '10.0')))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok 'cross family: VersionMax above the package version accepted' } else { Bad "cross: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry)) -NoOwn)
    if ((Refused $r 69105) -and $r.Log -match 'OwnIdentity') { Ok 'an Enforce entry without OwnIdentity in an MSI package: 69105' } else { Bad "no own: $(Show $r)" }

    # ---- field validation (the host rules again) ----
    foreach ($c in @(
            @{ L = 'empty publisher'; E = @{ Publisher = '' } }
            @{ L = 'a control character in the publisher'; E = @{ Publisher = "Vendor`tTeam" } }
            @{ L = 'no process names'; E = @{ Procs = @() } }
            @{ L = "a process name with '.exe'"; E = @{ Procs = @('app.exe') } }
            @{ L = "a '..' folder"; E = @{ Dir = '%ProgramFiles%\..\App' } }
            @{ L = 'a trailing-dot folder'; E = @{ Dir = '%ProgramFiles%\App.' } }
            @{ L = 'main exe = uninstaller'; E = @{ Main = 'uninstall.exe' } }
            @{ L = "a lower-case mode 'enforce'"; E = @{ Mode = 'enforce' } }
            @{ L = 'a wildcard key'; E = @{ Key = 'App*' } }
            @{ L = 'an Id with upper case'; E = @{ Id = 'App-X64' } }
            @{ L = 'an unknown uninstaller type'; E = @{ Type = 'msi' } }
            @{ L = 'an unreadable VersionMax'; E = @{ VersionMax = 'latest' } }
        )) {
        Reset-World
        $p = New-Prior
        $ee = $c.E
        $r = Invoke-Case (Cfg @((Entry @ee)))
        if ((Refused $r 69105) -and $r.Log -match 'failed validation|no valid Kind') { Ok "$($c.L): 69105, nothing removed" } else { Bad "$($c.L): $(Show $r)" }
    }
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry -Id 'one'), (Entry -Id 'two')))
    if ((Refused $r 69105) -and $r.Log -match 'two entries name the uninstall key') { Ok 'two entries for one (View, Key): 69105' } else { Bad "duplicate: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry -Id 'one' -Mode Report), (Entry -Id 'two' -Mode Report)))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and $r.Log -match 'two Report entries name') { Ok 'the same in a Report-only set: logged, the install goes on' } else { Bad "duplicate report: $(Show $r)" }

    # ---- kill switch, anti-ping-pong (D22) ----
    Reset-World
    $p = New-Prior
    $script:reg[$MarkRoot.ToLowerInvariant()] = @{ RemovePriorDisabled = 1 }
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 69111) -and (Microsoft.PowerShell.Management\Test-Path -LiteralPath $p.Exe)) { Ok 'RemovePriorDisabled = 1 (native view): 69111, nothing removed' } else { Bad "kill: $(Show $r)" }
    $r = Invoke-Case (Cfg @((Entry -Mode Block)))
    if (Refused $r 69101) { Ok 'under the kill switch a Block entry still refuses 69101' } else { Bad "kill block: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:reg[$WowMarkRoot.ToLowerInvariant()] = @{ RemovePriorDisabled = '1' }
    $r = Invoke-Case (Cfg @((Entry)))
    if (Refused $r 69111) { Ok 'RemovePriorDisabled only under WOW6432Node (a 32-bit remediation): 69111' } else { Bad "kill wow: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry))) -Between { $script:reg[$MarkRoot.ToLowerInvariant()] = @{ RemovePriorDisabled = 1 } }
    if ((Refused $r 69111) -and $r.Log -match 'disabled on this device after prior-check') { Ok 'kill switch set after prior-check (by the org hook): remove-prior reads it again -> 69111, nothing removed' } else { Bad "kill later: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:reg[("$MarkRoot\PriorInstalls\Native\App").ToLowerInvariant()] = @{ Removed = '2026-01-01'; Version = '8.9.8' }
    $r = Invoke-Case (Cfg @((Entry)))
    # Live row GUP (2026-10-27): the vendor's own updater (Notepad++ GUP) installed it again, not another deployment.
    if ((Refused $r 69110) -and $r.Log -match 'removed on 2026-01-01 and is back \(another deployment or the app''s own updater installed it again\)') { Ok 'a Removed marker and the prior is back: 69110, naming another deployment or the app''s own updater' } else { Bad "pingpong: $(Show $r)" }
    $script:reg[("$MarkRoot\PriorInstalls\Native\App").ToLowerInvariant()] = @{ LastSeen = '2026-01-01 Unproven 69103 8.0' }
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok 'a LastSeen-only marker never trips 69110' } else { Bad "lastseen: $(Show $r)" }

    # ---- restart, MSI busy, payload, running app ----
    Reset-World
    $p = New-Prior
    $script:rebootWu = $true
    $r = Invoke-Case (Cfg @((Entry)))
    if (Refused $r 69107) { Ok 'a pending restart: 69107, nothing removed' } else { Bad "reboot: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:reg[$SessionMgr.ToLowerInvariant()]['PendingFileRenameOperations'] = @("\??\$($p.Dir)\old.dll", '')
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 69107) -and $r.Log -match 'already scheduled for deletion') { Ok 'a delete-on-restart ALREADY pending under the prior folder: 69107, nothing removed' } else { Bad "pfro before: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:effects[$p.Exe]['Pfro'] = "\??\$($p.Dir)\locked.dll"
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -like 'threw*' -and $r.Code -eq 69107 -and $r.Log -match 'deleted at the next restart') { Ok 'the removal scheduled a delete-on-restart under the folder: 69107' } else { Bad "pfro after: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:msiBusy = $true
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 1618) -and $r.Log -match 'Windows Installer is busy') { Ok 'Windows Installer busy: 1618' } else { Bad "busy: $(Show $r)" }
    # Live row MSIBUSY (2026-10-27): PSADT 4.2.0-rc2's Test-ADTMutexAvailability throws (strict mode) while an msiexec holds
    # the mutex; the deployment ended 60001 (failed, no retry). A check that throws counts as busy.
    Reset-World
    $p = New-Prior
    $script:msiThrows = $true
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 1618) -and $r.Log -match 'Windows Installer is busy' -and $r.Res -notmatch 'FilePath') { Ok 'a Windows Installer check that throws counts as busy: 1618 (retry), nothing removed' } else { Bad "busy throw: $(Show $r)" }
    Reset-World
    $p = New-Prior
    [IO.File]::Delete((Join-Path $FilesDir 'pkg.msi'))
    $r = Invoke-Case (Cfg @((Entry)))
    if (Refused $r 69112) { Ok 'the package installer is missing: 69112' } else { Bad "payload: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:running = @('app')
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 1618) -and $r.Log -match "'app' is still running") { Ok 'the prior app still runs after the dialog: 1618, nothing removed' } else { Bad "running: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $p2 = New-Prior -Key 'Two' -Folder 'Two' -Main 'two.exe'
    $script:running = @('two')
    $r = Invoke-Case (Cfg @((Entry -Id 'a'), (Entry -Id 'b' -Key 'Two' -Dir '%ProgramFiles%\Two' -Main 'two.exe' -Procs @('two'))))
    if ((Refused $r 1618) -and (Microsoft.PowerShell.Management\Test-Path -LiteralPath $p.Exe)) { Ok "only entry B's app runs: 1618 and entry A is not removed either" } else { Bad "running B: $(Show $r)" }

    # ---- changes during the dialog ----
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry))) -Between { [void]$script:reg.Remove($p.KeyPath.ToLowerInvariant()) }
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and @($r.Started).Count -eq 0 -and $r.Log -match 'no longer present') { Ok 'the prior vanished during the dialog: logged, the install goes on' } else { Bad "vanished: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry))) -Between { $script:reg[$p.KeyPath.ToLowerInvariant()]['DisplayVersion'] = '8.9.7' }
    if ((Refused $r 1618) -and $r.Log -match 'changed while the close-apps dialog was open') { Ok 'the prior changed version during the dialog: 1618' } else { Bad "changed: $(Show $r)" }

    # ---- uninstaller outcomes ----
    foreach ($c in @(
            @{ L = 'timeout (OperationCanceledException)'; T = (New-Object System.OperationCanceledException 'took too long'); W = 'ran longer than 30 minutes' }
            @{ L = 'timeout (TimeoutException)'; T = (New-Object System.TimeoutException 'timed out'); W = 'ran longer than 30 minutes' }
            @{ L = 'a failing uninstaller'; T = (New-Object System.Runtime.InteropServices.ExternalException 'Execution failed with exit code [5].', 5); W = 'failed' }
        )) {
        Reset-World
        $p = New-Prior
        $script:effects[$p.Exe] = @{ Throw = $c.T }
        $r = Invoke-Case (Cfg @((Entry)))
        if ($r.Res -like 'threw*' -and $r.Code -eq 69108 -and $r.Log -match [regex]::Escape($c.W) -and -not (Mark 'Native' 'App' 'Removed')) { Ok "$($c.L): 69108, no Removed marker" } else { Bad "$($c.L): $(Show $r)" }
    }
    Reset-World
    $p = New-Prior
    $script:effects[$p.Exe]['Exit'] = 3010
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -like 'threw*' -and $r.Code -eq 69107) { Ok 'the uninstaller returned 3010: 69107 (the install runs after the restart)' } else { Bad "3010: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:effects[$p.Exe] = @{ Key1 = $p.KeyPath }
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -like 'threw*' -and $r.Code -eq 69109) { Ok 'the main program file survived the uninstaller: 69109' } else { Bad "survived: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $p2 = New-Prior -Key 'Two' -Folder 'Two' -Main 'two.exe'
    $script:effects[$p.Exe] = @{ Key1 = $p.KeyPath; File1 = $p.Main; Key2 = $p2.KeyPath; File2 = $p2.Main; File3 = $p2.Exe }
    $r = Invoke-Case (Cfg @((Entry -Id 'a'), (Entry -Id 'b' -Key 'Two' -Dir '%ProgramFiles%\Two' -Main 'two.exe' -Procs @('two'))))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and @($r.Started).Count -eq 1 -and $r.Log -match '\[b\]: already removed by an earlier uninstaller' -and (Mark 'Native' 'Two' 'Removed')) { Ok "one vendor uninstaller removed both priors: the second is marked Removed ('already removed'), the install goes on" } else { Bad "already removed: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $p2 = New-Prior -Key 'Two' -Folder 'Two' -Main 'two.exe'
    $script:effects[$p.Exe] = @{ Key1 = $p.KeyPath; File1 = $p.Main; Key2 = $p2.KeyPath; File3 = $p2.Exe }
    $r = Invoke-Case (Cfg @((Entry -Id 'a'), (Entry -Id 'b' -Key 'Two' -Dir '%ProgramFiles%\Two' -Main 'two.exe' -Procs @('two'))))
    if ($r.Res -like 'threw*' -and $r.Code -eq 69109 -and $r.Log -match 'program file is still there') { Ok 'key and uninstaller of prior 2 gone, its program file left: 69109' } else { Bad "half gone: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $script:markFail = @("$MarkRoot\PriorInstalls*")
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 69105) -and $r.Log -match 'its marker .* cannot be written') { Ok 'the marker key of a planned removal cannot be written: 69105, nothing removed' } else { Bad "marker fail: $(Show $r)" }

    # ---- MSI payload: own codes (D15), DefaultMsiFile shapes (4.1 string, 4.2 FileInfo, relative) ----
    Reset-World
    $p = New-Prior
    [W32tFakeInstaller]::States[$PayloadPC] = 5
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 69106) -and $r.Log -match [regex]::Escape($PayloadPC)) { Ok "the payload MSI's own ProductCode (Property table, not in OwnIdentity) is registered: 69106" } else { Bad "payload pc: $(Show $r)" }
    Reset-World
    $p = New-Prior
    [W32tFakeInstaller]::States[$PC] = 5
    $r = Invoke-Case (Cfg @((Entry)))
    if (Refused $r 69106) { Ok "OwnIdentity's ProductCode registered next to the prior: 69106" } else { Bad "own pc: $(Show $r)" }
    foreach ($c in @(@{ V = '9.0'; Want = 69106 }, @{ V = '9.5'; Want = 69106 }, @{ V = '8.0'; Want = 0 })) {
        Reset-World
        $p = New-Prior
        [W32tFakeInstaller]::Related[$PayloadUC] = @('{EEEEEEEE-1111-2222-3333-444444444444}')
        [W32tFakeInstaller]::Versions['{EEEEEEEE-1111-2222-3333-444444444444}'] = $c.V
        $r = Invoke-Case (Cfg @((Entry)))
        if ($c.Want -eq 69106) { if (Refused $r 69106) { Ok "a related product $($c.V) (same or newer than the package) is registered: 69106" } else { Bad "related $($c.V): $(Show $r)" } }
        elseif ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1) { Ok 'an OLDER related product: the removal goes on (the MSI upgrades it)' } else { Bad "related older: $(Show $r)" }
    }
    Reset-World
    $p = New-Prior
    [W32tFakeInstaller]::DbFail = $true
    $r = Invoke-Case (Cfg @((Entry)))
    if ((Refused $r 69112) -and $r.Log -match 'MSI cannot be opened') { Ok 'OpenDatabase fails: 69112' } else { Bad "db fail: $(Show $r)" }
    Reset-World
    $p = New-Prior
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and @($r.Started).Count -eq 1 -and [W32tFakeInstaller]::Opened.Count -eq 1 -and [W32tFakeInstaller]::Opened[0] -ceq (Join-Path $FilesDir 'pkg.msi')) { Ok 'an MSI package with a readable database: its codes read through InvokeMember, the removal proceeds' } else { Bad "msi ok: $(Show $r) opened=$([W32tFakeInstaller]::Opened -join ',')" }
    Reset-World
    $p = New-Prior
    $adtSession.DefaultMsiFile = (Microsoft.PowerShell.Utility\New-Object IO.DirectoryInfo $FilesDir).GetFiles('*.msi')[0]
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and $null -eq $r.Code -and [W32tFakeInstaller]::Opened[0] -ceq (Join-Path $FilesDir 'pkg.msi')) { Ok 'PSADT 4.2: DefaultMsiFile is a FileInfo from GetFiles() (its string is the bare name under 5.1): FullName is used, no 69112' } else { Bad "fileinfo: $(Show $r) opened=$([W32tFakeInstaller]::Opened -join ',')" }
    Reset-World
    $p = New-Prior
    $adtSession.DefaultMsiFile = 'pkg.msi'
    $r = Invoke-Case (Cfg @((Entry)))
    if ($r.Res -eq 'ok' -and [W32tFakeInstaller]::Opened[0] -ceq (Join-Path $FilesDir 'pkg.msi')) { Ok 'a relative DefaultMsiFile string is rooted with DirFiles' } else { Bad "relative: $(Show $r)" }
}
}
finally {
    if ($script:fail -gt 0) { Write-Output "HARNESS-FAILED $($script:fail)" } else { Write-Output 'HARNESS-OK' }
}
'@

$root = Join-Path $env:USERPROFILE ('AppData\Local\Temp\w32trp-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$author = 'W32T-RemovePriorTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    $null = New-Item -ItemType Directory -Path $root -Force
    $checkFile = Join-Path $root 'check.ps1'; $removeFile = Join-Path $root 'remove.ps1'; $harnessFile = Join-Path $root 'harness.ps1'
    [IO.File]::WriteAllText($checkFile, $check, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($removeFile, $remove, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($harnessFile, $harness, [Text.UTF8Encoding]::new($true))
    $out = @(& $ps51 -NoProfile -ExecutionPolicy Bypass -File $harnessFile -CheckPath $checkFile -RemovePath $removeFile -Root (Join-Path $root 'w') -Author $author 2>&1 | ForEach-Object { "$_" })
    foreach ($l in $out) {
        if ($l -like 'PASS: *') { Ok $l.Substring(6) }
        elseif ($l -like 'FAIL: *') { Bad $l.Substring(6) }
        elseif ($l -notlike 'HARNESS-*' -and $l.Trim()) { Write-Host "  | $l" -ForegroundColor DarkGray }
    }
    if (-not ($out -contains 'HARNESS-OK' -or @($out | Where-Object { $_ -like 'HARNESS-FAILED*' }).Count)) { Bad 'the 5.1 harness did not finish' }
    if (@($out | Where-Object { $_ -like 'PASS: *' }).Count -lt 90) { Bad "the 5.1 harness ran only $(@($out | Where-Object { $_ -like 'PASS: *' }).Count) checks" }

    # == [3] 32-bit Windows PowerShell ==================================================================
    Write-Host '[3] the 32-bit Windows PowerShell (Report never refuses; Block refuses 69105)' -ForegroundColor Cyan
    $ps32 = Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps32) {
        $out = @(& $ps32 -NoProfile -ExecutionPolicy Bypass -File $harnessFile -CheckPath $checkFile -RemovePath $removeFile -Root (Join-Path $root 'w32') -Author $author -Mode x86 2>&1 | ForEach-Object { "$_" })
        foreach ($l in $out) { if ($l -like 'PASS: *') { Ok $l.Substring(6) } elseif ($l -like 'FAIL: *') { Bad $l.Substring(6) } elseif ($l -notlike 'HARNESS-*' -and $l.Trim()) { Write-Host "  | $l" -ForegroundColor DarkGray } }
        if (@($out | Where-Object { $_ -like 'PASS: *' }).Count -lt 3) { Bad '32-bit harness incomplete' }
    } else { Write-Host '  (no SysWOW64 Windows PowerShell on this host)' -ForegroundColor DarkYellow }
    if (-not (Test-Path -LiteralPath "HKLM:\SOFTWARE\$author")) { Ok "the real HKLM:\SOFTWARE\$author was never created" } else { Bad "HKLM:\SOFTWARE\$author exists on the host" }
}
finally {
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All RemovePriorBlock tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail RemovePriorBlock test(s) FAILED." -ForegroundColor Red; exit 1 }
