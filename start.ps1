param([switch]$Open, [int]$Port = 4174, [string]$DataDir = (Join-Path $PSScriptRoot '.sapiens4'), [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (-not (Test-Path ./libs4/web/remote-vendor.js)) {
        git submodule update --init --recursive -- libs4
        if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize libs4' }
    }
    if (-not $SkipBuild) {
        if (-not (Test-Path ./blindly4/windows/Cargo.toml)) {
            git submodule update --init --recursive -- blindly4
            if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize Blindly4' }
        }
        & ./blindly4/windows/build.ps1
        if ($LASTEXITCODE -ne 0) { throw 'Blindly4 build failed' }
        & runghc -ihaskell haskell/Build.hs
        if ($LASTEXITCODE -ne 0) { throw 'Haskell application build failed' }
    }
    $arguments = @('--port', $Port, '--data-dir', $DataDir)
    if ($Open) { $arguments += '--open' }
    & ./.build/bin/sapiens4.exe @arguments
    exit $LASTEXITCODE
} finally { Pop-Location }
