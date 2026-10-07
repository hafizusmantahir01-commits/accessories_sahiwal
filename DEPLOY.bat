@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0tool\deploy.ps1"
echo.
pause