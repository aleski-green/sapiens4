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
    }
    $env:PYTHONUTF8 = '1'
    foreach ($build in @('sapiens/build.py', 'web/shell/build.py')) {
        if ($env:SAPIENS_PYTHON) { & $env:SAPIENS_PYTHON $build }
        elseif (Get-Command py -ErrorAction SilentlyContinue) { & py -3 $build }
        else { & python $build }
        if ($LASTEXITCODE -ne 0) { throw "$build failed" }
    }
    $arguments = @('-X', 'utf8', '-m', 'sapiens', '--port', $Port, '--data-dir', $DataDir)
    if ($Open) { $arguments += '--open' }
    if ($env:SAPIENS_PYTHON) { & $env:SAPIENS_PYTHON @arguments }
    elseif (Get-Command py -ErrorAction SilentlyContinue) { & py -3 @arguments }
    else { & python @arguments }
    exit $LASTEXITCODE
} finally { Pop-Location }
