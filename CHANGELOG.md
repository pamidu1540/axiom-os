# Changelog

All notable changes to **Axiom OS** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] - 2026-09-06

### Added
- **Non-blocking CI/CD Auto-Fix Workflow**: Updated `.github/workflows/ci.yml` so that lint violations automatically trigger `Invoke-ScriptAnalyzer -Fix`, emit GitHub warning annotations, and allow test, build, and release stages to proceed without a dead exit.
- **PSScriptAnalyzer Configuration**: Added `PSScriptAnalyzerSettings.psd1` tailored for interactive CLI applications (handles ANSI color output, domain commands, cross-platform UTF-8, and script evaluation).
- **Dedicated Lint Runner**: Added `tests/lint-axiom.ps1` with `-Fix` switch for single-command automated linting.
- **Non-interactive Sandbox Commit**: Added `--yes` / `-y` / `-Force` flags to `axiom sandbox commit` so automated AI agents and scripts execute without hanging on `Read-Host`.
- **Structured JSON in Sandbox & Process Subsystems**: `axiom sandbox list --json` and `axiom ps --json` now output pure, parseable JSON without banner or message interference.
- **Direct Target CLI Argument**: `axiom compile linux` and `axiom compile --all-targets` now automatically resolve to current project path `.` when target OS or flags are passed without explicit directory.
- **Multi-language Directory Tree Walk**: `Get-ProjectLanguage` now traverses up to 5 parent directories for Python (`pyproject.toml`, `requirements.txt`, `pytest.ini`) and Node (`package.json`) in addition to Go and Rust.

### Fixed
- **Process List Table Formatting**: Fixed format string index bug in `Process-List` (`{1,-10}` duplication) to properly align `PID`, `STATUS`, `STARTED`, and `COMMAND` headers.
- **PowerShell Parameter Slicing**: Fixed array slicing bug (`$Params[1..$Params.Count]`) in `sandbox.ps1`, `guard.ps1`, and `env.ps1` that produced `$null` elements when passed single-item arrays.
- **Go Binary Naming & Mod Directory Walk**: Fixed binary naming to prevent `.exe` appending to file extensions (e.g. `main.go.exe`), and safely handled root-level `go.mod` directory traversal.
- **Portable Workspace Detection**: Added `AXIOM_WORKSPACE` environment variable support with automatic fallback to `E:\workspace` or parent directory, removing hardcoded drive letter assumptions in CI/CD runners.
- **Watcher Event Scoping**: Used `-MessageData` dictionary in `watcher.ps1` event subscribers to ensure reliable background thread access to debounce timings and trigger commands.
- **Pin File Naming**: Corrected project pin filename from legacy `.vos-env` to `.axiom-env` in `env.ps1`.
- **Test Suite Counter Scope**: Fixed variable scoping bug in `tests/test-axiom.ps1` where `$script:Total` was not incremented, causing the summary banner to report `17 / 0 passed`.

---

## [1.0.0] - 2026-09-05

### Initial Release
- Universal cross-compiler for Go, Rust, Python, and Node with multi-target matrix.
- Ephemeral filesystem isolation sandbox engine (`create`, `exec`, `diff`, `commit`, `destroy`, `list`, `prune`).
- Named background process supervisor with PID registry and log tailing (`start`, `stop`, `restart`, `kill`, `logs`, `list`).
- Polyglot SDK & environment manager (`check`, `use`, `info`, `pin`).
- DPAPI encrypted secret store bridge and secret leak scanner (`vault`, `guard`).
- Taskfile.yml / axiom.tasks.json executor (`run`).
- FileSystemWatcher engine with debouncing (`watch`).
- Antigravity MCP bridge with machine-readable `--json` output (`mcp`).
