@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0guide_treatment_patch_window.ps1" %*
exit /b %ERRORLEVEL%
