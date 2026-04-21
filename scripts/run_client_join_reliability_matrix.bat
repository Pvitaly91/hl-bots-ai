@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_client_join_reliability_matrix.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
