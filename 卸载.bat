@echo off
chcp 65001 >nul
title 五邑大学天翼校园自动登录工具 - 卸载
cd /d "%~dp0"

fltmc >nul 2>&1
if %errorlevel%==0 goto admin

echo.
echo  正在请求管理员权限，请在弹窗中点击"是"...
echo.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:admin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall
echo.
pause
