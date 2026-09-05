#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [switch]$Fix
)

$ErrorActionPreference = "Continue"
$Root = Split-Path $PSScriptRoot -Parent
$Settings = Join-Path $Root "PSScriptAnalyzerSettings.psd1"

Write-Host "`n⚡ Running Axiom OS Lint Check..." -ForegroundColor Magenta

if ($Fix) {
    Write-Host "Applying automated fixes..." -ForegroundColor Cyan
    Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $Settings -Fix -ErrorAction SilentlyContinue
}

$results = Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $Settings
if ($results -and $results.Count -gt 0) {
    Write-Host "⚠ Found $($results.Count) lint issue(s):" -ForegroundColor Yellow
    $results | Format-Table ScriptName, Line, RuleName, Message -AutoSize
    if (-not $Fix) {
        Write-Host "Attempting auto-fix..." -ForegroundColor Cyan
        Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $Settings -Fix -ErrorAction SilentlyContinue
        $remaining = Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $Settings
        if ($remaining -and $remaining.Count -gt 0) {
            Write-Host "Remaining lint warnings (non-blocking):" -ForegroundColor Yellow
            $remaining | Format-Table ScriptName, Line, RuleName, Message -AutoSize
        } else {
            Write-Host "✅ All lint issues were successfully auto-fixed!" -ForegroundColor Green
        }
    }
} else {
    Write-Host "✅ All files passed PSScriptAnalyzer lint with zero warnings!" -ForegroundColor Green
}
