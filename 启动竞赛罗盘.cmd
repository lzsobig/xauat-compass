@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start-preview.ps1" -OpenBrowser
if errorlevel 1 pause
