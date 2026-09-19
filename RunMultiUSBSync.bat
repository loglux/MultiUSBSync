@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MultiUSBSync.ps1"
rem If the script fails to start, keep the window open so the error can be read.
if errorlevel 1 (
    echo.
    echo MultiUSBSync stopped with an error - see the message above.
    pause
)
