function Add-Win32ToolkitTemplateAssets {
    <#
    .SYNOPSIS
        B1/B7 — apply an org template's branding assets (logo + Classic banner) to a project.

    .DESCRIPTION
        The template may ship Templates\<name>\Assets\{AppIcon.png, Banner.Classic.png}. This copies
        them into the project so PSADT dialogs and the Intune tile carry the org's branding instead of
        the PSADT default. Runs from Apply-OrgTemplate.

        The PSADT config defaults already point Logo/LogoDark at '..\Assets\AppIcon.png' and Banner at
        '..\Assets\Banner.Classic.png', so simply dropping the files in Assets\ brands every dialog with
        NO config change (light + dark both use AppIcon.png; Classic uses the banner).

        AppIcon.png (B7 — also the Intune tile via Publish's Get-Win32ToolkitLargeIconBytes) is applied
        as a precedence-respecting BASE: only when nothing better has been stamped. Every app-specific
        icon still wins, because each runs AFTER this and overwrites:
          * a winget icon (Get-AppIconFromWinget, after Configure) overwrites it, re-stamping 'winget'
          * a manual -IconPath (New-Win32ToolkitManualApp, after Apply-OrgTemplate) likewise re-stamps
            'manual' — note it lands after, not before, this runs; the Copy-Item -Force is what wins
          * a captured icon (finalize) overrides 'template' (it only defers to winget/manual)
          * nothing else applies → the org logo persists as both the dialog icon and the Intune tile
        So the org logo is the floor. winget and manual never compete: they are mutually exclusive
        entry points, and both are treated as authoritative once stamped.

        Banner.Classic.png is pure branding (no icon precedence) and is copied whenever present.

    .PARAMETER ProjectPath
        The configured PSADT project.

    .PARAMETER Template
        The org-template object (schema 3.0+). CustomAssets gates the (registry-touching) asset-folder
        resolution; read defensively.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][PSCustomObject]$Template
    )

    $customAssets = $false
    if ($Template.PSObject.Properties['CustomAssets']) { $customAssets = [bool]$Template.CustomAssets }
    if (-not $customAssets) { return }

    $tn = if ($Template.PSObject.Properties['TemplateName']) { [string]$Template.TemplateName } else { '' }
    if (-not $tn) { return }

    $assetFolder = $null
    try { $assetFolder = Get-Win32ToolkitTemplateAssetFolder -TemplateName $tn } catch {
        Write-Verbose "Template assets: could not resolve asset folder — skipping ($($_.Exception.Message))"
        return
    }
    $assetsSrc = Join-Path $assetFolder 'Assets'
    if (-not (Test-Path -LiteralPath $assetsSrc)) { return }

    $projAssets  = Join-Path $ProjectPath 'Assets'
    $psadtAssets = Join-Path $ProjectPath 'PSAppDeployToolkit\Assets'
    if (-not (Test-Path -LiteralPath $projAssets)) { New-Item -ItemType Directory -Path $projAssets -Force | Out-Null }

    # Copies validated PNG bytes to project Assets AND the PSADT mirror so on-device dialogs use it too.
    function Copy-BrandingPng {
        param([string]$SrcFile, [string]$DestName)
        if (-not (Test-Path -LiteralPath $SrcFile)) { return $false }
        try { $raw = [System.IO.File]::ReadAllBytes($SrcFile) } catch {
            Write-Warning "Template asset '$SrcFile' could not be read: $($_.Exception.Message)"; return $false
        }
        $png = ConvertTo-Win32ToolkitPngBytes -Bytes $raw
        if (-not $png) { Write-Warning "Template asset '$([System.IO.Path]::GetFileName($SrcFile))' is not a valid image — skipped."; return $false }
        [System.IO.File]::WriteAllBytes((Join-Path $projAssets $DestName), $png)
        if (Test-Path -LiteralPath $psadtAssets) {
            try { [System.IO.File]::WriteAllBytes((Join-Path $psadtAssets $DestName), $png) }
            catch { Write-Verbose "Could not mirror '$DestName' into PSAppDeployToolkit\Assets: $($_.Exception.Message)" }
        }
        return $true
    }

    # ── Classic banner — pure branding, always when present ──
    [void](Copy-BrandingPng -SrcFile (Join-Path $assetsSrc 'Banner.Classic.png') -DestName 'Banner.Classic.png')

    # ── Org logo (B7) — apply as the base ONLY when nothing better is stamped ──
    $logoSrc = Join-Path $assetsSrc 'AppIcon.png'
    if (Test-Path -LiteralPath $logoSrc) {
        $existing = Get-Win32ToolkitIconSource -ProjectPath $ProjectPath
        if ([string]::IsNullOrEmpty($existing) -or $existing -eq 'template') {
            if (Copy-BrandingPng -SrcFile $logoSrc -DestName 'AppIcon.png') {
                Set-Win32ToolkitIconSource -ProjectPath $ProjectPath -Source 'template'
                Write-Verbose '  org template logo applied to Assets\AppIcon.png (fallback tile + dialog icon)'
            }
        } else {
            Write-Verbose "  org template logo skipped — an authoritative '$existing' icon is already applied."
        }
    }
}
