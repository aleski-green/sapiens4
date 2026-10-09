param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = "win-$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant())",
    [string]$OutputDirectory,
    [string]$BlindlySource = (Join-Path $PSScriptRoot '../blindly4'),
    [string]$PythonArchive
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo ".build/Sapiens4-$Runtime" }
$destination = [IO.Path]::GetFullPath($OutputDirectory)
$payload = Join-Path $destination 'runtime'
if ($destination -eq $repo -or $repo.StartsWith($destination + [IO.Path]::DirectorySeparatorChar)) { throw 'Output must not replace the source checkout' }
if (-not (Test-Path (Join-Path $BlindlySource 'windows/Blindly4.csproj'))) { throw 'Initialize the Windows-support revision of the Blindly4 submodule first' }

dotnet publish (Join-Path $PSScriptRoot 'Sapiens4.csproj') -c Release -r $Runtime --self-contained true -o $destination
if ($LASTEXITCODE -ne 0) { throw 'Sapiens4 desktop build failed' }
dotnet publish (Join-Path $BlindlySource 'windows/Blindly4.csproj') -c Release -r $Runtime --self-contained true -o (Join-Path $payload 'blindly4/.build/windows')
if ($LASTEXITCODE -ne 0) { throw 'Blindly4 build failed' }
Copy-Item -LiteralPath (Join-Path $repo 'license') -Destination $destination -Recurse -Force
Copy-Item -LiteralPath (Join-Path $BlindlySource 'license') -Destination (Join-Path $payload 'blindly4') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $BlindlySource 'README.md') -Destination (Join-Path $payload 'blindly4/README.md') -Force

foreach ($folder in @('sapiens','prompts','web')) {
    $source = Join-Path $repo $folder
    foreach ($file in (Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]' })) {
        $relative = $file.FullName.Substring($repo.Length + 1)
        $target = Join-Path $payload $relative
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}
Copy-Item -LiteralPath (Join-Path $repo 'sapiens4') -Destination (Join-Path $payload 'sapiens4') -Force

$arch = if ($Runtime -eq 'win-arm64') { 'arm64' } else { 'amd64' }
$hash = if ($arch -eq 'arm64') { 'CBA392BD5C7AED68B26D1B523822CC3D80802C085481DFDE79262EBFC7179D26' } else { '91D828C2DA3A029B41699E918674A0CB379C02CF20DAB9C501306885F837402A' }
if (-not $PythonArchive) {
    $cache = Join-Path $repo '.build/downloads'
    New-Item -ItemType Directory -Force $cache | Out-Null
    $PythonArchive = Join-Path $cache "python-3.13.9-embed-$arch.zip"
    if (-not (Test-Path $PythonArchive)) { Invoke-WebRequest "https://www.python.org/ftp/python/3.13.9/python-3.13.9-embed-$arch.zip" -OutFile $PythonArchive }
}
if ((Get-FileHash -LiteralPath $PythonArchive -Algorithm SHA256).Hash -ne $hash) { throw 'Embedded Python checksum mismatch' }
Expand-Archive -LiteralPath $PythonArchive -DestinationPath (Join-Path $payload 'python') -Force
[IO.File]::WriteAllText((Join-Path $payload 'python/python313._pth'), "python313.zip`n.`n..`nimport site`n", [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $destination 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'terminal.cmd') -Destination (Join-Path $destination 'sapiens4.cmd') -Force
Write-Host "Built $destination/Sapiens4.exe"
