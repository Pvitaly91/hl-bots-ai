@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_public_crossfire_server.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
