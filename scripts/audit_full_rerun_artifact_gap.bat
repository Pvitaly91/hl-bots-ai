@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0audit_full_rerun_artifact_gap.ps1" %*
exit /b %errorlevel%
