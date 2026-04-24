@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0preflight_public_steam_session.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
