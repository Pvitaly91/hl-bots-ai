@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0discover_hldm_client.ps1" %*
exit /b %errorlevel%
