@echo off
chcp 65001 >nul
setlocal
echo.

if "%~1"=="" goto :auto
if "%~2"=="" goto :one

echo  === Compare Two Reports ===
echo   A: %~nx1
echo   B: %~nx2
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-DisplayConsistency.ps1" -Compare "%~1,%~2"
echo.
echo  Press any key to close...
pause >nul
endlocal
exit /b 0

:auto
echo  === Compare Reports (auto) ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-DisplayConsistency.ps1" -Compare auto
echo.
echo  Press any key to close...
pause >nul
endlocal
exit /b 0

:one
echo  Only ONE file was given.
echo.
echo  Either drag TWO report .json files onto this file at the same time,
echo  or just double-click this file to auto-compare everything in this folder.
echo.
pause >nul
endlocal
exit /b 1
