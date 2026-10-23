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

When the checkpoint was taken with automatic checkpoints off, the VM is turned off first, the checkpoint
is restored and the VM is started again, so Hyper-V does not save the memory it is about to discard
(the HyperVRevertMode setting: TurnOffFirst by default, Legacy for the plain restore); the VM is running
afterwards.
A checkpoint taken with automatic checkpoints on gets the plain restore and one warning.
The plain restore keeps a running VM running, but leaves a VM that was off or saved before the reset in
the Saved state: Start-VM resumes it.

The reset holds the test VM's lease, the lock every win32-toolkit process takes before it changes the VM:
while another PowerShell session uses the VM (a test run, for example) the reset waits for it, up to
HyperVLeaseWaitMinutes (default 60), and then stops with the error W32T.HyperVLeaseTimeout.

## EXAMPLES

### Example 1
```powershell
PS C:\> {{ Add example code here }}
```

{{ Add example description here }}

## PARAMETERS

### -Name
VM name (default: the session's test VM: W32T_HYPERV_VM, else the stored HyperVVMName, else 'win32tk-golden').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: ((Get-Win32ToolkitHyperVTarget).VMName)
Accept pipeline input: False
Accept wildcard characters: False
```

### -CheckpointName
Checkpoint to restore (default: W32T_HYPERV_CHECKPOINT, else the stored HyperVCheckpoint, else 'clean-base').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: ((Get-Win32ToolkitHyperVTarget).CheckpointName)
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
