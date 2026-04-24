@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure_public_hlds_firewall.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
