@echo off
rem ============================================================
rem  WYU ESurfing Auto Login - installer launcher
rem  English/ASCII only on purpose:
rem  cmd.exe mis-parses non-ASCII batch files on some codepages
rem  (mojibake + line desync), so all Chinese text lives in
rem  install.ps1 instead. Do not add non-ASCII characters here.
rem ============================================================
if /i "%~1"=="--elevated-run" goto admin

cd /d "%~dp0"
fltmc >nul 2>&1
if %errorlevel% equ 0 goto admin

echo.
echo  Requesting administrator privileges, please click "Yes"...
echo.
set "CNW_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:CNW_SELF -ArgumentList '--elevated-run' -Verb RunAs"
exit /b

:admin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
