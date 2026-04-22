@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0audit_first_human_snapshot_boundary.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
