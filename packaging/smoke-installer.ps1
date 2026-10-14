#Requires -Version 7.2
[CmdletBinding()]
param([string]$Installer=(Join-Path (Split-Path $PSScriptRoot) 'dist/Axiom-OS-1.2.0-Setup.exe'))
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Installer checks require Windows.' }
$key='Software\Microsoft\Windows\CurrentVersion\Uninstall\{A7A44C37-80F8-488F-A38D-A43A69464851}_is1'
foreach ($hive in @('HKCU:','HKLM:')) { if (Test-Path "$hive\$key") { throw 'An Axiom OS installation exists. Use a disposable account or VM for installer testing.' } }
$root=Split-Path $PSScriptRoot -Parent
$temporary=Join-Path $root ('.build/installer-smoke-' + [guid]::NewGuid().ToString('N'))
$target=Join-Path $temporary 'app'
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
$oldPath=[Environment]::GetEnvironmentVariable('PATH','User')
try {
    $process=Start-Process -FilePath ([IO.Path]::GetFullPath($Installer)) -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/CURRENTUSER','/NOICONS','/TASKS=',('/DIR="'+$target+'"')) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'Installer failed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'AxiomOS.exe'))) { throw 'Installed executable missing.' }
    & (Join-Path $PSScriptRoot 'smoke-package.ps1') -Application $target
    $process=Start-Process -FilePath (Join-Path $target 'unins000.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'Uninstaller failed.' }
    if (Test-Path -LiteralPath (Join-Path $target 'AxiomOS.exe')) { throw 'Uninstall left the application executable.' }
    if (Test-Path "HKCU:\$key") { throw 'Uninstall registration was not removed.' }
    if ([Environment]::GetEnvironmentVariable('PATH','User') -ne $oldPath) { throw 'Installer test changed the real user PATH.' }
    Write-Host 'PASS: isolated per-user install, installed runtime, uninstall, and unchanged user PATH.'
} finally {
    if (Test-Path -LiteralPath (Join-Path $target 'unins000.exe')) {
        Start-Process -FilePath (Join-Path $target 'unins000.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -WindowStyle Hidden -Wait | Out-Null
    }
    $resolved=[IO.Path]::GetFullPath($temporary); $base=[IO.Path]::GetFullPath((Join-Path $root '.build'))
    if (-not $resolved.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'installer-smoke-*') { throw 'Unsafe installer-test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
