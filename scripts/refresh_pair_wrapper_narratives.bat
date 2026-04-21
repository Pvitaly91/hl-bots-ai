@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh_pair_wrapper_narratives.ps1" %*
exit /b %ERRORLEVEL%
