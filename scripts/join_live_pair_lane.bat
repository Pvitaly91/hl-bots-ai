@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0join_live_pair_lane.ps1" %*
exit /b %errorlevel%
