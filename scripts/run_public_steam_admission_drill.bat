@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_public_steam_admission_drill.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
