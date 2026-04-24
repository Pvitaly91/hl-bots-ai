@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0preflight_public_network_exposure.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
