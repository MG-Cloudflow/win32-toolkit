function Get-OrgTemplate {
    param(
        [string]$TemplateName = '',
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) { $BasePath = Get-Win32ToolkitBasePath }
    $templateFolder = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates
    if (-not (Test-Path $templateFolder)) {
        New-Item -ItemType Directory -Path $templateFolder -Force | Out-Null
    }

    # If a specific template name was requested, route directly (skip picker)
    if (-not [string]::IsNullOrWhiteSpace($TemplateName)) {
        $specificPath = Join-Path $templateFolder "$TemplateName.json"
        if (Test-Path $specificPath) {
            $t = Get-Content -Path $specificPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $t = Update-OrgTemplateIfNeeded -Template $t -FilePath $specificPath
            Write-Host "✓ Loaded org template: $($t.TemplateName)" -ForegroundColor Green
            return $t
        } else {
            Write-Host "Template '$TemplateName' not found. Creating it now..." -ForegroundColor Cyan
            return New-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath
        }
    }

    $templates = @(Get-ChildItem -Path $templateFolder -Filter '*.json' -ErrorAction SilentlyContinue)

    if ($templates.Count -eq 0) {
        Write-Host ''
        Write-Host 'No org template found. Creating one now...' -ForegroundColor Cyan
        return New-OrgTemplate -BasePath $BasePath
    }

    if ($templates.Count -eq 1) {
        $t = Get-Content -Path $templates[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $t = Update-OrgTemplateIfNeeded -Template $t -FilePath $templates[0].FullName
        Write-Host "✓ Loaded org template: $($t.TemplateName)" -ForegroundColor Green
        return $t
    }

    # Multiple templates — show picker
    Write-Host ''
    Write-Host '  Multiple org templates found:' -ForegroundColor Cyan
    Write-Host ("  {0,-4} {1}" -f '#', 'Template') -ForegroundColor Gray
    Write-Host ("  " + "-" * 40) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $templates.Count; $i++) {
        try { $label = (Get-Content -Path $templates[$i].FullName -Raw -Encoding UTF8 | ConvertFrom-Json).TemplateName }
        catch { $label = $templates[$i].BaseName }
        if (-not $label) { $label = $templates[$i].BaseName }
        $color = if ($i % 2 -eq 0) { 'Cyan' } else { 'White' }
        Write-Host ("  {0,-4} {1}" -f ($i + 1), $label) -ForegroundColor $color
    }
    $newIdx = $templates.Count + 1
    $editIdx = $templates.Count + 2
    Write-Host ("  {0,-4} {1}" -f $newIdx,  '[Create new template]') -ForegroundColor DarkGray
    Write-Host ("  {0,-4} {1}" -f $editIdx, '[Edit existing template]') -ForegroundColor DarkGray
    Write-Host ''

    do {
        $rawInput = Read-Host "Select template (1-$editIdx)"
        $parsed   = 0
        $valid    = [int]::TryParse($rawInput.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $editIdx
        if (-not $valid) { Write-Host "Please enter a number between 1 and $editIdx." -ForegroundColor Red }
    } while (-not $valid)

    if ($parsed -eq $newIdx)  { return New-OrgTemplate -BasePath $BasePath }
    if ($parsed -eq $editIdx) {
        # Pick which one to edit then open wizard pre-filled
        do {
            $rawInput2 = Read-Host "Select template to edit (1-$($templates.Count))"
            $parsed2   = 0
            $v2 = [int]::TryParse($rawInput2.Trim(), [ref]$parsed2) -and $parsed2 -ge 1 -and $parsed2 -le $templates.Count
            if (-not $v2) { Write-Host "Please enter a number between 1 and $($templates.Count)." -ForegroundColor Red }
        } while (-not $v2)
        $existing = Get-Content -Path $templates[$parsed2 - 1].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        return New-OrgTemplate -ExistingTemplate $existing -BasePath $BasePath
    }

    $t = Get-Content -Path $templates[$parsed - 1].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $t = Update-OrgTemplateIfNeeded -Template $t -FilePath $templates[$parsed - 1].FullName
    Write-Host "✓ Loaded org template: $($t.TemplateName)" -ForegroundColor Green
    return $t
}