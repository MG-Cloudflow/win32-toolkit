<#
    The not-configured marker (TUI audit G4, S10-F2; tui-gaps-spec 7.1): Documentation\NotConfigured.json.

      [1] Write-Win32ToolkitNotConfiguredMarker: the file and its shape (SchemaVersion, Stage, ErrorId, Reason,
          TimestampUtc), UTF-8 without BOM, a sanitised Reason (ESC -> '?', at most 1024 characters), a non-W32T
          id is dropped, a write that fails gives exactly one warning and never throws.
      [2] Get-Win32ToolkitNotConfiguredMarker: no file -> $null; a garbled or empty file is still a marker (Stage
          Unknown, ErrorId '', TimestampUtc $null); TimestampUtc round-trips as a UTC [datetime] (also under a
          de-DE culture); 'not a date' -> $null; hostile values are sanitised.
      [3] Get-PSADTProjects (real): NotConfigured true for a marked project, false otherwise.

    Temp folders only.

    Run:  pwsh -File Tests\NotConfiguredMarker.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'ConvertTo-Win32ToolkitSafeText', 'Write-Win32ToolkitNotConfiguredMarker', 'Get-Win32ToolkitNotConfiguredMarker', 'Get-Win32ToolkitPaths', 'Get-PSADTProjects') {
    . (Join-Path $repo "Private\$f.ps1")
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32nc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proj = Join-Path $tmp 'Projects\Contoso\App_x64_1.0'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
Set-Content -LiteralPath (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') '# stub'
$markerFile = Join-Path $proj 'Documentation\NotConfigured.json'

try {
    Write-Host '[1] the writer' -ForegroundColor Cyan
    $before = [datetime]::UtcNow.AddSeconds(-1)
    $esc = [char]27
    $w = $null
    Write-Win32ToolkitNotConfiguredMarker -ProjectPath $proj -Stage Configure -ErrorId 'W32T.OrgExtensionInvalid' -Reason "Org extension module 'X' cannot be used:$esc[2J bad" -WarningVariable w -WarningAction SilentlyContinue
    $after = [datetime]::UtcNow.AddSeconds(1)
    $bytes = [System.IO.File]::ReadAllBytes($markerFile)
    $data = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if (@($w).Count -eq 0 -and (Test-Path -LiteralPath $markerFile)) { Ok 'Documentation\NotConfigured.json written (the Documentation folder created), no warning' } else { Bad "warnings: $(@($w) -join ' | ')" }
    if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) { Ok 'UTF-8 without BOM' } else { Bad 'a BOM was written' }
    $raw = [System.Text.Encoding]::UTF8.GetString($bytes) -replace '\s', ''
    if ($raw -match '^\{"SchemaVersion":"1\.0","Stage":"Configure","ErrorId":"W32T\.OrgExtensionInvalid","Reason":".*","TimestampUtc":"[^"]+"\}$') { Ok 'shape: SchemaVersion, Stage, ErrorId, Reason, TimestampUtc in that order' } else { Bad "json: $raw" }
    if ($data.Reason -ceq "Org extension module 'X' cannot be used:?[2J bad") { Ok 'Reason is sanitised (ESC -> ?)' } else { Bad "reason: $($data.Reason)" }
    $ts = [datetime]::MinValue
    $tsText = [string](Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json -AsHashtable)['TimestampUtc']
    $raw2 = [System.Text.Encoding]::UTF8.GetString($bytes)
    $isoText = [regex]::Match($raw2, '"TimestampUtc":\s*"([^"]+)"').Groups[1].Value
    if ($isoText -match 'Z$' -and [datetime]::TryParse($isoText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$ts) -and $ts -ge $before -and $ts -le $after) { Ok "TimestampUtc is an invariant ISO UTC instant ($isoText)" } else { Bad "TimestampUtc '$isoText' ($tsText)" }

    Write-Win32ToolkitNotConfiguredMarker -ProjectPath $proj -Stage Download -ErrorId 'not.an.id' -Reason ('x' * 3000)
    $data = Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json
    if ($data.Stage -eq 'Download' -and $data.ErrorId -eq '' -and ([string]$data.Reason).Length -eq 1024 -and ([string]$data.Reason).EndsWith('...')) { Ok "Stage Download; a non-W32T id is dropped; Reason is cut at 1024 characters" } else { Bad "stage=$($data.Stage) id=[$($data.ErrorId)] reason length=$(([string]$data.Reason).Length)" }
    $threw = $null
    try { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $proj -Stage Other -Reason 'x' } catch { $threw = $_ }
    if ($threw) { Ok 'a Stage other than Download / Configure is refused by the parameter' } else { Bad 'Stage Other accepted' }

    # A write that cannot happen ('Documentation' is a FILE here): one warning, no throw.
    $blocked = Join-Path $tmp 'Projects\Contoso\Blocked_x64_1.0'
    New-Item -ItemType Directory -Path $blocked -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $blocked 'Documentation') 'a file, not a folder'
    $w = $null; $threw = $null
    try { Write-Win32ToolkitNotConfiguredMarker -ProjectPath $blocked -Stage Configure -ErrorId 'W32T.PipelineAborted' -Reason 'x' -WarningVariable w -WarningAction SilentlyContinue } catch { $threw = $_ }
    if (-not $threw -and @($w).Count -eq 1 -and "$($w[0])" -like "Could not mark '$blocked' as not configured (*): do not package or publish it; package the app again to re-create it.") { Ok 'a failed write -> exactly one warning (do not package or publish it), no throw' } else { Bad "threw=$threw warnings=[$(@($w) -join ' | ')]" }

    Write-Host '[2] the reader' -ForegroundColor Cyan
    $none = Join-Path $tmp 'Projects\Contoso\Clean_x64_1.0'
    New-Item -ItemType Directory -Path $none -Force | Out-Null
    if ($null -eq (Get-Win32ToolkitNotConfiguredMarker -ProjectPath $none)) { Ok 'no marker -> $null' } else { Bad 'a marker was read from a clean project' }

    Write-Win32ToolkitNotConfiguredMarker -ProjectPath $proj -Stage Configure -ErrorId 'W32T.PipelineAborted' -Reason 'The org template could not be applied'
    $written = [datetime]::Parse([regex]::Match((Get-Content -LiteralPath $markerFile -Raw), '"TimestampUtc":\s*"([^"]+)"').Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $m = Get-Win32ToolkitNotConfiguredMarker -ProjectPath $proj
    if ($m -and $m.Path -eq $markerFile -and $m.Stage -eq 'Configure' -and $m.ErrorId -eq 'W32T.PipelineAborted' -and $m.Reason -eq 'The org template could not be applied') { Ok 'Path, Stage, ErrorId, Reason as written' } else { Bad "marker: $($m | ConvertTo-Json -Compress)" }
    if ($m.TimestampUtc -is [datetime] -and $m.TimestampUtc.Kind -eq [System.DateTimeKind]::Utc -and $m.TimestampUtc -eq $written) { Ok "TimestampUtc round-trips as a UTC [datetime] ($($m.TimestampUtc.ToString('o')))" } else { Bad "TimestampUtc: $($m.TimestampUtc) kind=$(if ($m.TimestampUtc -is [datetime]) { $m.TimestampUtc.Kind })" }

    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    try {
        [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new('de-DE')
        Write-Win32ToolkitNotConfiguredMarker -ProjectPath $proj -Stage Download -ErrorId 'W32T.DownloadFailed' -Reason 'x'
        $writtenDe = [regex]::Match((Get-Content -LiteralPath $markerFile -Raw), '"TimestampUtc":\s*"([^"]+)"').Groups[1].Value
        $mDe = Get-Win32ToolkitNotConfiguredMarker -ProjectPath $proj
    }
    finally { [System.Globalization.CultureInfo]::CurrentCulture = $culture }
    $wantDe = [datetime]::Parse($writtenDe, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    if ($writtenDe -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$' -and $mDe.TimestampUtc -is [datetime] -and $mDe.TimestampUtc.Kind -eq 'Utc' -and $mDe.TimestampUtc -eq $wantDe) { Ok "under de-DE the marker is still written ISO ($writtenDe) and read back as the same UTC instant" } else { Bad "de-DE: written '$writtenDe' read $($mDe.TimestampUtc)" }

    [System.IO.File]::WriteAllText($markerFile, '{ "SchemaVersion": "1.0", "Stage": "Configure", "ErrorId": "W32T.X", "Reason": "r", "TimestampUtc": "not a date" }', [System.Text.UTF8Encoding]::new($false))
    $m = Get-Win32ToolkitNotConfiguredMarker -ProjectPath $proj
    if ($m -and $m.Stage -eq 'Configure' -and $null -eq $m.TimestampUtc) { Ok "TimestampUtc 'not a date' -> `$null (still a marker)" } else { Bad "marker: $($m | ConvertTo-Json -Compress)" }

    foreach ($garbled in @('{ this is not json', '', '[1,2]')) {
        [System.IO.File]::WriteAllText($markerFile, $garbled, [System.Text.UTF8Encoding]::new($false))
        $m = Get-Win32ToolkitNotConfiguredMarker -ProjectPath $proj
        if ($m -and $m.Stage -eq 'Unknown' -and $m.ErrorId -eq '' -and $m.Reason -eq 'the marker file could not be read' -and $null -eq $m.TimestampUtc -and $m.Path -eq $markerFile) { Ok "a garbled marker ('$garbled') still counts: Stage Unknown, TimestampUtc `$null" } else { Bad "garbled '$garbled': $($m | ConvertTo-Json -Compress)" }
    }

    [System.IO.File]::WriteAllText($markerFile, "{ `"Stage`": `"Configure\u001b[31m`", `"ErrorId`": `"W32T.A$([char]0x202E)B`", `"Reason`": `"line1\nline2`", `"TimestampUtc`": `"2026-10-23T10:15:00.0000000Z`" }", [System.Text.UTF8Encoding]::new($false))
    $m = Get-Win32ToolkitNotConfiguredMarker -ProjectPath $proj
    if ($m.Stage -eq 'Unknown' -and $m.ErrorId -ceq 'W32T.A?B' -and $m.Reason -ceq 'line1?line2' -and $m.TimestampUtc -eq [datetime]::new(2026, 10, 23, 10, 15, 0, [System.DateTimeKind]::Utc)) { Ok 'hostile values are sanitised (control and bidi characters -> ?; an unknown Stage -> Unknown)' } else { Bad "marker: $($m | ConvertTo-Json -Compress)" }

    Write-Host '[3] Get-PSADTProjects lists the marker' -ForegroundColor Cyan
    $list = @(Get-PSADTProjects -BasePath $tmp)
    $marked = @($list | Where-Object { $_.Name -eq 'App_x64_1.0' })
    $other = Join-Path $tmp 'Projects\Contoso\Other_x64_1.0'
    New-Item -ItemType Directory -Path $other -Force | Out-Null; Set-Content -LiteralPath (Join-Path $other 'Invoke-AppDeployToolkit.ps1') '# stub'
    $list = @(Get-PSADTProjects -BasePath $tmp)
    $o = @($list | Where-Object { $_.Name -eq 'Other_x64_1.0' })
    $a = @($list | Where-Object { $_.Name -eq 'App_x64_1.0' })
    if ($marked.Count -eq 1 -and $a[0].NotConfigured -eq $true -and $o.Count -eq 1 -and $o[0].NotConfigured -eq $false) { Ok 'NotConfigured: true for the marked project, false for the other one' } else { Bad "list: $($list | Select-Object Name, NotConfigured | ConvertTo-Json -Compress)" }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All NotConfiguredMarker tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail NotConfiguredMarker test(s) FAILED." -ForegroundColor Red
exit 1
