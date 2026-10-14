$AxiomVersion = (Get-Content (Join-Path $PSScriptRoot '../axiom.manifest.json') -Raw | ConvertFrom-Json).version

function New-AxiomContext {
    param([string]$WorkspaceRoot, [switch]$Json, [switch]$DryRun)
    if (-not $WorkspaceRoot) { $WorkspaceRoot = if ($env:AXIOM_WORKSPACE) { $env:AXIOM_WORKSPACE } else { (Get-Location).Path } }
    $WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
    if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) { throw "Workspace does not exist: $WorkspaceRoot" }
    $ctx = [pscustomobject]@{
        WorkspaceRoot=$WorkspaceRoot; StagingPath=(Join-Path $WorkspaceRoot '.staging')
        SandboxPath=(Join-Path $WorkspaceRoot '.staging/sandboxes'); TasksPath=(Join-Path $WorkspaceRoot '.staging/tasks')
        BinPath=(Join-Path $WorkspaceRoot 'bin'); SessionFile=(Join-Path $WorkspaceRoot '.staging/.axiom-session.json')
        VaultPath=(Join-Path $WorkspaceRoot '.vault/axiom-keys.json')
        Json=$Json.IsPresent; DryRun=$DryRun.IsPresent; StartTime=[Diagnostics.Stopwatch]::StartNew()
    }
    return $ctx
}

function Write-AxiomJson {
    param([string]$Command, [string]$Status='success', [int]$ExitCode=0, $Output=@{}, [string[]]$Errors=@(), [string[]]$Warnings=@(), $Ctx)
    [ordered]@{ axiom_version=$AxiomVersion; command=$Command; status=$Status; exit_code=$ExitCode; output=$Output; errors=$Errors; warnings=$Warnings; duration_ms=$(if ($Ctx) { [math]::Round($Ctx.StartTime.Elapsed.TotalMilliseconds) } else { 0 }) } | ConvertTo-Json -Depth 16
}

function Write-AxiomResult {
    param([string]$Command, $Output, $Ctx, [string]$Message)
    if ($Ctx.Json) { Write-AxiomJson -Command $Command -Output $Output -Ctx $Ctx }
    else {
        if ($Message) { Write-Host $Message -ForegroundColor Cyan }
        if ($Output) { $Output | ConvertTo-Json -Depth 12 }
    }
}

function Assert-AxiomName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'Use a name of 1–64 letters, digits, underscores, or hyphens; reserved device names are not allowed.' }
}

