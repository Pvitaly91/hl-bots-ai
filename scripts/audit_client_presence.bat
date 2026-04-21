@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0audit_client_presence.ps1" %*
exit /b %ERRORLEVEL%
