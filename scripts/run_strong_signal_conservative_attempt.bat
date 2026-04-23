@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_strong_signal_conservative_attempt.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
