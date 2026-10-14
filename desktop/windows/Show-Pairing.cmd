@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-Pairing.ps1"
if errorlevel 1 echo Pairing details not available.
pause
