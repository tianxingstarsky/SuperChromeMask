@echo off
chcp 65001 >nul
powershell.exe -noProfile -ExecutionPolicy Bypass -File "%~dp0EmergencyRestore.ps1"
