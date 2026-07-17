# Community tools and credits

win32-toolkit is mostly glue. The hard parts (installing software reliably, drawing a console UI,
talking to Microsoft Graph, packaging for Intune) are handled by excellent tools that other people
built and maintain. This page credits every third-party tool the project depends on, with its author
and license, so you know exactly what is running when you use the toolkit and under what terms.

Licenses below were checked against each project's own license file on 2026-07-17. The upstream
project is always the authoritative source for its current terms.

## Tools used when you run the toolkit

These are installed or downloaded on first use, or already ship with Windows. The toolkit does not
bundle any of them.

| Tool | What the toolkit uses it for | Author | License |
| --- | --- | --- | --- |
| [PSAppDeployToolkit](https://psappdeploytoolkit.com) | The deployment framework every generated project is built on | PSAppDeployToolkit Team | [LGPL-3.0](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/main/COPYING.Lesser) |
| [PwshSpectreConsole](https://pwshspectreconsole.com/) | The interactive text UI (`Show-Win32Toolkit`) | Shaun Lawrie | [MIT](https://github.com/ShaunLawrie/PwshSpectreConsole/blob/main/LICENSE.md) |
| [Spectre.Console](https://spectreconsole.net) | The console rendering engine beneath the UI, reached through PwshSpectreConsole | Patrik Svensson, Phil Scott, Nils Andresen | [MIT](https://github.com/spectreconsole/spectre.console/blob/main/LICENSE.md) |
| [Microsoft.Graph.Authentication](https://learn.microsoft.com/powershell/microsoftgraph/) | Signing in and calling Microsoft Graph to publish the app | Microsoft | [MIT](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/main/LICENSE.txt) |
| [Windows Package Manager (winget)](https://learn.microsoft.com/windows/package-manager/) | Discovering apps and downloading their installers | Microsoft | [MIT](https://github.com/microsoft/winget-cli/blob/master/LICENSE) |
| [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) | Wrapping the staged payload into the encrypted `.intunewin` file (`IntuneWinAppUtil.exe`) | Microsoft | [Proprietary (Microsoft EULA)](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/blob/master/Microsoft%20License%20Terms%20For%20Win32%20Content%20Prep%20Tool.pdf) |

!!! note "PSAppDeployToolkit is LGPL-3.0, and its license travels with your packages"
    Unlike the rest of the list, PSAppDeployToolkit is licensed under the **GNU Lesser General Public
    License v3.0**, a copyleft license, not a permissive one. This matters because the toolkit
    **scaffolds PSAppDeployToolkit into every project it generates**, so a copy of the framework (and
    its LGPL license) ships inside each package you build. Using and distributing it that way is exactly
    what the LGPL allows. If you modify the PSAppDeployToolkit files themselves, read the license first.
    The license is the same across v3 and v4.

!!! note "The Content Prep Tool is proprietary, which is why it is downloaded, not bundled"
    `IntuneWinAppUtil.exe` is covered by **Microsoft Software License Terms**, a proprietary end user
    license agreement, not an open-source license. Those terms restrict sharing and republishing the
    binary. The toolkit therefore never ships the executable: it **downloads the current release
    straight from Microsoft's own repository on first package** and verifies it is Microsoft-signed
    before running it. That keeps distribution compliant and the binary current.

## Windows platform features

Two capabilities come from Windows itself. The toolkit switches them on and drives them, but does not
redistribute anything.

| Feature | What the toolkit uses it for |
| --- | --- |
| [Windows Sandbox](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/) | A throwaway clean machine for capturing what an installer changes |
| [Hyper-V](https://learn.microsoft.com/virtualization/hyper-v-on-windows/) | The reusable, checkpoint-based test VM for installing and verifying packages |

## Tools used to build the docs and check the code

These run in development and in CI. They are not part of what ships to a device.

| Tool | What the toolkit uses it for | Author | License |
| --- | --- | --- | --- |
| [MkDocs](https://www.mkdocs.org) | Building this documentation site | Tom Christie and the MkDocs community | [BSD-2-Clause](https://github.com/mkdocs/mkdocs/blob/master/LICENSE) |
| [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) | The site theme and layout | Martin Donath (squidfunk) | [MIT](https://github.com/squidfunk/mkdocs-material/blob/master/LICENSE) |
| [Mermaid](https://mermaid.js.org) | Rendering the diagrams in these docs | Knut Sveidqvist and contributors | [MIT](https://github.com/mermaid-js/mermaid/blob/develop/LICENSE) |
| [PyMdown Extensions](https://facelessuser.github.io/pymdown-extensions/) | Superfences, admonitions, tabs and emoji in these docs | Isaac Muse | [MIT](https://github.com/facelessuser/pymdown-extensions/blob/main/LICENSE.md) |
| [platyPS](https://github.com/PowerShell/platyPS) | Generating the command reference from comment-based help (classic 0.14.2) | Microsoft (PowerShell team) | [MIT](https://github.com/PowerShell/platyPS/blob/0.14.2/LICENSE) |
| [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) | The lint gate in `scripts/Invoke-Lint.ps1` and CI | Microsoft (PowerShell team) | [MIT](https://github.com/PowerShell/PSScriptAnalyzer/blob/main/LICENSE) |

## Thank you

To every author and maintainer above: thank you. This toolkit would not exist without your work.
