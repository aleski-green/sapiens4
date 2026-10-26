param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = "win-$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant())",
    [string]$OutputDirectory,
    [string]$BlindlySource = (Join-Path $PSScriptRoot '../blindly4'),
    [ValidateSet('msvc','gnullvm')][string]$BlindlyToolchain = 'msvc',
    [string]$PythonArchive,
    [string]$BuildPython = $(if ($env:SAPIENS_PYTHON) { $env:SAPIENS_PYTHON } else { 'python' })
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo ".build/Sapiens4-$Runtime" }
$destination = [IO.Path]::GetFullPath($OutputDirectory)
$payload = Join-Path $destination 'runtime'
if ($destination -eq $repo -or $repo.StartsWith($destination + [IO.Path]::DirectorySeparatorChar)) { throw 'Output must not replace the source checkout' }
if (-not (Test-Path (Join-Path $BlindlySource 'windows/Cargo.toml'))) { throw 'Initialize the Rust revision of the Blindly4 submodule first' }
if (-not (Test-Path (Join-Path $repo 'libs4/web/remote-vendor.js'))) { throw 'Initialize dependencies with git submodule update --init --recursive first' }

dotnet publish (Join-Path $PSScriptRoot 'Sapiens4.csproj') -c Release -r $Runtime --self-contained true -o $destination
if ($LASTEXITCODE -ne 0) { throw 'Sapiens4 desktop build failed' }
foreach ($obsolete in @('runtime/sapiens', 'runtime/prompts', 'runtime/web', 'runtime/sapiens4', 'sapiens4.cmd')) {
    $path = Join-Path $destination $obsolete
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}
& (Join-Path $BlindlySource 'windows/build.ps1') -Runtime $Runtime -Toolchain $BlindlyToolchain
$blindlyOutput = Join-Path $payload 'blindly4/.build/windows'
New-Item -ItemType Directory -Force -Path $blindlyOutput | Out-Null
Copy-Item -LiteralPath (Join-Path $BlindlySource '.build/windows/blindly4.exe') -Destination $blindlyOutput -Force
Copy-Item -LiteralPath (Join-Path $repo 'license') -Destination $destination -Recurse -Force
Copy-Item -LiteralPath (Join-Path $BlindlySource 'license') -Destination (Join-Path $payload 'blindly4') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $BlindlySource 'README.md') -Destination (Join-Path $payload 'blindly4/README.md') -Force
$libsOutput = Join-Path $payload 'libs4'
New-Item -ItemType Directory -Force -Path $libsOutput | Out-Null
foreach ($folder in @('web','license')) {
    Copy-Item -LiteralPath (Join-Path $repo "libs4/$folder") -Destination $libsOutput -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $repo 'libs4/README.md') -Destination $libsOutput -Force

foreach ($folder in @('sapiens','prompts','web')) {
    $source = Join-Path $repo $folder
    foreach ($file in (Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]' })) {
        $relative = $file.FullName.Substring($repo.Length + 1)
        $target = Join-Path $payload $relative
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

& (Join-Path $repo 'libs4/python/package-windows.ps1') -Runtime $Runtime -TargetDirectory (Join-Path $payload 'python') -PythonArchive $PythonArchive -BuildPython $BuildPython
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $destination 'README.md') -Force
Write-Host "Built $destination/Sapiens4.exe"
