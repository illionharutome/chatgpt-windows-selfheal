@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ChatGPT-SelfHeal.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo [ChatGPT-SelfHeal] failed, exit code: %EXITCODE%
  echo Please keep this window open and check the self-heal log.
  pause
)
exit /b %EXITCODE%
