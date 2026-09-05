#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — process.ps1
    Background process supervisor. Named tasks, PID tracking, log tailing.
#>

function Get-PidRegistry {
    param($Ctx)
    $file = Join-Path $Ctx.TasksPath "pids.json"
    if (Test-Path $file) {
        try { return Get-Content $file -Raw | ConvertFrom-Json -AsHashtable }
        catch { return @{} }
    }
    return @{}
}

function Save-PidRegistry {
    param($Registry, $Ctx)
    $file = Join-Path $Ctx.TasksPath "pids.json"
    $Registry | ConvertTo-Json -Depth 4 | Set-Content $file -Encoding UTF8
}

function Invoke-AxiomProcess {
    param([string]$Verb, [string[]]$Params, $Ctx)

    switch ($Verb.ToLower()) {
        "start"   { Process-Start   $Params $Ctx }
        "stop"    { Process-Stop    $Params $Ctx }
        "restart" { Process-Restart $Params $Ctx }
        "kill"    { Process-Kill    $Params $Ctx }
        "logs"    { Process-Logs    $Params $Ctx }
        "list"    { Process-List    $Ctx }
        default   { Axiom-Error "Unknown task verb: $Verb. Use: start|stop|restart|kill|logs|list" }
    }
}

function Process-Start {
    param([string[]]$Params, $Ctx)
    Axiom-Banner "Task Start"

    $rest = [System.Collections.Generic.List[string]]($Params ?? @())

    # Extract --name
    $nameIdx = $rest.IndexOf("--name")
    $name    = if ($nameIdx -ge 0 -and $nameIdx+1 -lt $rest.Count) { $rest[$nameIdx+1]; $rest.RemoveAt($nameIdx+1); $rest.RemoveAt($nameIdx) } else { "task-$(Get-Date -Format 'HHmmss')" }

    # Extract --cwd
    $cwdIdx  = $rest.IndexOf("--cwd")
    $cwd     = if ($cwdIdx -ge 0 -and $cwdIdx+1 -lt $rest.Count) { $rest[$cwdIdx+1]; $rest.RemoveAt($cwdIdx+1); $rest.RemoveAt($cwdIdx) } else { $Ctx.WorkspaceRoot }

    $restartOnCrash = $rest.Remove("--restart-on-crash")
    $command        = ($rest -join " ").Trim()

    if ([string]::IsNullOrWhiteSpace($command)) { Axiom-Error "No command specified."; exit 1 }

    Axiom-Info "Name    : $name"
    Axiom-Info "Command : $command"
    Axiom-Info "CWD     : $cwd"

    if ($Ctx.DryRun) { Axiom-Dry "Would start background task '$name': $command"; return }

    $logFile = Join-Path $Ctx.TasksPath "$name.log"
    $reg = Get-PidRegistry $Ctx

    if ($reg.ContainsKey($name) -and $reg[$name].status -eq "running") {
        $procId = $reg[$name].pid
        if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
            Axiom-Warn "Task '$name' is already running (PID $procId). Stop it first."
            return
        }
    }

    # Start process, redirect output to log file
    $proc = Start-Process pwsh -ArgumentList @("-NoProfile", "-Command", "Set-Location '$cwd'; $command") `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError  "$logFile.err" `
        -WindowStyle Hidden -PassThru

    $entry = @{
        name             = $name
        command          = $command
        cwd              = $cwd
        pid              = $proc.Id
        status           = "running"
        started_at       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
        log_file         = $logFile
        restart_on_crash = $restartOnCrash
        restarts         = 0
    }
    $reg[$name] = $entry
    Save-PidRegistry $reg $Ctx

    Axiom-Success "Started '$name' (PID $($proc.Id)) → log: $logFile"
    if ($Ctx.Json) { Write-AxiomJson -Command "task start" -Output $entry -Ctx $Ctx }
}

function Process-Stop {
    param([string[]]$Params, $Ctx)
    $name = $Params[0]
    $reg  = Get-PidRegistry $Ctx
    if (-not $reg.ContainsKey($name)) { Axiom-Error "Task '$name' not found."; exit 1 }

    $procId = $reg[$name].pid
    Stop-Process -Id $procId -ErrorAction SilentlyContinue
    $reg[$name].status = "stopped"
    Save-PidRegistry $reg $Ctx
    Axiom-Success "Stopped '$name' (PID $procId)"
}

function Process-Restart {
    param([string[]]$Params, $Ctx)
    Process-Stop $Params $Ctx
    Start-Sleep 1
    $name = $Params[0]
    $reg  = Get-PidRegistry $Ctx
    if ($reg.ContainsKey($name)) {
        $e = $reg[$name]
        $newArgs = @($e.command, "--name", $name, "--cwd", $e.cwd)
        if ($e.restart_on_crash) { $newArgs += "--restart-on-crash" }
        Process-Start $newArgs $Ctx
    }
}

function Process-Kill {
    param([string[]]$Params, $Ctx)
    $name = $Params[0]
    $reg  = Get-PidRegistry $Ctx
    if (-not $reg.ContainsKey($name)) { Axiom-Error "Task '$name' not found."; exit 1 }
    $procId = $reg[$name].pid
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    $reg.Remove($name) | Out-Null
    Save-PidRegistry $reg $Ctx
    Axiom-Success "Killed and removed '$name'"
}

function Process-Logs {
    param([string[]]$Params, $Ctx)
    $rest    = [System.Collections.Generic.List[string]]($Params)
    $name    = $rest[0]; $rest.RemoveAt(0)
    $follow  = $rest.Remove("--follow")
    $tailIdx = $rest.IndexOf("--tail")
    $tail    = if ($tailIdx -ge 0 -and $tailIdx+1 -lt $rest.Count) { [int]$rest[$tailIdx+1] } else { 20 }

    $reg = Get-PidRegistry $Ctx
    if (-not $reg.ContainsKey($name)) { Axiom-Error "Task '$name' not found."; exit 1 }

    $logFile = $reg[$name].log_file
    if (-not (Test-Path $logFile)) { Axiom-Warn "No log file yet: $logFile"; return }

    if ($follow) {
        Axiom-Info "Streaming logs for '$name' (Ctrl+C to stop)..."
        Get-Content $logFile -Tail $tail -Wait
    } else {
        Get-Content $logFile -Tail $tail | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }
}

function Process-List {
    param($Ctx)
    Axiom-Banner "Running Tasks"
    $reg = Get-PidRegistry $Ctx
    if ($reg.Count -eq 0) { Axiom-Info "No tasks running."; return }

    Write-Host ("  {0,-18} {1,-7} {1,-10} {2,-22} {3}" -f "NAME","PID","STATUS","STARTED","COMMAND") -ForegroundColor White
    Write-Host "  ────────────────── ─────── ────────── ──────────────────────── ──────────────" -ForegroundColor DarkGray

    foreach ($name in $reg.Keys) {
        $e      = $reg[$name]
        $alive  = if ($e.pid -and (Get-Process -Id $e.pid -ErrorAction SilentlyContinue)) { "running" } else { "stopped" }
        $color  = if ($alive -eq "running") { "Green" } else { "Red" }
        $cmd    = if ($e.command.Length -gt 40) { $e.command.Substring(0,37) + "..." } else { $e.command }
        Write-Host ("  {0,-18} {1,-7} {2,-10} {3,-24} {4}" -f $name, $e.pid, $alive, $e.started_at, $cmd) -ForegroundColor $color
    }
    if ($Ctx.Json) {
        Write-AxiomJson -Command "ps" -Output @{ tasks = $reg } -Ctx $Ctx
    }
}

