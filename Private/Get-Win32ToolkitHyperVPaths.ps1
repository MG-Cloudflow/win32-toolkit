function Get-Win32ToolkitHyperVPaths {
    <#
    .SYNOPSIS
        Returns the Hyper-V test-backend folder roots under a given BasePath.
    .DESCRIPTION
        Centralises the Hyper-V tier layout so nothing hard-codes it (mirrors Get-Win32ToolkitPaths for
        the packaging tiers). The Hyper-V backend is a NEW tier parallel to Templates/Projects/Staging/
        IntuneWin:

            <BasePath>\HyperV\
              Golden\    built (or BYO) base VHDX — the checkpoint parent  [treat as a secret]
              VMs\       New-VM -Path target (VM config + checkpoints)
              Unattend\  generated unattend.xml (also seeded into the VHDX Panther)  [treat as a secret]
              ISO\       operator-dropped / fetched Windows ISO

        Does NOT create the folders — callers ensure a tier exists before writing.
    .PARAMETER BasePath
        The win32-toolkit base folder (see Get-Win32ToolkitBasePath).
    .OUTPUTS
        PSCustomObject with: BasePath, Root, Golden, VMs, Unattend, ISO.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BasePath
    )

    $root = Join-Path $BasePath 'HyperV'
    [pscustomobject]@{
        BasePath = $BasePath
        Root     = $root
        Golden   = Join-Path $root 'Golden'
        VMs      = Join-Path $root 'VMs'
        Unattend = Join-Path $root 'Unattend'
        ISO      = Join-Path $root 'ISO'
    }
}
