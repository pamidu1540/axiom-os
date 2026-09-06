#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — watcher.ps1
    Filesystem event watcher with debounce and trigger command.
#>

function Invoke-AxiomWatcher {
    param([string]$Verb, [string[]]$Params, $Ctx)
    # verb = glob pattern, Args contains --run <cmd> [--debounce <ms>]
    $glob      = $Verb
    $rest      = [System.Collections.Generic.List[string]]($Params ?? @())
    $runIdx    = $rest.IndexOf("--run")
    $triggerCmd = if ($runIdx -ge 0 -and $runIdx+1 -lt $rest.Count) { $rest[$runIdx+1] } else { $null }
    $debIdx    = $rest.IndexOf("--debounce")
    $debounce  = if ($debIdx -ge 0 -and $debIdx+1 -lt $rest.Count) { [int]$rest[$debIdx+1] } else { 500 }

    if (-not $triggerCmd) { Axiom-Error "Specify --run <command>"; exit 1 }

    # Resolve watch directory and filter from glob
    $parts     = $glob -replace '\\','/' -split '/'
    $watchDir  = $Ctx.WorkspaceRoot
    $filterPat = "*.*"

    # Find the non-glob prefix as base dir
    $nonGlob = ($parts | Where-Object { $_ -notmatch '\*' }) -join [System.IO.Path]::DirectorySeparatorChar
    $candidate = Join-Path $Ctx.WorkspaceRoot $nonGlob
    if (Test-Path $candidate -PathType Container) { $watchDir = $candidate }
    elseif (Test-Path (Split-Path $candidate) -PathType Container) { $watchDir = Split-Path $candidate }

    # Extract file filter
    $lastPart = $parts[-1]
    if ($lastPart -match '\*') { $filterPat = $lastPart }

    Axiom-Banner "Watch"
    Axiom-Info "Watching : $watchDir"
    Axiom-Info "Filter   : $filterPat"
    Axiom-Info "Trigger  : $triggerCmd"
    Axiom-Info "Debounce : ${debounce}ms"
    Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
    Write-Host ""

    if ($Ctx.DryRun) { Axiom-Dry "Would watch $watchDir/$filterPat and run: $triggerCmd"; return }

    $watcher = New-Object System.IO.FileSystemWatcher $watchDir, $filterPat
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents   = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName

    $script:lastRun = [datetime]::MinValue
    $eventData = @{ DebounceMs = $debounce; TriggerCmd = $triggerCmd }

    $action = {
        $path = $Event.SourceEventArgs.FullPath
        $now  = [datetime]::Now
        $data = $Event.MessageData
        $deb  = if ($data -and $data.DebounceMs) { $data.DebounceMs } else { 500 }
        $cmd  = if ($data -and $data.TriggerCmd) { $data.TriggerCmd } else { "" }

        if (($now - $script:lastRun).TotalMilliseconds -gt $deb) {
            $script:lastRun = $now
            Write-Host "  📁 Changed: $path" -ForegroundColor Yellow
            if ($cmd) {
                Write-Host "  ➤  Running: $cmd" -ForegroundColor Cyan
                Invoke-Expression $cmd
                Write-Host ""
            }
        }
    }

    Register-ObjectEvent $watcher "Changed" -Action $action -MessageData $eventData | Out-Null
    Register-ObjectEvent $watcher "Created" -Action $action -MessageData $eventData | Out-Null

    try {
        while ($true) { Start-Sleep 1 }
    } finally {
        $watcher.Dispose()
        Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
        Axiom-Info "Watcher stopped."
    }
}

