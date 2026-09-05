#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — env.ps1
    SDK & toolchain environment manager. Inspired by mise/rtx.
#>

function Invoke-AxiomEnv {
    param([string]$Verb, [string[]]$Params, $Ctx)

    switch ($Verb.ToLower()) {
        "check" { Env-Check $Ctx }
        "use"   { Env-Use   $Params $Ctx }
        "info"  { Env-Info  $Ctx }
        "pin"   { Env-Pin   $Params $Ctx }
        default { Axiom-Error "Unknown env verb: $Verb. Use: check|use|info|pin" }
    }
}

function Env-Check {
    param($Ctx)
    Axiom-Banner "Environment Check"

    $checks = @(
        @{ Name = "Go";     Test = { $env:GOROOT = (Join-Path $Ctx.WorkspaceRoot "sdks\go"); & (Join-Path $Ctx.WorkspaceRoot "sdks\go\bin\go.exe") version 2>$null }; Key = "GOROOT"; Val = (Join-Path $Ctx.WorkspaceRoot "sdks\go") },
        @{ Name = "Java";   Test = { & (Join-Path $Ctx.WorkspaceRoot "sdks\jdk21\bin\java.exe") -version 2>&1 | Select-Object -First 1 }; Key = "JAVA_HOME"; Val = (Join-Path $Ctx.WorkspaceRoot "sdks\jdk21") },
        @{ Name = "Python"; Test = { python --version 2>$null }; Key = ""; Val = "" },
        @{ Name = "Rust";   Test = { rustc --version 2>$null }; Key = ""; Val = "" },
        @{ Name = "Node";   Test = { node --version 2>$null }; Key = ""; Val = "" },
        @{ Name = "npm";    Test = { npm --version 2>$null }; Key = ""; Val = "" }
    )

    $results = @()
    foreach ($c in $checks) {
        $out  = & $c.Test 2>$null
        $ok   = $LASTEXITCODE -eq 0 -and $out
        $ver  = if ($ok) { "$out".Trim() } else { "(not found)" }
        $icon = if ($ok) { "✅" } else { "❌" }
        $loc  = if ($c.Val) { " → $($c.Key): $($c.Val)" } else { "" }
        Write-Host "  $icon $($c.Name.PadRight(10)) $ver$loc" -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
        $results += @{ tool = $c.Name; version = $ver; ok = $ok }
    }

    if ($Ctx.Json) { Write-AxiomJson -Command "env check" -Output @{ tools = $results } -Ctx $Ctx }
}

function Env-Use {
    param([string[]]$Params, $Ctx)
    Axiom-Banner "Environment Activate"
    $tool = $Params[0]

    switch ($tool.ToLower()) {
        "go" {
            $goRoot = Join-Path $Ctx.WorkspaceRoot "sdks\go"
            $env:GOROOT = $goRoot
            $env:GOPATH = Join-Path $Ctx.WorkspaceRoot "go"
            $env:Path   = "$goRoot\bin;$env:Path"
            Axiom-Success "Go environment activated"
            Axiom-Info "GOROOT = $goRoot"
            Axiom-Info "GOPATH = $($env:GOPATH)"
        }
        "python" {
            $venv = Join-Path $Ctx.WorkspaceRoot "python\.venv"
            if (Test-Path $venv) {
                & (Join-Path $venv "Scripts\Activate.ps1")
                Axiom-Success "Python venv activated: $venv"
            } else { Axiom-Warn "No venv at $venv. Create with: python -m venv python/.venv" }
        }
        "jdk21" {
            $jdk = Join-Path $Ctx.WorkspaceRoot "sdks\jdk21"
            $env:JAVA_HOME = $jdk
            $env:Path      = "$jdk\bin;$env:Path"
            Axiom-Success "JDK21 activated — JAVA_HOME=$jdk"
        }
        default { Axiom-Error "Unknown SDK: $tool. Supported: go, python, jdk21" }
    }
}

function Env-Info {
    param($Ctx)
    Axiom-Banner "Environment Info"

    $info = [ordered]@{
        workspace_root = $Ctx.WorkspaceRoot
        goroot  = $env:GOROOT
        gopath  = $env:GOPATH
        java_home = $env:JAVA_HOME
        python  = (python --version 2>$null)
        node    = (node --version 2>$null)
        path_entries = ($env:Path -split ";") | Where-Object { $_ -like "*workspace*" }
    }

    if ($Ctx.Json) {
        Write-AxiomJson -Command "env info" -Output $info -Ctx $Ctx
    } else {
        $info.GetEnumerator() | ForEach-Object { Axiom-Info "$($_.Key.PadRight(16)): $($_.Value)" }
    }
}

function Env-Pin {
    param([string[]]$Params, $Ctx)
    $sdk  = $Params[0]
    $path = if ($Params.Count -gt 1) { Join-Path $Ctx.WorkspaceRoot $Params[1] } else { (Get-Location).Path }

    $pinFile = Join-Path $path ".vos-env"
    @{ sdk = $sdk; workspace = $Ctx.WorkspaceRoot } | ConvertTo-Json | Set-Content $pinFile -Encoding UTF8
    Axiom-Success "Pinned '$sdk' for project at $path  →  $pinFile"
}

