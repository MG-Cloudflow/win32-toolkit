# Set-Win32ToolkitTestVMResource

## SYNOPSIS
Changes the CPU count and/or startup memory of the Hyper-V test VM and re-freezes its clean-base checkpoint.

## SYNTAX

```
Set-Win32ToolkitTestVMResource [[-ProcessorCount] <Int32>] [[-MemoryStartupBytes] <UInt64>] [[-Name] <String>]
 [[-CheckpointName] <String>] [[-Credential] <PSCredential>] [-ProgressAction <ActionPreference>] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Reconfigures an EXISTING test VM's hardware in place - it does NOT rebuild from ISO, so the installed
golden guest and its disk are preserved (minutes, not the ~hour a full re-provision costs).

Why this is more than a one-liner: the VM uses a STANDARD (memory-state) 'clean-base' checkpoint.
Changing
static memory / vCPU count requires the VM to be powered OFF, and the existing checkpoint encodes the OLD
memory state - so a change would be silently reverted by the next Reset-Win32ToolkitTestVM unless the
checkpoint is recreated.
This command therefore:

    Stop-VM -TurnOff  -\>  remove checkpoints  -\>  Set-VMProcessor / Set-VMMemory  -\>  Start-VM
    -\>  wait for the AutoLogon desktop  -\>  re-take the Standard 'clean-base' checkpoint  -\>  persist

The chosen values are saved (HyperVProcessorCount / HyperVMemoryStartupBytes) and become the defaults for the
next New-Win32ToolkitTestVM.
Requested CPU/RAM above the host's capacity is REFUSED.

## EXAMPLES

### EXAMPLE 1
```
Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB
```

### EXAMPLE 2
```
Set-Win32ToolkitTestVMResource -MemoryStartupBytes 6GB   # RAM only; CPU unchanged
```

## PARAMETERS

### -ProcessorCount
New virtual processor count (1-64).
Omit to leave CPU unchanged.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -MemoryStartupBytes
New static startup memory in bytes (accepts PowerShell size literals, e.g.
6GB).
Omit to leave RAM unchanged.

```yaml
Type: UInt64
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -Name
VM name.
Defaults to the configured HyperVVMName ('win32tk-golden').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CheckpointName
Clean-base checkpoint name to recreate.
Defaults to the configured HyperVCheckpoint ('clean-base').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Credential
Guest admin credential (to confirm the desktop is up before the warm checkpoint).
Defaults to the stored
DPAPI-protected guest credential.

```yaml
Type: PSCredential
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
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

### The reconfigured VM (Get-VM), or nothing under -WhatIf.
## NOTES

## RELATED LINKS
