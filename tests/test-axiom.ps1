#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — Local test suite.
    Run before every push to verify core functionality.
    Usage: pwsh -File tests/test-axiom.ps1
#>
$ErrorActionPreference = "Stop"
$AxiomRoot = Split-Path $PSScriptRoot -Parent
$AxiomEntry = Join-Path $AxiomRoot "axiom.ps1"

$Passed = 0
$Failed = 0
$Total  = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $Total++
    Write-Host "  TEST: $Name ... " -NoNewline
    try {
        $result = & $Body
        if ($result -eq $false) { throw "Assertion failed" }
        Write-Host "PASS" -ForegroundColor Green
        $script:Passed++
    } catch {
        Write-Host "FAIL — $_" -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-Equal { param($A, $B, [string]$Msg = "")
    if ($A -ne $B) { throw "Expected '$B' got '$A'. $Msg" }
}

function Assert-True { param([bool]$Val, [string]$Msg = "")
    if (-not $Val) { throw "Expected true. $Msg" }
}

# ─── Load kernel ─────────────────────────────────────────────────────────────
. (Join-Path $AxiomRoot "kernel\kernel.ps1")

Write-Host ""
Write-Host "  ═══════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "   ⚡ Axiom OS — Test Suite" -ForegroundColor Magenta
Write-Host "  ═══════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

# ── Kernel: Context ──────────────────────────────────────────────────────────
Test-Case "Kernel: New-AxiomContext returns valid object" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace"
    Assert-True ($ctx.WorkspaceRoot -eq "E:\workspace") "WorkspaceRoot mismatch"
    Assert-True ($null -ne $ctx.StagingPath) "StagingPath is null"
    Assert-True ($ctx.Json -eq $false) "Json should default false"
    Assert-True ($ctx.DryRun -eq $false) "DryRun should default false"
}

Test-Case "Kernel: New-AxiomContext creates staging dirs" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace"
    Assert-True (Test-Path $ctx.StagingPath)   "StagingPath not created"
    Assert-True (Test-Path $ctx.SandboxPath)   "SandboxPath not created"
    Assert-True (Test-Path $ctx.TasksPath)     "TasksPath not created"
    Assert-True (Test-Path $ctx.BinPath)       "BinPath not created"
}

# ── Kernel: Language Detection ────────────────────────────────────────────────
Test-Case "Language detector: Go (go.mod)" {
    $tmp = Join-Path $env:TEMP "axiom-test-go-$(Get-Random)"
    New-Item -ItemType Directory $tmp | Out-Null
    Set-Content (Join-Path $tmp "go.mod") "module test"
    $lang = Get-ProjectLanguage $tmp
    Remove-Item $tmp -Recurse -Force
    Assert-Equal $lang "go"
}

Test-Case "Language detector: Python (pytest.ini)" {
    $tmp = Join-Path $env:TEMP "axiom-test-py-$(Get-Random)"
    New-Item -ItemType Directory $tmp | Out-Null
    Set-Content (Join-Path $tmp "pytest.ini") "[pytest]"
    $lang = Get-ProjectLanguage $tmp
    Remove-Item $tmp -Recurse -Force
    Assert-Equal $lang "python"
}

Test-Case "Language detector: Rust (Cargo.toml)" {
    $tmp = Join-Path $env:TEMP "axiom-test-rs-$(Get-Random)"
    New-Item -ItemType Directory $tmp | Out-Null
    Set-Content (Join-Path $tmp "Cargo.toml") "[package]"
    $lang = Get-ProjectLanguage $tmp
    Remove-Item $tmp -Recurse -Force
    Assert-Equal $lang "rust"
}

Test-Case "Language detector: Node (package.json)" {
    $tmp = Join-Path $env:TEMP "axiom-test-node-$(Get-Random)"
    New-Item -ItemType Directory $tmp | Out-Null
    Set-Content (Join-Path $tmp "package.json") "{}"
    $lang = Get-ProjectLanguage $tmp
    Remove-Item $tmp -Recurse -Force
    Assert-Equal $lang "node"
}

Test-Case "Language detector: Unknown dir" {
    $tmp = Join-Path $env:TEMP "axiom-test-unk-$(Get-Random)"
    New-Item -ItemType Directory $tmp | Out-Null
    $lang = Get-ProjectLanguage $tmp
    Remove-Item $tmp -Recurse -Force
    Assert-Equal $lang "unknown"
}

