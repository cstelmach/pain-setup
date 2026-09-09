@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export-interactions.ps1" %*
set result=%errorlevel%
pause
exit /b %result%
