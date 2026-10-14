#Requires -Version 7.2
[CmdletBinding()]
param([string]$Application=(Join-Path (Split-Path $PSScriptRoot) 'dist/AxiomOS'),[string]$PreviewPath)
$ErrorActionPreference='Stop'
$Application=[IO.Path]::GetFullPath($Application)
$cli=Join-Path $Application 'axiom.exe'; $desktop=Join-Path $Application 'AxiomOS.exe'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('axiom-package-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $temporary "workspace with spaces and 'quote"
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
$oldHome=$env:AXIOM_HOME; $oldWorkspace=$env:AXIOM_WORKSPACE
$env:AXIOM_HOME=Join-Path $temporary 'settings'; $env:AXIOM_WORKSPACE=$workspace
. (Join-Path $Application 'kernel/kernel.ps1')
function Invoke-PackageCli {
    param([string[]]$Arguments)
    $result=Invoke-AxiomNative $cli ($Arguments+'--json') $workspace 120
    if ($result.exit_code -ne 0) { throw $result.stdout + $result.stderr }
    $result.stdout | ConvertFrom-Json
}
try {
    $result=Invoke-AxiomNative $desktop @('--configure',$workspace) $temporary 30
    if ($result.exit_code -ne 0) { throw 'Native workspace setup failed: ' + $result.stderr }
    if (-not (Test-Path -LiteralPath (Join-Path $workspace 'axiom.tasks.json'))) { throw 'Starter tasks were not created.' }
    $version=(Invoke-PackageCli @('--version')).output.version
    if ($version -ne (Get-Content (Join-Path $Application 'axiom.manifest.json') -Raw | ConvertFrom-Json).version) { throw 'Packaged version mismatch.' }
    if ((Invoke-PackageCli @('env','info')).output.workspace_root -ne $workspace) { throw 'Packaged workspace routing failed.' }
    $run=Invoke-PackageCli @('run','hello')
    if ($run.output.tasks[0].stdout -notmatch 'Hello from Axiom OS') { throw 'Packaged task execution failed.' }
    $report=Join-Path $temporary 'diagnostics.json'
    $result=Invoke-AxiomNative $desktop @('--diagnostics',$report) $temporary 30
    if ($result.exit_code -ne 0) { throw 'Desktop diagnostic failed: ' + $result.stderr }
    $diagnostics=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if (-not $diagnostics.runtime -or -not $diagnostics.entry -or -not $diagnostics.desktop) { throw 'Incomplete packaged desktop.' }
    if ($diagnostics.version -ne $version) { throw 'Desktop version does not match the package manifest.' }
    if ($PreviewPath) { Copy-Item -LiteralPath ([IO.Path]::ChangeExtension($report,'.png')) -Destination $PreviewPath -Force }
    $result=Invoke-AxiomNative $desktop @('--check-tools',(Join-Path $temporary 'tools.txt')) $temporary 100
    if ($result.exit_code -ne 0 -or (Get-Content -LiteralPath (Join-Path $temporary 'tools.txt') -Raw) -notmatch 'PowerShell is bundled') { throw 'Desktop tool-check parsing failed: ' + $result.stderr }
    $project=Join-Path $workspace 'project'; New-Item -ItemType Directory -Path $project | Out-Null
    Set-Content -LiteralPath (Join-Path $project 'file.txt') 'test'
    Invoke-PackageCli @('sandbox','create','project','--name','package-test') | Out-Null
    Invoke-PackageCli @('sandbox','diff','package-test') | Out-Null
    Invoke-PackageCli @('sandbox','destroy','package-test') | Out-Null
    $entry=(Invoke-PackageCli @('task','start','Write-Output test; Start-Sleep 60','--name','package-task')).output
    if ($entry.pid -le 0) { throw 'Packaged task start failed.' }
    Invoke-PackageCli @('task','stop','package-task') | Out-Null
    Write-Host 'PASS: bundled PowerShell, native onboarding, CLI quoting, starter tasks, tool checks, snapshots, and managed process lifecycle.'
} finally {
    . (Join-Path $Application 'modules/process.ps1')
    $ctx=New-AxiomContext -WorkspaceRoot $workspace
    foreach ($entry in (Get-PidRegistry $ctx).Values) { $process=Get-AxiomOwnedProcess $entry; if ($process) { $process.Kill($true); $process.WaitForExit(5000) | Out-Null } }
    $env:AXIOM_HOME=$oldHome; $env:AXIOM_WORKSPACE=$oldWorkspace
    $resolved=[IO.Path]::GetFullPath($temporary)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'axiom-package-*') { throw 'Unsafe package-test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
