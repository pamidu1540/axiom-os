function Invoke-AxiomWatcher {
    param([string]$Verb,[string[]]$Params,$Ctx)
    if ($Ctx.Json) { throw 'Watch is interactive; use a finite command with --json instead.' }
    if (-not $Verb) { throw 'Specify a file pattern.' }
    $index=[Array]::IndexOf($Params,'--run')
    if ($index -lt 0 -or $index+1 -ge $Params.Count) { throw '--run requires a quoted command.' }
    $command=$Params[$index+1]; $debounce=500; $index=[Array]::IndexOf($Params,'--debounce')
    if ($index -ge 0) {
        if ($index+1 -ge $Params.Count -or -not [int]::TryParse($Params[$index+1],[ref]$debounce) -or $debounce -lt 50 -or $debounce -gt 60000) { throw 'Debounce must be 50–60000 milliseconds.' }
    }
    $pattern=$Verb.Replace('\','/'); $prefix=@()
    foreach ($part in ($pattern -split '/')) { if ($part -match '[*?\[]') { break }; $prefix+=$part }
    $root=if ($prefix.Count) { Join-Path $Ctx.WorkspaceRoot ($prefix -join [IO.Path]::DirectorySeparatorChar) } else { $Ctx.WorkspaceRoot }
    if (Test-Path -LiteralPath $root -PathType Leaf) { $root=Split-Path $root }
    $root=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $root -AllowRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Watch directory does not exist.' }
    if ($Ctx.DryRun) { Write-AxiomResult 'watch' @{ root=$root; pattern=$pattern; dry_run=$true } $Ctx 'Watch preview'; return }
    $filter=($pattern -split '/')[-1]
    $watcher=[IO.FileSystemWatcher]::new($root,$filter)
    $watcher.IncludeSubdirectories=$pattern.Contains('**'); $watcher.NotifyFilter=[IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::FileName
    $prefixId='axiom-watch-' + [guid]::NewGuid().ToString('N')
    $ids=@('Changed','Created','Deleted','Renamed') | ForEach-Object { "$prefixId-$_" }
    try {
        $i=0; foreach ($eventName in @('Changed','Created','Deleted','Renamed')) { Register-ObjectEvent $watcher $eventName -SourceIdentifier $ids[$i++] | Out-Null }
        $watcher.EnableRaisingEvents=$true; $pending=$false; $last=[DateTime]::MinValue
        Write-Host "Watching $root ($filter). Press Ctrl+C to stop." -ForegroundColor Cyan
        while ($true) {
            foreach ($watchEvent in Get-Event -ErrorAction SilentlyContinue | Where-Object SourceIdentifier -In $ids) {
                $pending=$true; $last=[DateTime]::UtcNow; Remove-Event -EventIdentifier $watchEvent.EventIdentifier
            }
            if ($pending -and ([DateTime]::UtcNow-$last).TotalMilliseconds -ge $debounce) {
                $pending=$false; $result=Invoke-AxiomCommand $command $Ctx.WorkspaceRoot
                Write-Host $result.stdout
                if ($result.exit_code -ne 0) { Write-Warning "Trigger failed ($($result.exit_code)): $($result.stderr)" }
            }
            Start-Sleep -Milliseconds 50
        }
    } finally {
        foreach ($id in $ids) { Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue; Get-Event -SourceIdentifier $id -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue }
        $watcher.Dispose()
    }
}
