param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime,
    [string]$OutputDirectory,
    [string]$BlindlySource = (Join-Path $PSScriptRoot '../../blindly4'),
    [ValidateSet('msvc','gnullvm')][string]$BlindlyToolchain = 'msvc'
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$target = & ghc --print-target-platform
if ($LASTEXITCODE -ne 0) { throw 'GHC is required to build the Haskell application' }
if (-not $Runtime) {
    $Runtime = if ($target -match '^x86_64-') { 'win-x64' } elseif ($target -match '^aarch64-') { 'win-arm64' } else { throw "Unsupported GHC target: $target" }
}
if (($Runtime -eq 'win-x64' -and $target -notmatch '^x86_64-') -or ($Runtime -eq 'win-arm64' -and $target -notmatch '^aarch64-')) { throw "GHC target $target does not match $Runtime" }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo ".build/Sapiens4-$Runtime" }
$destination = [IO.Path]::GetFullPath($OutputDirectory)
$payload = Join-Path $destination 'runtime'
if ($destination -eq $repo -or $repo.StartsWith($destination + [IO.Path]::DirectorySeparatorChar)) { throw 'Output must not replace the source checkout' }
if (-not (Test-Path (Join-Path $BlindlySource 'windows/Cargo.toml'))) { throw 'Initialize the Rust revision of the Blindly4 submodule first' }
if (-not (Test-Path (Join-Path $repo 'libs4/web/remote-vendor.js'))) { throw 'Initialize dependencies with git submodule update --init --recursive first' }
Push-Location $repo
try {
    & runghc Build.hs
    if ($LASTEXITCODE -ne 0) { throw 'Haskell application build failed' }
} finally { Pop-Location }
& (Join-Path $BlindlySource 'windows/build.ps1') -Runtime $Runtime -Toolchain $BlindlyToolchain
if ($LASTEXITCODE -ne 0) { throw 'Blindly4 build failed' }
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $repo '.build/bin/sapiens-windows.exe') -Destination (Join-Path $destination 'Sapiens4.exe') -Force
foreach ($obsolete in @('runtime/sapiens', 'runtime/python', 'runtime/prompts', 'runtime/web', 'runtime/sapiens4', 'sapiens4.cmd')) {
    $path = Join-Path $destination $obsolete
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}
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
foreach ($folder in @('prompts','web')) {
    Copy-Item -LiteralPath (Join-Path $repo $folder) -Destination $payload -Recurse -Force
}
foreach ($folder in @('.build/bin','.build/web','osspecific/windows')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $payload $folder) | Out-Null
}
Copy-Item -LiteralPath (Join-Path $repo '.build/bin/sapiens4.exe') -Destination (Join-Path $payload '.build/bin') -Force
foreach ($asset in @('app.js','sw.js','guest.js')) {
    Copy-Item -LiteralPath (Join-Path $repo ".build/web/$asset") -Destination (Join-Path $payload '.build/web') -Force
}
foreach ($icon in @('AppIcon.ico','AppIconDark.ico')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $icon) -Destination (Join-Path $payload 'osspecific/windows') -Force
}
& (Join-Path $repo 'libs4/windows/webview2.ps1') -Runtime $Runtime -Destination $destination
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $destination 'README.md') -Force
Write-Host "Built $destination/Sapiens4.exe"
