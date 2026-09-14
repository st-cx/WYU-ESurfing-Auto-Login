@echo off
chcp 65001 >nul
title 天翼校园自动登录工具 - 校准按钮坐标
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\calibrate.ps1"
