@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0review_counted_pair_evidence.ps1" %*
exit /b %ERRORLEVEL%
