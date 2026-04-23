@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0compare_public_client_admission_paths.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
