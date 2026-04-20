@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PS_SCRIPT=%~dp0inject_pair_session_failure.ps1"
if not exist "%PS_SCRIPT%" (
    echo Missing launcher implementation: "%PS_SCRIPT%"
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
