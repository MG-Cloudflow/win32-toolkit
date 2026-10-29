---
description: "This page lists the tools from other people that win32-toolkit uses, with their authors and licenses."
---

# Community tools and credits

win32-toolkit connects tools that other people build and look after. These tools do the hard work. They find and
install apps, draw the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)), connect to Intune and build the
file that Intune needs. This page lists each tool with its author and license, so you know what runs and under which
terms.

On 2026-07-17, each license on this page matched the project's own license file. The project itself is always the
final source for its current terms.

## Tools used when you run the toolkit

If you install the toolkit from the [PowerShell Gallery](glossary.md#powershell-gallery), you get none
of these tools. The PowerShell Gallery is the Microsoft online store for PowerShell modules. Windows usually includes
winget. The toolkit gets the other tools the first time a feature needs them.

| Tool | What the toolkit uses it for | Author | License |
| --- | --- | --- | --- |
| [PSAppDeployToolkit](https://psappdeploytoolkit.com) | The free PowerShell tool that installs and removes your app on devices | PSAppDeployToolkit Team | [LGPL-3.0](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/main/COPYING.Lesser) |
| [PwshSpectreConsole](https://pwshspectreconsole.com/) | Drawing the menu (`Show-Win32Toolkit`) | Shaun Lawrie | [MIT](https://github.com/ShaunLawrie/PwshSpectreConsole/blob/main/LICENSE.md) |
| [Spectre.Console](https://spectreconsole.net) | The engine that draws the menu, used through PwshSpectreConsole | Patrik Svensson, Phil Scott, Nils Andresen | [MIT](https://github.com/spectreconsole/spectre.console/blob/main/LICENSE.md) |
| [Microsoft.Graph.Authentication](https://learn.microsoft.com/powershell/microsoftgraph/) | Signing in to Microsoft Graph and publishing the app to Intune | Microsoft | [MIT](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/main/LICENSE.txt) |
| [Windows Package Manager (winget)](https://learn.microsoft.com/windows/package-manager/) | Finding apps and downloading their installers | Microsoft | [MIT](https://github.com/microsoft/winget-cli/blob/master/LICENSE) |
| [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) | Building the encrypted `.intunewin` file (`IntuneWinAppUtil.exe`) | Microsoft | [Proprietary (Microsoft license terms)](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/blob/master/Microsoft%20License%20Terms%20For%20Win32%20Content%20Prep%20Tool.pdf) |

The toolkit installs [PSAppDeployToolkit (PSADT)](glossary.md#psadt) the first time you package an
app, without a question. PSADT is the free PowerShell tool that installs and removes your app on devices. It goes inside every
[package](glossary.md#package), the `.intunewin` file that you upload to Intune.

The toolkit asks before it installs PwshSpectreConsole or Microsoft.Graph.Authentication. For details, see
[What the toolkit installs later](install.md#what-the-toolkit-installs-later).

!!! note "PSADT travels with your packages"
    PSADT is licensed under the GNU Lesser General Public License v3.0 (LGPL-3.0), in versions 3 and 4. This license
    has more conditions than MIT, the license of most tools here. Each package you build contains PSADT and its
    license file. The LGPL allows this use. Read the license before you change the PSADT files themselves.

### Where the Content Prep Tool comes from

A PowerShell Gallery install of the toolkit does not include `IntuneWinAppUtil.exe`. The first time you build a
package, the toolkit downloads the latest release from Microsoft's GitHub repository. It saves the file in the
`Tools` folder of the toolkit. A Git clone or a ZIP download of the toolkit from GitHub already contains a copy.

Before each use, the toolkit checks the Microsoft signature of the file. If the check fails, it deletes the file and
stops.

!!! note "The Content Prep Tool is proprietary"
    The license of `IntuneWinAppUtil.exe` is the Microsoft Software License Terms. This is a proprietary license, not
    an open-source one. It limits sharing and publishing the file again. This is why a PowerShell Gallery install
    does not include the file. The toolkit downloads the current release from Microsoft instead.

## Windows platform features

Two features come from Windows itself, and the toolkit ships no part of them. The toolkit uses them as a [test machine](glossary.md#test-machine), a clean Windows where it installs and tests your app.

win32-toolkit never turns on Windows features. You turn them on once. This needs administrator rights and a restart.
See [Turn on Windows Sandbox](install.md#turn-on-windows-sandbox) and, for Hyper-V,
[Prepare your PC](hyperv-vm.md#prepare-your-pc).

| Feature | What the toolkit uses it for |
| --- | --- |
| [Windows Sandbox](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/) | The default test machine. It starts clean for every capture and test. |
| [Hyper-V](https://learn.microsoft.com/virtualization/hyper-v-on-windows/) | The optional Hyper-V test VM, a virtual machine (VM) that you build once. It goes back to a clean checkpoint before every test. |

## Tools for the docs and code checks

These tools run during development and in the automatic checks on GitHub. Nothing from them reaches a device.

| Tool | What the toolkit uses it for | Author | License |
| --- | --- | --- | --- |
| [Zensical](https://zensical.org) | Building this documentation site, with its theme and layout | Zensical and contributors, the team behind Material for MkDocs | [MIT](https://github.com/zensical/zensical/blob/master/LICENSE.md) |
| [Mermaid](https://mermaid.js.org) | Drawing the diagrams in these docs | Knut Sveidqvist and contributors | [MIT](https://github.com/mermaid-js/mermaid/blob/develop/LICENSE) |
| [PyMdown Extensions](https://facelessuser.github.io/pymdown-extensions/) | Code blocks, content tabs and collapsible notes in these docs | Isaac Muse | [MIT](https://github.com/facelessuser/pymdown-extensions/blob/main/LICENSE.md) |
| [platyPS](https://github.com/PowerShell/platyPS) | Building the command pages from the help in the code (classic 0.14.2) | Microsoft (PowerShell team) | [MIT](https://github.com/PowerShell/platyPS/blob/0.14.2/LICENSE) |
| [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) | The code check in `scripts/Invoke-Lint.ps1` and on GitHub | Microsoft (PowerShell team) | [MIT](https://github.com/PowerShell/PSScriptAnalyzer/blob/main/LICENSE) |

## Thank you

To every author and maintainer above: thank you. This toolkit would not exist without your work.
