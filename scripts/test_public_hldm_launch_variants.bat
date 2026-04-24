@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_public_hldm_launch_variants.ps1" %*
set EXITCODE=%ERRORLEVEL%
endlocal & exit /b %EXITCODE%
