@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_control_phase_accumulation_probe.ps1" %*
