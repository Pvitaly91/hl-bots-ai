@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PS_SCRIPT=%~dp0evaluate_latest_session_mission.ps1"
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

if defined PAIR_ROOT (
    set "REMAINING_ARGS="
    :collect_remaining
    if "%~1"=="" goto run_with_pair_root
    set "REMAINING_ARGS=!REMAINING_ARGS! %1"
    shift
    goto collect_remaining

    :run_with_pair_root
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -PairRoot "%PAIR_ROOT%" !REMAINING_ARGS!
    exit /b %ERRORLEVEL%
)

:passthrough
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
