@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_public_external_human_trigger_validation.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
