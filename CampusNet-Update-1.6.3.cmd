@echo off
setlocal DisableDelayedExpansion
set "CNW_CHECK=0"
if not "%~2"=="" goto usage
if /i "%~1"=="--check" set "CNW_CHECK=1"
if not "%~1"=="" if "%CNW_CHECK%"=="0" goto usage
set "CNW_DIR=%~dp0"
set "CNW_EXE=%~dp0CampusNet-Update-1.6.3.exe"
if exist "%CNW_EXE%" goto launch
if not exist "%~dp0tools\build-update.ps1" goto missing
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; & (Join-Path $env:CNW_DIR 'tools\build-update.ps1') -OutputPath $env:CNW_EXE"
if errorlevel 1 goto result
:launch
if "%CNW_CHECK%"=="1" goto check
"%CNW_EXE%"
goto result
:check
"%CNW_EXE%" --check
:result
set "CNW_RESULT=%errorlevel%"
if "%CNW_RESULT%"=="0" if "%CNW_CHECK%"=="1" echo CampusNet v1.6.3 update package check passed.
if "%CNW_RESULT%"=="0" exit /b 0
echo CampusNet update returned exit code %CNW_RESULT%.
if "%CNW_CHECK%"=="0" pause
exit /b %CNW_RESULT%
:missing
echo Extract the full release ZIP or place the matching EXE beside this CMD.
if "%CNW_CHECK%"=="0" pause
exit /b 2
:usage
echo Usage: CampusNet-Update-1.6.3.cmd [--check]
exit /b 64
