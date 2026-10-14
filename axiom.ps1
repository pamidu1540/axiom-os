#Requires -Version 7.2
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kernel/kernel.ps1')
$tokens = [Collections.Generic.List[string]]::new()
foreach ($token in $CliArgs) { $tokens.Add($token) }
$json = $tokens.Remove('--json') -or $tokens.Remove('-Json')
$dry = $tokens.Remove('--dry-run') -or $tokens.Remove('-DryRun')
$ctx = $null
$taskLock=$null; $ownsTaskLock=$false
try {
    $workspace = $env:AXIOM_WORKSPACE
    $index = $tokens.IndexOf('--workspace')
    if ($index -ge 0) {
        if ($index + 1 -ge $tokens.Count) { throw '--workspace requires a directory.' }
        $workspace = $tokens[$index + 1]
        $tokens.RemoveAt($index + 1); $tokens.RemoveAt($index)
    }
    if ($tokens.Contains('--version') -or $tokens.Contains('-Version') -or ($tokens.Count -eq 1 -and $tokens[0] -eq 'version')) {
        if ($json) { Write-AxiomJson -Command 'version' -Output @{ version = $AxiomVersion } }
        else { Write-Output "Axiom OS $AxiomVersion" }
        exit 0
    }
    $help = $tokens.Remove('--help') -or $tokens.Remove('-Help')
    $subsystem = if ($tokens.Count) { $tokens[0].ToLowerInvariant() } else { 'help' }
    if ($help -or $subsystem -eq 'help') {
        $topic = if ($subsystem -eq 'help' -and $tokens.Count -gt 1) { $tokens[1] } elseif ($subsystem -ne 'help') { $subsystem } else { '' }
        Invoke-AxiomHelp $topic -Json:$json
        exit 0
    }
    $verb = if ($tokens.Count -gt 1) { $tokens[1] } else { '' }
    $rest = if ($tokens.Count -gt 2) { $tokens.GetRange(2, $tokens.Count - 2).ToArray() } else { @() }
    $ctx = New-AxiomContext -WorkspaceRoot $workspace -Json:$json -DryRun:$dry
    if ($subsystem -eq 'task' -and $verb -in @('start','stop','kill','restart') -and -not $dry -and $IsWindows) {
        $identity=$ctx.WorkspaceRoot.ToUpperInvariant()
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
        $taskLock=[Threading.Mutex]::new($false,"Local\AxiomTasks-$hash")
        try { $ownsTaskLock=$taskLock.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $ownsTaskLock=$true }
        if (-not $ownsTaskLock) { throw 'Another task operation is still updating this workspace. Retry shortly.' }
    }
    $module = @{ compile='compiler'; sandbox='sandbox'; task='process'; ps='process'; env='env'; vault='guard'; guard='guard'; run='runner'; watch='watcher'; mcp='mcp' }[$subsystem]
    if (-not $module) { throw "Unknown command '$subsystem'. Run axiom --help." }
    . (Join-Path $PSScriptRoot "modules/$module.ps1")
    switch ($subsystem) {
        compile { Invoke-AxiomCompiler $verb $rest $ctx }
        sandbox { Invoke-AxiomSandbox $verb $rest $ctx }
        task { Invoke-AxiomProcess $verb $rest $ctx }
        ps { Invoke-AxiomProcess 'list' @() $ctx }
        env { Invoke-AxiomEnv $verb $rest $ctx }
        vault { Invoke-AxiomGuard 'vault' (@($verb) + $rest) $ctx }
        guard { Invoke-AxiomGuard $verb $rest $ctx }
        run { Invoke-AxiomRunner $verb $rest $ctx }
        watch { Invoke-AxiomWatcher $verb $rest $ctx }
        mcp { Invoke-AxiomMcp $verb $rest $ctx }
    }
    exit 0
} catch {
    if ($json) { Write-AxiomJson -Command 'error' -Status 'fail' -ExitCode 1 -Errors @($_.Exception.Message) -Ctx $ctx }
    else { [Console]::Error.WriteLine("Axiom: $($_.Exception.Message)") }
    exit 1
} finally {
    if ($ownsTaskLock) { $taskLock.ReleaseMutex() }
    if ($taskLock) { $taskLock.Dispose() }
}
