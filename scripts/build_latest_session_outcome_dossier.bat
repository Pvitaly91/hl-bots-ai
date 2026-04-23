@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PS_SCRIPT=%~dp0build_latest_session_outcome_dossier.ps1"
if not exist "%PS_SCRIPT%" (
    echo Missing launcher implementation: "%PS_SCRIPT%"
    exit /b 1
)

if not "%~1"=="" (
    set "FIRST_ARG=%~1"
    if "!FIRST_ARG:~0,1!"=="-" goto passthrough
)

set "PAIR_ROOT="
if not "%~1"=="" (
    set "PAIR_ROOT=%~1"
    shift
)

set "PS_ARGS="
if defined PAIR_ROOT (
    set "PS_ARGS=-PairRoot ""%PAIR_ROOT%"""
)
if not "%~1"=="" (
    set "PS_ARGS=!PS_ARGS! %*"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" !PS_ARGS!
exit /b %ERRORLEVEL%

:passthrough
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
