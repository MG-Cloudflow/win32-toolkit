# Export-Win32ToolkitDocumentation

## SYNOPSIS
Writes a clean, customer-facing one-page Documentation.md summarising a packaged project.

## SYNTAX

```
Export-Win32ToolkitDocumentation [-ProjectPath] <String> [[-OutputPath] <String>] [-IncludeIntuneIds]
 [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Gathers the read-only facts about a packaged PSADT/Intune project - its AppConfig, the Intune
detection method, declared dependencies, the newest install-change capture, and any recorded
automated test results - and renders them as a tight, skimmable Markdown one-pager aimed at a
human reviewer (an IT admin signing off on the package, or an end-customer deliverable).

Every gather is guarded: a missing piece degrades gracefully to a sensible line, never throws.

By default NO tenant or app ids are read or printed, and the capture JSON's raw sandbox host paths
are summarised to COUNTS and program names only, never surfaced.
Pass -IncludeIntuneIds to add an
Intune section with the published app id and portal link (only do this for internal documentation).

The rendered Markdown is deliberately ASCII-only (typographic characters use HTML entities), so the
file cannot mojibake regardless of how a viewer decodes it.

## EXAMPLES

### EXAMPLE 1
```
Export-Win32ToolkitDocumentation -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

Writes Documentation.md next to the project with no Intune ids.

### EXAMPLE 2
```
Export-Win32ToolkitDocumentation -ProjectPath $proj -OutputPath 'C:\temp\Git.md' -IncludeIntuneIds
```

Writes an internal copy that also lists the published Intune app id and a portal link.

## PARAMETERS

### -ProjectPath
Full path to the PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -OutputPath
Where to write the Markdown.
Defaults to \<ProjectPath\>\Documentation.md.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeIntuneIds
Also read \<ProjectPath\>\Intune\Publications.json and add an "Intune" section with the app id and a
portal deep-link.
Omitted by default so the one-pager carries no tenant-specific identifiers.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction
{{ Fill ProgressAction Description }}

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### [string] - the full path of the Markdown file that was written.
## NOTES

## RELATED LINKS
