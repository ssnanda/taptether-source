@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TapTether.ps1"
if errorlevel 1 echo Installation did not complete. Review the message above.
pause
