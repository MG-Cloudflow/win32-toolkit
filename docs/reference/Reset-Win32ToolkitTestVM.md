# Reset-Win32ToolkitTestVM

## SYNOPSIS
Puts the Hyper-V test VM back to its clean checkpoint.

## SYNTAX

```
Reset-Win32ToolkitTestVM [[-Name] <String>] [[-CheckpointName] <String>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Reset-Win32ToolkitTestVM puts the Hyper-V test VM back to its clean-base checkpoint: a
saved state of the VM at a clean, signed-in desktop.
Every change since that checkpoint is
lost.
By default the command turns the VM off, restores the checkpoint and starts the VM
again.

Tests already do this by themselves.
Use the command after you worked in the VM yourself,
or before you change its processors or memory.
In the menu: Settings \> Hyper-V test VM \>
Reset the VM to its clean checkpoint.

The command prints nothing when it works.
A checkpoint taken with automatic checkpoints on
gets a slower restore and one warning.
With the HyperVRevertMode setting Legacy, every
reset uses the slower restore.
After the slower restore, a VM that was off can stay in the
Saved state: start it with Start-VM.

It stops with an error when the VM or the checkpoint does not exist.
While another
PowerShell window uses the VM, the command waits.
After 60 minutes by default, it stops
with the error W32T.HyperVLeaseTimeout and changes nothing.

## EXAMPLES

### EXAMPLE 1
```
Reset-Win32ToolkitTestVM
```

This puts your test VM back to its clean-base checkpoint.
It prints nothing when it works.

### EXAMPLE 2
```
Reset-Win32ToolkitTestVM -WhatIf
```

This shows which VM and which checkpoint the command would use, and changes nothing.

## PARAMETERS

### -Name
The VM to reset.
Default: the VM in the W32T_HYPERV_VM environment variable if it is set,
else your saved test VM (win32tk-golden unless you chose another name).

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

### -CheckpointName
The checkpoint to restore.
Default: the name in the W32T_HYPERV_CHECKPOINT environment
variable if it is set, else your saved checkpoint name (clean-base unless you chose another
name).

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### None. When the reset works, the command prints nothing.
## NOTES
Needs: PowerShell 7 run as administrator.
Time: about 30 to 70 seconds, depending on your
PC.
Only one PowerShell window at a time can use the test VM.

## RELATED LINKS

[https://win32toolkit.com/reference/Reset-Win32ToolkitTestVM/](https://win32toolkit.com/reference/Reset-Win32ToolkitTestVM/)

[https://win32toolkit.com/hyperv-vm-care/](https://win32toolkit.com/hyperv-vm-care/)

