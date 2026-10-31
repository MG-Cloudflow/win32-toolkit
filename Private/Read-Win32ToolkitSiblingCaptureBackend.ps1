function Read-Win32ToolkitSiblingCaptureBackend {
    <#
    .SYNOPSIS
        Menu (Spectre): before a sibling capture the menu starts, picks its backend and, without a ready Hyper-V test VM,
        says what a Windows Sandbox capture gives and offers to cancel.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.18; SV28: "the TUI offers to cancel"). Used by the review screen's Widen action
        (Show-Win32ToolkitSiblingCaptureReview) and the Prior installs screen's capture action
        (Show-Win32ToolkitPriorInstallScreen); the winget wizard asks its own capture question.

        A ready Hyper-V test VM (Test-Win32ToolkitHyperVReady): 'HyperV', nothing asked. Otherwise one yellow line says
        why the VM is not ready and that the capture would run in Windows Sandbox as a user with Block-only proposals; when
        the project already holds captures an Enforce rule can use (Get-Win32ToolkitSiblingSandboxImpact: Enforce-eligible
        proposals and captured Enforce rules of the technologies captured now), it names them: a Sandbox record joins the
        records of the identity it sees and makes it Block-only, which a later capture on Hyper-V does not take back. Then
        'Capture in Windows Sandbox anyway?' (default No): Yes -> 'Sandbox', No -> '' (nothing is captured). Every text
        passes Get-SpectreEscapedText.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER SiblingType
        The sibling installer types the capture would run (empty: every type).
    .OUTPUTS
        [string] HyperV, Sandbox, or '' when the operator cancelled.
    .EXAMPLE
        $backend = Read-Win32ToolkitSiblingCaptureBackend -ProjectPath $p -SiblingType nullsoft
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$SiblingType = @()
    )

    $notReady = @(Test-Win32ToolkitHyperVReady)
    if ($notReady.Count -eq 0) { return 'HyperV' }
    $lost = @(Get-Win32ToolkitSiblingSandboxImpact -ProjectPath $ProjectPath -SiblingType $SiblingType)
    $text = 'Hyper-V is not ready (' + ($notReady -join '; ') + '): this capture would run in Windows Sandbox as a user and can only give Block-only proposals.'
    if ($lost.Count -gt 0) {
        $text += ' A Sandbox record joins the records of the identity it sees: ' + ($lost -join ', ') + ' would become Block-only (an Enforce rule of it is then refused at Export), and a later capture on the Hyper-V test VM does not take that back.'
    }
    Write-SpectreHost "[yellow]$(Get-SpectreEscapedText -Text $text)[/]"
    if (Read-SpectreConfirm -Message 'Capture in Windows Sandbox anyway?' -DefaultAnswer 'n') { return 'Sandbox' }
    Write-SpectreHost '[grey]Nothing was captured.[/]'
    return ''
}
