#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — compiler.ps1
    Universal cross-compilation engine (Go, Rust, Python, Node).
#>

function Invoke-AxiomCompiler {
    param(
        [string]$Verb,          # path or OS target when used positionally
        [string[]]$Params,
        $Ctx
    )

    Axiom-Banner "Compile"

    # Parse positional: axiom compile <path> [os] [arch] [flags]
    # $Verb = first arg (path), $Params = rest
    $projectPath = $Verb
    $remaining   = [System.Collections.Generic.List[string]]($Params ?? @())

    # Extract flags
    $allTargets = $remaining.Remove("--all-targets")
    $bundle     = $remaining.Remove("--bundle")
    $dryRun     = $Ctx.DryRun -or $remaining.Remove("--dry-run")
    $outputDir  = $null
    $outIdx = $remaining.IndexOf("--output")
    if ($outIdx -ge 0 -and $outIdx + 1 -lt $remaining.Count) {
        $outputDir = $remaining[$outIdx + 1]
        $remaining.RemoveAt($outIdx + 1)
        $remaining.RemoveAt($outIdx)
    }

    # Remaining positionals: [os] [arch]
    $targetOs   = if ($remaining.Count -gt 0) { $remaining[0] } else { $null }
    $targetArch = if ($remaining.Count -gt 1) { $remaining[1] } else { "amd64" }

    # Resolve absolute project path
    $absPath = if ([System.IO.Path]::IsPathRooted($projectPath)) {
        $projectPath
    } else {
        Join-Path $Ctx.WorkspaceRoot $projectPath
    }

    if (-not (Test-Path $absPath)) {
        Axiom-Error "Path not found: $absPath"
        exit 1
    }

    # Detect language
    $lang = Get-ProjectLanguage -ProjectPath $absPath
    Axiom-Info "Path     : $absPath"
    Axiom-Info "Language : $lang"

    # Define target matrix
    $matrix = if ($allTargets) {
        @(
            @{Os="linux";   Arch="amd64"},
            @{Os="windows"; Arch="amd64"},
            @{Os="darwin";  Arch="arm64"}
        )
    } elseif ($targetOs) {
        @(@{Os=$targetOs; Arch=$targetArch})
    } else {
        # Default: compile for current host
        @(@{Os="windows"; Arch="amd64"})
    }

    $artifacts = @()

    foreach ($target in $matrix) {
        $os   = $target.Os
        $arch = $target.Arch
        $outDir = if ($outputDir) { $outputDir } else { Join-Path $Ctx.BinPath "${os}_${arch}" }
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null

        Axiom-Step "Target: $os/$arch  →  $outDir"

        $artifact = switch ($lang) {
            "go"     { Compile-Go     -Path $absPath -Os $os -Arch $arch -OutDir $outDir -DryRun $dryRun -Ctx $Ctx }
            "rust"   { Compile-Rust   -Path $absPath -Os $os -Arch $arch -OutDir $outDir -DryRun $dryRun -Ctx $Ctx }
            "python" { Compile-Python -Path $absPath -Os $os -Arch $arch -OutDir $outDir -DryRun $dryRun -Bundle $bundle -Ctx $Ctx }
            "node"   { Compile-Node   -Path $absPath -Os $os -Arch $arch -OutDir $outDir -DryRun $dryRun -Ctx $Ctx }
            default  {
                Axiom-Warn "Unknown language. Trying generic make/build..."
                $null
            }
        }
        if ($artifact) { $artifacts += $artifact }
    }

    if ($Ctx.Json) {
        Write-AxiomJson -Command "compile" -Status "success" -Output @{
            artifacts = $artifacts
            language  = $lang
            targets   = $matrix | ForEach-Object { "$($_.Os)/$($_.Arch)" }
        } -Ctx $Ctx
    } else {
        Write-Host ""
        Axiom-Success "Compilation complete. $($artifacts.Count) artifact(s) produced."
        $artifacts | ForEach-Object { Axiom-Info "  📦 $_" }
    }
}

# ─── Go ──────────────────────────────────────────────────────────────────────
function Compile-Go {
    param([string]$Path, [string]$Os, [string]$Arch, [string]$OutDir, [bool]$DryRun, $Ctx)

    $goExe = Join-Path $Ctx.WorkspaceRoot "sdks\go\bin\go.exe"
    if (-not (Test-Path $goExe)) { $goExe = "go" }

    $binName = (Split-Path $Path -Leaf) + $(if ($Os -eq "windows") { ".exe" } else { "" })
    $outFile = Join-Path $OutDir $binName

    # Find go.mod root
    $goModDir = $Path
    while ($goModDir -ne (Split-Path $goModDir -Parent) -and -not (Test-Path (Join-Path $goModDir "go.mod"))) {
        $goModDir = Split-Path $goModDir -Parent
    }

    $env:GOOS        = $Os
    $env:GOARCH      = $Arch
    $env:CGO_ENABLED = "0"

    $cmd = "$goExe build -o `"$outFile`" `"$Path`""
    Axiom-Step "CMD: GOOS=$Os GOARCH=$Arch CGO_ENABLED=0 $cmd"

    if ($DryRun) { Axiom-Dry $cmd; return $outFile }

    Push-Location $goModDir
    try {
        & $goExe build -o $outFile $Path 2>&1 | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
        if ($LASTEXITCODE -ne 0) { Axiom-Error "Go build failed"; exit 1 }
    } finally {
        Pop-Location
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }

    Axiom-Success "Built: $outFile ($([math]::Round((Get-Item $outFile).Length / 1KB)) KB)"
    return $outFile
}

