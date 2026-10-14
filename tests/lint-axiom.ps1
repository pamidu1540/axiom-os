#Requires -Version 7.2
[CmdletBinding()]
param([switch]$Fix)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { throw 'Install PSScriptAnalyzer for development lint checks.' }
$paths=@((Join-Path $root 'axiom.ps1'),(Join-Path $root 'kernel'),(Join-Path $root 'modules'),(Join-Path $root 'packaging'),(Join-Path $root 'tests'))
$issues=@(foreach ($path in $paths) { Invoke-ScriptAnalyzer -Path $path -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1') -Fix:$Fix })
if ($Fix) { $issues=@(foreach ($path in $paths) { Invoke-ScriptAnalyzer -Path $path -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1') }) }
if ($issues.Count) { $issues | Format-Table ScriptName,Line,RuleName,Message -AutoSize; exit 1 }
Write-Host 'PASS: source lint.'
$global:LASTEXITCODE=0
