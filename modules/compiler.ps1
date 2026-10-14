function Invoke-AxiomCompiler {
    param([string]$Verb,[string[]]$Params,$Ctx)
    $hostOs=if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
    $hostArch=if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
    $tokens=[Collections.Generic.List[string]]::new(); foreach ($item in (@($Verb)+$Params)) { if ($item) { $tokens.Add($item) } }
    $all=$tokens.Remove('--all-targets'); $bundle=$tokens.Remove('--bundle'); $dry=$Ctx.DryRun -or $tokens.Remove('--dry-run')
    $output=$null; $index=$tokens.IndexOf('--output')
    if ($index -ge 0) {
        if ($index+1 -ge $tokens.Count) { throw '--output requires a directory.' }
        $output=[IO.Path]::GetFullPath($tokens[$index+1]); $tokens.RemoveAt($index+1); $tokens.RemoveAt($index)
    }
    $path=$Ctx.WorkspaceRoot
    if ($tokens.Count -and $tokens[0] -notin @('linux','windows','darwin')) {
        $path=if ([IO.Path]::IsPathRooted($tokens[0])) { $tokens[0] } else { Join-Path $Ctx.WorkspaceRoot $tokens[0] }
        $tokens.RemoveAt(0)
    }
    $path=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $path -AllowRoot
    if (-not (Test-Path -LiteralPath $path)) { throw "Project not found: $path" }
    if ($tokens.Count -gt 2) { throw 'Unexpected compile arguments. Run axiom help compile.' }
    $os=if ($tokens.Count) { $tokens[0] } else { $hostOs }
    $arch=if ($tokens.Count -gt 1) { $tokens[1] } else { $hostArch }
    if ($os -notin @('linux','windows','darwin') -or $arch -notin @('amd64','arm64','386')) { throw 'Unsupported OS or architecture.' }
    $targets=@(if ($all) { @{os='linux';arch='amd64'}; @{os='windows';arch='amd64'}; @{os='darwin';arch='arm64'} } else { @{os=$os;arch=$arch} })
    $language=Get-ProjectLanguage $path
    if ($language -eq 'unknown') { throw 'No supported Go, Rust, Python, or Node project was found.' }
    if ($language -in @('python','node') -and @($targets | Where-Object { $_.os -ne $hostOs -or $_.arch -ne $hostArch }).Count) { throw "$language builds run on the current host only; they do not cross-compile." }
    $artifacts=@(); $plans=@()
    foreach ($target in $targets) {
        if ($language -in @('python','node') -and ($target.os -ne $hostOs -or $target.arch -ne $hostArch)) { throw "$language builds run on the current host only; they do not cross-compile." }
        $outDir=if ($output -and $targets.Count -gt 1) { Join-Path $output "$($target.os)_$($target.arch)" } elseif ($output) { $output } else { Join-Path $Ctx.BinPath "$($target.os)_$($target.arch)" }
        $base=if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.Path]::GetFileNameWithoutExtension($path) } else { Split-Path $path -Leaf }
        $outFile=Join-Path $outDir ($base + $(if ($target.os -eq 'windows') { '.exe' } else { '' }))
        $plan=@{ language=$language; path=$path; target="$($target.os)/$($target.arch)"; output=$outDir; bundle=$bundle }
        $plans+=$plan
        if ($dry) { continue }
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        $cwd=if (Test-Path -LiteralPath $path -PathType Container) { $path } else { Split-Path $path }
        switch ($language) {
            go {
                $tool=(Get-Command go -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
                $saved=@{}; foreach ($key in @('GOOS','GOARCH','CGO_ENABLED')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
                try {
                    $env:GOOS=$target.os; $env:GOARCH=$target.arch; $env:CGO_ENABLED='0'
                    $result=Invoke-AxiomNative $tool @('build','-o',$outFile,$path) $cwd
                } finally { foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') } }
                if ($result.exit_code -ne 0) { throw "Go build failed: $($result.stderr)" }
                $artifacts+=$outFile
            }
            rust {
                if (-not (Test-Path -LiteralPath (Join-Path $cwd 'Cargo.toml'))) { throw 'Rust builds require a Cargo project directory.' }
                $triples=@{ 'linux/amd64'='x86_64-unknown-linux-gnu'; 'linux/arm64'='aarch64-unknown-linux-gnu'; 'windows/amd64'='x86_64-pc-windows-msvc'; 'windows/arm64'='aarch64-pc-windows-msvc'; 'darwin/amd64'='x86_64-apple-darwin'; 'darwin/arm64'='aarch64-apple-darwin' }
                $triple=$triples[$plan.target]; if (-not $triple) { throw 'Unsupported Rust target.' }
                $tool=(Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
                $result=Invoke-AxiomNative $tool @('build','--release','--target',$triple,'--message-format=json-render-diagnostics') $cwd
                if ($result.exit_code -ne 0) { throw "Cargo build failed; check the installed target/linker: $($result.stderr)" }
                foreach ($line in $result.stdout -split "`n") {
                    if (-not $line.Trim()) { continue }
                    $artifactEvent=$line | ConvertFrom-Json
                    if ($artifactEvent.reason -eq 'compiler-artifact' -and $artifactEvent.executable) {
                        $destination=Join-Path $outDir ([IO.Path]::GetFileName($artifactEvent.executable))
                        Copy-Item -LiteralPath $artifactEvent.executable -Destination $destination -Force; $artifacts+=$destination
                    }
                }
            }
            python {
                $tool=(Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
                if ($bundle) {
                    $entry=if (Test-Path -LiteralPath $path -PathType Leaf) { $path } else { Join-Path $path 'main.py' }
                    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'For bundling, pass a Python entry file or a directory with main.py. Install PyInstaller in that Python environment first.' }
                    $result=Invoke-AxiomNative $tool @('-m','PyInstaller','--noconfirm','--onefile','--distpath',$outDir,'--workpath',(Join-Path $outDir 'build'),'--specpath',$outDir,$entry) $cwd
                    if ($result.exit_code -eq 0) { $artifacts+=Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($entry)+$(if ($IsWindows) { '.exe' } else { '' })) }
                } else {
                    $arguments=if (Test-Path -LiteralPath $path -PathType Leaf) { @('-m','py_compile',$path) } else { @('-m','compileall','-q',$path) }
                    $result=Invoke-AxiomNative $tool $arguments $cwd
                }
                if ($result.exit_code -ne 0) { throw "Python build/check failed: $($result.stderr)" }
            }
            node {
                $package=Join-Path $cwd 'package.json'
                if (-not (Test-Path -LiteralPath $package)) { throw 'Node builds require a package.json directory.' }
                $metadata=Get-Content -LiteralPath $package -Raw | ConvertFrom-Json
                if (-not $metadata.scripts.build) { throw 'package.json does not define a build script.' }
                $tool=(Get-Command npm -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
                $result=if ($IsWindows -and $tool -match '\.(cmd|bat)$') { Invoke-AxiomCommand ("& '"+$tool.Replace("'","''")+"' run build") $cwd } else { Invoke-AxiomNative $tool @('run','build') $cwd }
                if ($result.exit_code -ne 0) { throw "Node build failed: $($result.stderr)" }
            }
        }
    }
    Write-AxiomResult 'compile' @{ language=$language; plans=$plans; artifacts=$artifacts; dry_run=$dry } $Ctx $(if ($dry) { 'Build plan (no files changed)' } else { 'Build/check completed' })
}
