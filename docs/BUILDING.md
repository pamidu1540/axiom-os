# Build and verify Windows distributions

Requirements: Windows x64, PowerShell 7.2+, the Windows .NET Framework C# compiler, and Inno Setup 6.7+. No Python, Node, or Go is required to build the installer itself.

Use an official x64 PowerShell ZIP/runtime directory as `-PowerShellHome`. The build defaults to the running PowerShell's `$PSHOME`; its entire runtime is copied into the distribution with its original license notices. Use a clean distribution folder without user profiles or credentials.

The packaging workflow currently pins official PowerShell 7.6.7, verifies the published SHA-256 checksum, and checks Microsoft's executable signature. Update this pin when new stable security patches are released.

```powershell
pwsh -NoProfile -File tests/test-axiom.ps1
pwsh -NoProfile -File tests/lint-axiom.ps1
pwsh -NoProfile -File packaging/build.ps1 -Iscc "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
pwsh -NoProfile -File packaging/smoke-package.ps1
pwsh -NoProfile -File packaging/smoke-installer.ps1
```

The build creates `dist/AxiomOS/`, a versioned setup EXE, a portable ZIP, and `SHA256SUMS.txt`. `BUILD_INFO.json` records the bundled runtime version. The app is per-user and self-contained; language SDKs are intentionally not bundled.

Source tests use a unique disposable workspace and dummy credentials. They never read a real vault. Optional Go/Node execution checks run when their tools are available. Database or AI provider accounts are not required.

The installer smoke test refuses an existing Axiom OS installation, installs into a unique temporary directory with PATH and shortcuts disabled, verifies the packaged runtime, and uninstalls it. Run it on a disposable account or VM when an installation already exists.

The desktop diagnostic mode renders an offscreen onboarding window and writes a nonsecret report. It does not open a terminal, install SDKs, or change settings. Packaged tests use `AXIOM_HOME` and `AXIOM_WORKSPACE` overrides pointing only to their disposable directories.

Manual release verification should include first launch, folder selection, a workspace path containing spaces, starter tasks, optional SDK detection, desktop/Start menu shortcuts, PATH availability in a new terminal, and uninstall with workspace preservation. Signing requires a separate publisher certificate; none is stored or bundled here.

For upgrades from 1.1, stop old managed tasks first. Old task records lack process identity timestamps, so the new version will not stop those PIDs. Recreate old snapshots before committing; version 1.2 requires base hashes to detect source conflicts.

CI runs source checks on pushes and pull requests. The Windows packaging workflow runs manually or for version tags. Manual runs upload artifacts; version tags create a draft release. Review artifacts and notices before publishing.
