#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — sandbox.ps1
    Ephemeral filesystem isolation engine.
#>

function Invoke-AxiomSandbox {
    param([string]$Verb, [string[]]$Params, $Ctx)

    switch ($Verb.ToLower()) {
        "create"  { Sandbox-Create  $Params $Ctx }
        "exec"    { Sandbox-Exec    $Params $Ctx }
        "diff"    { Sandbox-Diff    $Params $Ctx }
        "commit"  { Sandbox-Commit  $Params $Ctx }
        "destroy" { Sandbox-Destroy $Params $Ctx }
        "list"    { Sandbox-List    $Ctx }
        "prune"   { Sandbox-Prune   $Ctx }
        default   { Axiom-Error "Unknown sandbox verb: $Verb. Use: create|exec|diff|commit|destroy|list|prune" }
    }
}

function Get-SandboxMeta { param([string]$SandboxDir)
    $meta = Join-Path $SandboxDir ".axiom-sandbox.json"
    if (Test-Path $meta) { return Get-Content $meta -Raw | ConvertFrom-Json }
    return $null
}

function Sandbox-Create {
    param([string[]]$Params, $Ctx)
    Axiom-Banner "Sandbox Create"

    $sourcePath = $Params[0]
    $rest       = $Params[1..$Params.Count]
    $nameIdx    = $rest.IndexOf("--name")
    $customName = if ($nameIdx -ge 0 -and $nameIdx+1 -lt $rest.Count) { $rest[$nameIdx+1] } else { $null }
    $ttlIdx     = $rest.IndexOf("--ttl")
    $ttl        = if ($ttlIdx -ge 0 -and $ttlIdx+1 -lt $rest.Count) { $rest[$ttlIdx+1] } else { "4h" }

    $absSource = if ([System.IO.Path]::IsPathRooted($sourcePath)) {
        $sourcePath
    } else { Join-Path $Ctx.WorkspaceRoot $sourcePath }

    if (-not (Test-Path $absSource)) { Axiom-Error "Source not found: $absSource"; exit 1 }

    $id      = if ($customName) { $customName } else { "$(Split-Path $absSource -Leaf)-$(Get-Date -Format 'yyyyMMddHHmmss')" }
    $boxPath = Join-Path $Ctx.SandboxPath $id

    if (Test-Path $boxPath) { Axiom-Error "Sandbox '$id' already exists. Choose a different --name."; exit 1 }

    Axiom-Info "Source  : $absSource"
    Axiom-Info "Sandbox : $boxPath"
    Axiom-Info "TTL     : $ttl"

    if ($Ctx.DryRun) { Axiom-Dry "Would copy $absSource → $boxPath"; return }

    Copy-Item -Path $absSource -Destination $boxPath -Recurse -Force

    # Write metadata
    $expires = (Get-Date).AddHours(4)  # simple default; parse TTL string for real use
    if ($ttl -match '^(\d+)h$') { $expires = (Get-Date).AddHours([int]$Matches[1]) }
    if ($ttl -match '^(\d+)m$') { $expires = (Get-Date).AddMinutes([int]$Matches[1]) }

    $meta = @{
        id           = $id
        source       = $sourcePath
        source_abs   = $absSource
        sandbox_path = $boxPath
        created_at   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
        ttl_expires  = $expires.ToString("yyyy-MM-ddTHH:mm:ssK")
        status       = "active"
    }
    $meta | ConvertTo-Json | Set-Content (Join-Path $boxPath ".axiom-sandbox.json") -Encoding UTF8

    Axiom-Success "Sandbox '$id' created at $boxPath"

    if ($Ctx.Json) {
        Write-AxiomJson -Command "sandbox create" -Output @{ id = $id; path = $boxPath } -Ctx $Ctx
    }
}

function Sandbox-Exec {
    param([string[]]$Params, $Ctx)
    Axiom-Banner "Sandbox Exec"

    $id      = $Params[0]
    $command = $Params[1..$Params.Count] -join " "
    $boxPath = Join-Path $Ctx.SandboxPath $id

    if (-not (Test-Path $boxPath)) { Axiom-Error "Sandbox '$id' not found. Run 'axiom sandbox list'."; exit 1 }

    Axiom-Info "Sandbox : $boxPath"
    Axiom-Info "Command : $command"

    if ($Ctx.DryRun) { Axiom-Dry "Would run in sandbox: $command"; return }

    Push-Location $boxPath
    try {
        Invoke-Expression $command
        if ($LASTEXITCODE -ne 0) { Axiom-Warn "Command exited with code $LASTEXITCODE" }
    } finally { Pop-Location }
}

