#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — Pseudo-OS Execution Kernel for Antigravity AI Workspaces.

.DESCRIPTION
    Axiom OS is a lightweight virtual execution kernel that provides a unified
    CLI interface over native PowerShell for cross-compilation, sandboxing,
    process supervision, secret management, and AI agent interoperability.

    Usage: axiom <subsystem> <verb> [args] [--json] [--dry-run]

.EXAMPLE
    axiom compile go/cmd/hello linux
    axiom compile go/cmd/hello windows --dry-run
    axiom compile go/cmd/hello --all-targets
    axiom sandbox create backend/my-service --name test-box
    axiom sandbox exec test-box "python server.py --help"
    axiom task start "python server.py" --name api-server
    axiom ps
    axiom task logs api-server --follow
    axiom env check
    axiom vault get API_KEY
    axiom run test
    axiom watch "src/**/*.go" --run "axiom compile . linux"
    axiom mcp start
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Subsystem,

    [Parameter(Position = 1)]
    [string]$Verb,

    [Parameter(Position = 2, ValueFromRemainingArguments)]
    [string[]]$Args,

    [switch]$Json,
    [switch]$DryRun,
    [switch]$Version,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$AxiomVersion = "1.0.0"
$WorkspaceRoot = "E:\workspace"
$AxiomRoot = Join-Path $WorkspaceRoot "scripts\axiom-os"
$ModulesPath = Join-Path $AxiomRoot "modules"

# Load kernel
. (Join-Path $AxiomRoot "kernel\kernel.ps1")

# Version flag
if ($Version) {
    Write-Host "Axiom OS v$AxiomVersion" -ForegroundColor Magenta
    Write-Host "Antigravity Pseudo-OS Execution Kernel" -ForegroundColor Gray
    exit 0
}

# Help flag or no subsystem
if ($Help -or [string]::IsNullOrWhiteSpace($Subsystem)) {
    Invoke-AxiomHelp -Subsystem $Verb
    exit 0
}

# Dispatch to subsystem
$ctx = New-AxiomContext -Json:$Json -DryRun:$DryRun -WorkspaceRoot $WorkspaceRoot

switch ($Subsystem.ToLower()) {
    "compile"  { . (Join-Path $ModulesPath "compiler.ps1");  Invoke-AxiomCompiler  -Verb $Verb -Args $Args -Ctx $ctx }
    "sandbox"  { . (Join-Path $ModulesPath "sandbox.ps1");   Invoke-AxiomSandbox   -Verb $Verb -Args $Args -Ctx $ctx }
    "task"     { . (Join-Path $ModulesPath "process.ps1");   Invoke-AxiomProcess   -Verb $Verb -Args $Args -Ctx $ctx }
    "ps"       { . (Join-Path $ModulesPath "process.ps1");   Invoke-AxiomProcess   -Verb "list" -Args $Args -Ctx $ctx }
    "env"      { . (Join-Path $ModulesPath "env.ps1");       Invoke-AxiomEnv       -Verb $Verb -Args $Args -Ctx $ctx }
    "vault"    { . (Join-Path $ModulesPath "guard.ps1");     Invoke-AxiomGuard     -Verb "vault" -Args (@($Verb) + $Args) -Ctx $ctx }
    "guard"    { . (Join-Path $ModulesPath "guard.ps1");     Invoke-AxiomGuard     -Verb $Verb -Args $Args -Ctx $ctx }
    "run"      { . (Join-Path $ModulesPath "runner.ps1");    Invoke-AxiomRunner    -Verb $Verb -Args $Args -Ctx $ctx }
    "watch"    { . (Join-Path $ModulesPath "watcher.ps1");   Invoke-AxiomWatcher   -Verb $Verb -Args $Args -Ctx $ctx }
    "mcp"      { . (Join-Path $ModulesPath "mcp.ps1");       Invoke-AxiomMcp       -Verb $Verb -Args $Args -Ctx $ctx }
    "help"     { Invoke-AxiomHelp -Subsystem $Verb }
    "version"  { Write-Host "Axiom OS v$AxiomVersion" -ForegroundColor Magenta }
    default    {
        Axiom-Error "Unknown subsystem '$Subsystem'. Run 'axiom help' for usage."
        exit 1
    }
}
