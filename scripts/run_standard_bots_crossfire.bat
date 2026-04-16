@echo off
setlocal

set "MAP=%~1"
if "%MAP%"=="" set "MAP=crossfire"

set "BOT_COUNT=%~2"
if "%BOT_COUNT%"=="" set "BOT_COUNT=4"

set "BOT_SKILL=%~3"
if "%BOT_SKILL%"=="" set "BOT_SKILL=3"

set "LAB_ROOT=%~4"

set "PS_SCRIPT=%~dp0run_standard_bots_crossfire.ps1"

if not exist "%PS_SCRIPT%" (
    echo Missing launcher implementation: "%PS_SCRIPT%"
    exit /b 1
)

if not "%LAB_ROOT%"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Map "%MAP%" -BotCount "%BOT_COUNT%" -BotSkill "%BOT_SKILL%" -LabRoot "%LAB_ROOT%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Map "%MAP%" -BotCount "%BOT_COUNT%" -BotSkill "%BOT_SKILL%"
)
exit /b %ERRORLEVEL%
