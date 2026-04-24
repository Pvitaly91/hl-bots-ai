@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0print_public_external_validation_plan.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
