@echo off
rem ============================================================
rem  Login button calibration launcher
rem  English/ASCII only on purpose (cmd codepage safety).
rem  Chinese UI text is printed by tools\calibrate.ps1.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\calibrate.ps1"
if errorlevel 1 (
  echo.
  pause
)
