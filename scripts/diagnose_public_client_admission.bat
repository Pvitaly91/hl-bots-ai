@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose_public_client_admission.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
