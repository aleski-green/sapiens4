param([switch]$Open, [int]$Port = 4174, [string]$DataDir = (Join-Path $PSScriptRoot '.sapiens4'), [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (-not $SkipBuild) {
        if (-not (Test-Path ./blindly4/windows/Blindly4.csproj)) {
            git submodule update --init --recursive -- blindly4
            if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize Blindly4' }
        }
        & ./blindly4/windows/build.ps1
    }
    $env:PYTHONUTF8 = '1'
    $arguments = @('-X', 'utf8', '-m', 'sapiens', '--port', $Port, '--data-dir', $DataDir)
    if ($Open) { $arguments += '--open' }
    if ($env:SAPIENS_PYTHON) { & $env:SAPIENS_PYTHON @arguments }
    elseif (Get-Command py -ErrorAction SilentlyContinue) { & py -3 @arguments }
    else { & python @arguments }
    exit $LASTEXITCODE
} finally { Pop-Location }
