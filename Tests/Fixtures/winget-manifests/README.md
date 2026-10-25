# winget manifests (public data)

Installer manifests copied from the public winget-pkgs repository (microsoft/winget-pkgs, MIT license) for the winget
manifest reader tests (`Tests\WingetManifestReader.unit.ps1`, installer-identity PR 3b). `merged-8.9.8.1.yaml` and
`8.9.8.1.locale.en-US.yaml` are hand-made in the shapes `winget download` and winget-pkgs use. Never edit the copied
files: the tests pin their values.

`Microsoft.OneDrive\26.153.0809.0004.installer.yaml` has root-level `InstallerSwitches` (`Silent`, `SilentWithProgress`,
`Upgrade`) and machine-scope installers that add only `Custom: /allusers`: winget merges the two key by key, so the
machine installers run `/silent /allusers`.
