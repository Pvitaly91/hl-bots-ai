@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_shadow_profile_review.ps1" %*
set EXIT_CODE=%ERRORLEVEL%
endlocal & exit /b %EXIT_CODE%
