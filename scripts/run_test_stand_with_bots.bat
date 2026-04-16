@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PS_SCRIPT=%~dp0run_test_stand_with_bots.ps1"
if not exist "%PS_SCRIPT%" (
    echo Missing launcher implementation: "%PS_SCRIPT%"
    exit /b 1
)

if not "%~1"=="" (
    set "FIRST_ARG=%~1"
    if "!FIRST_ARG:~0,1!"=="-" goto passthrough
)

set "MAP=stalkyard"
if not "%~1"=="" (
    set "MAP=%~1"
    shift
)

set "BOT_COUNT=4"
if not "%~1"=="" (
    set "BOT_COUNT=%~1"
    shift
)

set "BOT_SKILL=3"
if not "%~1"=="" (
    set "BOT_SKILL=%~1"
    shift
)

set "LAB_ROOT="
if not "%1"=="" (
    set "LAB_ROOT=%~1"
    shift
)

set "PS_ARGS=-Map ""%MAP%"" -BotCount ""%BOT_COUNT%"" -BotSkill ""%BOT_SKILL%"""
if defined LAB_ROOT (
    set "PS_ARGS=!PS_ARGS! -LabRoot ""%LAB_ROOT%"""
)
if not "%~1"=="" (
    set "PS_ARGS=!PS_ARGS! %*"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" !PS_ARGS!
exit /b %ERRORLEVEL%

:passthrough
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
