#Requires -Version 7.2
[CmdletBinding()]
param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'kernel/kernel.ps1')
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('axiom-tests-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $temporary "Workspace with spaces and 'quote"
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
$passed=0; $failed=0
$testProcesses=[Collections.Generic.List[Diagnostics.Process]]::new()
function Assert-True { param([bool]$Value,[string]$Message='Assertion failed') if (-not $Value) { throw $Message } }
function Assert-Equal { param($Actual,$Expected) if ($Actual -ne $Expected) { throw "Expected '$Expected', got '$Actual'." } }
function Test-Case {
    param([string]$Name,[scriptblock]$Body)
    try { & $Body | Out-Null; $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "FAIL $Name — $($_.Exception.Message)" -ForegroundColor Red }
}
function Invoke-TestCli {
    param([string[]]$Arguments,[switch]$AllowFailure)
    $runtime=Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $result=Invoke-AxiomNative $runtime (@('-NoProfile','-File',(Join-Path $root 'axiom.ps1'),'--workspace',$workspace)+$Arguments) $workspace 120
    if (-not $AllowFailure -and $result.exit_code -ne 0) { throw $result.stderr + $result.stdout }
    return $result
}
function Read-TestJson {
    param([string[]]$Arguments,[switch]$AllowFailure)
    $result=Invoke-TestCli ($Arguments + '--json') -AllowFailure:$AllowFailure
    $parsed=$result.stdout | ConvertFrom-Json
    Assert-Equal $parsed.exit_code $result.exit_code
    return $parsed
}
try {
    $project=Join-Path $workspace 'sample'
    New-Item -ItemType Directory -Path $project | Out-Null
    Set-Content -LiteralPath (Join-Path $project 'hello.txt') 'original'
    Set-Content -LiteralPath (Join-Path $project 'remove.txt') 'original'
    Set-Content -LiteralPath (Join-Path $project '.env') 'EXAMPLE_ONLY=placeholder'
    Set-Content -LiteralPath (Join-Path $project 'go.mod') "module example.test/hello`ngo 1.22"
    Set-Content -LiteralPath (Join-Path $project 'main.go') 'package main; import "fmt"; func main(){fmt.Println("axiom-test")}'

    Test-Case 'All source PowerShell parses' {
        $files=@(Get-Item (Join-Path $root 'axiom.ps1')) + @(Get-ChildItem (Join-Path $root 'kernel'),(Join-Path $root 'modules'),(Join-Path $root 'packaging'),$PSScriptRoot -Filter '*.ps1' -Recurse)
        foreach ($file in $files) {
            $tokens=$null; $errors=$null
            [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
            if ($errors.Count) { throw "$($file.Name): $($errors.Message -join '; ')" }
        }
    }
    Test-Case 'Version matches manifest and supports JSON' {
        $version=(Get-Content (Join-Path $root 'axiom.manifest.json') -Raw | ConvertFrom-Json).version
        Assert-Equal (Read-TestJson @('--version')).output.version $version
    }
    Test-Case 'Help and environment inspection do not create workspace state' {
        Invoke-TestCli @('--help') | Out-Null
        Assert-Equal (Read-TestJson @('env','info')).output.workspace_root $workspace
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace '.staging')))
    }
    Test-Case 'Unknown commands fail with one JSON response' {
        Assert-Equal (Read-TestJson @('unknown') -AllowFailure).status 'fail'
    }
    Test-Case 'Language detection and current host compile plan' {
        Assert-Equal (Get-ProjectLanguage $project) 'go'
        $plan=Read-TestJson @('compile','sample','--dry-run')
        Assert-Equal $plan.output.language 'go'
        Assert-True $plan.output.dry_run
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'bin')))
    }
    Test-Case 'Build planning preserves caller environment' {
        $saved=$env:GOOS; $env:GOOS='test-sentinel'
        try { Read-TestJson @('compile','sample','linux','--dry-run') | Out-Null; Assert-Equal $env:GOOS 'test-sentinel' }
        finally { $env:GOOS=$saved }
    }
    Test-Case 'Unsupported compile targets fail' {
        Assert-Equal (Read-TestJson @('compile','sample','invalid','--dry-run') -AllowFailure).status 'fail'
    }
    Test-Case 'Snapshot create skips private files' {
        $result=Read-TestJson @('sandbox','create','sample','--name','demo','--ttl','2h')
        Assert-True (Test-Path -LiteralPath (Join-Path $result.output.path 'hello.txt'))
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $result.output.path '.env')))
    }
    $box=Join-Path $workspace '.staging/sandboxes/demo'
    Test-Case 'Snapshot diff reports added, changed, and deleted files' {
        Set-Content -LiteralPath (Join-Path $box 'hello.txt') 'changed'
        Set-Content -LiteralPath (Join-Path $box 'added.txt') 'added'
        Remove-Item -LiteralPath (Join-Path $box 'remove.txt')
        $changes=(Read-TestJson @('sandbox','diff','demo')).output.changes
        Assert-True ('added' -in $changes.status -and 'changed' -in $changes.status -and 'deleted' -in $changes.status)
    }
    Test-Case 'Commit dry-run neither prompts nor changes files' {
        Read-TestJson @('sandbox','commit','demo','--dry-run') | Out-Null
        Assert-Equal (Get-Content -LiteralPath (Join-Path $project 'hello.txt') -Raw).Trim() 'original'
    }
    Test-Case 'Commit merges changes and preserves source deletions policy' {
        Read-TestJson @('sandbox','commit','demo','--yes') | Out-Null
        Assert-Equal (Get-Content -LiteralPath (Join-Path $project 'hello.txt') -Raw).Trim() 'changed'
        Assert-True (Test-Path -LiteralPath (Join-Path $project 'remove.txt'))
    }
    Test-Case 'Concurrent source changes block commit before writes' {
        Set-Content -LiteralPath (Join-Path $box 'hello.txt') 'snapshot-change'
        Set-Content -LiteralPath (Join-Path $project 'hello.txt') 'source-change'
        Assert-Equal (Read-TestJson @('sandbox','commit','demo','--yes') -AllowFailure).status 'fail'
        Assert-Equal (Get-Content -LiteralPath (Join-Path $project 'hello.txt') -Raw).Trim() 'source-change'
    }
    Test-Case 'Snapshot names reject traversal and device names' {
        foreach ($name in @('..','../sample','CON','a/b')) { Assert-Equal (Read-TestJson @('sandbox','destroy',$name) -AllowFailure).status 'fail' }
        Assert-True (Test-Path -LiteralPath $project)
    }
    Test-Case 'Snapshot list returns structured data' { Assert-Equal (Read-TestJson @('sandbox','list')).output.sandboxes[0].name 'demo' }
    Test-Case 'Prune dry-run preserves expired snapshots' {
        $metaPath=Join-Path $box '.axiom-sandbox.json'; $meta=Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json -AsHashtable
        $meta.ttl_expires=[DateTimeOffset]::Now.AddMinutes(-5).ToString('o'); Save-AxiomData $metaPath $meta
        Read-TestJson @('sandbox','prune','--dry-run') | Out-Null; Assert-True (Test-Path -LiteralPath $box)
        Read-TestJson @('sandbox','prune') | Out-Null; Assert-True (-not (Test-Path -LiteralPath $box))
    }
    Test-Case 'Snapshot of workspace avoids recursive state copying' {
        $result=Read-TestJson @('sandbox','create','.','--name','whole')
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $result.output.path '.staging')))
        Read-TestJson @('sandbox','destroy','whole') | Out-Null
    }
    if ($IsWindows) {
        Test-Case 'Junction traversal is rejected' {
            $junction=Join-Path $project 'redirect'
            New-Item -ItemType Junction -Path $junction -Target $temporary | Out-Null
            try { Assert-Equal (Read-TestJson @('sandbox','create','sample/redirect','--name','bad') -AllowFailure).status 'fail' }
            finally { Remove-Item -LiteralPath $junction -Force }
        }
    }
    Test-Case 'JSON task dependency graph runs in order' {
        Save-AxiomData (Join-Path $workspace 'axiom.tasks.json') @{tasks=@{first=@{command="Write-Output 'first'"};second=@{command="Write-Output 'second'";depends_on=@('first')}}}
        $result=Read-TestJson @('run','second')
        Assert-Equal ($result.output.tasks.task -join ',') 'first,second'
    }
    Test-Case 'Dependency dry-run has no side effects' {
        Save-AxiomData (Join-Path $workspace 'axiom.tasks.json') @{tasks=@{first=@{command="Set-Content marker.txt changed"};second=@{command="Write-Output 'second'";depends_on=@('first')}}}
        Read-TestJson @('run','second','--dry-run') | Out-Null
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace 'marker.txt')))
    }
    Test-Case 'Dependency cycles and failing commands fail cleanly' {
        Save-AxiomData (Join-Path $workspace 'axiom.tasks.json') @{tasks=@{a=@{command='Write-Output a';depends_on=@('b')};b=@{command='Write-Output b';depends_on=@('a')};fail=@{command='exit 7'}}}
        Assert-Equal (Read-TestJson @('run','a') -AllowFailure).status 'fail'
        Assert-Equal (Read-TestJson @('run','fail') -AllowFailure).status 'fail'
    }
    Test-Case 'Background process lifecycle and log paths with quotes' {
        $entry=(Read-TestJson @('task','start','Write-Output ready; Start-Sleep 60','--name','worker')).output
        Assert-True ($entry.pid -gt 0)
        Assert-Equal (Read-TestJson @('ps')).output.tasks[0].status 'running'
        Read-TestJson @('task','restart','worker') | Out-Null
        Read-TestJson @('task','stop','worker') | Out-Null
        Assert-Equal (Read-TestJson @('ps')).output.tasks[0].status 'stopped'
        Read-TestJson @('task','kill','worker') | Out-Null
    }
    Test-Case 'Task names reject traversal; unsupported restart flag fails' {
        Assert-Equal (Read-TestJson @('task','start','Start-Sleep 1','--name','../bad') -AllowFailure).status 'fail'
        Assert-Equal (Read-TestJson @('task','start','Start-Sleep 1','--restart-on-crash') -AllowFailure).status 'fail'
    }
    Test-Case 'Stale PID identity never stops an unrelated process' {
        Save-AxiomData (Join-Path $workspace '.staging/tasks/pids.json') @{stale=@{name='stale';pid=$PID;start_ticks='0';command='none';cwd=$workspace}}
        $result=Read-TestJson @('task','kill','stale')
        Assert-Equal $result.output.stopped $false
        Assert-True ([bool](Get-Process -Id $PID))
    }
    Test-Case 'Concurrent task starts retain both registrations' {
        $pending=@()
        foreach ($name in @('parallel-one','parallel-two')) {
            $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
            $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.WorkingDirectory=$workspace
            foreach ($argument in @('-NoProfile','-File',(Join-Path $root 'axiom.ps1'),'task','start','Start-Sleep 60','--name',$name,'--workspace',$workspace,'--json')) { $start.ArgumentList.Add($argument) }
            $process=[Diagnostics.Process]::Start($start); $testProcesses.Add($process)
            $pending+=@{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync()}
        }
        foreach ($item in $pending) {
            Assert-True ($item.process.WaitForExit(15000)); Assert-Equal $item.process.ExitCode 0
            $item.stdout.GetAwaiter().GetResult() | ConvertFrom-Json | Out-Null; Assert-Equal $item.stderr.GetAwaiter().GetResult() ''
        }
        $names=(Read-TestJson @('ps')).output.tasks.name
        Assert-True ('parallel-one' -in $names -and 'parallel-two' -in $names)
        foreach ($name in @('parallel-one','parallel-two')) { Read-TestJson @('task','kill',$name) | Out-Null }
    }
    if ($IsWindows) {
        Test-Case 'DPAPI vault roundtrip, redaction, child injection, and removal' {
            $value='dummy-' + [guid]::NewGuid().ToString('N')
            $secret=[Security.SecureString]::new(); foreach ($character in $value.ToCharArray()) { $secret.AppendChar($character) }
            try { $cipher=ConvertFrom-SecureString $secret } finally { $secret.Dispose() }
            Save-AxiomData (Join-Path $workspace '.vault/axiom-keys.json') @{version=1;keys=@{AXIOM_TEST_SECRET=$cipher}}
            Assert-True ((Get-Content -LiteralPath (Join-Path $workspace '.vault/axiom-keys.json') -Raw) -notlike "*$value*")
            Assert-True (Read-TestJson @('vault','get','AXIOM_TEST_SECRET')).output.present
            $result=Read-TestJson @('vault','exec','AXIOM_TEST_SECRET','Write-Output $env:AXIOM_TEST_SECRET')
            Assert-Equal $result.output.stdout.Trim() '[REDACTED]'
            Assert-True (-not [Environment]::GetEnvironmentVariable('AXIOM_TEST_SECRET','Process'))
            Read-TestJson @('vault','remove','AXIOM_TEST_SECRET') | Out-Null
            Assert-Equal (Read-TestJson @('vault','list')).output.names.Count 0
        }
    }
    Test-Case 'Guard reports file/line without leaking matching text' {
        $dummy='gsk_' + ('x' * 40)
        Set-Content -LiteralPath (Join-Path $project '.env') ('EXAMPLE=' + $dummy)
        $result=Invoke-TestCli @('guard','scan','--path','sample','--json') -AllowFailure
        Assert-Equal $result.exit_code 1; Assert-True (-not $result.stdout.Contains($dummy))
        Assert-Equal ($result.stdout | ConvertFrom-Json).output.findings[0].rule 'groq'
        Set-Content -LiteralPath (Join-Path $project '.env') 'EXAMPLE_ONLY=placeholder'
    }
    Test-Case 'MCP initialization, discovery, calls, errors, and EOF' {
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})))
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.WorkingDirectory=$workspace
        foreach ($argument in @('-NoProfile','-File',(Join-Path $root 'axiom.ps1'),'mcp','start','--workspace',$workspace)) { $start.ArgumentList.Add($argument) }
        $process=[Diagnostics.Process]::Start($start); $testProcesses.Add($process)
        $output=$process.StandardOutput.ReadToEndAsync(); $errorText=$process.StandardError.ReadToEndAsync()
        foreach ($request in @(
            @{jsonrpc='2.0';id=0;method='tools/list'},
            @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='test';version='1'}}},
            @{jsonrpc='2.0';method='notifications/initialized'},
            @{jsonrpc='2.0';id=2;method='tools/list'},
            @{jsonrpc='2.0';id=3;method='tools/call';params=@{name='axiom_environment';arguments=@{}}},
            @{jsonrpc='2.0';id=4;method='unknown'}
        )) { $process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 10 -Compress)) }
        $process.StandardInput.Close(); Assert-True ($process.WaitForExit(15000))
        Assert-Equal $process.ExitCode 0
        $responses=@($output.GetAwaiter().GetResult() -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal $responses.Count 5
        Assert-Equal $responses[0].error.code -32002
        Assert-Equal $responses[1].result.protocolVersion '2025-06-18'
        Assert-Equal $responses[2].result.tools.Count 3
        Assert-Equal (($responses[3].result.content[0].text | ConvertFrom-Json).output.workspace_root) $workspace
        Assert-Equal $responses[4].error.code -32601
        Assert-Equal $errorText.GetAwaiter().GetResult() ''
    }
    Test-Case 'Watch preview validates configuration without starting a watcher' {
        Invoke-TestCli @('watch','sample/**/*.txt','--run','Write-Output changed','--dry-run') | Out-Null
        Assert-Equal (Read-TestJson @('watch','sample/**/*.txt','--run','Write-Output changed') -AllowFailure).status 'fail'
    }
    Test-Case 'Watch detects changes and runs a debounced trigger' {
        $marker=Join-Path $workspace 'watch-result.txt'
        $command="Set-Content -LiteralPath '" + $marker.Replace("'","''") + "' -Value changed"
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})))
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.WorkingDirectory=$workspace
        foreach ($argument in @('-NoProfile','-File',(Join-Path $root 'axiom.ps1'),'watch','sample/**/*.txt','--run',$command,'--debounce','200','--workspace',$workspace)) { $start.ArgumentList.Add($argument) }
        $process=[Diagnostics.Process]::Start($start); $testProcesses.Add($process)
        $output=$process.StandardOutput.ReadToEndAsync(); $errors=$process.StandardError.ReadToEndAsync()
        try {
            Start-Sleep -Milliseconds 1500
            Set-Content -LiteralPath (Join-Path $project 'hello.txt') 'watch-change'
            $deadline=[DateTime]::UtcNow.AddSeconds(12)
            while (-not (Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 100 }
            Assert-True (Test-Path -LiteralPath $marker) 'Watch trigger did not run.'
        } finally { if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $output.GetAwaiter().GetResult() | Out-Null; $errors.GetAwaiter().GetResult() | Out-Null }
    }
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        Test-Case 'Staged scanning reads the index even after working-tree cleanup' {
            $repository=Join-Path $workspace 'index-test'; New-Item -ItemType Directory -Path $repository | Out-Null
            $git=(Get-Command git -CommandType Application | Select-Object -First 1).Source
            Invoke-AxiomNative $git @('init','--quiet') $repository | Out-Null
            $dummy='gsk_' + ('z' * 40)
            Set-Content -LiteralPath (Join-Path $repository 'config.txt') $dummy
            Invoke-AxiomNative $git @('add','config.txt') $repository | Out-Null
            Set-Content -LiteralPath (Join-Path $repository 'config.txt') 'clean-working-copy'
            $result=Read-TestJson @('guard','scan','--path','index-test','--staged') -AllowFailure
            Assert-Equal $result.status 'fail'; Assert-Equal $result.output.findings[0].rule 'groq'
        }
    }
    if (-not $SkipBuild -and (Get-Command go -CommandType Application -ErrorAction SilentlyContinue)) {
        Test-Case 'Real Go host and Linux binaries build' {
            $result=Read-TestJson @('compile','sample','linux','amd64')
            $bytes=[IO.File]::ReadAllBytes($result.output.artifacts[0]); Assert-Equal ([Text.Encoding]::ASCII.GetString($bytes[1..3])) 'ELF'
            $result=Read-TestJson @('compile','sample')
            Assert-True (Test-Path -LiteralPath $result.output.artifacts[0])
        }
    }
} finally {
    foreach ($process in $testProcesses) { if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose() }
    $ctx=New-AxiomContext -WorkspaceRoot $workspace
    . (Join-Path $root 'modules/process.ps1')
    foreach ($entry in (Get-PidRegistry $ctx).Values) { $process=Get-AxiomOwnedProcess $entry; if ($process) { $process.Kill($true); $process.WaitForExit(5000) | Out-Null } }
    $resolved=[IO.Path]::GetFullPath($temporary)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'axiom-tests-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Results: $passed passed, $failed failed."
if ($failed) { exit 1 }
$global:LASTEXITCODE=0
