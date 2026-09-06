#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — guard.ps1
    Security & vault bridge. Thin proxy to existing vault.ps1 and scan-secrets.ps1.
#>

function Invoke-AxiomGuard {
    param([string]$Verb, [string[]]$Params, $Ctx)

    switch ($Verb.ToLower()) {
        "vault"  { Guard-Vault  $Params $Ctx }
        "scan"   { Guard-Scan   $Params $Ctx }
        "check"  { Guard-Check  $Ctx }
        default  { Axiom-Error "Unknown guard verb: $Verb. Use: vault|scan|check" }
    }
}

function Guard-Vault {
    param([string[]]$Params, $Ctx)
    if (-not (Test-Path $Ctx.VaultScript)) {
        Axiom-Error "vault.ps1 not found at $($Ctx.VaultScript)"
        exit 1
    }
    $action = $Params[0]
    $rest   = if ($Params.Count -gt 1) { $Params[1..($Params.Count - 1)] } else { @() }

    Axiom-Info "Routing to vault: $action $($rest -join ' ')"
    & pwsh -ExecutionPolicy Bypass -File $Ctx.VaultScript -Action $action @rest
}

function Guard-Scan {
    param([string[]]$Params, $Ctx)
    Axiom-Banner "Secret Scan"

    if (-not (Test-Path $Ctx.SecretsScript)) {
        Axiom-Error "scan-secrets.ps1 not found at $($Ctx.SecretsScript)"
        exit 1
    }

    $paramList = [System.Collections.Generic.List[string]]($Params ?? @())
    $staged    = $paramList.Contains("--staged")
    $path      = $Ctx.WorkspaceRoot
    $pathIdx   = $paramList.IndexOf("--path")
    if ($pathIdx -ge 0 -and $pathIdx+1 -lt $paramList.Count) {
        $path = $paramList[$pathIdx+1]
    }

    Axiom-Info "Scanning: $path"
    if ($staged) { Axiom-Info "Mode: staged files only" }

    $scanArgs = @("-Path", $path)
    if ($staged) { $scanArgs += "-Staged" }

    & pwsh -ExecutionPolicy Bypass -File $Ctx.SecretsScript @scanArgs
    if ($LASTEXITCODE -ne 0) {
        if ($Ctx.Json) { Write-AxiomJson -Command "guard scan" -Status "fail" -ExitCode 1 -Errors @("Secrets detected") -Ctx $Ctx }
        exit 1
    }
    if ($Ctx.Json) { Write-AxiomJson -Command "guard scan" -Status "success" -Ctx $Ctx }
}

function Guard-Check {
    param($Ctx)
    Axiom-Banner "Security Policy Check"

    $policy = Join-Path $Ctx.WorkspaceRoot ".fortification\policy.json"
    if (Test-Path $policy) {
        $p = Get-Content $policy -Raw | ConvertFrom-Json
        Axiom-Info "Policy loaded: $policy"
        Axiom-Info "Version: $($p.version)"
    } else {
        Axiom-Warn ".fortification/policy.json not found."
    }

    Guard-Scan @() $Ctx

    # Check vault is not in git tracking
    $vaultTracked = git ls-files (Join-Path $Ctx.WorkspaceRoot ".vault") 2>$null
    if ($vaultTracked) {
        Axiom-Error "CRITICAL: .vault/ files are tracked by git! Run: git rm -r --cached .vault/"
    } else {
        Axiom-Success ".vault/ is not tracked by git ✅"
    }
    Axiom-Success "Security policy check complete."
}

