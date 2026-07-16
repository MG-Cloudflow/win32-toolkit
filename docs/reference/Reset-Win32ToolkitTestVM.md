# Reset-Win32ToolkitTestVM

## SYNOPSIS
Reverts the Hyper-V test VM to its warm 'clean-base' checkpoint (the between-run reset).

## SYNTAX

```
Reset-Win32ToolkitTestVM [[-Name] <String>] [[-CheckpointName] <String>] [-ProgressAction <ActionPreference>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
HOST-ONLY.
Restoring a STANDARD (memory-state) checkpoint returns the VM directly to the captured
running, logged-in desktop - no OOBE, logon, or boot - so a test run can go straight to
PowerShell Direct.
Uses the configured VM + checkpoint names by default.

## EXAMPLES

### Example 1
```powershell
PS C:\> {{ Add example code here }}
```

{{ Add example description here }}

## PARAMETERS

### -Name
VM name (default: the stored HyperVVMName, else 'win32tk-golden').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: (Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden')
Accept pipeline input: False
Accept wildcard characters: False
```

### -CheckpointName
Checkpoint to restore (default: the stored HyperVCheckpoint, else 'clean-base').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: (Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base')
Accept pipeline input: False
Accept wildcard characters: False
```

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
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
