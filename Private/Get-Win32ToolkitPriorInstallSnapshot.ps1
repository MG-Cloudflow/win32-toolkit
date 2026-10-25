function Get-Win32ToolkitPriorInstallSnapshot {
    <#
    .SYNOPSIS
        Reads what a same-version rebuild must keep of a project's prior-install state, before the folder is re-created.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.13 step 1, L4). Create-PSADTProject deletes the project folder of a version that
        is rebuilt (-Force), so Invoke-Win32Toolkit and New-Win32ToolkitManualApp call this first, next to the publication
        record backup, and hand the result to Copy-Win32ToolkitPriorInstallState after the configure step:

          HasPriorInstalls  the AppConfig had a PriorInstalls property (an empty Entries list included)
          PriorInstallsJson that property as JSON text (a copy: nothing refers to the old folder)
          Decisions         the bytes of Documentation\PriorInstallDecisions.json ($null when absent)
          Dropped           the bytes of Documentation\PriorInstallDropped.json, the rules it has lost ($null when absent)
          CaptureFiles      @{ Path = <path relative to the project>; Bytes } of Documentation\SiblingCapture*.json and
                            Documentation\SiblingCapture\*.json (host files; re-verified by their readers on every use)
          Version, Architecture, ProjectPath

        TestResults.json is never kept (the script and the installer change with the rebuild, so no proof survives it).
        Files above 1 MB and more than 256 capture files are skipped. Returns $null when the folder holds none of these.
        A project a test guest changed (Documentation\GuestTamper.json, GUEST-TAMPER) keeps NO rule, decision or capture
        record: re-creating it is the remedy, and they are exactly what the guest may have written. The snapshot is then
        only a marker { ProjectPath; Tampered = $true; Lost } where Lost holds WHICH rules there were - { Id; Kind; Key;
        View; From } of its PriorInstalls entries (AppConfig up to 4 MB) and of its own PriorInstallDropped.json - and
        nothing else (no bytes, no decisions, no capture files). Copy-Win32ToolkitPriorInstallState records them in the
        new project, and Export lists each one as ID-PRIOR-DROPPED until it is declared again or acknowledged
        (fail-closed, like a carry source a guest changed). One warning; $null when there was no rule to record (the new
        project then starts like any new version: carry-forward from the version before).
        Fail-open (C-7): any problem gives one warning and $null (a W32T.* error is re-thrown).
    .PARAMETER ProjectPath
        The project folder that is about to be re-created.
    .OUTPUTS
        [pscustomobject] the snapshot, or $null.
    .EXAMPLE
        $priorSnapshot = Get-Win32ToolkitPriorInstallSnapshot -ProjectPath $projectFullPath
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    try {
        if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { return $null }
        $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
        if (Test-Path -LiteralPath (Join-Path $ProjectPath 'Documentation\GuestTamper.json') -PathType Leaf) {
            # Only WHICH rules there were survives (their identity, for ID-PRIOR-DROPPED): never a rule's data, a decision
            # or a capture record. Best effort: a rule the guest removed from the AppConfig cannot be known.
            $name = Split-Path -Path $ProjectPath.TrimEnd('\') -Leaf
            $lost = [System.Collections.Generic.List[object]]::new()
            try {
                $oldCfg = Join-Path $ProjectPath 'SupportFiles\AppConfig.json'
                if ((Test-Path -LiteralPath $oldCfg -PathType Leaf) -and (Get-Item -LiteralPath $oldCfg).Length -le 4MB) {
                    $old = Get-Content -LiteralPath $oldCfg -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($e in @(& $prop (& $prop $old 'PriorInstalls') 'Entries')) {
                        if ($e -isnot [System.Management.Automation.PSCustomObject]) { continue }
                        $lost.Add([pscustomobject]@{ Id = [string](& $prop $e 'Id'); Kind = [string](& $prop $e 'Kind'); Key = [string](& $prop $e 'Key'); View = [string](& $prop $e 'View'); From = $name })
                    }
                }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Get-Win32ToolkitPriorInstallSnapshot: the rules of the changed project could not be read: $($_.Exception.Message)"
            }
            try { foreach ($d in @(Get-Win32ToolkitPriorInstallDropped -ProjectPath $ProjectPath)) { $lost.Add($d) } }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Get-Win32ToolkitPriorInstallSnapshot: $($_.Exception.Message)"
            }
            $what = if ($lost.Count -gt 0) { ' Export lists each of its rules as ID-PRIOR-DROPPED until you declare it again (Set-Win32ToolkitPriorInstall, or capture the sibling technologies again) or acknowledge the drop.' } else { ' Declare its rules again with Set-Win32ToolkitPriorInstall.' }
            Write-Warning ("A test guest changed the files of '$(ConvertTo-Win32ToolkitSafeText -Text $ProjectPath -MaxLength 260)' (Documentation\GuestTamper.json): " +
                'its prior-install rules, decisions and capture records are NOT kept by the rebuild.' + $what)
            if ($lost.Count -eq 0) { return $null }
            return [pscustomobject]@{ ProjectPath = $ProjectPath; Tampered = $true; Lost = @($lost.ToArray()) }
        }
        $cfgFile = Join-Path $ProjectPath 'SupportFiles\AppConfig.json'
        $cfg = $null
        if (Test-Path -LiteralPath $cfgFile -PathType Leaf) { $cfg = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        $has = $null -ne $cfg -and $null -ne $cfg.PSObject.Properties['PriorInstalls']
        $json = if ($has) { ConvertTo-Json -InputObject $cfg.PriorInstalls -Depth 8 } else { '' }

        $docDir = Join-Path $ProjectPath 'Documentation'
        $decisions = $null
        $decFile = Join-Path $docDir 'PriorInstallDecisions.json'
        if ((Test-Path -LiteralPath $decFile -PathType Leaf) -and (Get-Item -LiteralPath $decFile).Length -le 1MB) { $decisions = [System.IO.File]::ReadAllBytes($decFile) }
        $dropped = $null
        $dropFile = Join-Path $docDir 'PriorInstallDropped.json'
        if ((Test-Path -LiteralPath $dropFile -PathType Leaf) -and (Get-Item -LiteralPath $dropFile).Length -le 1MB) { $dropped = [System.IO.File]::ReadAllBytes($dropFile) }

        $captureFiles = [System.Collections.Generic.List[object]]::new()
        $found = @()
        if (Test-Path -LiteralPath $docDir -PathType Container) {
            $found += @(Get-ChildItem -LiteralPath $docDir -Filter 'SiblingCapture*.json' -File -ErrorAction SilentlyContinue)
            $capDir = Join-Path $docDir 'SiblingCapture'
            if (Test-Path -LiteralPath $capDir -PathType Container) { $found += @(Get-ChildItem -LiteralPath $capDir -Filter '*.json' -File -ErrorAction SilentlyContinue) }
        }
        foreach ($f in @($found | Sort-Object FullName | Select-Object -First 256)) {
            if ($f.Length -gt 1MB) { Write-Verbose "Get-Win32ToolkitPriorInstallSnapshot: $($f.Name) is larger than 1 MB - not kept."; continue }
            $rel = $f.FullName.Substring($ProjectPath.TrimEnd('\').Length).TrimStart('\')
            $captureFiles.Add([pscustomobject]@{ Path = $rel; Bytes = [System.IO.File]::ReadAllBytes($f.FullName) })
        }
        if (-not $has -and $null -eq $decisions -and $null -eq $dropped -and $captureFiles.Count -eq 0) { return $null }

        $app = & $prop $cfg 'App'
        $arch = [string](& $prop (& $prop $cfg 'Source') 'Architecture')
        if (-not $arch -and (Split-Path -Path $ProjectPath -Leaf) -match '_(x64|x86|arm64)_') { $arch = $Matches[1] }
        if (-not $arch) { $arch = [string](& $prop $app 'Arch') }
        return [pscustomobject]@{
            ProjectPath       = $ProjectPath
            Version           = [string](& $prop $app 'Version')
            Architecture      = $arch.ToLowerInvariant()
            HasPriorInstalls  = $has
            PriorInstallsJson = $json
            Decisions         = $decisions
            Dropped           = $dropped
            CaptureFiles      = @($captureFiles.ToArray())
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning ("The prior-install rules of '$ProjectPath' could not be kept for the rebuild (" + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200) + '): declare them again with Set-Win32ToolkitPriorInstall.')
        return $null
    }
}
