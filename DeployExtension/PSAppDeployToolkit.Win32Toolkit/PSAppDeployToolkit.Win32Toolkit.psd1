@{
    # win32-toolkit's PSAppDeployToolkit extension module. Copied byte for byte into every package win32-toolkit builds;
    # never edit a copy in a project. A change of this file or of the .psm1 bumps ModuleVersion and adds a row to the
    # known-versions table in win32-toolkit's Private\Get-Win32ToolkitDeployExtension.ps1 (the SHA-256 of both files).
    RootModule        = 'PSAppDeployToolkit.Win32Toolkit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '3f35da54-700b-47a7-ae9f-101dca7b153f'
    Author            = 'win32-toolkit'
    CompanyName       = 'CloudFlow'
    Copyright         = '(c) CloudFlow. All rights reserved.'
    Description       = 'win32-toolkit deploy-script functions for PSAppDeployToolkit 4.1.x and 4.2.x packages (constant, value-free).'
    PowerShellVersion = '5.1'

    # A minimum, never a pin: one copy serves PSAppDeployToolkit 4.1.x and 4.2.x packages. PSADT is already loaded when it
    # imports its extensions (after Open-ADTSession), so this entry is satisfied by the loaded module.
    RequiredModules   = @(
        @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.0' }
    )

    FunctionsToExport = @(
        'Install-W32TApp'
        'Install-W32TMsiPatch'
        'Uninstall-W32TApp'
        'Set-W32TInstallTattoo'
        'Remove-W32TInstallTattoo'
        'Show-W32TInstallWelcome'
        'Show-W32TMaintenanceWelcome'
        'Show-W32TCompletionPrompt'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
