function Invoke-AxiomRunner {
    param([string]$Verb,[string[]]$Params,$Ctx)
    $tokens=[Collections.Generic.List[string]]::new(); foreach ($item in (@($Verb)+$Params)) { if ($item) { $tokens.Add($item) } }
    $list=$tokens.Remove('--list'); $dry=$Ctx.DryRun -or $tokens.Remove('--dry-run')
    if ($tokens.Contains('--watch')) { throw 'Use axiom watch to rerun a named task on file changes.' }
    $config=$null; $index=$tokens.IndexOf('--config')
    if ($index -ge 0) {
        if ($index+1 -ge $tokens.Count) { throw '--config requires a task file.' }
        $config=$tokens[$index+1]; $tokens.RemoveAt($index+1); $tokens.RemoveAt($index)
        if (-not [IO.Path]::IsPathRooted($config)) { $config=Join-Path $Ctx.WorkspaceRoot $config }
        $config=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $config
    }
    if ($tokens.Count -gt 1) { throw 'Specify a single task name.' }
    $name=if ($tokens.Count) { $tokens[0] } else { '' }
    if (-not $config) {
        foreach ($candidate in @('axiom.tasks.json','Taskfile.yml','Taskfile.yaml','Makefile')) {
            $file=Join-Path $Ctx.WorkspaceRoot $candidate
            if (Test-Path -LiteralPath $file) { $config=$file; break }
        }
    }
    if (-not $config -or -not (Test-Path -LiteralPath $config -PathType Leaf)) { throw 'No task file found. Create axiom.tasks.json, or install Task/make for their formats.' }
    if ([IO.Path]::GetExtension($config) -ne '.json') {
        $toolName=if ([IO.Path]::GetFileName($config) -eq 'Makefile') { 'make' } else { 'task' }
        $arguments=if ($toolName -eq 'make') { @('-f',$config) } else { @('--taskfile',$config) }
        if ($list -or -not $name) {
            if ($toolName -eq 'make') { throw 'For Makefiles, specify a target; automatic listing is not supported.' }
            $arguments+='--list-all'
        } else { $arguments+=$name }
        if ($dry) { $arguments+=if ($toolName -eq 'make') { '-n' } else { '--dry' } }
        $tool=(Get-Command $toolName -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $result=Invoke-AxiomNative $tool $arguments (Split-Path $config)
        if ($result.exit_code -ne 0) { throw "Task runner failed: $($result.stderr)" }
        Write-AxiomResult 'run' @{ task=$name; stdout=$result.stdout; dry_run=$dry; runner=$toolName } $Ctx 'External task runner finished'
        return
    }
    $data=Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    $tasks=if ($data.ContainsKey('tasks')) { $data.tasks } else { $data }
    if ($list -or -not $name) { Write-AxiomResult 'run list' @{ tasks=@($tasks.Keys | Sort-Object) } $Ctx 'Available tasks'; return }
    $active=[Collections.Generic.HashSet[string]]::new(); $done=[Collections.Generic.HashSet[string]]::new(); $results=[Collections.Generic.List[object]]::new()
    function Invoke-AxiomNamedTask {
        param([string]$TaskName)
        if ($done.Contains($TaskName)) { return }
        if (-not $tasks.ContainsKey($TaskName)) { throw "Unknown task '$TaskName'." }
        if (-not $active.Add($TaskName)) { throw "Circular task dependency involving '$TaskName'." }
        $task=$tasks[$TaskName]
        foreach ($dependency in $task.depends_on) { Invoke-AxiomNamedTask $dependency }
        $command=$task.command ?? $task.cmd ?? $task.run
        if ($command -isnot [string] -or -not $command.Trim()) { throw "Task '$TaskName' requires a command string." }
        $cwd=if ($task.cwd) { Join-Path (Split-Path $config) $task.cwd } else { Split-Path $config }
        $cwd=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $cwd -AllowRoot
        if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { throw "Working directory missing for '$TaskName'." }
        if ($dry) { $results.Add(@{ task=$TaskName; cwd=$cwd; dry_run=$true }) }
        else {
            $result=Invoke-AxiomCommand $command $cwd
            if ($result.exit_code -ne 0) { throw "Task '$TaskName' failed ($($result.exit_code)): $($result.stderr)" }
            $results.Add(@{ task=$TaskName; stdout=$result.stdout; stderr=$result.stderr; exit_code=$result.exit_code })
        }
        $active.Remove($TaskName) | Out-Null; $done.Add($TaskName) | Out-Null
    }
    Invoke-AxiomNamedTask $name
    Write-AxiomResult 'run' @{ tasks=$results.ToArray(); dry_run=$dry } $Ctx 'Task graph completed'
}
