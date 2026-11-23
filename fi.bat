@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\win\fi.ps1" %*
exit /b %ERRORLEVEL%