function Assert-AxiomPathWithin {
    param([string]$Base, [string]$Path, [switch]$AllowRoot)
    $basePath = [IO.Path]::GetFullPath($Base).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (($AllowRoot -and $full.Equals($basePath, $comparison)) -or $full.StartsWith($basePath + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        $walk = $full
        while ($walk) {
            if (Test-Path -LiteralPath $walk) {
                if ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Symbolic links and junctions are not supported for this operation.' }
            }
            $walk = Split-Path $walk -Parent
        }
        return $full
    }
    throw "Path must stay inside $basePath."
}

function Resolve-AxiomChildPath {
    param([string]$Base, [string]$Name)
    Assert-AxiomName $Name
    Assert-AxiomPathWithin $Base (Join-Path $Base $Name)
}

function Save-AxiomData {
    param([string]$Path, $Data)
    $directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-AxiomSession {
    param($Ctx)
    if (Test-Path -LiteralPath $Ctx.SessionFile) { return Get-Content -LiteralPath $Ctx.SessionFile -Raw | ConvertFrom-Json }
    [pscustomobject]@{ session_id='axiom-' + [guid]::NewGuid().ToString('N'); active_sandboxes=@(); running_tasks=@(); workspace_root=$Ctx.WorkspaceRoot }
}
function Save-AxiomSession { param($Session, $Ctx) Save-AxiomData $Ctx.SessionFile $Session }

function Get-ProjectLanguage {
    param([string]$ProjectPath)
    if (Test-Path -LiteralPath $ProjectPath -PathType Leaf) {
        $extension = [IO.Path]::GetExtension($ProjectPath)
        switch ($extension) { '.go' { return 'go' }; '.rs' { return 'rust' }; '.py' { return 'python' }; '.js' { return 'node' }; '.ts' { return 'node' } }
    }
    $walk = if (Test-Path -LiteralPath $ProjectPath -PathType Container) { [IO.Path]::GetFullPath($ProjectPath) } else { Split-Path ([IO.Path]::GetFullPath($ProjectPath)) -Parent }
    for ($i=0; $i -lt 6 -and $walk; $i++) {
        foreach ($entry in @(@('go.mod','go'),@('Cargo.toml','rust'),@('pyproject.toml','python'),@('requirements.txt','python'),@('pytest.ini','python'),@('package.json','node'))) {
            if (Test-Path -LiteralPath (Join-Path $walk $entry[0])) { return $entry[1] }
        }
        $walk = Split-Path $walk -Parent
    }
    'unknown'
}

function Invoke-AxiomNative {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [int]$TimeoutSeconds=300, [hashtable]$EnvironmentVariables=@{})
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$FilePath; $start.WorkingDirectory=$WorkingDirectory; $start.UseShellExecute=$false
    $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in $ArgumentList) { $start.ArgumentList.Add($argument) }
    foreach ($key in $EnvironmentVariables.Keys) { $start.Environment[$key]=$EnvironmentVariables[$key] }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill($true); $process.WaitForExit(); throw "Command exceeded ${TimeoutSeconds}s." }
        [pscustomobject]@{ exit_code=$process.ExitCode; stdout=$stdout.GetAwaiter().GetResult(); stderr=$stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function Invoke-AxiomCommand {
    param([string]$Command, [string]$WorkingDirectory, [int]$TimeoutSeconds=300, [hashtable]$EnvironmentVariables=@{})
    $code = '$ErrorActionPreference="Stop"; $global:LASTEXITCODE=0; try { & { ' + $Command + ' }; exit $global:LASTEXITCODE } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    Invoke-AxiomNative (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) @('-NoProfile','-OutputFormat','Text','-EncodedCommand',$encoded) $WorkingDirectory $TimeoutSeconds -EnvironmentVariables $EnvironmentVariables
}

function Invoke-AxiomHelp {
    param([string]$Subsystem, [switch]$Json)
    $usage = @{
        compile='axiom compile <path> [linux|windows|darwin] [amd64|arm64] [--all-targets] [--bundle]'
        sandbox='axiom sandbox create <project> --name demo | list | diff demo | exec demo "command" | commit demo --yes | destroy demo | prune'
        task='axiom task start "command" --name api [--cwd path] | list | logs api [--follow] | stop api | restart api | kill api'
        env='axiom env check | info | use go|python|jdk21 | pin <sdk> [project]'
        vault='axiom vault set <NAME> | list | get <NAME> | remove <NAME> (Windows encrypted storage; set prompts securely)'
        guard='axiom guard scan [--path directory] [--staged] | check'
        run='axiom run <task> [--config axiom.tasks.json] | --list'
        watch='axiom watch "src/**/*.go" --run "command" [--debounce 500]'
        mcp='axiom mcp start | schema | status (read-only stdio tools)'
    }
    $output = @{ version=$AxiomVersion; usage=$(if ($Subsystem -and $usage.ContainsKey($Subsystem)) { $usage[$Subsystem] } else { $usage }); flags=@('--workspace <directory>','--json','--dry-run','--help','--version') }
    if ($Json) { Write-AxiomJson -Command 'help' -Output $output }
    else { Write-Host "`nAxiom OS $AxiomVersion — developer workspace toolkit`n" -ForegroundColor Cyan; $output | ConvertTo-Json -Depth 6 }
}
