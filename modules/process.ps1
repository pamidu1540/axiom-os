function Get-PidRegistry {
    param($Ctx)
    $file=Join-Path $Ctx.TasksPath 'pids.json'
    if (Test-Path -LiteralPath $file) { return Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable }
    @{}
}
function Save-PidRegistry { param($Registry,$Ctx) Save-AxiomData (Join-Path $Ctx.TasksPath 'pids.json') $Registry }

function Get-AxiomOwnedProcess {
    param($Entry)
    $process=Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue
    if ($process -and $Entry.start_ticks -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$Entry.start_ticks) { return $process }
    return $null
}

function Invoke-AxiomProcess {
    param([string]$Verb,[string[]]$Params,$Ctx)
    $null=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $Ctx.TasksPath
    $registry=Get-PidRegistry $Ctx
    if ($Verb -eq 'list') {
        $items=@(foreach ($entry in $registry.Values) { $copy=@{} + $entry; $copy.status=if (Get-AxiomOwnedProcess $entry) { 'running' } else { 'stopped' }; $copy })
        Write-AxiomResult 'ps' @{ tasks=$items } $Ctx 'Managed tasks'
        return
    }
    if ($Verb -eq 'start') {
        if (-not $IsWindows) { throw 'Managed background tasks currently require Windows. Finite project tasks use axiom run on other platforms.' }
        $tokens=[Collections.Generic.List[string]]::new(); foreach ($item in $Params) { $tokens.Add($item) }
        $name='task-' + [guid]::NewGuid().ToString('N').Substring(0,8); $cwd=$Ctx.WorkspaceRoot
        foreach ($flag in @('--name','--cwd')) {
            $index=$tokens.IndexOf($flag)
            if ($index -ge 0) {
                if ($index+1 -ge $tokens.Count) { throw "$flag requires a value." }
                if ($flag -eq '--name') { $name=$tokens[$index+1] } else { $cwd=$tokens[$index+1] }
                $tokens.RemoveAt($index+1); $tokens.RemoveAt($index)
            }
        }
        if ($tokens.Contains('--restart-on-crash')) { throw 'Automatic crash restart is not implemented. Use task restart <name>.' }
        $log=Resolve-AxiomChildPath $Ctx.TasksPath $name
        $log += '.log'
        $log=Assert-AxiomPathWithin $Ctx.TasksPath $log
        $null=Assert-AxiomPathWithin $Ctx.TasksPath "$log.err"
        $cwd=if ([IO.Path]::IsPathRooted($cwd)) { [IO.Path]::GetFullPath($cwd) } else { Join-Path $Ctx.WorkspaceRoot $cwd }
        $cwd=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $cwd -AllowRoot
        if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { throw 'Task working directory does not exist.' }
        $command=$tokens -join ' '
        if (-not $command.Trim()) { throw 'Provide a trusted command in quotes.' }
        if ($registry.ContainsKey($name) -and (Get-AxiomOwnedProcess $registry[$name])) { throw "Task '$name' is already running." }
        if ($Ctx.DryRun) { Write-AxiomResult 'task start' @{ name=$name; cwd=$cwd; dry_run=$true } $Ctx 'Task preview'; return }
        New-Item -ItemType Directory -Path $Ctx.TasksPath -Force | Out-Null
        $escapedLog=$log.Replace("'","''"); $escapedError="$log.err".Replace("'","''")
        $code='$ErrorActionPreference="Stop"; $global:LASTEXITCODE=0; try { & { ' + $command + " } 1> '$escapedLog' 2> '$escapedError' 3>&1 4>&1 5>&1 6>&1; " + 'exit $global:LASTEXITCODE } catch { [IO.File]::AppendAllText(' + "'$escapedError', " + '$_.Exception.Message); exit 1 }'
        $arguments=@('-NoProfile','-NonInteractive','-OutputFormat','Text','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
        # The child writes its own files; parent-owned output pipes would keep short CLI calls alive.
        $start=@{ FilePath=(Join-Path $PSHOME 'pwsh.exe'); ArgumentList=$arguments; WorkingDirectory=$cwd; PassThru=$true }
        if ($IsWindows) { $start.WindowStyle='Hidden' }
        $process=Start-Process @start
        $entry=@{ name=$name; command=$command; cwd=$cwd; pid=$process.Id; start_ticks=$process.StartTime.ToUniversalTime().Ticks.ToString(); started_at=[DateTimeOffset]::Now.ToString('o'); log_file=$log; status='running' }
        $registry[$name]=$entry
        try { Save-PidRegistry $registry $Ctx }
        catch { if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(5000) | Out-Null }; throw }
        Write-AxiomResult 'task start' $entry $Ctx 'Task started'
        return
    }
    if (-not $Params.Count) { throw 'Specify a task name.' }
    $name=$Params[0]; Assert-AxiomName $name
    if (-not $registry.ContainsKey($name)) { throw "Task '$name' was not found." }
    $entry=$registry[$name]
    switch ($Verb) {
        { $_ -in @('stop','kill','restart') } {
            if ($Ctx.DryRun) { Write-AxiomResult "task $Verb" @{ name=$name; dry_run=$true } $Ctx 'Task preview'; return }
            $process=Get-AxiomOwnedProcess $entry
            if ($process) { $process.Kill($true); $process.WaitForExit(5000) | Out-Null }
            if ($Verb -eq 'kill') { $registry.Remove($name) } else { $entry.status='stopped' }
            Save-PidRegistry $registry $Ctx
            if ($Verb -eq 'restart') { Invoke-AxiomProcess 'start' @($entry.command,'--name',$name,'--cwd',$entry.cwd) $Ctx }
            else { Write-AxiomResult "task $Verb" @{ name=$name; stopped=[bool]$process } $Ctx 'Task stopped' }
        }
        logs {
            $log=Assert-AxiomPathWithin $Ctx.TasksPath $entry.log_file
            if (-not (Test-Path -LiteralPath $log)) { throw 'No task log is available.' }
            $tail=20
            $index=[Array]::IndexOf($Params,'--tail')
            if ($index -ge 0) {
                if ($index+1 -ge $Params.Count -or -not [int]::TryParse($Params[$index+1],[ref]$tail) -or $tail -lt 1 -or $tail -gt 10000) { throw '--tail requires a number from 1 to 10000.' }
            }
            if ($Params -contains '--follow') {
                if ($Ctx.Json) { throw '--follow cannot be combined with --json.' }
                Get-Content -LiteralPath $log -Tail $tail -Wait
            } else {
                $errorLog=if (Test-Path -LiteralPath "$log.err") { @(Get-Content -LiteralPath "$log.err" -Tail $tail) } else { @() }
                Write-AxiomResult 'task logs' @{ stdout=@(Get-Content -LiteralPath $log -Tail $tail); stderr=$errorLog } $Ctx 'Task output'
            }
        }
        default { throw 'Unknown task verb. Use start, stop, restart, kill, logs, or list.' }
    }
}