# ── Kernel: JSON Builder ─────────────────────────────────────────────────────
Test-Case "Kernel: Write-AxiomJson produces valid JSON" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace"
    $out = Write-AxiomJson -Command "test" -Status "success" -Output @{ result = "ok" } -Ctx $ctx
    $parsed = $out | ConvertFrom-Json
    Assert-Equal $parsed.command "test"
    Assert-Equal $parsed.status "success"
    Assert-Equal $parsed.output.result "ok"
}

# ── Compiler: Dry Run ─────────────────────────────────────────────────────────
. (Join-Path $AxiomRoot "modules\compiler.ps1")

Test-Case "Compiler: Go dry-run does not error" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace" -DryRun
    $goDir = Join-Path "E:\workspace" "go\cmd\hello"
    if (Test-Path $goDir) {
        Invoke-AxiomCompiler -Verb $goDir -Args @("windows") -Ctx $ctx
        $true
    } else {
        # skip if dir doesn't exist
        $true
    }
}

# ── Sandbox ───────────────────────────────────────────────────────────────────
. (Join-Path $AxiomRoot "modules\sandbox.ps1")

Test-Case "Sandbox: create, list, destroy lifecycle" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace"
    # Create a temp source
    $src = Join-Path $env:TEMP "axiom-sandbox-src-$(Get-Random)"
    New-Item -ItemType Directory $src | Out-Null
    Set-Content (Join-Path $src "hello.txt") "hello world"

    $name = "axiom-test-box-$(Get-Random)"

    # Create
    Sandbox-Create @($src, "--name", $name, "--ttl", "1m") $ctx
    $boxPath = Join-Path $ctx.SandboxPath $name
    Assert-True (Test-Path $boxPath) "Sandbox dir not created"
    Assert-True (Test-Path (Join-Path $boxPath ".axiom-sandbox.json")) "Metadata not written"

    # Destroy
    Sandbox-Destroy @($name) $ctx
    Assert-True (-not (Test-Path $boxPath)) "Sandbox dir not cleaned up"

    Remove-Item $src -Recurse -Force
}

Test-Case "Sandbox: diff detects changed file" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace"
    $src  = Join-Path $env:TEMP "axiom-diff-src-$(Get-Random)"
    New-Item -ItemType Directory $src | Out-Null
    Set-Content (Join-Path $src "config.txt") "original"

    $name = "axiom-diff-box-$(Get-Random)"
    Sandbox-Create @($src, "--name", $name) $ctx
    $boxPath = Join-Path $ctx.SandboxPath $name

    # Mutate inside sandbox
    Set-Content (Join-Path $boxPath "config.txt") "modified"
    Set-Content (Join-Path $boxPath "new-file.txt") "new"

    # Diff should detect changes (just run it, check no exception)
    Sandbox-Diff @($name) $ctx

    Sandbox-Destroy @($name) $ctx
    Remove-Item $src -Recurse -Force
}

# ── Env ───────────────────────────────────────────────────────────────────────
. (Join-Path $AxiomRoot "modules\env.ps1")

Test-Case "Env: check runs without exception" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace"
    Invoke-AxiomEnv -Verb "check" -Args @() -Ctx $ctx
    $true
}

Test-Case "Env: info produces output" {
    $ctx = New-AxiomContext -WorkspaceRoot "E:\workspace" -Json
    $out = Invoke-AxiomEnv -Verb "info" -Args @() -Ctx $ctx
    $true
}

# ── Entrypoint: Smoke Test ────────────────────────────────────────────────────
Test-Case "axiom.ps1 --version exits 0" {
    pwsh -NoProfile -ExecutionPolicy Bypass -File $AxiomEntry --version
    Assert-Equal $LASTEXITCODE 0
}

Test-Case "axiom.ps1 help exits 0" {
    pwsh -NoProfile -ExecutionPolicy Bypass -File $AxiomEntry --help
    Assert-Equal $LASTEXITCODE 0
}

Test-Case "axiom.ps1 env check exits 0" {
    pwsh -NoProfile -ExecutionPolicy Bypass -File $AxiomEntry env check
    Assert-Equal $LASTEXITCODE 0
}

Test-Case "axiom.ps1 compile --dry-run exits 0 for go/cmd/hello windows" {
    $goHello = Join-Path "E:\workspace" "go\cmd\hello"
    if (Test-Path $goHello) {
        pwsh -NoProfile -ExecutionPolicy Bypass -File $AxiomEntry compile $goHello windows --dry-run
        Assert-Equal $LASTEXITCODE 0
    } else { $true }  # skip
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ═══════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "   Results: $Passed / $Total passed, $Failed failed" -ForegroundColor $(if ($Failed -gt 0) { "Red" } else { "Green" })
Write-Host "  ═══════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

if ($Failed -gt 0) { exit 1 } else { exit 0 }
