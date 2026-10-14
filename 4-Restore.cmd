@echo off
chcp 65001 >nul
setlocal
echo.
echo  === Restore monitor values from the latest snapshot ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Adjust-Monitor.ps1" -Restore
echo.
echo  Press any key to close...
pause >nul
endlocal
