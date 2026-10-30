function Test-Win32ToolkitDeployExtension {
    <#
    .SYNOPSIS
        Checks a project's PSADT extension folders against win32-toolkit's rules; returns findings, never throws.
    .DESCRIPTION
        PSADT 4.1.x and 4.2.x import every folder next to Invoke-AppDeployToolkit.ps1 whose name matches
        'PSAppDeployToolkit\..+$' - without a '^' anchor, so 'Old.PSAppDeployToolkit.X' or a 'PSAppDeployToolkit.Contoso -
        Copy' is imported too, and a broken one fails every deployment with 60001. Findings (Code, Severity, Message, Path):

          EXTENSION-STRAY     a folder PSADT would import that is never intended: one the anchored '^PSAppDeployToolkit\.'
                              rule does not match, or one whose name starts with the reserved 'PSAppDeployToolkit.Win32Toolkit'
                              without being exactly win32-toolkit's folder. Error for a GeneratorVersion 3 deploy script,
                              Warning for GeneratorVersion 0 / 2 (legacy projects are packaged unchanged with a warning).
          EXTENSION-MISSING   the deploy script calls the toolkit extension (GeneratorVersion 3) but the folder is missing.
          EXTENSION-UNKNOWN   the folder is not a known version: changed, extra or missing files, or a link.
          EXTENSION-MISMATCH  a known version, but not the one the deploy script was generated for (its loader marker), or
                              without the uninstall / prior-install revision the script's markers name.
          PLAN-MISMATCH       a GeneratorVersion 3 script whose blocks are not the ones Get-Win32ToolkitDeployBlockPlan names
                              for the project (AppConfig Installer.Type, manual = its manual-install block, the hook files in
                              SupportFiles\OrgHooks): a block missing or extra, a call block whose code lines are not this
                              toolkit's call (the prior-install pair and hooks: presence only), or an Uninstall section in
                              AppConfig while the plan has no uninstall call.
          EXTENSION-STAGING   (-StagingPath) the Staging copy of the folder differs from the project's.

        The extension checks apply to a GeneratorVersion 3 deploy script (the shape's ExtensionVersion); the stray rule
        applies to every project. Design: knowledge-base/designs/lean-deploy-script-extension.md, section 4.7.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Shape
        Get-Win32ToolkitDeployScriptShape of the project's deploy script; read from the project when not given.
    .PARAMETER StagingPath
        The project's Staging copy: its extension folder must equal the project's.
    .OUTPUTS
        [pscustomobject] Code, Severity ('Error' | 'Warning'), Message, Path - none for a clean project.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [object]$Shape,

        [string]$StagingPath
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Code, [string]$Severity, [string]$Message, [string]$Path)
        $findings.Add([pscustomobject]@{ Code = $Code; Severity = $Severity; Message = $Message; Path = $Path })
    }
    # A folder's files -> @{ <name> = <SHA-256> }, or a reason it cannot be one ('' = fine).
    $readFolder = {
        param([string]$Folder)
        $item = Get-Item -LiteralPath $Folder -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return @{ Why = 'it is a link (reparse point)'; Files = @{} } }
        $files = @{}
        $why = ''
        foreach ($child in @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction Stop)) {
            if ($child.PSIsContainer) { $why = "it holds a folder '$($child.Name)'"; continue }
            $files[$child.Name] = (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash
        }
        @{ Why = $why; Files = $files }
    }
    $sameFiles = {
        param($A, $B)
        if (@($A.Keys).Count -ne @($B.Keys).Count) { return $false }
        foreach ($k in @($A.Keys)) { if (-not $B.Contains($k) -or $B[$k] -ne $A[$k]) { return $false } }
        $true
    }

    try {
        $known = @(Get-Win32ToolkitDeployExtension -All)
        $name = $known[-1].Name
        if ($null -eq $Shape) {
            $script = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
            if (Test-Path -LiteralPath $script -PathType Leaf) { $Shape = Get-Win32ToolkitDeployScriptShape -Path $script }
        }
        $generator = if ($Shape -and $Shape.PSObject.Properties['GeneratorVersion']) { $Shape.GeneratorVersion } else { $null }
        $wanted = $null
        if ($Shape -and $Shape.PSObject.Properties['ExtensionVersion'] -and $Shape.ExtensionVersion) { $wanted = [version]$Shape.ExtensionVersion }
        $usesExtension = $generator -eq 3 -or $null -ne $wanted

        # ---- stray folders (every generation) ----
        $strayLevel = if ($usesExtension) { 'Error' } else { 'Warning' }
        foreach ($dir in @(Get-ChildItem -LiteralPath $ProjectPath -Directory -Force -ErrorAction Stop)) {
            if ($dir.Name -notmatch 'PSAppDeployToolkit\..+$') { continue }
            if ($dir.Name -notmatch '^PSAppDeployToolkit\.') {
                & $add 'EXTENSION-STRAY' $strayLevel "The folder '$($dir.Name)' is imported by PSAppDeployToolkit as an extension module on every device (PSADT imports each folder whose name contains 'PSAppDeployToolkit.' and more text), but it is not an extension module win32-toolkit placed. Remove it from the project." $dir.FullName
            }
            elseif (-not [string]::Equals($dir.Name, $name, [System.StringComparison]::OrdinalIgnoreCase) -and
                $dir.Name.TrimEnd('.', ' ').StartsWith($name, [System.StringComparison]::OrdinalIgnoreCase)) {
                & $add 'EXTENSION-STRAY' $strayLevel "The folder '$($dir.Name)' starts with '$name', the name win32-toolkit reserves for its own PSADT extension module, but it is not that folder. PSAppDeployToolkit imports it too on every device. Remove it from the project." $dir.FullName
            }
        }

        # ---- the toolkit extension of a GeneratorVersion 3 deploy script ----
        $folder = Join-Path $ProjectPath $name
        if ($usesExtension) {
            $shown = if ($wanted) { " $wanted" } else { '' }
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                & $add 'EXTENSION-MISSING' 'Error' "The deploy script calls win32-toolkit's PSADT extension module ($name$shown), but the project has no '$name' folder, so every deployment would fail. Re-create the project." $folder
            }
            else {
                $read = & $readFolder $folder
                $row = $null
                if (-not $read.Why) { $row = $known | Where-Object { & $sameFiles $_.Files $read.Files } | Select-Object -First 1 }
                if (-not $row) {
                    $why = if ($read.Why) { $read.Why } else { 'its files differ from every version this win32-toolkit knows: changed, extra or missing' }
                    & $add 'EXTENSION-UNKNOWN' 'Error' "The project's '$name' folder is not a version of win32-toolkit's PSADT extension module ($why). Re-create the project; never edit that folder." $folder
                }
                else {
                    $off = [System.Collections.Generic.List[string]]::new()
                    if ($wanted -and $row.Version -ne $wanted) { $off.Add("it is version $($row.Version), the deploy script was generated for $wanted") }
                    if ($Shape.PSObject.Properties['UninstallRevision'] -and [int]$Shape.UninstallRevision -gt 0 -and [int]$Shape.UninstallRevision -ne $row.UninstallRevision) {
                        $off.Add("the deploy script names uninstall revision $($Shape.UninstallRevision), the folder provides $($row.UninstallRevision)")
                    }
                    if ($row.RemovePriorRevision -gt 0 -and $Shape.PSObject.Properties['RemovePriorRevision'] -and [int]$Shape.RemovePriorRevision -ne $row.RemovePriorRevision) {
                        $off.Add("the deploy script names prior-install revision $($Shape.RemovePriorRevision), the folder provides $($row.RemovePriorRevision)")
                    }
                    if ($off.Count -gt 0) {
                        & $add 'EXTENSION-MISMATCH' 'Error' "The project's '$name' folder does not belong to its deploy script ($($off -join '; ')). Re-create the project." $folder
                    }
                }
            }
        }

        # ---- the blocks of a GeneratorVersion 3 script against the block plan ----
        $script = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        if ($usesExtension -and $Shape.PSObject.Properties['Shape'] -and [string]$Shape.Shape -in @('Psadt41', 'Psadt42ZeroConfig') -and (Test-Path -LiteralPath $script -PathType Leaf)) {
            $text = [System.IO.File]::ReadAllText($script, [System.Text.Encoding]::UTF8) -replace "`r`n", "`n"
            $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
            $type = if ($cfg.PSObject.Properties['Installer'] -and $cfg.Installer -and $cfg.Installer.PSObject.Properties['Type']) { [string]$cfg.Installer.Type } else { '' }
            $hookPhases = @(foreach ($ph in 'Pre-Install', 'Post-Install', 'Pre-Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Post-Repair') {
                    if (Test-Path -LiteralPath (Join-Path $ProjectPath ('SupportFiles\OrgHooks\' + ($ph -replace '-', '') + '.ps1')) -PathType Leaf) { $ph }
                })
            $plan = $null
            try { $plan = @(Get-Win32ToolkitDeployBlockPlan -Shape $Shape.Shape -InstallerType $type -ManualInstall:($text.Contains('## win32-toolkit:Install:manual-install (begin)')) -HookPhases $hookPhases) }
            catch {
                if ($_.FullyQualifiedErrorId -ne 'W32T.UnsupportedInstallerType') { throw }
                & $add 'PLAN-MISMATCH' 'Error' "The project's installer type has no deploy-script blocks: $($_.Exception.Message)" $script
            }
            if ($plan) {
                $present = @{}
                foreach ($m in [regex]::Matches($text, '(?ms)^[ \t]*## win32-toolkit:(?<p>[\w-]+):(?<s>[\w-]+) \(begin\)[^\n]*\n(?<body>.*?)^[ \t]*## win32-toolkit:\k<p>:\k<s> \(end\)')) {
                    $present["$($m.Groups['p'].Value):$($m.Groups['s'].Value)"] = $m.Groups['body'].Value
                }
                $wanted = @($plan | ForEach-Object { "$($_.Phase):$($_.Slot)" })
                $extra = @($present.Keys | Where-Object { $wanted -notcontains $_ } | Sort-Object)
                $missing = @($wanted | Where-Object { -not $present.ContainsKey($_) })
                # A call block must hold this toolkit's call (its code lines; comments may differ between versions). The
                # prior-install pair and the hooks are inline texts: present is enough.
                $codeLines = { param([string]$Body) @(($Body -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) -join "`n" }
                $wrong = @(foreach ($row in $plan) {
                        $key = "$($row.Phase):$($row.Slot)"
                        if (-not $present.ContainsKey($key) -or $row.Block -in @('RemovePriorCheck', 'RemovePrior', 'Hook')) { continue }
                        $want = if ($row.Technology) { Get-Win32ToolkitDeployScriptBlock -Name $row.Block -Technology $row.Technology } else { Get-Win32ToolkitDeployScriptBlock -Name $row.Block }
                        if ((& $codeLines $present[$key]) -cne (& $codeLines $want)) { $key }
                    })
                $uninstallData = $cfg.PSObject.Properties['Uninstall'] -and $cfg.Uninstall -and
                    (@(@($cfg.Uninstall.ProductCodes) + @($cfg.Uninstall.Uninstallers) + @($cfg.Uninstall.CleanupPaths) | Where-Object { $_ }).Count -gt 0)
                $why = [System.Collections.Generic.List[string]]::new()
                if ($missing.Count) { $why.Add("it lacks the block(s) $($missing -join ', ')") }
                if ($extra.Count) { $why.Add("it has block(s) this project does not need: $($extra -join ', ')") }
                if ($wrong.Count) { $why.Add("these blocks do not hold this toolkit's call: $($wrong -join ', ')") }
                if ($uninstallData -and $wanted -notcontains 'Uninstall:uninstall') { $why.Add("SupportFiles\AppConfig.json has an Uninstall section, but a(n) '$type' project has no uninstall call") }
                if ($why.Count) {
                    & $add 'PLAN-MISMATCH' 'Error' "The deploy script does not match the blocks this project needs (installer type '$type'$(if ($text.Contains('## win32-toolkit:Install:manual-install (begin)')) { ', manual' })): $($why -join '; '). Re-create the project." $script
                }
            }
        }

        # ---- the Staging copy ----
        if ($StagingPath -and (Test-Path -LiteralPath $folder -PathType Container)) {
            $staged = Join-Path $StagingPath $name
            if (-not (Test-Path -LiteralPath $staged -PathType Container)) {
                & $add 'EXTENSION-STAGING' 'Error' "The Staging copy has no '$name' folder although the project has one. Export again." $staged
            }
            else {
                $a = & $readFolder $folder
                $b = & $readFolder $staged
                if ($b.Why -or -not (& $sameFiles $a.Files $b.Files)) {
                    & $add 'EXTENSION-STAGING' 'Error' "The Staging copy of '$name' differs from the project's (changed, extra or missing files). Export again." $staged
                }
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $add 'EXTENSION-UNKNOWN' 'Error' "win32-toolkit could not check the project's PSADT extension folders: $($_.Exception.Message)" $ProjectPath
    }
    $findings.ToArray()
}
