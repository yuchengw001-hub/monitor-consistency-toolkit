@echo off
chcp 65001 >nul
setlocal
echo.
echo  === Display Consistency Check ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-DisplayConsistency.ps1" %*
echo.
echo  Press any key to close...
pause >nul
endlocal
