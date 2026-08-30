@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0rdap.ps1" %*
exit /b %errorlevel%
