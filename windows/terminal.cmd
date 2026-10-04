@echo off
setlocal
set PYTHONUTF8=1
"%~dp0runtime\python\python.exe" -X utf8 "%~dp0runtime\sapiens4" %*
