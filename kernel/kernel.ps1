#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS Kernel — Command dispatcher, context factory, output helpers.
#>

$AxiomVersion = "1.1.0"

# ─── Context Object ────────────────────────────────────────────────────────────
function New-AxiomContext {
    param(
        [string]$WorkspaceRoot = "",
        [switch]$Json,
        [switch]$DryRun
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = if ($env:AXIOM_WORKSPACE) { $env:AXIOM_WORKSPACE } elseif (Test-Path "E:\workspace") { "E:\workspace" } else { (Get-Location).Path }
    }
    $ctx = [PSCustomObject]@{
        WorkspaceRoot = $WorkspaceRoot
        StagingPath   = Join-Path $WorkspaceRoot ".staging"
        SandboxPath   = Join-Path $WorkspaceRoot ".staging\sandboxes"
        TasksPath     = Join-Path $WorkspaceRoot ".staging\tasks"
        BinPath       = Join-Path $WorkspaceRoot "bin"
        VaultScript   = Join-Path $WorkspaceRoot "scripts\vault.ps1"
        SecretsScript = Join-Path $WorkspaceRoot "scripts\scan-secrets.ps1"
        RegistryPath  = Join-Path $WorkspaceRoot "project-registry.json"
        SessionFile   = Join-Path $WorkspaceRoot ".staging\.axiom-session.json"
        Json          = $Json.IsPresent
        DryRun        = $DryRun.IsPresent
        StartTime     = [System.Diagnostics.Stopwatch]::StartNew()
    }

    # Ensure core dirs exist
    foreach ($d in @($ctx.StagingPath, $ctx.SandboxPath, $ctx.TasksPath, $ctx.BinPath)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    return $ctx
}

# ─── Output Helpers ────────────────────────────────────────────────────────────
function Axiom-Info    { param([string]$Msg) Write-Host "  ℹ  $Msg" -ForegroundColor Cyan }
function Axiom-Success { param([string]$Msg) Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Axiom-Warn    { param([string]$Msg) Write-Host "  ⚠  $Msg" -ForegroundColor Yellow }
function Axiom-Error   { param([string]$Msg) Write-Host "  ❌ $Msg" -ForegroundColor Red }
function Axiom-Step    { param([string]$Msg) Write-Host "  ➤  $Msg" -ForegroundColor White }
function Axiom-Dry     { param([string]$Msg) Write-Host "  [DRY] $Msg" -ForegroundColor DarkGray }

function Axiom-Banner {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ══════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "   ⚡ Axiom OS — $Title" -ForegroundColor Magenta
    Write-Host "  ══════════════════════════════════════" -ForegroundColor Magenta
    Write-Host ""
}

# ─── JSON Response Builder ──────────────────────────────────────────────────────
function Write-AxiomJson {
    param(
        [string]$Command,
        [string]$Status = "success",
        [int]$ExitCode = 0,
        [hashtable]$Output = @{},
        [string[]]$Errors = @(),
        [string[]]$Warnings = @(),
        $Ctx
    )
    $elapsed = if ($Ctx) { [math]::Round($Ctx.StartTime.Elapsed.TotalMilliseconds) } else { 0 }
    $result = [ordered]@{
        axiom_version = $AxiomVersion
        command       = $Command
        status        = $Status
        exit_code     = $ExitCode
        output        = $Output
        errors        = $Errors
        warnings      = $Warnings
        duration_ms   = $elapsed
    }
    Write-Output ($result | ConvertTo-Json -Depth 6)
}

# ─── Session State ──────────────────────────────────────────────────────────────
function Get-AxiomSession {
    param($Ctx)
    if (Test-Path $Ctx.SessionFile) {
        try { return Get-Content $Ctx.SessionFile -Raw | ConvertFrom-Json }
        catch { $null }
    }
    return [PSCustomObject]@{
        session_id       = "axiom-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        active_sandboxes = @()
        running_tasks    = @()
        workspace_root   = $Ctx.WorkspaceRoot
        last_command     = ""
    }
}

function Save-AxiomSession {
    param($Session, $Ctx)
    $Session | ConvertTo-Json -Depth 4 | Set-Content $Ctx.SessionFile -Encoding UTF8
}

# ─── Language Detector ──────────────────────────────────────────────────────────
function Get-ProjectLanguage {
    param([string]$ProjectPath)
    $p = $ProjectPath
    if (Test-Path (Join-Path $p "go.mod"))           { return "go" }
    if (Test-Path (Join-Path $p "Cargo.toml"))        { return "rust" }
    if ((Test-Path (Join-Path $p "pyproject.toml")) -or
        (Test-Path (Join-Path $p "requirements.txt")) -or
        (Test-Path (Join-Path $p "setup.py")) -or
        (Test-Path (Join-Path $p "pytest.ini")))      { return "python" }
    if (Test-Path (Join-Path $p "package.json"))      { return "node" }
    # Walk up to find marker files (e.g. go/cmd/hello finds go/go.mod)
    $walk = $p
    for ($i = 0; $i -lt 5; $i++) {
        $walk = Split-Path $walk -Parent
        if (-not $walk -or $walk -eq (Split-Path $walk -Parent)) { break }
        if (Test-Path (Join-Path $walk "go.mod"))     { return "go" }
        if (Test-Path (Join-Path $walk "Cargo.toml")) { return "rust" }
        if ((Test-Path (Join-Path $walk "pyproject.toml")) -or
            (Test-Path (Join-Path $walk "requirements.txt")) -or
            (Test-Path (Join-Path $walk "setup.py")) -or
            (Test-Path (Join-Path $walk "pytest.ini"))) { return "python" }
        if (Test-Path (Join-Path $walk "package.json")) { return "node" }
    }
    # Single file extension fallback
    if ($p -match '\.go$')   { return "go" }
    if ($p -match '\.rs$')   { return "rust" }
    if ($p -match '\.py$')   { return "python" }
    if ($p -match '\.(ts|js)$') { return "node" }
    return "unknown"
}

# ─── Help ───────────────────────────────────────────────────────────────────────
function Invoke-AxiomHelp {
    param([string]$Subsystem)

    $help = @{
        "" = @"

  ⚡ Axiom OS v$AxiomVersion — Pseudo-OS Execution Kernel
  ─────────────────────────────────────────────────────
  USAGE:  axiom <subsystem> <verb> [args] [--json] [--dry-run]

  SUBSYSTEMS:
    compile   Cross-compile projects to Linux/Windows/macOS/ARM
    sandbox   Create and manage ephemeral isolated workspaces
    task      Background process supervisor (start/stop/restart/logs)
    ps        List all running tasks (alias for 'task list')
    env       SDK and toolchain environment manager
    vault     Encrypted secret store (proxy to .vault/)
    guard     Security scanner and policy enforcement
    run       Execute named tasks from Taskfile.yml / axiom.tasks.json
    watch     Filesystem watcher with trigger commands
    mcp       Antigravity MCP bridge (JSON-RPC agent mode)

  GLOBAL FLAGS:
    --json      Output structured JSON (for AI agent consumption)
    --dry-run   Show commands without executing
    --version   Print version
    --help      Show this help

  EXAMPLES:
    axiom compile go/cmd/hello linux
    axiom compile rust windows --dry-run
    axiom compile go/cmd/hello --all-targets
    axiom sandbox create backend/my-svc --name test-box
    axiom task start "python server.py" --name api
    axiom ps
    axiom env check
    axiom vault get MY_SECRET
    axiom run test

  Run 'axiom help <subsystem>' for subsystem-specific help.
"@
        "compile" = @"
  axiom compile <path> [os] [arch] [options]

  TARGETS:  linux  windows  darwin
  ARCHS:    amd64  arm64  386
  OPTIONS:
    --all-targets    Build all OS/arch combinations
    --bundle         Create standalone binary (Python: PyInstaller)
    --output <dir>   Override output directory (default: bin/<os>_<arch>/)
    --dry-run        Show command without running

  EXAMPLES:
    axiom compile go/cmd/hello linux
    axiom compile go/cmd/hello windows amd64
    axiom compile go/cmd/hello --all-targets
    axiom compile rust linux
    axiom compile python/main.py linux --bundle
"@
        "sandbox" = @"
  axiom sandbox <verb> [options]

  VERBS:
    create <path>   Snapshot a project into .staging/sandboxes/<id>
    exec <id> <cmd> Run command inside the sandbox
    diff <id>       Show changes vs original
    commit <id>     Merge changes back to workspace
    destroy <id>    Delete sandbox
    list            List all sandboxes
    prune           Delete expired sandboxes

  OPTIONS:
    --name <name>   Custom sandbox name
    --ttl <dur>     Auto-expire (e.g. 2h, 30m)
"@
        "task" = @"
  axiom task <verb> [options]

  VERBS:
    start <cmd>     Start a named background task
    stop <name>     Stop a task
    restart <name>  Restart a task
    kill <name>     Force-kill a task
    logs <name>     Show task logs
    list            List all tasks

  OPTIONS (start):
    --name <name>          Named handle for the task
    --cwd <path>           Working directory
    --restart-on-crash     Auto-restart if task exits with error
    --follow               Stream logs live (with 'logs' verb)
    --tail <n>             Last N lines (with 'logs' verb)
"@
    }

    $key = if ($Subsystem -and $help.ContainsKey($Subsystem)) { $Subsystem } else { "" }
    Write-Host $help[$key]
}
