# Command reference

> Generated from the module's built-in help by `build/Update-Docs.ps1`. Do not edit these pages by hand. The same content is available offline via `Get-Help <command> -Full`.

## Start here

- [Show-Win32Toolkit](Show-Win32Toolkit.md): Launches the interactive, menu-driven text UI (TUI) for win32-toolkit.
- [Invoke-Win32Toolkit](Invoke-Win32Toolkit.md): End-to-end Win32 app packaging automation.
- [New-Win32ToolkitManualApp](New-Win32ToolkitManualApp.md): Creates a Win32 packaging project for an app that is NOT in winget.
- [Complete-Win32ToolkitManualApp](Complete-Win32ToolkitManualApp.md): Finalises a scaffolded project: sandbox capture → uninstall automation → test/package/upload.
- [Test-Win32ToolkitProject](Test-Win32ToolkitProject.md): Tests a PSADT project in a disposable guest: Windows Sandbox or the Hyper-V test VM.

## Pipeline steps

- [Export-Win32ToolkitIntuneWin](Export-Win32ToolkitIntuneWin.md): Packages a PSADT project into a .intunewin file for Intune deployment.
- [Publish-Win32ToolkitIntuneApp](Publish-Win32ToolkitIntuneApp.md): Uploads a packaged Win32 app (.intunewin) to Microsoft Intune via the Graph API.
- [Export-Win32ToolkitDocumentation](Export-Win32ToolkitDocumentation.md): Writes a clean, customer-facing one-page Documentation.md summarising a packaged project.
- [Set-Win32ToolkitAppDependency](Set-Win32ToolkitAppDependency.md): Declares which apps must be installed BEFORE this one (Intune app dependencies).
- [Sync-Win32ToolkitAppDependency](Sync-Win32ToolkitAppDependency.md): Pushes a project's declared dependencies onto the app it ALREADY published in Intune, without
re-publishing it.

## Test-VM management

- [New-Win32ToolkitTestVM](New-Win32ToolkitTestVM.md): Provisions the Hyper-V test VM: build (or attach) a golden VHDX, create a Gen2 VM, first-boot,
wait for PowerShell Direct, and take a warm 'clean-base' standard checkpoint.
- [Set-Win32ToolkitTestVMResource](Set-Win32ToolkitTestVMResource.md): Changes the CPU count and/or startup memory of the Hyper-V test VM and re-freezes its clean-base checkpoint.
- [Reset-Win32ToolkitTestVM](Reset-Win32ToolkitTestVM.md): Reverts the Hyper-V test VM to its warm 'clean-base' checkpoint (the between-run reset).
- [Remove-Win32ToolkitTestVM](Remove-Win32ToolkitTestVM.md): Tears down the Hyper-V test VM (stop, remove checkpoints + VM, optionally delete the VHDX).

