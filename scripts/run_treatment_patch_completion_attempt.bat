@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_treatment_patch_completion_attempt.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
