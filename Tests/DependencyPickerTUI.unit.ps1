<#
    TUI audit G9 (tui-gaps-spec 8, G9): the dependency picker leaves out the project being edited.

    Before: 'Add a dependency from an already-packaged project' listed every project, the one being edited (or
    built) included, so the operator could pick the app itself; the refusal (W32T.InvalidDependencyReference)
    only came later. The labels the picker builds also carried raw winget / project / Intune names into
    Spectre markup (Dv12).

    Now Show-Win32ToolkitDependencyPicker -ExcludeProject '<Template>\<Name>' leaves that project out
    (case-insensitive); when it was the only one: one yellow line and no project prompt. Every label is
    escaped. Get-SpectreEscapedText is shadowed faithfully: like PwshSpectreConsole's, it refuses an empty string.

    Driven with shadows; nothing renders, nothing is searched, nobody signs in.
    Run:  pwsh -File Tests\DependencyPickerTUI.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Show-Win32ToolkitDependencyPicker.ps1')

# --- shadows -------------------------------------------------------------------------------------------
$script:hostLines = [System.Collections.Generic.List[string]]::new()
function Write-SpectreHost { param($Message) $script:hostLines.Add([string]$Message) }
# Faithful to PwshSpectreConsole 2.6.x: -Text is mandatory and an empty string is refused.
function Get-SpectreEscapedText { param([Parameter(Mandatory)][string]$Text) $Text.Replace('[', '[[').Replace(']', ']]') }
function Read-SpectreText { param($Message, $DefaultAnswer) 'vc' }
$script:prompts = [System.Collections.Generic.List[object]]::new()
$script:keys = [System.Collections.Queue]::new()
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, $PageSize)
    $script:prompts.Add([pscustomobject]@{ Message = [string]$Message; Choices = @($Choices) })
    $want = if ($script:keys.Count) { $script:keys.Dequeue() } else { 'done' }
    $m = @($Choices | Where-Object { $_.Key -eq $want })
    if ($m.Count) { return $m[0] }
    @($Choices)[0]
}
$script:projects = @()
function Get-PSADTProjects { param($BasePath) $script:projects }
$script:hits = @()
function Search-WingetApps { param($SearchTerm) $script:hits }
function Connect-Win32ToolkitGraph { }
$script:intuneApps = @()
function Find-Win32ToolkitIntuneApp { param([switch]$All) $script:intuneApps }

function P($Template, $Name) { [pscustomobject]@{ Template = $Template; Name = $Name; Path = "C:\Base\Projects\$Template\$Name" } }
function Invoke-Picker([string[]]$Keys, [hashtable]$Params) {
    $script:keys = [System.Collections.Queue]::new(); foreach ($k in $Keys) { $script:keys.Enqueue($k) }
    $script:prompts.Clear(); $script:hostLines.Clear()
    $threw = $null; $out = @()
    try { $out = @(Show-Win32ToolkitDependencyPicker -BasePath 'C:\Base' @Params) } catch { $threw = $_ }
    [pscustomobject]@{ Out = $out; Threw = $threw }
}
$projectPrompt = { @($script:prompts | Where-Object Message -eq 'Which packaged project?') }

# == [1] the project being edited is not a choice =====================================================
Write-Host '[1] -ExcludeProject leaves the project being edited out of the packaged-project list' -ForegroundColor Cyan
$script:projects = @((P 'Contoso' 'Tool_x64_1.0'), (P 'Contoso' 'Other[x]_x64_2.0'), (P 'Fabrikam' 'Tool_x64_1.0'))
$r = Invoke-Picker @('project', 'Contoso\Other[x]_x64_2.0', 'done') @{ ExcludeProject = 'contoso\TOOL_x64_1.0' }
$pp = & $projectPrompt
$keys = @(if ($pp.Count) { $pp[0].Choices | ForEach-Object Key })
if (-not $r.Threw -and ($keys -join '|') -ceq 'Contoso\Other[x]_x64_2.0|Fabrikam\Tool_x64_1.0') { Ok "Contoso\Tool_x64_1.0 is not offered (compared case-insensitively); the same name in another template is" } else { Bad "threw=$($r.Threw) keys=$($keys -join '|')" }
$labels = @(if ($pp.Count) { $pp[0].Choices | ForEach-Object Label })
if ($labels[0] -ceq 'Other[[x]]_x64_2.0  [grey](Contoso)[/]') { Ok "the project label is escaped: '$($labels[0])'" } else { Bad "labels: $($labels -join ' | ')" }
if (($r.Out -join '|') -ceq 'project:Contoso\Other[x]_x64_2.0') { Ok 'the pick returns the raw reference (project:Contoso\Other[x]_x64_2.0)' } else { Bad "out: $($r.Out -join '|')" }

