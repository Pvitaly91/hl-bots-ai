@echo off
setlocal EnableExtensions

set "PS_SCRIPT=%~dp0launch_local_hldm_client.ps1"
if not exist "%PS_SCRIPT%" (
    echo Missing launcher implementation: "%PS_SCRIPT%"
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