# ─── Rust ─────────────────────────────────────────────────────────────────────
function Compile-Rust {
    param([string]$Path, [string]$Os, [string]$Arch, [string]$OutDir, [bool]$DryRun, $Ctx)

    $tripleMap = @{
        "linux/amd64"   = "x86_64-unknown-linux-gnu"
        "linux/arm64"   = "aarch64-unknown-linux-gnu"
        "windows/amd64" = "x86_64-pc-windows-msvc"
        "windows/arm64" = "aarch64-pc-windows-msvc"
        "darwin/amd64"  = "x86_64-apple-darwin"
        "darwin/arm64"  = "aarch64-apple-darwin"
    }
    $triple = $tripleMap["$Os/$Arch"]
    if (-not $triple) { Axiom-Error "Unsupported Rust target: $Os/$Arch"; return $null }

    $cmd = "cargo build --release --target $triple"
    Axiom-Step "CMD: $cmd"

    if ($DryRun) { Axiom-Dry $cmd; return "target/$triple/release/<binary>" }

    # Ensure target is installed
    rustup target add $triple 2>&1 | Out-Null

    Push-Location $Path
    try {
        & cargo build --release --target $triple 2>&1 | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
        if ($LASTEXITCODE -ne 0) { Axiom-Error "Cargo build failed"; exit 1 }
    } finally { Pop-Location }

    # Copy artifact to bin/
    $ext = if ($Os -eq "windows") { ".exe" } else { "" }
    $srcBin = Get-ChildItem (Join-Path $Path "target\$triple\release\") -File |
              Where-Object { $_.Extension -in @("", ".exe") -and $_.Name -notmatch '\.' } |
              Select-Object -First 1
    if ($srcBin) {
        $dest = Join-Path $OutDir ($srcBin.BaseName + $ext)
        Copy-Item $srcBin.FullName $dest -Force
        Axiom-Success "Built: $dest"
        return $dest
    }
    return $null
}

# ─── Python ──────────────────────────────────────────────────────────────────
function Compile-Python {
    param([string]$Path, [string]$Os, [string]$Arch, [string]$OutDir, [bool]$DryRun, [bool]$Bundle, $Ctx)

    if (-not $Bundle) {
        Axiom-Warn "Python requires --bundle flag for standalone binary. Checking syntax only..."
        $cmd = "python -m py_compile `"$Path`""
        Axiom-Step "CMD: $cmd"
        if (-not $DryRun) {
            python -m py_compile $Path
            if ($LASTEXITCODE -eq 0) { Axiom-Success "Syntax OK: $Path" }
        }
        return $Path
    }

    $cmd = "python -m PyInstaller --onefile --distpath `"$OutDir`" `"$Path`""
    Axiom-Step "CMD: $cmd"
    if ($DryRun) { Axiom-Dry $cmd; return $null }

    python -c "import PyInstaller; print('ok')" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Axiom-Warn "PyInstaller not installed. Install with: pip install pyinstaller"
        return $null
    }

    python -m PyInstaller --onefile --distpath $OutDir $Path
    if ($LASTEXITCODE -ne 0) { Axiom-Error "PyInstaller failed"; exit 1 }

    $outBin = Get-ChildItem $OutDir -File | Select-Object -First 1
    if ($outBin) { Axiom-Success "Bundle: $($outBin.FullName)" }
    return $outBin?.FullName
}

# ─── Node/TypeScript ─────────────────────────────────────────────────────────
function Compile-Node {
    param([string]$Path, [string]$Os, [string]$Arch, [string]$OutDir, [bool]$DryRun, $Ctx)

    $pkgJson = Join-Path $Path "package.json"
    if (Test-Path $pkgJson) {
        $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
        if ($pkg.scripts -and $pkg.scripts.build) {
            $cmd = "npm run build"
            Axiom-Step "CMD: $cmd (in $Path)"
            if ($DryRun) { Axiom-Dry $cmd; return $null }
            Push-Location $Path
            try { npm run build 2>&1 | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray } }
            finally { Pop-Location }
            Axiom-Success "Node build complete"
            return $OutDir
        }
    }
    Axiom-Warn "No 'build' script found in package.json"
    return $null
}

