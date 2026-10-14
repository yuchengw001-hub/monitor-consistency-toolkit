@echo off
chcp 65001 >nul
setlocal
echo.
echo  === Monitor DDC/CI Adjust ===
echo.
echo   In the white fullscreen screen, press keys:
echo     Up / Down        brightness  -1 / +1
echo     Left / Right     contrast    -1 / +1
echo     R                R gain      -1     (Shift+R = +1)
echo     G                G gain      -1     (Shift+G = +1)
echo     B                B gain      -1     (Shift+B = +1)
echo     hold Ctrl        step becomes 5
echo     W                background: white / gray / black
echo     Tab              switch to the other screen
echo     Z                undo        H = hide text
echo     Esc              revert ALL changes and quit
echo     Q                keep changes and quit
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Adjust-Monitor.ps1" %*
echo.
echo  Press any key to close...
pause >nul
endlocal
