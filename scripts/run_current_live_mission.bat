@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_current_live_mission.ps1" %*
exit /b %errorlevel%
