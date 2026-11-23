@echo off
setlocal
title freeimage local - AMD iGPU Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\win\install.ps1" %*
set EXIT_CODE=%ERRORLEVEL%
echo %CMDCMDLINE% | find /i "/c" >nul
if %ERRORLEVEL%==0 (
    echo.
    pause
)
exit /b %EXIT_CODE%
