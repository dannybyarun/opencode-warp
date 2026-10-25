@echo off
setlocal
set "PS=powershell.exe"
where powershell.exe >nul 2>nul || set "PS=pwsh.exe"
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0probe.ps1" %*
exit /b %ERRORLEVEL%