$r = Invoke-Picker @('project', 'done') @{}
$pp = & $projectPrompt
if ($pp.Count -eq 1 -and $pp[0].Choices.Count -eq 3) { Ok 'without -ExcludeProject every project is offered (unchanged)' } else { Bad "choices: $(if ($pp.Count) { $pp[0].Choices.Count })" }

# == [2] only the excluded project ====================================================================
Write-Host '[2] the excluded project was the only one -> one yellow line, no project prompt' -ForegroundColor Cyan
$script:projects = @((P 'Contoso' 'Tool_x64_1.0'))
$r = Invoke-Picker @('project', 'done') @{ ExcludeProject = 'Contoso\Tool_x64_1.0' }
$wantY = "[yellow]No other packaged projects found $([char]0x2014) package the dependency first, or pick it from winget.[/]"
if (-not $r.Threw -and (& $projectPrompt).Count -eq 0 -and $script:hostLines -ccontains $wantY -and $r.Out.Count -eq 0) { Ok "'No other packaged projects found ...' and no 'Which packaged project?' prompt" } else { Bad "threw=$($r.Threw) prompts=$((& $projectPrompt).Count) lines=$($script:hostLines -join ' | ')" }

# == [3] winget and Intune labels are escaped (Dv12) ==================================================
Write-Host '[3] winget and Intune labels are escaped; an empty publisher does not stop the picker' -ForegroundColor Cyan
$script:hits = @([pscustomobject]@{ Name = 'VC++ [x64]'; Id = 'Microsoft.VCRedist[2015]' })
$r = Invoke-Picker @('winget', 'Microsoft.VCRedist[2015]', 'done') @{}
$wp = @($script:prompts | Where-Object Message -eq 'Which package?')
if (-not $r.Threw -and $wp.Count -eq 1 -and $wp[0].Choices[0].Label -ceq 'VC++ [[x64]]  [grey](Microsoft.VCRedist[[2015]])[/]' -and ($r.Out -join '|') -ceq 'winget:Microsoft.VCRedist[2015]') { Ok "winget label '$($wp[0].Choices[0].Label)'; the id is stored verbatim" } else { Bad "threw=$($r.Threw) label=$(if ($wp.Count) { $wp[0].Choices[0].Label })" }
$script:intuneApps = @([pscustomobject]@{ Id = '11111111-2222-3333-4444-555555555555'; DisplayName = 'App [a]'; Publisher = '' }, [pscustomobject]@{ Id = '66666666-2222-3333-4444-555555555555'; DisplayName = 'B'; Publisher = 'Fab[r]ikam' })
$r = Invoke-Picker @('intune', '11111111-2222-3333-4444-555555555555', 'done') @{}
$ip = @($script:prompts | Where-Object Message -eq 'Which published app?')
$il = @(if ($ip.Count) { $ip[0].Choices | ForEach-Object Label })
if (-not $r.Threw -and $il[0] -ceq 'App [[a]]  [grey][/]' -and $il[1] -ceq 'B  [grey]Fab[[r]]ikam[/]' -and ($r.Out -join '|') -ceq 'intune:11111111-2222-3333-4444-555555555555') { Ok "Intune labels escaped ('$($il[1])'); an empty publisher -> '$($il[0])', no error" } else { Bad "threw=$($r.Threw) labels=$($il -join ' | ')" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All DependencyPickerTUI tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail DependencyPickerTUI test(s) FAILED." -ForegroundColor Red
exit 1
