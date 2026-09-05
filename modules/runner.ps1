#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — runner.ps1
    Task file executor. Reads Taskfile.yml, axiom.tasks.json, or Makefile.
#>

function Invoke-AxiomRunner {
    param([string]$Verb, [string[]]$Params, $Ctx)

    $rest     = [System.Collections.Generic.List[string]]($Params ?? @())
    $list     = $rest.Remove("--list")
    $dryRun   = $Ctx.DryRun -or $rest.Remove("--dry-run")
    $watch    = $rest.Remove("--watch")
    $cfgIdx   = $rest.IndexOf("--config")
    $cfgFile  = if ($cfgIdx -ge 0 -and $cfgIdx+1 -lt $rest.Count) { $rest[$cfgIdx+1]; $rest.RemoveAt($cfgIdx+1); $rest.RemoveAt($cfgIdx) } else { $null }
    $taskName = $Verb

    $cwd  = (Get-Location).Path
    $tasks = Load-TaskFile -CfgFile $cfgFile -Cwd $cwd -Ctx $Ctx

    if ($list -or [string]::IsNullOrWhiteSpace($taskName)) {
        Axiom-Banner "Available Tasks"
        foreach ($t in $tasks.Keys) {
            $desc = if ($tasks[$t].description) { "  # $($tasks[$t].description)" } else { "" }
            Write-Host "  ➤  $t$desc" -ForegroundColor Cyan
        }
        return
    }

    if (-not $tasks.ContainsKey($taskName)) {
        Axiom-Error "Task '$taskName' not found. Run 'axiom run --list' to see available tasks."
        exit 1
    }

    $task = $tasks[$taskName]

    # Resolve depends_on
    if ($task.depends_on) {
        foreach ($dep in $task.depends_on) {
            Axiom-Step "Dependency: $dep"
            Invoke-AxiomRunner -Verb $dep -Args @() -Ctx $Ctx
        }
    }

    Axiom-Banner "Run: $taskName"
    $cmd = $task.command ?? $task.cmd ?? $task.run
    $taskCwd = if ($task.cwd) { Join-Path $Ctx.WorkspaceRoot $task.cwd } else { $cwd }

    Axiom-Info "Command : $cmd"
    Axiom-Info "CWD     : $taskCwd"

    if ($dryRun) { Axiom-Dry $cmd; return }

    Push-Location $taskCwd
    try {
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) { Axiom-Error "Task '$taskName' failed (exit $LASTEXITCODE)"; exit $LASTEXITCODE }
    } finally { Pop-Location }

    Axiom-Success "Task '$taskName' completed."
}

function Load-TaskFile {
    param([string]$CfgFile, [string]$Cwd, $Ctx)

    # Priority: explicit --config > axiom.tasks.json > Taskfile.yml > Makefile
    $candidates = @(
        $CfgFile,
        (Join-Path $Cwd "axiom.tasks.json"),
        (Join-Path $Cwd "Taskfile.yml"),
        (Join-Path $Cwd "Taskfile.yaml"),
        (Join-Path $Cwd "Makefile")
    ) | Where-Object { $_ -and (Test-Path $_) }

    if (-not $candidates) { Axiom-Error "No task file found. Create axiom.tasks.json or Taskfile.yml."; exit 1 }

    $file = $candidates[0]
    Axiom-Info "Loading tasks from: $file"

    $ext = [System.IO.Path]::GetExtension($file).ToLower()
    switch ($ext) {
        ".json" {
            $data = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
            return $data.tasks ?? $data
        }
        ".yml" {
            # Simple YAML parser for Taskfile format (handles basic cases)
            return Parse-Taskfile $file
        }
        ".yaml" { return Parse-Taskfile $file }
        "" {
            # Makefile — extract targets
            return Parse-Makefile $file
        }
    }
    return @{}
}

function Parse-Taskfile {
    param([string]$File)
    $tasks = @{}
    $content = Get-Content $File
    $currentTask = $null
    $inTasks = $false

    foreach ($line in $content) {
        if ($line -match '^tasks:') { $inTasks = $true; continue }
        if ($inTasks -and $line -match '^  (\w[\w-]+):') {
            $currentTask = $Matches[1]
            $tasks[$currentTask] = @{ command = ""; description = ""; cwd = "" }
        }
        if ($currentTask -and $line -match '^\s+cmds?:\s*\|\s*$') { continue }
        if ($currentTask -and $line -match '^\s+-\s+(.+)$') {
            $tasks[$currentTask].command += $Matches[1] + " && "
        }
        if ($currentTask -and $line -match '^\s+desc:\s+(.+)$') {
            $tasks[$currentTask].description = $Matches[1].Trim('"','')
        }
    }
    # trim trailing &&
    foreach ($t in $tasks.Keys) {
        $tasks[$t].command = $tasks[$t].command.TrimEnd(" && ")
    }
    return $tasks
}

function Parse-Makefile {
    param([string]$File)
    $tasks = @{}
    Get-Content $File | Where-Object { $_ -match '^([a-zA-Z_-]+):' } | ForEach-Object {
        $t = $Matches[1]
        $tasks[$t] = @{ command = "make $t"; description = "Makefile target" }
    }
    return $tasks
}

