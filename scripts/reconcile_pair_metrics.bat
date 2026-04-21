@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reconcile_pair_metrics.ps1" %*
exit /b %ERRORLEVEL%
