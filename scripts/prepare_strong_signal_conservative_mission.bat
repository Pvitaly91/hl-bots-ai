@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare_strong_signal_conservative_mission.ps1" %*
exit /b %ERRORLEVEL%