function Sandbox-Diff {
    param([string[]]$Params, $Ctx)
    Axiom-Banner "Sandbox Diff"

    $id      = $Params[0]
    $boxPath = Join-Path $Ctx.SandboxPath $id
    if (-not (Test-Path $boxPath)) { Axiom-Error "Sandbox '$id' not found."; exit 1 }

    $meta = Get-SandboxMeta $boxPath
    if (-not $meta) { Axiom-Error "No metadata found for sandbox '$id'."; exit 1 }

    Axiom-Info "Comparing sandbox '$id' vs original source..."

    $changed = 0
    Get-ChildItem $boxPath -Recurse -File |
        Where-Object { $_.Name -ne ".axiom-sandbox.json" } |
        ForEach-Object {
            $rel  = $_.FullName.Substring($boxPath.Length + 1)
            $orig = Join-Path $meta.source_abs $rel
            if (-not (Test-Path $orig)) {
                Write-Host "  [ADDED]   $rel" -ForegroundColor Green; $changed++
            } elseif ((Get-FileHash $_.FullName).Hash -ne (Get-FileHash $orig).Hash) {
                Write-Host "  [CHANGED] $rel" -ForegroundColor Yellow; $changed++
            }
        }
    Get-ChildItem $meta.source_abs -Recurse -File | ForEach-Object {
        $rel  = $_.FullName.Substring($meta.source_abs.Length + 1)
        $sand = Join-Path $boxPath $rel
        if (-not (Test-Path $sand)) { Write-Host "  [DELETED] $rel" -ForegroundColor Red; $changed++ }
    }

    if ($changed -eq 0) { Axiom-Success "No changes detected." } else { Axiom-Warn "$changed file(s) differ." }
}

function Sandbox-Commit {
    param([string[]]$Params, $Ctx)
    Axiom-Banner "Sandbox Commit"

    $id      = $Params[0]
    $boxPath = Join-Path $Ctx.SandboxPath $id
    if (-not (Test-Path $boxPath)) { Axiom-Error "Sandbox '$id' not found."; exit 1 }

    $meta = Get-SandboxMeta $boxPath
    $dest = $meta.source_abs

    Axiom-Warn "This will overwrite $dest with sandbox contents."
    $confirm = Read-Host "Confirm? [y/N]"
    if ($confirm -notmatch '^[Yy]') { Axiom-Info "Aborted."; return }

    if ($Ctx.DryRun) { Axiom-Dry "Would copy $boxPath → $dest"; return }

    Get-ChildItem $boxPath -Recurse -File |
        Where-Object { $_.Name -ne ".axiom-sandbox.json" } |
        ForEach-Object {
            $rel  = $_.FullName.Substring($boxPath.Length + 1)
            $out  = Join-Path $dest $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
            Copy-Item $_.FullName $out -Force
        }
    Axiom-Success "Committed sandbox '$id' → $dest"
}

function Sandbox-Destroy {
    param([string[]]$Params, $Ctx)
    $id      = $Params[0]
    $boxPath = Join-Path $Ctx.SandboxPath $id
    if (-not (Test-Path $boxPath)) { Axiom-Error "Sandbox '$id' not found."; exit 1 }
    if ($Ctx.DryRun) { Axiom-Dry "Would delete $boxPath"; return }
    Remove-Item $boxPath -Recurse -Force
    Axiom-Success "Sandbox '$id' destroyed."
}

function Sandbox-List {
    param($Ctx)
    Axiom-Banner "Sandbox List"
    $boxes = Get-ChildItem $Ctx.SandboxPath -Directory -ErrorAction SilentlyContinue
    if (-not $boxes) { Axiom-Info "No sandboxes found."; return }

    Write-Host "  NAME                           SOURCE                        STATUS    EXPIRES" -ForegroundColor White
    Write-Host "  ────────────────────────────── ───────────────────────────── ───────── ─────────────────────" -ForegroundColor DarkGray
    foreach ($b in $boxes) {
        $meta   = Get-SandboxMeta $b.FullName
        $name   = $b.Name.PadRight(30)
        $src    = if ($meta) { $meta.source.PadRight(29) } else { "unknown".PadRight(29) }
        $status = if ($meta) { $meta.status } else { "unknown" }
        $exp    = if ($meta) { $meta.ttl_expires } else { "—" }
        $color  = if ($status -eq "active") { "Green" } else { "Yellow" }
        Write-Host "  $name  $src  $status  $exp" -ForegroundColor $color
    }
}

function Sandbox-Prune {
    param($Ctx)
    Axiom-Banner "Sandbox Prune"
    $boxes = Get-ChildItem $Ctx.SandboxPath -Directory -ErrorAction SilentlyContinue
    $pruned = 0
    foreach ($b in $boxes) {
        $meta = Get-SandboxMeta $b.FullName
        if ($meta -and $meta.ttl_expires) {
            $exp = [datetime]$meta.ttl_expires
            if ($exp -lt (Get-Date)) {
                Remove-Item $b.FullName -Recurse -Force
                Axiom-Info "Pruned expired sandbox: $($b.Name)"
                $pruned++
            }
        }
    }
    Axiom-Success "Pruned $pruned sandbox(es)."
}

