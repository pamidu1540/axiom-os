# Axiom OS

**A local developer workspace toolkit, built on PowerShell.**

Run project tasks, plan builds, manage background processes, and compare project snapshots through one `axiom` command. The Windows app helps you choose a workspace and open a ready-to-use terminal. JSON output and a small read-only MCP server support agent integrations.

Experimental software for testing and educational use. Run tasks only from projects you trust.

## Install on Windows

Requires **Windows 10 or 11, x64**. The installer bundles PowerShell 7; a separate PowerShell installation is not required. Go, Rust, Python, Node.js, and other build tools are optional and installed separately.

1. Run `Axiom-OS-1.2.0-Setup.exe` from the build/release artifacts.
2. Choose a desktop shortcut and whether to add `axiom` to your user PATH.
3. Open **Axiom OS**, choose a workspace outside the application folder, and select **Save workspace & open terminal**.
4. Try `axiom env check` and `axiom run hello` if starter tasks were selected.

Installation is for your Windows account and requires no administrator access. Start menu entries open the app, workspace terminal, and quick-start guide. Open a new terminal after changing PATH.

The portable ZIP also includes PowerShell. Extract the whole archive and run `AxiomOS.exe`; keep `runtime/`, `kernel/`, and `modules/` beside it. Portable builds do not alter PATH automatically.

## Everyday commands

```powershell
axiom --help
axiom env check
axiom env info --json
axiom run --list
axiom run hello

axiom compile . linux --dry-run
axiom compile . --all-targets

axiom sandbox create my-project --name experiment --ttl 2h
axiom sandbox exec experiment "python main.py"
axiom sandbox diff experiment
axiom sandbox commit experiment --dry-run
axiom sandbox commit experiment --yes
axiom sandbox destroy experiment

axiom task start "python server.py" --name api --cwd my-project
axiom ps --json
axiom task logs api --tail 40
axiom task restart api
axiom task stop api
```

Paths are resolved against the current workspace. Use `--workspace "C:\Projects\My Store"` or `AXIOM_WORKSPACE` to select a different directory. The app's workspace terminal selects the saved workspace automatically; invoking the CLI in another project uses that current directory unless explicitly overridden.

## Capabilities and boundaries

| Command | Behavior |
| --- | --- |
| `compile` | Go cross-compilation; Cargo target builds; Python syntax checks or host-only PyInstaller bundles; a Node project's own build script |
| `sandbox` | Project file snapshots with diff, conflict checks, merge of added/changed files, expiry, and removal |
| `task`, `ps` | Named background processes, separate stdout/stderr logs, manual restart, and process identity checks |
| `env` | Detect optional tools, show workspace info, print activation instructions, record SDK preferences |
| `vault` | Windows DPAPI-encrypted secrets and private child-process environment injection |
| `guard` | Redacted scanning for known token/private-key patterns, including Git index content with `--staged` |
| `run` | JSON task graphs with dependency-cycle detection; Taskfile and Makefile delegation to installed Task/make |
| `watch` | Debounced file events and a trusted trigger command; interactive until Ctrl+C |
| `mcp` | A stdio MCP server exposing three read-only workspace inspection tools |

Snapshots are file copies, **not operating-system, network, or permission isolation**. Commands run with your account's permissions. Snapshot copies skip `.git`, private environment/key files, caches, and generated directories. Commit merges added/changed files after checking for source conflicts; it does not delete source files. TTL is enforced only when you run `sandbox prune`.

Rust cross-compilation requires the target and appropriate linker to be installed. Python and Node builds are host-only; Node artifacts stay wherever the project's build script places them. `env pin` records preference metadata without installing or switching SDKs. Automatic crash restart is not implemented; use `task restart`.

## Secrets

```powershell
axiom vault set MY_API_KEY         # Hidden interactive entry
axiom vault list                   # Names only
axiom vault get MY_API_KEY         # Presence check; no plaintext
axiom vault exec MY_API_KEY "python client.py"
axiom vault remove MY_API_KEY
axiom guard scan
axiom guard scan --staged
```

The vault uses Windows DPAPI for your current account. `vault exec` supplies the selected key only to its child environment and redacts its exact value from captured output. Do not put credentials in command strings: task commands and logs are stored locally. DPAPI is not a cross-account backup or protection against programs running as you. The built-in scanner covers known patterns and files up to 2 MB; use a dedicated scanner such as Gitleaks for a broader review.

## Project tasks

Create `axiom.tasks.json` in your workspace:

```json
{
  "tasks": {
    "test": { "command": "go test ./...", "cwd": "backend" },
    "build": { "command": "go build ./...", "cwd": "backend", "depends_on": ["test"] }
  }
}
```

Relative task directories are resolved from the configuration file. `--dry-run` previews the entire dependency graph without executing commands.

## Agent integration

Finite commands support `--json` with `status`, `exit_code`, `output`, `errors`, and `warnings`. Shell exit codes reflect failures. `watch --json` and interactive secret entry with `--json` are intentionally rejected.

```powershell
axiom mcp schema
axiom mcp start --workspace C:\Projects\MyWorkspace
```

The MCP server handles initialization, ping, tools/list, and tools/call over newline-delimited JSON-RPC. Its tools are `axiom_environment`, `axiom_tasks`, and `axiom_snapshots`; it does not expose vault values or arbitrary execution. Close stdin to end a session. See [agent configuration](docs/AGENT_INTEGRATION.md).

## Data and uninstall

Settings live in `%LOCALAPPDATA%\AxiomOS\settings.json`. Each workspace keeps snapshots/process records under `.staging/`, encrypted keys in `.vault/axiom-keys.json`, and generated builds under `bin/`. None belongs in source control.

Uninstall through Windows Settings. The uninstaller preserves your workspace and settings and removes only a PATH entry that this installer added. Stop managed tasks before uninstalling. The app itself requires no AI service account or API key.

## Source and builds

```powershell
git clone https://github.com/pamidu1540/axiom-os.git
cd axiom-os
pwsh -NoProfile -File ./axiom.ps1 --help
pwsh -NoProfile -File tests/test-axiom.ps1
pwsh -NoProfile -File tests/lint-axiom.ps1
pwsh -NoProfile -File packaging/build.ps1 -Iscc "C:\path\to\ISCC.exe"
```

Source commands require PowerShell 7.2+. Finite task execution and snapshots can run on other PowerShell-supported platforms; managed background tasks, the installer, desktop app, and DPAPI vault are Windows-specific. See [building and verification](docs/BUILDING.md). CI checks committed code without auto-fixing it or automatically publishing releases on every push.

## License

[MIT](LICENSE). Bundled runtime notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Local builds are unsigned unless the publisher signs them separately.
