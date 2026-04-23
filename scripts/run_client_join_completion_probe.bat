@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_client_join_completion_probe.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
