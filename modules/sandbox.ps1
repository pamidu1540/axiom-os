function Get-AxiomProjectFiles {
    param([string]$Root,[switch]$Scan)
    $skip = @('.git','.vault','.secrets','.staging','.venv','.tools','.cache','.build','.pytest_cache','.ruff_cache','node_modules','bin','dist','build','target','__pycache__')
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) {
            if ($item.Name -notin $skip) { Get-AxiomProjectFiles $item.FullName -Scan:$Scan }
        } elseif ($Scan -or ($item.Name -notlike '.env*' -and $item.Extension -notin @('.key','.pem','.enc','.secret') -and $item.Name -ne '.axiom-sandbox.json')) { $item }
    }
}

function Get-SandboxMeta {
    param([string]$SandboxDir)
    $path=Join-Path $SandboxDir '.axiom-sandbox.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Sandbox metadata is missing.' }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
}

function Invoke-AxiomSandbox {
    param([string]$Verb, [string[]]$Params, $Ctx)
    $null=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $Ctx.SandboxPath
    if ($Verb -eq 'list') {
        $boxes=@(Get-ChildItem -LiteralPath $Ctx.SandboxPath -Directory -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object { $meta=Get-SandboxMeta $_.FullName; @{ name=$_.Name; source=$meta.source_abs; expires=$meta.ttl_expires; path=$_.FullName } })
        Write-AxiomResult 'sandbox list' @{ sandboxes=$boxes } $Ctx 'Project snapshots'
        return
    }
    if ($Verb -eq 'prune') {
        $removed=@()
        foreach ($box in Get-ChildItem -LiteralPath $Ctx.SandboxPath -Directory -ErrorAction SilentlyContinue) {
            $path=Resolve-AxiomChildPath $Ctx.SandboxPath $box.Name
            $meta=Get-SandboxMeta $path
            $expires=if ($meta.ttl_expires -is [DateTime]) { [DateTimeOffset]$meta.ttl_expires } else { [DateTimeOffset]::Parse([string]$meta.ttl_expires,[Globalization.CultureInfo]::InvariantCulture) }
            if ($expires -lt [DateTimeOffset]::Now) {
                if (-not $Ctx.DryRun) { Remove-Item -LiteralPath $path -Recurse -Force }
                $removed += $box.Name
            }
        }
        Write-AxiomResult 'sandbox prune' @{ sandboxes=$removed; dry_run=$Ctx.DryRun } $Ctx 'Expired snapshots'
        return
    }
    if ($Verb -eq 'create') {
        if (-not $Params.Count) { throw 'Specify a project directory.' }
        $source=if ([IO.Path]::IsPathRooted($Params[0])) { $Params[0] } else { Join-Path $Ctx.WorkspaceRoot $Params[0] }
        $source=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $source -AllowRoot
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'The source must be an existing project directory inside the workspace.' }
        if ($source.StartsWith($Ctx.StagingPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cannot snapshot workspace state directories.' }
        $name='snapshot-' + [guid]::NewGuid().ToString('N').Substring(0,10)
        $ttl='4h'
        for ($i=1; $i -lt $Params.Count; $i++) {
            if ($Params[$i] -notin @('--name','--ttl') -or $i+1 -ge $Params.Count) { throw 'Expected --name <name> or --ttl <minutes>m|<hours>h.' }
            if ($Params[$i] -eq '--name') { $name=$Params[++$i] } else { $ttl=$Params[++$i] }
        }
        if ($ttl -notmatch '^([1-9][0-9]{0,3})(m|h)$') { throw 'TTL must be a positive duration such as 30m or 4h.' }
        $minutes=[int]$Matches[1] * $(if ($Matches[2] -eq 'h') { 60 } else { 1 })
        $box=Resolve-AxiomChildPath $Ctx.SandboxPath $name
        if (Test-Path -LiteralPath $box) { throw "Snapshot '$name' already exists." }
        $hashes=@{}
        if (-not $Ctx.DryRun) {
            New-Item -ItemType Directory -Path $box -Force | Out-Null
            foreach ($file in Get-AxiomProjectFiles $source) {
                $relative=[IO.Path]::GetRelativePath($source,$file.FullName)
                $destination=Assert-AxiomPathWithin $box (Join-Path $box $relative)
                New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination
                $hashes[$relative]=(Get-FileHash -LiteralPath $file.FullName).Hash
            }
            Save-AxiomData (Join-Path $box '.axiom-sandbox.json') @{ id=$name; source_abs=$source; created_at=[DateTimeOffset]::Now.ToString('o'); ttl_expires=[DateTimeOffset]::Now.AddMinutes($minutes).ToString('o'); base_hashes=$hashes }
        }
        Write-AxiomResult 'sandbox create' @{ id=$name; path=$box; dry_run=$Ctx.DryRun } $Ctx 'Project snapshot prepared'
        return
    }
    if (-not $Params.Count) { throw 'Specify a snapshot name.' }
    $name=$Params[0]
    $box=Resolve-AxiomChildPath $Ctx.SandboxPath $name
    if (-not (Test-Path -LiteralPath $box -PathType Container)) { throw "Snapshot '$name' does not exist." }
    $meta=Get-SandboxMeta $box
    $source=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $meta.source_abs -AllowRoot
    switch ($Verb) {
        destroy {
            if (-not $Ctx.DryRun) { Remove-Item -LiteralPath $box -Recurse -Force }
            Write-AxiomResult 'sandbox destroy' @{ id=$name; dry_run=$Ctx.DryRun } $Ctx 'Snapshot removed'
        }
        exec {
            if ($Params.Count -lt 2) { throw 'Specify a trusted command to execute.' }
            $command=$Params[1..($Params.Count-1)] -join ' '
            if ($Ctx.DryRun) { Write-AxiomResult 'sandbox exec' @{ id=$name; dry_run=$true } $Ctx 'Command preview'; return }
            $result=Invoke-AxiomCommand $command $box
            if ($result.exit_code -ne 0) { throw "Snapshot command failed ($($result.exit_code)): $($result.stderr)" }
            Write-AxiomResult 'sandbox exec' @{ id=$name; stdout=$result.stdout; stderr=$result.stderr } $Ctx 'Command finished'
        }
        diff {
            $changes=@(); $seen=@{}
            foreach ($file in Get-AxiomProjectFiles $box) {
                $relative=[IO.Path]::GetRelativePath($box,$file.FullName); $seen[$relative]=$true
                $original=Assert-AxiomPathWithin $source (Join-Path $source $relative)
                if (-not (Test-Path -LiteralPath $original)) { $changes+=@{ path=$relative; status='added' } }
                elseif ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $original).Hash) { $changes+=@{ path=$relative; status='changed' } }
            }
            foreach ($file in Get-AxiomProjectFiles $source) {
                $relative=[IO.Path]::GetRelativePath($source,$file.FullName)
                if (-not $seen.ContainsKey($relative)) { $changes+=@{ path=$relative; status='deleted' } }
            }
            Write-AxiomResult 'sandbox diff' @{ changes=$changes } $Ctx 'Snapshot comparison'
        }
        commit {
            if ($meta.base_hashes -isnot [Collections.IDictionary]) { throw 'This snapshot predates conflict tracking. Create a new snapshot before committing.' }
            if ($Ctx.DryRun) { Write-AxiomResult 'sandbox commit' @{ id=$name; dry_run=$true } $Ctx 'Merge preview'; return }
            $writes=@()
            foreach ($file in Get-AxiomProjectFiles $box) {
                $relative=[IO.Path]::GetRelativePath($box,$file.FullName)
                $hash=(Get-FileHash -LiteralPath $file.FullName).Hash
                if ($meta.base_hashes.ContainsKey($relative) -and $hash -eq $meta.base_hashes[$relative]) { continue }
                $destination=Assert-AxiomPathWithin $source (Join-Path $source $relative)
                if (Test-Path -LiteralPath $destination) {
                    $current=(Get-FileHash -LiteralPath $destination).Hash
                    if (-not $meta.base_hashes.ContainsKey($relative) -or ($current -ne $meta.base_hashes[$relative] -and $current -ne $hash)) { throw "Source changed since snapshot: $relative. Resolve it before committing." }
                } elseif ($meta.base_hashes.ContainsKey($relative)) { throw "Source file was deleted since snapshot: $relative." }
                $writes+=@{ source=$file.FullName; destination=$destination }
            }
            if ($Params -notcontains '--yes' -and $Params -notcontains '-y' -and $Params -notcontains '-Force') {
                if ((Read-Host "Copy $($writes.Count) added/changed files into the source? [y/N]") -notmatch '^[yY]$') { return }
            }
            foreach ($write in $writes) {
                New-Item -ItemType Directory -Path (Split-Path $write.destination) -Force | Out-Null
                Copy-Item -LiteralPath $write.source -Destination $write.destination -Force
            }
            Write-AxiomResult 'sandbox commit' @{ files_written=$writes.Count; deletions_applied=$false } $Ctx 'Added and changed files merged'
        }
        default { throw 'Unknown sandbox verb. Use create, exec, diff, commit, destroy, list, or prune.' }
    }
}
