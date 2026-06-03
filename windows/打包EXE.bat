@echo off
chcp 65001 >nul
title OCKey - 打包 EXE
cd /d "%~dp0"

echo ============================================
echo   OCKey Windows  -  打包成 EXE
echo ============================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [错误] 未检测到 Node.js，请先安装：https://nodejs.org
  pause
  exit /b 1
)

if not exist "node_modules" (
  echo [首次] 正在安装依赖...
  call npm install
  echo.
)

echo 正在打包，首次会下载 Electron 运行时，请耐心等待...
echo.
call npm run build
if errorlevel 1 (
  echo.
  echo [打包失败] 请把上面的错误信息发出来。
  pause
  exit /b 1
)

echo.
echo ============================================
echo   打包完成！产物在 dist 目录：
echo   - 便携版（免安装，双击即用）: dist\OCKey-Portable-1.0.0-Windows.exe
echo   - 安装版: dist\OCKey-Setup-1.0.0-Windows.exe
echo ============================================
start "" "%~dp0dist"
pause
