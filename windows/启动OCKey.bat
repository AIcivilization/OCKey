@echo off
chcp 65001 >nul
title OCKey Windows
cd /d "%~dp0"

echo ============================================
echo   OCKey Windows  -  本地 OpenCode 网关
echo ============================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [错误] 未检测到 Node.js，请先安装：https://nodejs.org
  pause
  exit /b 1
)

if not exist "node_modules" (
  echo [首次运行] 正在安装依赖，请稍候...
  call npm install
  echo.
)

echo 正在启动服务，地址： http://127.0.0.1:8789
echo 启动后浏览器会自动打开控制台。按 Ctrl+C 可停止服务。
echo.

start "" http://127.0.0.1:8789
call npm run start:server

pause
