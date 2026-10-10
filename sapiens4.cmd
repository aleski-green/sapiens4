@echo off
setlocal
set PYTHONUTF8=1
if defined SAPIENS_PYTHON (
  "%SAPIENS_PYTHON%" -X utf8 "%~dp0sapiens4" %*
) else (
  py -3 -X utf8 "%~dp0sapiens4" %*
)
