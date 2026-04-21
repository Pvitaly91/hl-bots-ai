@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0guide_conservative_phase_flow.ps1" %*
exit /b %ERRORLEVEL%
