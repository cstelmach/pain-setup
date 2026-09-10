@echo off
@REM File attribution
@REM created by Christian Stelmach (chrisp.stel@gmail.com), GitHub: @cstelmach
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export-interactions.ps1" %*
set result=%errorlevel%
pause
exit /b %result%
