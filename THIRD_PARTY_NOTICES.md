# Third-party notices

Axiom OS is MIT licensed. Windows distributions bundle an official x64 PowerShell 7 runtime, including its .NET runtime and modules. Their licenses and notices remain in `runtime/LICENSE.txt`, `runtime/ThirdPartyNotices.txt`, and the component directories supplied by PowerShell. See `BUILD_INFO.json` for the bundled version.

PowerShell source and licensing: https://github.com/PowerShell/PowerShell

Windows and .NET Framework are operating-system prerequisites; this package does not redistribute .NET Framework. Optional Go, Rust, Python, Node.js, Git, Task, make, and PyInstaller installations are not bundled. Their own licenses apply when installed separately.

Inno Setup compiles the installer and is not included as an application dependency. The installer and application are unsigned unless the publisher signs them separately.
