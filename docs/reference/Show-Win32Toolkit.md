# Show-Win32Toolkit

## SYNOPSIS
Starts the win32-toolkit menu, where you do every task step by step.

## SYNTAX

```
Show-Win32Toolkit [[-BasePath] <String>] [<CommonParameters>]
```

## DESCRIPTION
Show-Win32Toolkit starts the win32-toolkit menu in this PowerShell window.
In the menu you
package apps from winget or from your own installer, then test, build and publish them.
You
also manage org templates, the Intune connection, the Hyper-V test VM and the settings.

Use the menu for your first app and for daily work.
In scripts, use the other commands, for
example Invoke-Win32Toolkit.

If the PwshSpectreConsole module is missing, the command first asks to install it for your
user account.
Without that module the menu does not start, but the other commands still work.
If no base folder is saved yet, the menu asks for one (the default is C:\Win32Apps) and saves
it in the registry.

The main screen shows the System check table of what the toolkit needs.
On a new PC, up to
three red rows are normal: PSAppDeployToolkit, Microsoft.Graph.Authentication and
IntuneWinAppUtil.exe.
The toolkit gets each one when you first need it.
It asks before it
installs Microsoft.Graph.Authentication.

If a task stops on an error, you see a red "Something went wrong" panel and stay in the menu.

## EXAMPLES

### EXAMPLE 1
```
Show-Win32Toolkit
```

This starts the menu with your saved base folder.
If no base folder is saved yet, it asks for
one first.

### EXAMPLE 2
```
Show-Win32Toolkit -BasePath 'D:\Win32Apps'
```

This starts the menu with the base folder D:\Win32Apps.
Your saved base folder does not change.

## PARAMETERS

### -BasePath
The base folder to use for this menu session only.
It is not saved, and the menu skips the
first-run question.
Default: your saved base folder.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### None. The menu shows its results on screen.
## NOTES
Needs: PowerShell 7.4 or later in an interactive console window.
If the input or output is
redirected, the menu does not start: "Show-Win32Toolkit needs an interactive console window".

## RELATED LINKS

[https://win32toolkit.com/reference/Show-Win32Toolkit/](https://win32toolkit.com/reference/Show-Win32Toolkit/)

[https://win32toolkit.com/menu/](https://win32toolkit.com/menu/)

[https://win32toolkit.com/install/](https://win32toolkit.com/install/)

