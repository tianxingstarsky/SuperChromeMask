@echo off
chcp 65001 >nul
start "" powershell.exe -noProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0SuperMask.ps1"
