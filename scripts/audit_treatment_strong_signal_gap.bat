@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0audit_treatment_strong_signal_gap.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
