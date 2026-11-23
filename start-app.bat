@echo off
setlocal
title freeimage local - AMD iGPU App
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\win\fi.ps1" app %*
if %ERRORLEVEL% neq 0 (
    echo.
    pause
)
