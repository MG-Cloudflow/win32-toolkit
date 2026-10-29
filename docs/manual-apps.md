---
description: "Package your own MSI, MSIX or EXE installer, with or without silent switches."
---

# Package an app that is not in winget

Use this page when an app is not in [winget](glossary.md#winget), the Windows Package Manager. It also
helps when you need an older version, or when the app is your own build.

You bring an MSI, MSIX or EXE installer, with or without [silent switches](glossary.md#silent-switches). These are extra words such as `/S` that make an installer run without
windows or questions. win32-toolkit then captures, tests, packages and publishes the app as it does for a winget app.

## Easy or Advanced

Who writes the install depends on the installer.

| Installer | Mode | Who writes the install |
|---|---|---|
| MSI (`.msi`) | Easy | The toolkit. An MSI needs no switches. |
| MSIX or APPX (`.msix`, `.appx` and their bundles) | Easy | The toolkit. These packages need no switches. |
| EXE with silent switches that you know | Easy | The toolkit, with your switches. |
| EXE without silent switches, or with extra steps | Advanced | You, in a few lines of PowerShell. |

An [Easy app](glossary.md#easy-app) needs no code from you. An [Advanced app](glossary.md#advanced-app) needs your own install code. The console calls an Advanced app a "HARD APP".

You never write the uninstall. The toolkit builds it from the installer itself or from the [install capture](glossary.md#install-capture). This is a test install on a clean copy of Windows that records every
change.

## Before you start

- win32-toolkit is installed and [Windows Sandbox](glossary.md#windows-sandbox) is turned on. See
  [Install the toolkit](install.md).
- You have an [org template](glossary.md#org-template), your saved settings for one customer. See
  [Create your org template](org-templates.md).
- The installer is on your PC, as one file or as a folder. For an EXE, you know its silent switches, if it has any.
- You know the publisher, for example `Contoso Ltd`. See [Always give a publisher](#always-give-a-publisher).
- Time: 2 to 5 minutes of your input, then usually 5 to 20 minutes for the install capture.

## Package an Easy app

The example is Contoso Reader 3.2.0, an MSI from Contoso Ltd. The toolkit creates a [project](glossary.md#project) for it: the folder with the installer, scripts and settings of one app version.

=== "Menu"

    Start the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) and answer the questions in this order.

    1. In the main menu, choose **Package a manual app**.
    2. At **How does this app install?**, choose **Easy**.
    3. At **Full path to the installer file**, type the path, for example `C:\Installers\ContosoReader.msi`.
    4. Answer **Application name**, **Version** and **Target architecture** with `Contoso Reader`, `3.2.0` and `x64`.
    5. At **Publisher**, type `Contoso Ltd`. For the description, information URL and icon, type a value or
       press <kbd>Enter</kbd>.
    6. At **Silent-install switch**, press <kbd>Enter</kbd>. An MSI needs none. For an EXE, type its switches.
    7. At **Choose an org template**, choose `Contoso`. At **Does this app need another app installed FIRST**, answer `n`.
    8. At **After building, also…**, tick **Run an install/uninstall test in Windows Sandbox** with
       <kbd>Space</kbd>. Press <kbd>Enter</kbd>.
    9. Read the **Review** panel. At **Continue?**, type `y` and press <kbd>Enter</kbd>. (The default is No.)
        <!-- SCREENSHOT: the TUI "Package a manual app" wizard with the review panel visible -->

    The menu always runs the install capture, even when you tick nothing. A ticked test then runs on your
    [test machine](glossary.md#test-machine). This is Windows Sandbox, or the Hyper-V test VM (virtual
    machine) if you use one.

    If you ticked **Publish to Intune**, the menu then asks **Publishing UPLOADS to your Intune tenant**. Answer `y`
    to publish. (The default is No.) At the end, the **Done** or **Finished with problems** panel shows the result.

    !!! warning "The menu replaces existing projects"

        If a project of the same app, architecture and version exists, the menu replaces it without asking.
        Re-creating a project deletes its folder. Copy your own code out first.

=== "Command line"

    Run [`New-Win32ToolkitManualApp`](reference/New-Win32ToolkitManualApp.md) with the details of the app. This
    example also tests the app and builds the package. The `@app` form passes all values of the list to the command
    (see [Answer every question with a parameter](automation.md#answer-every-question-with-a-parameter)).

    ```powershell
    $app = @{
        Name          = 'Contoso Reader'
        Version       = '3.2.0'
        Architecture  = 'x64'
        SourcePath    = 'C:\Installers\ContosoReader.msi'
        Publisher     = 'Contoso Ltd'
        TemplateName  = 'Contoso'
        RunTest       = 'InstallUninstall'
        PackageIntune = $true
    }
    New-Win32ToolkitManualApp @app
    ```

    With the default [base folder](glossary.md#base-folder) `C:\Win32Apps`, the project is
    `C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0`. If you leave out the name, version, architecture or
    installer path, the command asks for it. For the architecture, <kbd>Enter</kbd> means `x64`. If the project exists,
    the command asks before it replaces it.

    After the build, the command asks **Upload to Microsoft Intune now? (Y/N)**. Answer `n` and publish after you read
    the test result. Without a test, package or publish option, the command only creates the project. Add `-Continue`
    to run the install capture in that case.

    In a script, check the `Status` of the result, not only that a result came back. See
    [Check the result](automation.md#check-the-result).

    For every option, see [New-Win32ToolkitManualApp](reference/New-Win32ToolkitManualApp.md).

## Always give a publisher

The publisher looks optional, but detection needs it. After a good install, the package writes an [install tattoo](glossary.md#install-tattoo): a registry value with the installed version. The [detection rule](glossary.md#detection-rule) in Intune reads it to check the version.

The install tattoo needs the publisher and the [app script author](glossary.md#app-script-author) of
your org template. This is the name that your org template gives as the author of the scripts. Without a publisher:

- There is no version detection. At publish, the toolkit warns
  `Tattoo/version detection unavailable - missing App.Vendor` ... It then builds a weaker rule from the install
  capture, for example "this file exists".
- Intune shows the publisher as "Unknown".
- An MSIX or APPX app can be refused at publish. The install capture often gives no other rule for such an app.

## Installer files and folders

You can give one installer file or a folder. For a folder, the toolkit copies everything in it, with its subfolders,
into the `Files` folder of the project. Use a folder when the installer needs files next to it, such as a transform.

With an MSI, you can also put MSI patch files (`.msp`) next to it. The package installs them after the MSI.

The installer must be at the top level of the folder. The toolkit does not look in subfolders. It takes an MSI first,
then an EXE, then an MSIX, then an APPX file.

With several files of one type, the toolkit takes the first by name and warns you. Remove the extra files and package
the app again.

- An EXE wins over an MSIX file. If the MSIX is the real installer, remove the extra EXE.
- Do not use square brackets (`[` or `]`) in the folder path or in the app name. The toolkit then cannot copy or find
  the installer.
- Silent switches are ignored for an MSI, MSIX or APPX file.
- On the command line, a missing icon file is ignored without a message. The menu checks the path for you.

## Package an Advanced app

The example is Fabrikam CAD 12.0, an EXE. Its install needs extra steps, so you write the install yourself and give
the toolkit no switches.

First the toolkit creates the project `Fabrikam_CAD_x64_12.0`. Then you write the install code in the
[deploy script](glossary.md#deploy-script) `Invoke-AppDeployToolkit.ps1`, which installs and removes the
app on devices. Then the toolkit finishes the project.

=== "Menu"

    1. In the main menu, choose **Package a manual app**.
    2. At **How does this app install?**, choose **Advanced**. The wizard does not ask for silent switches.
    3. Answer the other questions as for an Easy app. At **Continue?**, answer `y`.
    4. If the **Check these warnings** panel appears, read it, then press any key.
    5. On the **Advanced app - your turn** screen, choose **Open Invoke-AppDeployToolkit.ps1 in Notepad**.
        <!-- SCREENSHOT: The Advanced app - your turn screen for Fabrikam_CAD_x64_12.0, with the project path and its four choices -->
    6. Write your install code as shown in [Write the install code](#write-the-install-code). Save the file.
    7. Choose **Finish setup now**.

    The screen has four choices:

    | Choice | What it does |
    |---|---|
    | **Open the project folder** | Opens the project in File Explorer. |
    | **Open Invoke-AppDeployToolkit.ps1 in Notepad** | Opens the deploy script for your install code. |
    | **Finish setup now** | Runs the install capture, then the test, package and publish you ticked. |
    | **Do it later** | Goes back to the menu. Finish later with **Finalize / refresh**. |

    If the toolkit refuses the deploy script, the **Not ready to finish** panel says why. Fix the script and choose
    **Finish setup now** again. Your ticked choices are kept.

    **Easy** with an EXE and no switches gives the same result. The **Advanced app** panel tells you so.

=== "Command line"

    First create the project with the `Advanced` option. An EXE without `SilentArgs` gives the same result.

    ```powershell
    $app = @{
        Name         = 'Fabrikam CAD'
        Version      = '12.0'
        Architecture = 'x64'
        SourcePath   = 'C:\Installers\FabrikamCAD'
        Publisher    = 'Fabrikam'
        TemplateName = 'Contoso'
        Advanced     = $true
    }
    $result = New-Win32ToolkitManualApp @app
    ```

    The command stops after it creates the project, and `$result.Status` is `Scaffolded`. It ignores test, package
    and publish options for an Advanced app. It prints the next steps under a `HARD APP` heading.

    Then write the install code. When you are ready, run
    [`Complete-Win32ToolkitManualApp`](reference/Complete-Win32ToolkitManualApp.md). It runs the install capture and a
    test.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Fabrikam_CAD_x64_12.0'   # your project folder
    Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall
    ```

    Add `-PackageIntune` to also build the package, or `-PublishIntune` to also publish it.

    For every option, see [New-Win32ToolkitManualApp](reference/New-Win32ToolkitManualApp.md) and
    [Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md).

## Write the install code

The deploy script uses [PSAppDeployToolkit (PSADT)](glossary.md#psadt), the free PowerShell tool that
installs apps on devices. Your code goes between two [toolkit blocks](glossary.md#toolkit-block): marked parts of
the script that the toolkit owns and writes again. Never change anything inside a toolkit block.

On PSADT 4.2, the place is under `## MARK: Install`. On PSADT 4.1, it is inside `Install-ADTDeployment`. Look for these
lines:

```powershell
    ## win32-toolkit:Install:manual-install (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## MANUAL APP: write your install code BETWEEN this block and the 'install-done' block below.
    ## Never edit inside a '## win32-toolkit:' block - those are regenerated.
    ## Fail with 'throw', never 'return' (on PSADT 4.2 a 'return' does not skip Post-Install).
    ## Never assign PSADT variable names ($Culture, $envTemp, ...): they are read-only on PSADT 4.2.
    ## The uninstall is generated from the documentation capture - no action needed there.
    ## win32-toolkit:Install:manual-install (end)

    # Your install code goes here.

    ## win32-toolkit:Install:install-done (begin) - managed by win32-toolkit; regenerated, do not edit inside
    $w32tInstallDone = $true
    ## win32-toolkit:Install:install-done (end)
```

Follow these four rules:

1. **Use Windows PowerShell 5.1 syntax only.** Devices run the script in [Windows PowerShell 5.1](glossary.md#powershell-7-and-windows-powershell-51), the older PowerShell that comes with Windows. Do
   not use `??`, `?.`, `&&`, `||` or the `? :` form. The toolkit refuses such a script when it builds the package.
2. **Stop with `throw`, never with `return`.** A `return` makes the install look good, but the install tattoo is not
   written. Intune then reports the app as not detected. Only the install and uninstall test finds this mistake.
3. **Never assign PSADT variable names**, such as `$Culture` or `$envTemp`. They are read-only on PSADT 4.2, so the
   install fails.
4. **Write only the install.** The toolkit builds the uninstall from the install capture.

In this made-up example, the Fabrikam setup needs an answer file next to it. The code stops with `throw` if the file
is missing. `$adtSession.DirFiles` is the `Files` folder of the package on the device.

```powershell
    # Example only: use the steps your vendor documents
    $setup = Join-Path -Path $adtSession.DirFiles -ChildPath 'FabrikamCAD_Setup.exe'
    $answers = Join-Path -Path $adtSession.DirFiles -ChildPath 'answers.ini'
    if (-not (Test-Path -LiteralPath $answers)) { throw "Answer file not found: $answers" }
    Start-ADTProcess -FilePath $setup -ArgumentList '/unattended'
```

Create an Advanced app only for an EXE installer. With an MSI, PSADT still installs the MSI by itself, and your code runs too.

## MSIX and APPX packages

[MSIX and APPX](glossary.md#msix-and-appx) are modern Windows app package formats. On devices, the
toolkit installs the package for all users. Some rules apply:

- The package must be signed, and devices must trust the certificate. This is a Windows rule. If the certificate is
  self-signed, deploy it to the Trusted People store of the local computer on your devices. Do this before you deploy
  the app.
- The toolkit does not install framework packages, the shared runtimes such as VCLibs. An app that needs one can fail
  on clean devices with error `0x80073CF3`. Do not put framework packages next to the installer. The toolkit does not
  use them, and it can take one as the installer by mistake. It warns you when it sees several packages.
- The uninstall comes from the identity of the package, not from the install capture.
- At publish, the minimum Windows version of the app becomes at least Windows 10 1809.

## Finish or refresh a project later

Use this after **Do it later**, after you changed a project by hand, or after a failed install capture.

=== "Menu"

    Choose **Work with an existing project** > choose your project > **Finalize / refresh**. This runs the install
    capture only. Then use **Run a test**, **Package to .intunewin** and **Publish to Intune** in the same list.

=== "Command line"

    Run `Complete-Win32ToolkitManualApp` on the project. It works on any project, also on one from winget.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Fabrikam_CAD_x64_12.0'   # your project folder
    Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall
    ```

    For every option, see [Complete-Win32ToolkitManualApp](reference/Complete-Win32ToolkitManualApp.md).

The menu and the command never change your install code. They check the deploy script, run the install capture again
and update the uninstall data. See [Run the install capture again](projects.md#run-the-install-capture-again).

## Test an update of a manual app

An [update test](glossary.md#update-test) installs an **old version** of the app first, then your new
package over it. An app that is not in winget has no old versions there, so you need the old version as a project. The
console calls it the [baseline](glossary.md#baseline). For example, package Contoso Reader 3.1.0 first,
as `Contoso_Reader_x64_3.1.0`.

=== "Menu"

    1. Choose **Work with an existing project** > choose `Contoso_Reader_x64_3.2.0` > **Run a test**.
    2. At **Which test backend?**, choose **Windows Sandbox**.
    3. At **Test scenario**, choose **Update from an older version**.
    4. At **Baseline project**, choose `Contoso_Reader_x64_3.1.0`.
    5. At **Also verify the update-app requirement rule during the test?**, press <kbd>Enter</kbd>. (The default is
       Yes.)

    Without another project, the **No baseline available** panel appears. Package the old version first.

=== "Command line"

    Run [`Test-Win32ToolkitProject`](reference/Test-Win32ToolkitProject.md) with the old version as the baseline.

    ```powershell
    $project = 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0'   # your project folder
    Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -BaselineProject 'Contoso\Contoso_Reader_x64_3.1.0'
    ```

    For every option, see [Test-Win32ToolkitProject](reference/Test-Win32ToolkitProject.md).

Do not use `-RunTest Update` with `New-Win32ToolkitManualApp` or `Complete-Win32ToolkitManualApp`. They cannot take an
old version, so the update test gets no result. The toolkit warns `The Update test produced NO verdict` and continues.
See also [Apps that are not in winget](testing.md#apps-that-are-not-in-winget).

## Known limits

- An MSI app is published under the project folder name, such as `Contoso_Reader_x64_3.2.0`. Rename it in the Intune
  admin center.
- Apps that are not in winget do not keep the [tenant pin](glossary.md#pin), the tenant ID that stops a
  publish to the wrong tenant. The toolkit checks the tenant only when you publish in the same run that creates the
  project. A later publish warns `This project's template does not pin a tenant`. Connect first and read the
  [tenant banner](intune-connection.md#check-the-tenant-banner).
- When you [re-create](glossary.md#re-create) such a project, you lose its dependencies. Declare them
  again. Re-creating a project deletes its folder. Copy your own code out first.
- Re-creating such a project also deletes its [publication record](glossary.md#publication-record): the
  file that remembers its app in Intune.

For all limits, see [Known limits](known-limits.md).

## If something goes wrong

| Message starts with | What to do |
|---|---|
| `No installer (msi/exe/msix/appx) detected in` | Put the installer at the top level of your installer folder. Then package the app again. |
| `Source path not found` | Check the path to the installer, then try again. |
| `The capture recorded NO changes` | The install did nothing on the test machine. Check the switches or your install code, then choose **Finalize / refresh**. |
| `Uninstaller(s) ... have no silent switch` | Set the switches in `SupportFiles\AppConfig.json` ([Change a project by hand](projects.md#change-a-project-by-hand)). Set them again after each install capture. |
| `The org template could not be applied` | Read the warnings above the message. Fix the org template, then package the app again. |
| `... does not parse under Windows PowerShell 5.1` | Remove PowerShell 7 syntax such as `??` or `&&` from your install code. Then build again. |
| `... is marked not configured` | The project was not finished. Fix the cause, then package the app again. This replaces the folder. |

For more messages, see [Troubleshooting](troubleshooting.md#manual-apps).

## Next steps

- [Test the package](testing.md): read the result before you publish.
- [Apps that need another app first](dependencies.md): add a runtime such as the Visual C++ redistributable.
- [Change or re-create a project](projects.md): change switches, the icon or the processes to close.
