function Get-AxiomToolInfo {
    param([string]$Name,[string[]]$Arguments,$Ctx)
    $tool=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tool) { return @{ tool=$Name; available=$false; path=$null; version=$null } }
    try {
        $result=if ($tool.Source -match '\.(cmd|bat)$') { Invoke-AxiomCommand ("& '" + $tool.Source.Replace("'","''") + "' " + ($Arguments -join ' ')) $Ctx.WorkspaceRoot 15 }
        else { Invoke-AxiomNative $tool.Source $Arguments $Ctx.WorkspaceRoot 15 }
        @{ tool=$Name; available=($result.exit_code -eq 0); path=$tool.Source; version=($result.stdout + $result.stderr).Trim() }
    } catch { @{ tool=$Name; available=$false; path=$tool.Source; version=$null } }
}

function Invoke-AxiomEnv {
    param([string]$Verb,[string[]]$Params,$Ctx)
    switch ($Verb) {
        check {
            $tools=@(Get-AxiomToolInfo 'go' @('version') $Ctx; Get-AxiomToolInfo 'rustc' @('--version') $Ctx; Get-AxiomToolInfo 'python' @('--version') $Ctx; Get-AxiomToolInfo 'node' @('--version') $Ctx; Get-AxiomToolInfo 'npm' @('--version') $Ctx)
            Write-AxiomResult 'env check' @{ powershell=$PSVersionTable.PSVersion.ToString(); tools=$tools } $Ctx 'Optional build tools'
        }
        info {
            Write-AxiomResult 'env info' @{ workspace_root=$Ctx.WorkspaceRoot; powershell=$PSVersionTable.PSVersion.ToString(); platform=[Runtime.InteropServices.RuntimeInformation]::OSDescription; architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); state=$Ctx.StagingPath; build_output=$Ctx.BinPath } $Ctx 'Workspace environment'
        }
        use {
            if (-not $Params.Count) { throw 'Choose go, python, or jdk21.' }
            $script= switch ($Params[0]) {
                go {
                    $tool=Get-Command go -CommandType Application -ErrorAction Stop | Select-Object -First 1
                    '$env:PATH = ''' + (Split-Path $tool.Source).Replace("'","''") + ''' + [IO.Path]::PathSeparator + $env:PATH'
                }
                python {
                    $activate=Join-Path $Ctx.WorkspaceRoot $(if ($IsWindows) { '.venv/Scripts/Activate.ps1' } else { '.venv/bin/Activate.ps1' })
                    if (-not (Test-Path -LiteralPath $activate)) { throw 'No .venv activation script exists in this workspace.' }
                    '. ''' + $activate.Replace("'","''") + "'"
                }
                jdk21 {
                    $root=Join-Path $Ctx.WorkspaceRoot 'sdks/jdk21'
                    if (-not (Test-Path -LiteralPath $root)) { throw 'No JDK exists at sdks/jdk21.' }
                    '$env:JAVA_HOME = ''' + $root.Replace("'","''") + '''; $env:PATH = (Join-Path $env:JAVA_HOME ''bin'') + [IO.Path]::PathSeparator + $env:PATH'
                }
                default { throw 'Supported activation helpers: go, python, jdk21.' }
            }
            if ($Ctx.Json) { Write-AxiomJson -Command 'env use' -Output @{ script=$script; applies_to_parent_shell=$false } -Ctx $Ctx }
            else { Write-Host 'Run this in your current PowerShell session:' -ForegroundColor Cyan; $script }
        }
        pin {
            if (-not $Params.Count) { throw 'Specify an SDK name to record.' }
            $sdk=$Params[0]; Assert-AxiomName $sdk
            $path=if ($Params.Count -gt 1) { Join-Path $Ctx.WorkspaceRoot $Params[1] } else { $Ctx.WorkspaceRoot }
            $path=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $path -AllowRoot
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Project directory does not exist.' }
            if (-not $Ctx.DryRun) { Save-AxiomData (Join-Path $path '.axiom-env') @{ sdk=$sdk; note='Preference metadata only; no SDK download or version switching.' } }
            Write-AxiomResult 'env pin' @{ sdk=$sdk; project=$path; dry_run=$Ctx.DryRun } $Ctx 'SDK preference recorded'
        }
        default { throw 'Use env check, info, use, or pin.' }
    }
}
