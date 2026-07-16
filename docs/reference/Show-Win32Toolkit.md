# Show-Win32Toolkit

## SYNOPSIS
Launches the interactive, menu-driven text UI (TUI) for win32-toolkit.

## SYNTAX

```
Show-Win32Toolkit [[-BasePath] <String>] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
A fool-proof, first-line-friendly front-end over the whole pipeline: package an app from winget
or a manual installer, test and update-test existing projects (Windows Sandbox or the Hyper-V
VM), manage dependencies, package and publish to Intune, manage org templates, the test VM, and
settings - all from guided menus.
The first screen is a prerequisite health check that tells you
exactly what is missing and how to fix it.

Built on PwshSpectreConsole - offered for one-time install on first launch if absent.
Requires
PowerShell 7.2+ and an interactive console.

## EXAMPLES

### EXAMPLE 1
```
Show-Win32Toolkit
```

## PARAMETERS

### -BasePath
Optional base folder override for this session.
If omitted, the registry-saved value is used, or
first-run setup prompts for it.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
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

## NOTES

## RELATED LINKS
