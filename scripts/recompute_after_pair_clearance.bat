@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0recompute_after_pair_clearance.ps1" %*
exit /b %ERRORLEVEL%
