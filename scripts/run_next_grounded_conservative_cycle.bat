@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_next_grounded_conservative_cycle.ps1" %*
exit /b %ERRORLEVEL%
