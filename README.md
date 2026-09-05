# ⚡ Axiom OS

> **Pseudo-OS Execution Kernel for Antigravity AI Workspaces**

Axiom OS is a lightweight virtual execution kernel built entirely on native PowerShell Core. It abstracts cross-compilation, process supervision, ephemeral sandboxing, secret management, and filesystem watching into a unified `axiom` command — with full JSON-RPC output for AI agent interoperability.

---

## ✨ Features

| Subsystem | Description |
|-----------|-------------|
| `compile` | Cross-compile Go, Rust, Python, Node to Linux/Windows/macOS/ARM — single command |
| `sandbox` | Ephemeral filesystem isolation — create, exec, diff, commit, destroy |
| `task`    | Named background process supervisor — start, stop, restart, tail logs |
| `env`     | Polyglot SDK manager — check, activate, pin toolchains per project |
| `vault`   | DPAPI-encrypted secret store bridge |
| `guard`   | Secret leak scanner + security policy enforcement |
| `run`     | Named task executor — reads `Taskfile.yml` or `axiom.tasks.json` |
| `watch`   | Filesystem event watcher with debounce + trigger commands |
| `mcp`     | Antigravity MCP bridge — structured JSON-RPC output for AI agents |

---

## 🚀 Quick Start

```powershell
# Cross-compile for multiple targets
axiom compile go/cmd/hello linux
axiom compile go/cmd/hello windows
axiom compile go/cmd/hello --all-targets    # linux + windows + darwin/arm64

# Ephemeral sandbox
axiom sandbox create backend/my-service --name test-box --ttl 2h
axiom sandbox exec test-box "python server.py --dry-run"
axiom sandbox diff test-box
axiom sandbox destroy test-box

# Background process manager
axiom task start "python server.py" --name api-server --restart-on-crash
axiom ps
axiom task logs api-server --follow
axiom task stop api-server

# Toolchain environment
axiom env check
axiom env use go
axiom env info --json

# Secrets
axiom vault get MY_API_KEY
axiom vault set MY_API_KEY "sk-..."
axiom guard scan

# Task runner
axiom run test
axiom run build --dry-run
axiom run --list

# Filesystem watcher
axiom watch "src/**/*.go" --run "axiom compile . linux" --debounce 500

# AI Agent mode (JSON output)
axiom compile go/cmd/hello linux --json
axiom env info --json
axiom mcp start
```

---

## 📁 Project Structure

```
axiom-os/
├── axiom.ps1                  ← CLI entrypoint
├── axiom.manifest.json        ← Project manifest
├── kernel/
│   └── kernel.ps1             ← Command router, context, output, JSON builder
├── modules/
│   ├── compiler.ps1           ← Cross-compilation (Go/Rust/Python/Node)
│   ├── sandbox.ps1            ← Ephemeral FS isolation
│   ├── process.ps1            ← Background task supervisor
│   ├── env.ps1                ← SDK & environment manager
│   ├── guard.ps1              ← Vault & secret scanner proxy
│   ├── runner.ps1             ← Taskfile.yml / axiom.tasks.json executor
│   ├── watcher.ps1            ← FileSystemWatcher engine
│   └── mcp.ps1                ← Antigravity MCP bridge
├── tests/
│   └── test-axiom.ps1         ← Local test suite (run before push)
└── .github/
    └── workflows/
        └── ci.yml             ← GitHub Actions: lint + test + compile + release
```

---

## 🎯 Cross-Compilation Targets

| Language | Linux | Windows | macOS (Darwin) |
|----------|-------|---------|----------------|
| **Go**   | `amd64`, `arm64` | `amd64` | `arm64` |
| **Rust** | `x86_64-unknown-linux-gnu` | `x86_64-pc-windows-msvc` | `aarch64-apple-darwin` |
| **Python** | `--bundle` (PyInstaller) | `--bundle` | — |
| **Node** | `npm run build` | `npm run build` | — |

Output lands in `E:\workspace\bin\<os>_<arch>\`.

---

## 🤖 Agent Integration (Antigravity)

All commands support `--json` for machine-readable output:

```json
{
  "axiom_version": "1.0.0",
  "command": "compile",
  "status": "success",
  "exit_code": 0,
  "output": {
    "artifact": "bin/linux_amd64/hello",
    "size_bytes": 2031616,
    "target_os": "linux",
    "target_arch": "amd64",
    "duration_ms": 1823
  },
  "errors": [],
  "warnings": [],
  "duration_ms": 1823
}
```

MCP tool definitions:
```powershell
axiom mcp schema    # prints full tool schema JSON for agent registration
axiom mcp start     # activates JSON-RPC bridge mode
```

---

## 🔧 `axiom.tasks.json` Format

```json
{
  "tasks": {
    "test": {
      "command": "go test ./...",
      "cwd": "go",
      "description": "Run all Go tests"
    },
    "build": {
      "command": "axiom compile go/cmd/hello --all-targets",
      "depends_on": ["test"],
      "description": "Cross-compile all targets"
    },
    "dev": {
      "command": "python server.py",
      "cwd": "backend/logistics-engine-core",
      "restart_on_crash": true
    }
  }
}
```

---

## 🧪 Running Tests Locally

```powershell
pwsh -ExecutionPolicy Bypass -File tests/test-axiom.ps1
```

Tests cover:
- Kernel context factory and session state
- Language auto-detection (Go/Rust/Python/Node/unknown)
- JSON output schema validation
- Compiler dry-run (no actual build needed)
- Sandbox full lifecycle (create → diff → destroy)
- Environment check
- Entrypoint smoke tests (`--version`, `--help`, `env check`)

---

## ⚙️ CI/CD Pipeline

GitHub Actions on every push to `main` / `develop`:

1. **Lint** — PSScriptAnalyzer on all `.ps1` files
2. **Test** — Full test suite on `windows-latest`
3. **Compile Smoke** — Go cross-compile dry-run (linux + windows) + real Linux binary build
4. **Release** — Auto-creates GitHub Release on `main` push (only when version bumped)

---

## 📋 Requirements

- **PowerShell 7+** (`pwsh`)
- **Go** (for Go compilation) — provided by `E:\workspace\sdks\go\`
- **Rust + rustup** (optional, for Rust compilation)
- **Python 3.8+** (optional, for Python bundling)
- **Node.js** (optional, for Node builds)

---

## 📖 Documentation

See [`WORKSPACE.md`](../../WORKSPACE.md) for the full workspace framework reference including how Axiom OS integrates with the `.vault/`, `.staging/`, `project-registry.json`, and `git-push.ps1` pipeline.

---

## 📄 License

MIT — © 2026 [pamidu1540](https://github.com/pamidu1540)
