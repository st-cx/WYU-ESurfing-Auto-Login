@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\set-default-account.ps1"
set "CNW_RESULT=%errorlevel%"
pause
exit /b %CNW_RESULT%
