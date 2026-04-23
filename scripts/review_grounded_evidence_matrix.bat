@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0review_grounded_evidence_matrix.ps1" %*
exit /b %ERRORLEVEL%
