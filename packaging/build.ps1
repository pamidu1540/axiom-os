#Requires -Version 7.2
[CmdletBinding()]
param([string]$Iscc,[string]$PowerShellHome=$PSHOME,[switch]$SkipInstaller)
$ErrorActionPreference='Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Build the Windows x64 distribution on Windows x64.' }
$root=Split-Path $PSScriptRoot -Parent
$version=(Get-Content (Join-Path $root 'axiom.manifest.json') -Raw | ConvertFrom-Json).version
$dist=Join-Path $root 'dist'
$application=Join-Path $dist 'AxiomOS'
$runtime=Join-Path $PowerShellHome 'pwsh.exe'
if (-not (Test-Path -LiteralPath $runtime)) { throw 'Provide an official PowerShell 7 x64 runtime directory.' }
$signature=Get-AuthenticodeSignature -LiteralPath $runtime
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw 'Use an official Microsoft-signed PowerShell runtime.' }
$runtimeVersion=& $runtime -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0 -or [version]$runtimeVersion -lt [version]'7.2') { throw 'PowerShell runtime must be version 7.2 or newer.' }
if ([IO.Path]::GetFullPath($PowerShellHome).StartsWith([IO.Path]::GetFullPath($application)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Use a runtime outside the build output directory.' }
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework C# compiler is required.' }
New-Item -ItemType Directory -Path $dist -Force | Out-Null
if (Test-Path -LiteralPath $application) {
    $resolved=[IO.Path]::GetFullPath($application)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($dist)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe build output path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Path $application -Force | Out-Null

# Generate a native icon without external design tools.
Add-Type -AssemblyName System.Drawing
$bitmap=[Drawing.Bitmap]::new(256,256)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([Drawing.Color]::FromArgb(12,19,31))
$pen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(94,234,180),20)
$graphics.DrawLines($pen,[Drawing.Point[]]@([Drawing.Point]::new(54,191),[Drawing.Point]::new(128,59),[Drawing.Point]::new(202,191)))
$graphics.DrawLine($pen,86,143,170,143)
$icon=[Drawing.Icon]::FromHandle($bitmap.GetHicon())
$iconPath=Join-Path $PSScriptRoot 'axiom.ico'
$stream=[IO.File]::Create($iconPath)
try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose(); $pen.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $application 'axiom.ico')

$sources=@((Join-Path $PSScriptRoot 'AppCommon.cs'),(Join-Path $PSScriptRoot 'AssemblyInfo.cs'))
& $compiler /nologo /optimize+ /platform:x64 /target:exe /r:System.Web.Extensions.dll "/out:$application/axiom.exe" @sources (Join-Path $PSScriptRoot 'Cli.cs')
if ($LASTEXITCODE -ne 0) { throw 'CLI launcher compilation failed.' }
& $compiler /nologo /optimize+ /platform:x64 /target:winexe /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll "/win32icon:$iconPath" "/out:$application/AxiomOS.exe" @sources (Join-Path $PSScriptRoot 'Desktop.cs')
if ($LASTEXITCODE -ne 0) { throw 'Desktop compilation failed.' }

Write-Host "Bundling PowerShell $runtimeVersion…"
Copy-Item -LiteralPath $PowerShellHome -Destination (Join-Path $application 'runtime') -Recurse
foreach ($name in @('axiom.ps1','axiom.manifest.json','LICENSE','README.md','CHANGELOG.md','THIRD_PARTY_NOTICES.md')) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $application }
foreach ($name in @('kernel','modules','docs')) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $application -Recurse }
foreach ($file in Get-ChildItem -LiteralPath $application -Recurse -Force -File) {
    if ($file.Name -in @('.env','axiom-keys.json','credentials.json','pids.json','settings.json') -or $file.FullName -match '[\\/](\.vault|\.staging|\.secrets)[\\/]') { throw 'Refusing to bundle local credentials or workspace state.' }
}
@{ app_version=$version; powershell_version=$runtimeVersion; runtime_source='Official PowerShell distribution supplied to the build'; architecture='x64'; signing='Unsigned unless signed separately by the publisher' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $application 'BUILD_INFO.json')
$archive=Join-Path $dist "Axiom-OS-$version-Windows-Portable.zip"
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($application,$archive,[IO.Compression.CompressionLevel]::Optimal,$true)
$artifacts=@($archive)
if (-not $SkipInstaller) {
    if (-not $Iscc) { $Iscc=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe' }
    if (-not (Test-Path -LiteralPath $Iscc)) { throw 'Inno Setup 6.7+ is required. Pass -Iscc C:\path\ISCC.exe.' }
    & $Iscc "/DAppVersion=$version" (Join-Path $PSScriptRoot 'installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $artifacts+=Join-Path $dist "Axiom-OS-$version-Setup.exe"
}
$hashes=foreach ($artifact in $artifacts) { "{0}  {1}" -f (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant(),[IO.Path]::GetFileName($artifact) }
$hashes | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii
Write-Host "Built Axiom OS ${version}:"
$artifacts | ForEach-Object { Write-Host $_ }
