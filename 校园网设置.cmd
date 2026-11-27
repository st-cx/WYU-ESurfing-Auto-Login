@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0tools\settings.ps1" goto missing
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0tools\settings.ps1"
exit /b %errorlevel%
:missing
echo Extract the complete CampusNet ZIP, then open this settings command again.
pause
exit /b 2
