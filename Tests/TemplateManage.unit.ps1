# TemplateManage.unit.ps1 — F3: duplicate + delete org templates (with sidecar folder + in-use check).

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'Private\Sanitize-ProjectName.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitPaths.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTemplateUsage.ps1')
. (Join-Path $repo 'Private\Copy-Win32ToolkitTemplate.ps1')
. (Join-Path $repo 'Private\Remove-Win32ToolkitTemplate.ps1')

$fail = 0
function Ok  { param($m) Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad { param($m) Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# Isolated BasePath fixture with one template ('Contoso') + a sidecar folder (hooks + assets).
function New-Base {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ('tplmgr_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $tpl = Join-Path $base 'Templates'
    New-Item -ItemType Directory -Path $tpl -Force | Out-Null
    ([pscustomobject]@{ TemplateName='Contoso'; CompanyName='Contoso IT'; CustomAssets=$true } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $tpl 'Contoso.json') -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $tpl 'Contoso\Hooks') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tpl 'Contoso\Hooks\PreInstall.ps1') -Value "Write-Host 'hi'" -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $tpl 'Contoso\Assets') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tpl 'Contoso\Assets\AppIcon.png') -Value 'x' -Encoding ASCII
    return $base
}

Write-Host "`n[1] Duplicate clones JSON (renamed) + the sidecar folder" -ForegroundColor Cyan
$b = New-Base
$new = Copy-Win32ToolkitTemplate -SourceName 'Contoso' -NewName 'Fabrikam' -BasePath $b
if (Test-Path (Join-Path $b 'Templates\Fabrikam.json')) { Ok 'new JSON created' } else { Bad 'new JSON missing' }
$obj = Get-Content (Join-Path $b 'Templates\Fabrikam.json') -Raw | ConvertFrom-Json
if ($obj.TemplateName -eq 'Fabrikam') { Ok 'TemplateName updated in the clone' } else { Bad "TemplateName=[$($obj.TemplateName)]" }
if (Test-Path (Join-Path $b 'Templates\Fabrikam\Hooks\PreInstall.ps1')) { Ok 'sidecar Hooks folder cloned' } else { Bad 'sidecar hooks not cloned' }
if (Test-Path (Join-Path $b 'Templates\Fabrikam\Assets\AppIcon.png')) { Ok 'sidecar Assets folder cloned' } else { Bad 'sidecar assets not cloned' }
# original untouched
if (Test-Path (Join-Path $b 'Templates\Contoso.json')) { Ok 'source template preserved' } else { Bad 'source template lost' }

Write-Host "`n[2] Duplicate rejects blank name + collision" -ForegroundColor Cyan
try { Copy-Win32ToolkitTemplate -SourceName 'Contoso' -NewName '   ' -BasePath $b; Bad 'blank name accepted' } catch { Ok 'blank name rejected' }
try { Copy-Win32ToolkitTemplate -SourceName 'Contoso' -NewName 'Fabrikam' -BasePath $b; Bad 'collision accepted' } catch { Ok 'name collision rejected' }
try { Copy-Win32ToolkitTemplate -SourceName 'Contoso' -NewName 'Bad/Name' -BasePath $b; Bad 'illegal char accepted' } catch { Ok 'illegal filename char rejected' }

Write-Host "`n[3] Usage check — unused template reports no usage" -ForegroundColor Cyan
$b3 = New-Base
$u = @(Get-Win32ToolkitTemplateUsage -Name 'Contoso' -BasePath $b3)
if ($u.Count -eq 0) { Ok 'no projects -> not in use' } else { Bad "reported in use: $($u -join ',')" }

Write-Host "`n[4] Usage check — a project under the segment marks it in use" -ForegroundColor Cyan
$seg = Sanitize-ProjectName -Name 'Contoso'
New-Item -ItemType Directory -Path (Join-Path $b3 "Projects\$seg\SomeApp_x64_1.0") -Force | Out-Null
$u4 = @(Get-Win32ToolkitTemplateUsage -Name 'Contoso' -BasePath $b3)
if ($u4.Count -eq 1 -and $u4[0] -like "*Projects\$seg") { Ok 'project under segment -> in use' } else { Bad "usage=[$($u4 -join ',')]" }

Write-Host "`n[5] Delete without -Force is blocked while in use; projects untouched" -ForegroundColor Cyan
$res = Remove-Win32ToolkitTemplate -Name 'Contoso' -BasePath $b3
if (-not $res.Removed -and $res.InUse.Count -eq 1) { Ok 'in-use delete blocked without -Force' } else { Bad "unexpected: $($res | ConvertTo-Json -Compress)" }
if (Test-Path (Join-Path $b3 'Templates\Contoso.json')) { Ok 'template JSON still present' } else { Bad 'template deleted despite block' }
if (Test-Path (Join-Path $b3 "Projects\$seg\SomeApp_x64_1.0")) { Ok 'project folder untouched' } else { Bad 'project folder deleted!' }

Write-Host "`n[6] Delete with -Force removes JSON + sidecar folder, never the project tier" -ForegroundColor Cyan
$res6 = Remove-Win32ToolkitTemplate -Name 'Contoso' -BasePath $b3 -Force
if ($res6.Removed) { Ok 'force delete removed the template' } else { Bad "not removed: $($res6.Message)" }
if (-not (Test-Path (Join-Path $b3 'Templates\Contoso.json'))) { Ok 'JSON deleted' } else { Bad 'JSON survived' }
if (-not (Test-Path (Join-Path $b3 'Templates\Contoso'))) { Ok 'sidecar folder deleted' } else { Bad 'sidecar folder survived' }
if (Test-Path (Join-Path $b3 "Projects\$seg\SomeApp_x64_1.0")) { Ok 'output-tier project STILL untouched after force delete' } else { Bad 'force delete removed a project!' }

Write-Host "`n[7] Delete an unused template succeeds without -Force" -ForegroundColor Cyan
$b7 = New-Base
$res7 = Remove-Win32ToolkitTemplate -Name 'Contoso' -BasePath $b7
if ($res7.Removed -and -not (Test-Path (Join-Path $b7 'Templates\Contoso.json'))) { Ok 'unused template deleted without -Force' } else { Bad "unexpected: $($res7 | ConvertTo-Json -Compress)" }

Write-Host ""
if ($fail -eq 0) { Write-Host "TemplateManage unit test PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILURE(S)" -ForegroundColor Red; exit 1 }
